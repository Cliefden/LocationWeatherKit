import Foundation

/// Tides for a coordinate from the best source available:
///
/// 1. **NOAA CO-OPS harmonic predictions** (US coasts and territories): the
///    caller's preferred station, else the nearest station in `stations` within
///    `maxStationDistanceKm`. Hi/lo events plus (optional) hourly heights, MLLW.
/// 2. **Open-Meteo Marine model** (`sea_level_height_msl`, MSL) everywhere else,
///    or when NOAA fails. Label it as a model estimate (`TideSource.isModelEstimate`).
///
/// Inland points (all-null model sea level) throw `TideError.notCoastal`, so
/// callers can hide tide UI; that answer is remembered for `inlandRetryInterval`.
public actor TideClient {

    public struct Configuration: Sendable {
        /// Sent to NOAA as `application=`.
        public var applicationName: String
        /// Farthest a station may be and still be used automatically. Tides can
        /// differ a lot across an estuary — show the station name and distance.
        /// (Sextant used 25 km, Lunker 50 km.)
        public var maxStationDistanceKm: Double
        public var cacheLifetime: TimeInterval
        /// How long an all-null ("inland") model answer is trusted before retrying.
        public var inlandRetryInterval: TimeInterval
        /// NOAA window: from `noaaLookback` before now, `noaaRangeHours` long.
        public var noaaLookback: TimeInterval
        public var noaaRangeHours: Int
        /// Also fetch NOAA hourly heights for a smooth curve (subordinate stations
        /// have none; their samples fall back to the hi/lo points).
        public var includeNOAAHourlyHeights: Bool
        public var marineForecastDays: Int
        /// Minimum non-null model samples to treat a point as coastal.
        public var minimumModelSamples: Int

        public init(
            applicationName: String,
            maxStationDistanceKm: Double = 25,
            cacheLifetime: TimeInterval = 3600,
            inlandRetryInterval: TimeInterval = 24 * 3600,
            noaaLookback: TimeInterval = 12 * 3600,
            noaaRangeHours: Int = 84,
            includeNOAAHourlyHeights: Bool = true,
            marineForecastDays: Int = 3,
            minimumModelSamples: Int = 6
        ) {
            self.applicationName = applicationName
            self.maxStationDistanceKm = maxStationDistanceKm
            self.cacheLifetime = cacheLifetime
            self.inlandRetryInterval = inlandRetryInterval
            self.noaaLookback = noaaLookback
            self.noaaRangeHours = noaaRangeHours
            self.includeNOAAHourlyHeights = includeNOAAHourlyHeights
            self.marineForecastDays = marineForecastDays
            self.minimumModelSamples = minimumModelSamples
        }
    }

    public let configuration: Configuration
    public nonisolated let stations: NOAAStationIndex
    private let loader: any HTTPDataLoader
    private let errorReporter: ErrorReporter?
    private let now: @Sendable () -> Date
    private let cache: TTLCache<String, TideData>
    private var inlandUntil: [String: Date] = [:]

    public init(
        configuration: Configuration,
        stations: NOAAStationIndex = .bundledTideStations,
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
    }

    // MARK: - Stations

    /// The station `fetchTides` would use: `preferredStationID` if it exists in
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

    /// Stations for a picker (Lunker: 120 km, 12 results).
    public nonisolated func nearbyStations(
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 120,
        limit: Int = 12
    ) -> [NOAAStationMatch] {
        guard NOAAStationIndex.isPlausiblyCovered(latitude: latitude, longitude: longitude) else { return [] }
        return stations.nearby(latitude: latitude, longitude: longitude, radiusKm: radiusKm, limit: limit)
    }

    // MARK: - Fetch

    public func fetchTides(
        latitude: Double,
        longitude: Double,
        preferredStationID: String? = nil
    ) async throws -> TideData {
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
                errorReporter?("tides.noaa", error)
            }
        }

        let modelKey = "\(coordinateKey)|model"
        if let until = inlandUntil[modelKey] {
            if until > now() { throw TideError.notCoastal }
            inlandUntil[modelKey] = nil
        }
        if let cached = await cache.value(for: modelKey) { return cached }

        let data = try await fetchModel(latitude: latitude, longitude: longitude, key: modelKey)
        await cache.set(data, for: modelKey)
        return data
    }

    public func clearCache() async {
        await cache.removeAll()
        inlandUntil.removeAll()
    }

    // MARK: NOAA

    private func fetchNOAA(_ match: NOAAStationMatch) async throws -> TideData {
        let begin = now().addingTimeInterval(-configuration.noaaLookback)
        let hours = configuration.noaaRangeHours
        let app = configuration.applicationName
        guard let hiloURL = NOAATideRequest.predictionsURL(
            stationID: match.id, interval: .hilo, begin: begin, hours: hours, application: app
        ) else { throw TideError.invalidResponse }
        let hourlyURL = configuration.includeNOAAHourlyHeights
            ? NOAATideRequest.predictionsURL(stationID: match.id, interval: .hourly, begin: begin, hours: hours, application: app)
            : nil

        let loader = self.loader
        async let hiloTask = Self.loadPredictions(hiloURL, loader: loader)
        async let hourlyTask = Self.loadOptionalPredictions(hourlyURL, loader: loader)

        let hilo = try await hiloTask
        let hourly = await hourlyTask
        let events = hilo.compactMap { p in p.kind.map { TideEvent(kind: $0, time: p.time, heightMeters: p.height) } }
        // A real 3-day window has ~6 extremes; fewer than 2 is not usable.
        guard events.count >= 2 else { throw TideError.invalidResponse }

        let samples = hourly.isEmpty
            ? events.map { TideSample(time: $0.time, height: $0.heightMeters) }
            : hourly.map { TideSample(time: $0.time, height: $0.height) }
        return TideData(
            events: events,
            samples: samples,
            fetchedAt: now(),
            source: .noaa(station: match.station, distanceKm: match.distanceKm)
        )
    }

    private static func loadPredictions(_ url: URL, loader: any HTTPDataLoader) async throws -> [NOAATideRequest.Prediction] {
        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw TideError.invalidResponse }
        return try NOAATideRequest.parsePredictions(data)
    }

    /// Hourly heights are optional (subordinate stations have none): failures yield [].
    private static func loadOptionalPredictions(_ url: URL?, loader: any HTTPDataLoader) async -> [NOAATideRequest.Prediction] {
        guard let url else { return [] }
        return (try? await loadPredictions(url, loader: loader)) ?? []
    }

    // MARK: Open-Meteo Marine

    private func fetchModel(latitude: Double, longitude: Double, key: String) async throws -> TideData {
        guard let url = OpenMeteoMarineRequest.seaLevelURL(
            latitude: latitude, longitude: longitude, forecastDays: configuration.marineForecastDays
        ) else { throw TideError.invalidResponse }
        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw TideError.invalidResponse }

        let seaLevel: OpenMeteoMarineRequest.SeaLevel
        do {
            seaLevel = try OpenMeteoMarineRequest.parseSeaLevel(data)
        } catch {
            errorReporter?("tides.decode", error)
            throw error
        }

        // Only the definite all-null answer is remembered as inland; a merely
        // sparse response may be transient, so it hides the card uncached.
        guard seaLevel.samples.count >= configuration.minimumModelSamples else {
            if seaLevel.allNull {
                inlandUntil[key] = now().addingTimeInterval(configuration.inlandRetryInterval)
            }
            throw TideError.notCoastal
        }

        return TideData(
            events: TideData.findExtremes(in: seaLevel.samples),
            samples: seaLevel.samples,
            fetchedAt: now(),
            source: .model
        )
    }
}
