import Foundation

/// Tidal-current set and drift for a coordinate from the best source available
/// (Sextant's `TidalCurrentService`, moved into the package):
///
/// 1. **NOAA CO-OPS current predictions** (`currents_predictions`) in US waters:
///    the caller's preferred station, else the nearest station in `stations`
///    (default: the bundled current-station list — weak-and-variable stations
///    dropped, shallowest bin kept) within `maxStationDistanceKm` (10 km:
///    currents change over a few hundred metres). Requested as `MAX_SLACK`;
///    the current *now* is interpolated between events with NOAA's sine rule.
/// 2. **Open-Meteo Marine model** (`ocean_current_velocity/direction`, ~8 km
///    grid) everywhere else, or when NOAA fails. Label it as a model estimate
///    (`CurrentSource.isModelEstimate`) — it can badly understate tidal streams
///    in channels and harbours.
///
/// Points the model has no current for throw `CurrentError.unavailable`
/// (remembered for `unavailableRetryInterval`), so callers can hide current UI.
/// `modelCurrents` returns the raw model time series (e.g. for a router).
public actor TidalCurrentClient {

    public struct Configuration: Sendable {
        /// Sent to NOAA as `application=`.
        public var applicationName: String
        /// Farthest a station may be and still be used automatically. Always
        /// show the station name and distance.
        public var maxStationDistanceKm: Double
        public var cacheLifetime: TimeInterval
        /// How long a "no model current here" answer is trusted before retrying.
        public var unavailableRetryInterval: TimeInterval
        /// NOAA window: from `noaaLookback` before now (so the previous event
        /// brackets now), `noaaRangeHours` long.
        public var noaaLookback: TimeInterval
        public var noaaRangeHours: Int
        /// Model days for `fetchCurrent` (the "now" value; from 00:00 GMT today).
        public var marineForecastDays: Int
        /// Below this speed the NOAA phase is reported as slack.
        public var slackThresholdKnots: Double
        /// When false, plain transport failures (`NSURLErrorDomain`, cancellation —
        /// see `TransportError.isTransportError`) are not passed to `errorReporter`.
        public var reportsTransportErrors: Bool

        public init(
            applicationName: String,
            maxStationDistanceKm: Double = 10,
            cacheLifetime: TimeInterval = 3600,
            unavailableRetryInterval: TimeInterval = 24 * 3600,
            noaaLookback: TimeInterval = 8 * 3600,
            noaaRangeHours: Int = 56,
            marineForecastDays: Int = 1,
            slackThresholdKnots: Double = 0.2,
            reportsTransportErrors: Bool = true
        ) {
            self.applicationName = applicationName
            self.maxStationDistanceKm = maxStationDistanceKm
            self.cacheLifetime = cacheLifetime
            self.unavailableRetryInterval = unavailableRetryInterval
            self.noaaLookback = noaaLookback
            self.noaaRangeHours = noaaRangeHours
            self.marineForecastDays = marineForecastDays
            self.slackThresholdKnots = slackThresholdKnots
            self.reportsTransportErrors = reportsTransportErrors
        }
    }

    public let configuration: Configuration
    public nonisolated let stations: NOAAStationIndex
    private let loader: any HTTPDataLoader
    private let errorReporter: ErrorReporter?
    private let now: @Sendable () -> Date
    private let cache: TTLCache<String, CurrentData>
    private let seriesCache: TTLCache<String, [CurrentSample]>
    private var unavailableUntil: [String: Date] = [:]

    public init(
        configuration: Configuration,
        stations: NOAAStationIndex = .bundledCurrentStations,
        loader: any HTTPDataLoader = URLSession.boundedTimeouts(request: 15, resource: 40),
        errorReporter: ErrorReporter? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.stations = stations
        self.loader = loader
        self.errorReporter = errorReporter
        self.now = now
        self.cache = TTLCache(ttl: configuration.cacheLifetime, now: now)
        self.seriesCache = TTLCache(ttl: configuration.cacheLifetime, now: now)
    }

    // MARK: - Stations

    /// The station `fetchCurrent` would use: `preferredStationID` if it exists in
    /// the index, else the nearest within `maxStationDistanceKm`.
    public nonisolated func station(
        latitude: Double,
        longitude: Double,
        preferredStationID: String? = nil
    ) -> NOAAStationMatch? {
        if let preferredStationID, let picked = stations.station(id: preferredStationID) {
            return NOAAStationMatch(
                station: picked,
                distanceKm: GeoDistance.haversineKm(latitude, longitude, picked.latitude, picked.longitude)
            )
        }
        guard NOAAStationIndex.isPlausiblyCovered(latitude: latitude, longitude: longitude) else { return nil }
        return stations.nearest(latitude: latitude, longitude: longitude, maxDistanceKm: configuration.maxStationDistanceKm)
    }

    /// Stations for a picker.
    public nonisolated func nearbyStations(
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 50,
        limit: Int = 12
    ) -> [NOAAStationMatch] {
        guard NOAAStationIndex.isPlausiblyCovered(latitude: latitude, longitude: longitude) else { return [] }
        return stations.nearby(latitude: latitude, longitude: longitude, radiusKm: radiusKm, limit: limit)
    }

    // MARK: - Fetch

    /// The current now, from a NOAA station when one is close enough, else the model.
    public func fetchCurrent(
        latitude: Double,
        longitude: Double,
        preferredStationID: String? = nil
    ) async throws -> CurrentData {
        let coordinateKey = CoordinateKey.make(latitude, longitude, decimals: 3)

        // NOAA first. Any failure falls through to the model.
        if let match = station(latitude: latitude, longitude: longitude, preferredStationID: preferredStationID) {
            let noaaKey = "\(coordinateKey)|noaa|\(match.id)"
            if let cached = await cache.value(for: noaaKey) { return cached }
            do {
                let data = try await fetchNOAA(match)
                await cache.set(data, for: noaaKey)
                return data
            } catch {
                report("currents.noaa", error)
            }
        }

        let modelKey = "\(coordinateKey)|model"
        try checkAvailability(modelKey)
        if let cached = await cache.value(for: modelKey) { return cached }

        let samples = try await loadModel(latitude: latitude, longitude: longitude,
                                          days: configuration.marineForecastDays, key: modelKey)
        let fetchedAt = now()
        guard let nowSample = CurrentSample.nearest(in: samples, to: fetchedAt) else { throw CurrentError.unavailable }
        let data = CurrentData(
            speedKnots: nowSample.speedKnots,
            directionDegrees: Int(nowSample.directionDegrees.rounded()),
            fetchedAt: fetchedAt,
            source: .model,
            samples: samples
        )
        await cache.set(data, for: modelKey)
        return data
    }

    /// The Open-Meteo Marine hourly current series for `days` days (from 00:00
    /// GMT today), non-null hours only, cached per ~100 m. Always a model
    /// estimate. Throws `CurrentError.unavailable` where the model has no current.
    public func modelCurrents(latitude: Double, longitude: Double, days: Int = 3) async throws -> [CurrentSample] {
        let coordinateKey = CoordinateKey.make(latitude, longitude, decimals: 3)
        let modelKey = "\(coordinateKey)|model"
        try checkAvailability(modelKey)
        let seriesKey = "\(coordinateKey)|series|\(days)"
        if let cached = await seriesCache.value(for: seriesKey) { return cached }
        let samples = try await loadModel(latitude: latitude, longitude: longitude, days: days, key: modelKey)
        await seriesCache.set(samples, for: seriesKey)
        return samples
    }

    public func clearCache() async {
        await cache.removeAll()
        await seriesCache.removeAll()
        unavailableUntil.removeAll()
    }

    // MARK: NOAA

    private func fetchNOAA(_ match: NOAAStationMatch) async throws -> CurrentData {
        let current = now()
        guard let url = NOAACurrentRequest.predictionsURL(
            stationID: match.id,
            bin: match.bin,
            begin: current.addingTimeInterval(-configuration.noaaLookback),
            hours: configuration.noaaRangeHours,
            application: configuration.applicationName
        ) else { throw CurrentError.invalidResponse }

        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw CurrentError.invalidResponse }
        let events = try NOAACurrentRequest.parsePredictions(data, slackThresholdKnots: configuration.slackThresholdKnots)
        guard let value = CurrentData.interpolate(events, at: current,
                                                  slackThresholdKnots: configuration.slackThresholdKnots) else {
            throw CurrentError.invalidResponse
        }
        return CurrentData(
            speedKnots: value.speedKnots,
            directionDegrees: value.directionDegrees,
            fetchedAt: current,
            source: .noaa(station: match.station, distanceKm: match.distanceKm),
            phase: value.phase,
            events: events
        )
    }

    // MARK: Open-Meteo Marine

    private func checkAvailability(_ key: String) throws {
        guard let until = unavailableUntil[key] else { return }
        if until > now() { throw CurrentError.unavailable }
        unavailableUntil[key] = nil
    }

    private func loadModel(latitude: Double, longitude: Double, days: Int, key: String) async throws -> [CurrentSample] {
        guard let url = OpenMeteoMarineRequest.currentsURL(latitude: latitude, longitude: longitude, forecastDays: days) else {
            throw CurrentError.invalidResponse
        }
        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw CurrentError.invalidResponse }

        let currents: OpenMeteoMarineRequest.Currents
        do {
            currents = try OpenMeteoMarineRequest.parseCurrents(data)
        } catch {
            report("currents.decode", error)
            throw error
        }
        guard !currents.samples.isEmpty else {
            // Only the definite all-null answer is remembered; an empty series may be transient.
            if currents.allNull {
                unavailableUntil[key] = now().addingTimeInterval(configuration.unavailableRetryInterval)
            }
            throw CurrentError.unavailable
        }
        return currents.samples
    }

    private func report(_ operation: String, _ error: any Error) {
        TransportError.report(errorReporter, operation, error,
                              includingTransportErrors: configuration.reportsTransportErrors)
    }
}

extension NOAAStationIndex {
    /// NOAA tidal-current prediction stations bundled with this package
    /// (`NOAACurrentStations.json`, ~2,600 stations, weak-and-variable ones
    /// excluded, shallowest bin each; decoded on first use). Regenerate from
    /// `https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions`
    /// in the compact `{"stations": [[id, name, lat, lon, bin], …]}` form.
    public static let bundledCurrentStations = NOAAStationIndex(bundle: .module, resource: "NOAACurrentStations")
}
