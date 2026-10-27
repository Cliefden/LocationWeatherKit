import Foundation

/// Open-Meteo forecast client (free, no API key): current conditions with a
/// 3-hour pressure trend, and a multi-day hourly + daily forecast.
///
/// Replaces Lunker's `WeatherService` + `WeatherForecastService` and Sextant's
/// `WeatherService`. App-specific interpretation (Lunker's `FishingCondition` /
/// `WeatherModifier`, Sextant's sailing notes) stays in the apps.
public actor OpenMeteoClient {

    public struct Configuration: Sendable {
        /// Which pressure field drives `CurrentWeather.pressure` and the trend.
        public var pressureKind: PressureKind
        /// Current conditions are cached per ~100 m for this long.
        public var currentCacheLifetime: TimeInterval
        /// Forecasts are cached per ~1 km for this long (memory, plus disk if enabled).
        public var forecastCacheLifetime: TimeInterval
        /// When a forecast refresh fails, a cached forecast up to this old is returned instead.
        public var staleForecastLimit: TimeInterval
        /// Directory for the on-disk forecast cache (e.g. `URL.cachesDirectory/WeatherForecast`).
        /// nil keeps the forecast in memory only.
        public var forecastDiskCacheDirectory: URL?
        /// UserDefaults key for persisted per-place pressure baselines; nil disables persistence.
        public var pressureBaselineKey: String?
        /// UserDefaults suite for the baselines; nil = `.standard`. (A name rather
        /// than a `UserDefaults`, which isn't `Sendable`, so it can cross into the actor.)
        public var pressureBaselineSuiteName: String?

        public init(
            pressureKind: PressureKind = .meanSeaLevel,
            currentCacheLifetime: TimeInterval = 15 * 60,
            forecastCacheLifetime: TimeInterval = 3 * 3600,
            staleForecastLimit: TimeInterval = 24 * 3600,
            forecastDiskCacheDirectory: URL? = nil,
            pressureBaselineKey: String? = "locationweatherkit.weather.pressureBaselines",
            pressureBaselineSuiteName: String? = nil
        ) {
            self.pressureKind = pressureKind
            self.currentCacheLifetime = currentCacheLifetime
            self.forecastCacheLifetime = forecastCacheLifetime
            self.staleForecastLimit = staleForecastLimit
            self.forecastDiskCacheDirectory = forecastDiskCacheDirectory
            self.pressureBaselineKey = pressureBaselineKey
            self.pressureBaselineSuiteName = pressureBaselineSuiteName
        }
    }

    public let configuration: Configuration
    private let loader: any HTTPDataLoader
    private let errorReporter: ErrorReporter?
    private let now: @Sendable () -> Date
    private let currentCache: TTLCache<String, CurrentWeather>
    private let forecastCache: TTLCache<String, WeatherForecast>
    private var baselines: PressureBaselineStore

    /// - Parameters:
    ///   - loader: Network seam; defaults to a session with 15 s / 30 s timeouts.
    ///   - errorReporter: Receives decode/cache-write failures (e.g. `AppLog.reportError`).
    ///   - now: Clock, injectable for tests.
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
        self.currentCache = TTLCache(ttl: configuration.currentCacheLifetime, now: now)
        self.forecastCache = TTLCache(ttl: configuration.forecastCacheLifetime, now: now)
        let defaults: UserDefaults? = configuration.pressureBaselineKey == nil
            ? nil
            : configuration.pressureBaselineSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.baselines = PressureBaselineStore(
            defaults: defaults,
            key: configuration.pressureBaselineKey ?? "",
            now: now()
        )
    }

    // MARK: - Current conditions

    /// Current weather for a coordinate (cached for `currentCacheLifetime`).
    public func currentWeather(latitude: Double, longitude: Double) async throws -> CurrentWeather {
        let key = CoordinateKey.make(latitude, longitude, decimals: 3)
        if let cached = await currentCache.value(for: key) { return cached }

        guard let url = OpenMeteoRequest.currentURL(latitude: latitude, longitude: longitude) else {
            throw WeatherError.invalidResponse
        }
        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw WeatherError.invalidResponse }

        let decoded: OpenMeteoCurrentResponse
        do {
            decoded = try JSONDecoder().decode(OpenMeteoCurrentResponse.self, from: data)
        } catch {
            errorReporter?("weather.decode", error)
            throw WeatherError.decodingFailed
        }

        let fetchedAt = now()
        guard var weather = Self.makeCurrentWeather(decoded, pressureKind: configuration.pressureKind, fetchedAt: fetchedAt) else {
            errorReporter?("weather.decode", WeatherError.decodingFailed)
            throw WeatherError.decodingFailed
        }

        let place = PressureBaselineStore.placeKey(latitude: latitude, longitude: longitude)
        let readings = baselines.record(weather.pressure, place: place, now: fetchedAt)
        weather.pressureTrend = PressureTrend.calculate(
            currentPressure: weather.pressure,
            history: weather.pressureHistory,
            readings: readings,
            now: fetchedAt
        )
        baselines.persist(now: fetchedAt)

        await currentCache.set(weather, for: key)
        return weather
    }

    /// Decodes a current-conditions payload (pure; the trend is left `.stable`
    /// for the caller to compute against its baselines).
    public static func parseCurrentWeather(
        _ data: Data,
        pressureKind: PressureKind = .meanSeaLevel,
        fetchedAt: Date
    ) throws -> CurrentWeather {
        let decoded: OpenMeteoCurrentResponse
        do {
            decoded = try JSONDecoder().decode(OpenMeteoCurrentResponse.self, from: data)
        } catch {
            throw WeatherError.decodingFailed
        }
        guard let weather = makeCurrentWeather(decoded, pressureKind: pressureKind, fetchedAt: fetchedAt) else {
            throw WeatherError.decodingFailed
        }
        return weather
    }

    static func makeCurrentWeather(
        _ decoded: OpenMeteoCurrentResponse,
        pressureKind: PressureKind,
        fetchedAt: Date
    ) -> CurrentWeather? {
        let current = decoded.current
        // Prefer the configured field; fall back to the other rather than fail.
        let pressure: Double
        let kind: PressureKind
        switch (pressureKind, current.pressure_msl, current.surface_pressure) {
        case (.meanSeaLevel, let msl?, _): pressure = msl; kind = .meanSeaLevel
        case (.surface, _, let surface?): pressure = surface; kind = .surface
        case (_, let msl?, _): pressure = msl; kind = .meanSeaLevel
        case (_, _, let surface?): pressure = surface; kind = .surface
        default: return nil
        }

        var history: [PressureSample] = []
        var wind: [WindSample] = []
        if let hourly = decoded.hourly {
            let pressures = kind == .meanSeaLevel ? hourly.pressure_msl : hourly.surface_pressure
            // Carry the last known direction forward across null hours, seeded
            // from the current observation (Sextant's rule).
            var lastDirection = current.wind_direction_10m
            for (i, epoch) in hourly.time.enumerated() {
                let time = Date(timeIntervalSince1970: epoch)
                if let p = element(pressures, i) {
                    history.append(PressureSample(time: time, pressure: p))
                }
                if let speed = element(hourly.wind_speed_10m, i) {
                    if let d = element(hourly.wind_direction_10m, i) { lastDirection = d }
                    wind.append(WindSample(
                        time: time,
                        speed: speed,
                        gusts: element(hourly.wind_gusts_10m, i) ?? speed,
                        direction: lastDirection
                    ))
                }
            }
        }

        return CurrentWeather(
            temperature: current.temperature_2m,
            pressure: pressure,
            pressureKind: kind,
            pressureMSL: current.pressure_msl,
            surfacePressure: current.surface_pressure,
            pressureTrend: .stable,
            windSpeed: current.wind_speed_10m,
            windGusts: current.wind_gusts_10m,
            windDirection: current.wind_direction_10m,
            humidity: current.relative_humidity_2m,
            weatherCode: current.weather_code,
            isDay: current.is_day == 1,
            cloudCover: current.cloud_cover,
            fetchedAt: fetchedAt,
            pressureHistory: history,
            windForecast: wind
        )
    }

    /// Drops cached current conditions (e.g. pull-to-refresh).
    public func clearCurrentCache() async {
        await currentCache.removeAll()
    }

    // MARK: - Forecast

    /// Hourly + daily forecast for `days` days. Served from memory/disk while
    /// younger than `forecastCacheLifetime`; concurrent calls share one download;
    /// when offline, a forecast up to `staleForecastLimit` old is returned.
    public func forecast(latitude: Double, longitude: Double, days: Int = 14) async throws -> WeatherForecast {
        let key = "\(CoordinateKey.make(latitude, longitude, decimals: 2))|\(days)"
        let current = now()

        if let cached = await forecastCache.value(for: key) { return cached }
        if let disk = readDisk(key: key), current.timeIntervalSince(disk.fetchedAt) < configuration.forecastCacheLifetime {
            await forecastCache.set(disk, for: key, storedAt: disk.fetchedAt)
            return disk
        }

        do {
            let loader = self.loader
            let fetchedAt = current
            let fresh = try await forecastCache.value(for: key) {
                try await Self.downloadForecast(latitude: latitude, longitude: longitude, days: days,
                                                loader: loader, fetchedAt: fetchedAt)
            }
            writeDisk(fresh, key: key)
            return fresh
        } catch {
            if let decodeError = error as? WeatherError, decodeError == .decodingFailed {
                errorReporter?("weatherForecast.decode", error)
            }
            let stale = await forecastCache.staleValue(for: key)?.value ?? readDisk(key: key)
            if let stale, current.timeIntervalSince(stale.fetchedAt) < configuration.staleForecastLimit {
                return stale
            }
            throw error
        }
    }

    private static func downloadForecast(
        latitude: Double, longitude: Double, days: Int,
        loader: any HTTPDataLoader, fetchedAt: Date
    ) async throws -> WeatherForecast {
        guard let url = OpenMeteoRequest.forecastURL(latitude: latitude, longitude: longitude, days: days) else {
            throw WeatherError.invalidResponse
        }
        let (data, response) = try await loader.loadData(from: url)
        guard HTTPStatus.isSuccess(response) else { throw WeatherError.invalidResponse }
        return try parseForecast(data, fetchedAt: fetchedAt)
    }

    /// Decodes an hourly/daily forecast payload (pure; testable).
    public static func parseForecast(_ data: Data, fetchedAt: Date) throws -> WeatherForecast {
        let decoded: OpenMeteoForecastResponse
        do {
            decoded = try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
        } catch {
            throw WeatherError.decodingFailed
        }

        var hourly: [HourlyWeatherSample] = []
        if let h = decoded.hourly {
            hourly = h.time.enumerated().map { i, epoch in
                HourlyWeatherSample(
                    time: Date(timeIntervalSince1970: epoch),
                    temperature: element(h.temperature_2m, i),
                    pressure: element(h.pressure_msl, i),
                    surfacePressure: element(h.surface_pressure, i),
                    windSpeed: element(h.wind_speed_10m, i),
                    windGusts: element(h.wind_gusts_10m, i),
                    windDirection: element(h.wind_direction_10m, i),
                    cloudCover: element(h.cloud_cover, i),
                    precipitation: element(h.precipitation, i),
                    weatherCode: element(h.weather_code, i)
                )
            }
        }

        var daily: [DailyWeatherSample] = []
        if let d = decoded.daily {
            daily = d.time.enumerated().map { i, epoch in
                DailyWeatherSample(
                    dayStart: Date(timeIntervalSince1970: epoch),
                    weatherCode: element(d.weather_code, i),
                    temperatureMax: element(d.temperature_2m_max, i),
                    temperatureMin: element(d.temperature_2m_min, i),
                    precipitationSum: element(d.precipitation_sum, i),
                    precipitationProbabilityMax: element(d.precipitation_probability_max, i),
                    windSpeedMax: element(d.wind_speed_10m_max, i),
                    windGustsMax: element(d.wind_gusts_10m_max, i),
                    windDirectionDominant: element(d.wind_direction_10m_dominant, i),
                    sunrise: element(d.sunrise, i).map(Date.init(timeIntervalSince1970:)),
                    sunset: element(d.sunset, i).map(Date.init(timeIntervalSince1970:))
                )
            }
        }

        return WeatherForecast(
            fetchedAt: fetchedAt,
            timeZoneIdentifier: decoded.timezone,
            utcOffsetSeconds: decoded.utc_offset_seconds,
            hourly: hourly,
            daily: daily
        )
    }

    // MARK: Disk cache

    private func cacheFile(key: String) -> URL? {
        guard let dir = configuration.forecastDiskCacheDirectory else { return nil }
        let safe = key.replacingOccurrences(of: "|", with: "_")
        return dir.appending(path: "\(safe).json")
    }

    private func readDisk(key: String) -> WeatherForecast? {
        guard let file = cacheFile(key: key), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WeatherForecast.self, from: data)
    }

    private func writeDisk(_ forecast: WeatherForecast, key: String) {
        guard let dir = configuration.forecastDiskCacheDirectory, let file = cacheFile(key: key) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(forecast).write(to: file, options: .atomic)
        } catch {
            errorReporter?("weatherForecast.cacheWrite", error)
        }
    }
}
