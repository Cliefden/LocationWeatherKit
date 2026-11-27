import Foundation

/// Sea-surface temperature and wave height for coastal points (Open-Meteo
/// Marine, free, no key). Returns nil inland. Cached per ~1 km for an hour.
public actor MarineConditionsClient {
    private let loader: any HTTPDataLoader
    private let errorReporter: ErrorReporter?
    private let reportsTransportErrors: Bool
    private let now: @Sendable () -> Date
    private let cache: TTLCache<String, CachedMarine>

    private struct CachedMarine: Sendable { let value: MarineConditions? }

    public init(
        loader: any HTTPDataLoader = URLSession.boundedTimeouts(),
        errorReporter: ErrorReporter? = nil,
        reportsTransportErrors: Bool = true,
        cacheLifetime: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.errorReporter = errorReporter
        self.reportsTransportErrors = reportsTransportErrors
        self.now = now
        self.cache = TTLCache(ttl: cacheLifetime, now: now)
    }

    /// nil when the model has no sea at this point (inland). Inland answers are cached too.
    public func current(latitude: Double, longitude: Double) async throws -> MarineConditions? {
        let key = CoordinateKey.make(latitude, longitude, decimals: 2)
        if let cached = await cache.value(for: key) { return cached.value }
        guard let url = MarineConditionsRequest.url(latitude: latitude, longitude: longitude) else {
            throw WeatherError.invalidResponse
        }
        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw WeatherError.invalidResponse }
        let conditions: MarineConditions?
        do {
            conditions = try MarineConditionsRequest.parse(data, fetchedAt: now())
        } catch {
            TransportError.report(errorReporter, "marine.decode", error, includingTransportErrors: reportsTransportErrors)
            throw error
        }
        await cache.set(CachedMarine(value: conditions), for: key)
        return conditions
    }
}

/// The nearest live USGS stream gauge (US only): discharge, gauge height,
/// water temperature and the 24 h flow trend, from the USGS Water Data API.
/// Cached per ~100 m for 30 minutes.
public actor USGSWaterClient {
    public struct Configuration: Sendable {
        /// Gauges further away are ignored.
        public var radiusKm: Double
        /// Readings older than this are treated as missing (some gauges stop reporting).
        public var maxReadingAge: TimeInterval
        /// Optional api.data.gov key (raises USGS's per-IP rate limit).
        public var apiKey: String?
        public var cacheLifetime: TimeInterval
        public var reportsTransportErrors: Bool

        public init(
            radiusKm: Double = 25,
            maxReadingAge: TimeInterval = 6 * 3600,
            apiKey: String? = nil,
            cacheLifetime: TimeInterval = 30 * 60,
            reportsTransportErrors: Bool = true
        ) {
            self.radiusKm = radiusKm
            self.maxReadingAge = maxReadingAge
            self.apiKey = apiKey
            self.cacheLifetime = cacheLifetime
            self.reportsTransportErrors = reportsTransportErrors
        }
    }

    public let configuration: Configuration
    private let loader: any HTTPDataLoader
    private let errorReporter: ErrorReporter?
    private let now: @Sendable () -> Date
    private let cache: TTLCache<String, CachedGauge>

    private struct CachedGauge: Sendable { let value: RiverGauge? }

    public init(
        configuration: Configuration = Configuration(),
        loader: any HTTPDataLoader = URLSession.boundedTimeouts(),
        errorReporter: ErrorReporter? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.loader = loader
        self.errorReporter = errorReporter
        self.now = now
        self.cache = TTLCache(ttl: configuration.cacheLifetime, now: now)
    }

    /// Whether the point could have a USGS gauge nearby (the US and its
    /// territories, generously boxed) — skips the request elsewhere.
    public static func isPlausiblyCovered(latitude: Double, longitude: Double) -> Bool {
        // Contiguous US, Alaska, Hawaii, Puerto Rico / USVI, Guam.
        let boxes: [(lat: ClosedRange<Double>, lon: ClosedRange<Double>)] = [
            (24...50, -125...(-66)),
            (51...72, -180...(-129)),
            (18...23, -161...(-154)),
            (17...19, -68...(-64)),
            (13...14, 144...146),
        ]
        return boxes.contains { $0.lat.contains(latitude) && $0.lon.contains(longitude) }
    }

    /// The nearest gauge with a fresh discharge or gauge-height reading, or nil
    /// when there is none within `radiusKm` (or outside the US).
    public func nearestGauge(latitude: Double, longitude: Double) async throws -> RiverGauge? {
        guard Self.isPlausiblyCovered(latitude: latitude, longitude: longitude) else { return nil }
        let key = CoordinateKey.make(latitude, longitude, decimals: 3)
        if let cached = await cache.value(for: key) { return cached.value }

        guard let url = USGSWaterRequest.latestURL(
            latitude: latitude, longitude: longitude, radiusKm: configuration.radiusKm, apiKey: configuration.apiKey
        ) else { throw WeatherError.invalidResponse }
        let readings: [USGSWaterRequest.LatestReading]
        do {
            let (data, response) = try await loader.loadData(from: url)
            guard HTTPStatus.isSuccess(response) else { throw WeatherError.invalidResponse }
            readings = try USGSWaterRequest.parseLatest(data)
        } catch {
            report("usgs.latest", error)
            throw error
        }

        guard var gauge = Self.nearest(
            readings, latitude: latitude, longitude: longitude,
            radiusKm: configuration.radiusKm, maxAge: configuration.maxReadingAge, now: now()
        ) else {
            await cache.set(CachedGauge(value: nil), for: key)
            return nil
        }

        // Name and trend are extras: failures leave them nil.
        let trendParameter: USGSWaterRequest.Parameter = gauge.discharge != nil ? .discharge : .gaugeHeight
        let gaugeID = gauge.id
        async let name = loadName(gaugeID: gaugeID)
        async let trend = loadTrend(gaugeID: gaugeID, parameter: trendParameter)
        gauge.name = await name
        gauge.trend = await trend

        await cache.set(CachedGauge(value: gauge), for: key)
        return gauge
    }

    /// Groups readings by gauge and picks the closest gauge that has a fresh
    /// discharge or gauge height (pure; testable).
    public static func nearest(
        _ readings: [USGSWaterRequest.LatestReading],
        latitude: Double,
        longitude: Double,
        radiusKm: Double,
        maxAge: TimeInterval,
        now: Date
    ) -> RiverGauge? {
        let fresh = readings.filter { now.timeIntervalSince($0.time) <= maxAge }
        let byGauge = Dictionary(grouping: fresh, by: \.gaugeID)
        var best: RiverGauge?
        for (id, gaugeReadings) in byGauge {
            func reading(_ parameter: USGSWaterRequest.Parameter) -> RiverGauge.Reading? {
                gaugeReadings
                    .filter { $0.parameter == parameter }
                    .max { $0.time < $1.time }
                    .map { RiverGauge.Reading(value: $0.value, time: $0.time) }
            }
            let discharge = reading(.discharge)
            let height = reading(.gaugeHeight)
            guard discharge != nil || height != nil, let first = gaugeReadings.first else { continue }
            let distance = GeoDistance.haversineKm(latitude, longitude, first.latitude, first.longitude)
            guard distance <= radiusKm else { continue }
            if let best, best.distanceKm < distance || (best.distanceKm == distance && best.id < id) { continue }
            best = RiverGauge(
                id: id, name: nil, latitude: first.latitude, longitude: first.longitude, distanceKm: distance,
                discharge: discharge, gaugeHeight: height, waterTemperature: reading(.waterTemperature), trend: nil
            )
        }
        return best
    }

    /// Oldest vs newest value of the last 24 h.
    public static func trend(from history: [(time: Date, value: Double)]) -> FlowTrend? {
        guard history.count >= 2, let first = history.first, let last = history.last else { return nil }
        return FlowTrend.between(first.value, last.value)
    }

    private func loadName(gaugeID: String) async -> String? {
        guard let url = USGSWaterRequest.locationURL(gaugeID: gaugeID, apiKey: configuration.apiKey),
              let (data, response) = try? await loader.loadData(from: url),
              HTTPStatus.isSuccess(response) else { return nil }
        return try? USGSWaterRequest.parseLocationName(data)
    }

    private func loadTrend(gaugeID: String, parameter: USGSWaterRequest.Parameter) async -> FlowTrend? {
        guard let url = USGSWaterRequest.historyURL(gaugeID: gaugeID, parameter: parameter, apiKey: configuration.apiKey),
              let (data, response) = try? await loader.loadData(from: url),
              HTTPStatus.isSuccess(response),
              let history = try? USGSWaterRequest.parseHistory(data) else { return nil }
        return Self.trend(from: history)
    }

    private func report(_ operation: String, _ error: any Error) {
        TransportError.report(errorReporter, operation, error, includingTransportErrors: configuration.reportsTransportErrors)
    }
}
