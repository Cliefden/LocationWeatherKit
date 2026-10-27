import Foundation

/// Which Open-Meteo pressure field drives `CurrentWeather.pressure` and the trend.
public enum PressureKind: String, Sendable, Codable {
    /// `pressure_msl` — reduced to mean sea level; what forecasts and barometers
    /// quote. Comparable across elevations (Lunker).
    case meanSeaLevel
    /// `surface_pressure` — at ground elevation (Sextant before adoption; ≈ MSL at sea).
    case surface
}

/// One hour of wind forecast.
public struct WindSample: Sendable, Hashable, Codable, Identifiable {
    public let time: Date
    /// km/h at 10 m.
    public let speed: Double
    /// km/h at 10 m (falls back to `speed` when the API omits the gust).
    public let gusts: Double
    /// Direction the wind blows FROM, degrees. Null hours carry the last known
    /// direction forward (seeded from the current observation).
    public let direction: Int

    public var id: Date { time }
    public var speedKnots: Double { speed * UnitConversion.knotsPerKmh }
    public var gustsKnots: Double { gusts * UnitConversion.knotsPerKmh }
    public var compass: String { Compass.abbreviation(degrees: direction) }

    public init(time: Date, speed: Double, gusts: Double, direction: Int) {
        self.time = time
        self.speed = speed
        self.gusts = gusts
        self.direction = direction
    }
}

/// Current conditions plus ±24 h of hourly pressure and wind.
/// Superset of Lunker's and Sextant's `WeatherService.WeatherData`.
public struct CurrentWeather: Sendable, Hashable {
    /// °C.
    public var temperature: Double
    /// hPa, of `pressureKind`.
    public var pressure: Double
    public var pressureKind: PressureKind
    /// hPa, mean sea level (nil if the API omitted it).
    public var pressureMSL: Double?
    /// hPa, surface (nil if the API omitted it).
    public var surfacePressure: Double?
    public var pressureTrend: PressureTrend
    /// km/h.
    public var windSpeed: Double
    /// km/h (nil if the API omitted it).
    public var windGusts: Double?
    /// Degrees, direction the wind is coming FROM.
    public var windDirection: Int
    /// %.
    public var humidity: Int
    /// WMO code.
    public var weatherCode: Int
    public var isDay: Bool
    /// Total cloud cover, % (nil if the API omitted it).
    public var cloudCover: Double?
    public var fetchedAt: Date
    /// Hourly pressure of `pressureKind`, ±24 h around now (empty if unavailable).
    public var pressureHistory: [PressureSample]
    /// Hourly wind, ±24 h around now (empty if unavailable).
    public var windForecast: [WindSample]

    public init(
        temperature: Double, pressure: Double, pressureKind: PressureKind = .meanSeaLevel,
        pressureMSL: Double? = nil, surfacePressure: Double? = nil,
        pressureTrend: PressureTrend, windSpeed: Double, windGusts: Double? = nil,
        windDirection: Int, humidity: Int, weatherCode: Int, isDay: Bool,
        cloudCover: Double? = nil, fetchedAt: Date,
        pressureHistory: [PressureSample] = [], windForecast: [WindSample] = []
    ) {
        self.temperature = temperature
        self.pressure = pressure
        self.pressureKind = pressureKind
        self.pressureMSL = pressureMSL
        self.surfacePressure = surfacePressure
        self.pressureTrend = pressureTrend
        self.windSpeed = windSpeed
        self.windGusts = windGusts
        self.windDirection = windDirection
        self.humidity = humidity
        self.weatherCode = weatherCode
        self.isDay = isDay
        self.cloudCover = cloudCover
        self.fetchedAt = fetchedAt
        self.pressureHistory = pressureHistory
        self.windForecast = windForecast
    }

    public var pressureInHg: Double { pressure * UnitConversion.inHgPerHPa }
    public var windSpeedKnots: Double { windSpeed * UnitConversion.knotsPerKmh }
    /// Gusts in knots; the sustained speed when no gust was reported.
    public var windGustsKnots: Double { (windGusts ?? windSpeed) * UnitConversion.knotsPerKmh }
    public var beaufortForce: Int { Beaufort.force(knots: windSpeedKnots) }
    /// Localized 16-point compass abbreviation.
    public var windDirectionText: String { Compass.abbreviation(degrees: windDirection) }
    public var weatherDescription: String { WMOWeatherCode.description(for: weatherCode) }
    /// SF Symbol name.
    public var weatherIcon: String { WMOWeatherCode.symbolName(for: weatherCode, isDay: isDay) }
}

/// One hour of forecast weather. Any field may be missing (Open-Meteo nulls
/// values at the edges of a model run). Field names match Lunker's
/// `HourlyWeatherSample` so its `WeatherModifier` keeps compiling.
public struct HourlyWeatherSample: Sendable, Hashable, Codable {
    public let time: Date
    /// °C.
    public var temperature: Double?
    /// hPa, mean sea level.
    public var pressure: Double?
    /// hPa, surface.
    public var surfacePressure: Double?
    /// km/h at 10 m.
    public var windSpeed: Double?
    /// km/h at 10 m.
    public var windGusts: Double?
    /// Degrees, FROM.
    public var windDirection: Double?
    /// %.
    public var cloudCover: Double?
    /// mm in the preceding hour.
    public var precipitation: Double?
    /// WMO code.
    public var weatherCode: Int?

    public init(
        time: Date, temperature: Double? = nil, pressure: Double? = nil, surfacePressure: Double? = nil,
        windSpeed: Double? = nil, windGusts: Double? = nil, windDirection: Double? = nil,
        cloudCover: Double? = nil, precipitation: Double? = nil, weatherCode: Int? = nil
    ) {
        self.time = time
        self.temperature = temperature
        self.pressure = pressure
        self.surfacePressure = surfacePressure
        self.windSpeed = windSpeed
        self.windGusts = windGusts
        self.windDirection = windDirection
        self.cloudCover = cloudCover
        self.precipitation = precipitation
        self.weatherCode = weatherCode
    }
}

/// One local day from Open-Meteo's `daily` block.
public struct DailyWeatherSample: Sendable, Hashable, Codable {
    /// Local midnight of the day (in the forecast's `timeZoneIdentifier`).
    public let dayStart: Date
    public var weatherCode: Int?
    /// °C.
    public var temperatureMax: Double?
    public var temperatureMin: Double?
    /// mm.
    public var precipitationSum: Double?
    /// %.
    public var precipitationProbabilityMax: Double?
    /// km/h.
    public var windSpeedMax: Double?
    public var windGustsMax: Double?
    /// Degrees, FROM.
    public var windDirectionDominant: Double?
    public var sunrise: Date?
    public var sunset: Date?

    public init(
        dayStart: Date, weatherCode: Int? = nil, temperatureMax: Double? = nil, temperatureMin: Double? = nil,
        precipitationSum: Double? = nil, precipitationProbabilityMax: Double? = nil,
        windSpeedMax: Double? = nil, windGustsMax: Double? = nil, windDirectionDominant: Double? = nil,
        sunrise: Date? = nil, sunset: Date? = nil
    ) {
        self.dayStart = dayStart
        self.weatherCode = weatherCode
        self.temperatureMax = temperatureMax
        self.temperatureMin = temperatureMin
        self.precipitationSum = precipitationSum
        self.precipitationProbabilityMax = precipitationProbabilityMax
        self.windSpeedMax = windSpeedMax
        self.windGustsMax = windGustsMax
        self.windDirectionDominant = windDirectionDominant
        self.sunrise = sunrise
        self.sunset = sunset
    }
}

/// Multi-day hourly + daily forecast.
public struct WeatherForecast: Sendable, Hashable, Codable {
    public let fetchedAt: Date
    /// IANA zone Open-Meteo resolved for the coordinate (`timezone=auto`).
    public var timeZoneIdentifier: String?
    public var utcOffsetSeconds: Int?
    public var hourly: [HourlyWeatherSample]
    public var daily: [DailyWeatherSample]

    public init(fetchedAt: Date, timeZoneIdentifier: String? = nil, utcOffsetSeconds: Int? = nil,
                hourly: [HourlyWeatherSample], daily: [DailyWeatherSample]) {
        self.fetchedAt = fetchedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
        self.hourly = hourly
        self.daily = daily
    }

    public var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:))
    }

    /// Mean-sea-level pressure series from the hourly samples.
    public var pressureHistory: [PressureSample] {
        hourly.compactMap { s in s.pressure.map { PressureSample(time: s.time, pressure: $0) } }
    }

    /// Conditions at `date` (nearest hourly sample within `maxDistance`), with
    /// the 3-hour pressure trend when the series has a baseline. Nil when `date`
    /// is outside the forecast. (Lunker's `HourlyConditionsSnapshot.at`.)
    public func snapshot(at date: Date, maxDistance: TimeInterval = 90 * 60) -> WeatherSnapshot? {
        guard let nearest = hourly.min(by: {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }), abs(nearest.time.timeIntervalSince(date)) <= maxDistance else { return nil }

        let trend = nearest.pressure.flatMap {
            PressureTrend.calculate(at: nearest.time, pressure: $0, history: pressureHistory)
        }
        return WeatherSnapshot(sample: nearest, pressureTrend: trend)
    }
}

/// Weather at one moment, read from the hourly forecast.
public struct WeatherSnapshot: Sendable, Hashable {
    public let sample: HourlyWeatherSample
    /// nil when there is no sample ≥3 h earlier.
    public let pressureTrend: PressureTrend?

    public var pressure: Double? { sample.pressure }
    public var windSpeed: Double? { sample.windSpeed }
    public var cloudCover: Double? { sample.cloudCover }
}

public enum WeatherError: LocalizedError, Sendable, Equatable {
    /// Bad coordinate, transport-level failure shape, or a non-2xx response.
    case invalidResponse
    /// The payload did not match the expected Open-Meteo shape.
    case decodingFailed

    public var errorDescription: String? {
        .lwk("Weather unavailable. Please try again later.")
    }
}
