import Foundation

/// URL builders for the Open-Meteo forecast API (free, no key). Pure, so the
/// exact query each app sends is unit-tested.
public enum OpenMeteoRequest {
    public static let forecastEndpoint = "https://api.open-meteo.com/v1/forecast"

    /// Superset of Lunker's and Sextant's `current=` fields.
    public static let currentFields = [
        "temperature_2m", "relative_humidity_2m", "pressure_msl", "surface_pressure",
        "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m", "weather_code", "is_day", "cloud_cover",
    ]
    /// Hourly fields fetched alongside current conditions (±24 h history for the trend + wind arrows).
    public static let currentHourlyFields = [
        "pressure_msl", "surface_pressure", "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m",
    ]
    /// Hourly fields of the multi-day forecast (superset of Lunker's `WeatherForecastService`).
    public static let forecastHourlyFields = [
        "temperature_2m", "pressure_msl", "surface_pressure", "wind_speed_10m", "wind_gusts_10m",
        "wind_direction_10m", "cloud_cover", "precipitation", "weather_code",
    ]
    public static let forecastDailyFields = [
        "weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_sum",
        "precipitation_probability_max", "wind_speed_10m_max", "wind_gusts_10m_max",
        "wind_direction_10m_dominant", "sunrise", "sunset",
    ]

    /// Current conditions + hourly pressure/wind for `pastHours`…`forecastHours`.
    /// Units are Open-Meteo defaults (°C, km/h, hPa); times are unix seconds.
    public static func currentURL(
        latitude: Double,
        longitude: Double,
        pastHours: Int = 24,
        forecastHours: Int = 24
    ) -> URL? {
        guard isValid(latitude: latitude, longitude: longitude) else { return nil }
        return url([
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentFields.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: currentHourlyFields.joined(separator: ",")),
            URLQueryItem(name: "past_hours", value: String(pastHours)),
            URLQueryItem(name: "forecast_hours", value: String(forecastHours)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
        ])
    }

    /// Hourly + daily forecast for `days` days (Open-Meteo allows up to 16).
    /// `fields` picks the variables (default: the full set). An empty hourly or
    /// daily list omits that block; nil when both are empty.
    public static func forecastURL(
        latitude: Double,
        longitude: Double,
        days: Int,
        fields: OpenMeteoForecastFields = .all
    ) -> URL? {
        guard isValid(latitude: latitude, longitude: longitude), (1...16).contains(days),
              !(fields.hourly.isEmpty && fields.daily.isEmpty) else { return nil }
        var items = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
        ]
        if !fields.hourly.isEmpty {
            items.append(URLQueryItem(name: "hourly", value: fields.hourly.joined(separator: ",")))
        }
        if !fields.daily.isEmpty {
            items.append(URLQueryItem(name: "daily", value: fields.daily.joined(separator: ",")))
        }
        items += [
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return url(items)
    }

    // MARK: Past weather

    /// Recorded model runs from 2022 on, available up to today.
    public static let historicalForecastEndpoint = "https://historical-forecast-api.open-meteo.com/v1/forecast"
    /// ERA5 reanalysis (1940 on, a few days behind), for dates before `historicalForecastStart`.
    public static let archiveEndpoint = "https://archive-api.open-meteo.com/v1/archive"
    /// 2022-01-01T00:00:00Z — the first day `historicalForecastEndpoint` covers.
    public static let historicalForecastStart = Date(timeIntervalSince1970: 1_640_995_200)

    /// Hourly weather (the `forecastHourlyFields`, no daily block) for the UTC
    /// day before `date` through the day after it — wide enough for a snapshot
    /// and its pressure trend at any hour of the local day. The end is clamped
    /// to `now`'s day. Dates from 2022 on use the historical-forecast API,
    /// older ones the ERA5 archive. nil for a future `date` or invalid coordinates.
    public static func historicalURL(
        latitude: Double,
        longitude: Double,
        around date: Date,
        now: Date = Date()
    ) -> URL? {
        guard isValid(latitude: latitude, longitude: longitude), date <= now.addingTimeInterval(3600) else { return nil }
        let start = date.addingTimeInterval(-86_400)
        let end = min(date.addingTimeInterval(86_400), now)
        let endpoint = date >= historicalForecastStart ? historicalForecastEndpoint : archiveEndpoint
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: forecastHourlyFields.joined(separator: ",")),
            URLQueryItem(name: "start_date", value: utcDay(start)),
            URLQueryItem(name: "end_date", value: utcDay(end)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components?.url
    }

    /// "yyyy-MM-dd" of `date` in UTC.
    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private static func url(_ items: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: forecastEndpoint)
        components?.queryItems = items
        return components?.url
    }
}

/// Which Open-Meteo variables `OpenMeteoClient.forecast` requests. Only names in
/// `OpenMeteoRequest.forecastHourlyFields` / `forecastDailyFields` are decoded
/// into `HourlyWeatherSample` / `DailyWeatherSample`; anything else is sent but ignored.
public struct OpenMeteoForecastFields: Sendable, Hashable {
    public var hourly: [String]
    public var daily: [String]

    public init(hourly: [String], daily: [String] = []) {
        self.hourly = hourly
        self.daily = daily
    }

    /// The full hourly + daily set (0.1.0's request).
    public static let all = OpenMeteoForecastFields(
        hourly: OpenMeteoRequest.forecastHourlyFields,
        daily: OpenMeteoRequest.forecastDailyFields
    )

    /// Hourly 10 m wind speed, gusts and direction only — no daily block
    /// (weather routers sampling a grid of cells).
    public static let wind = OpenMeteoForecastFields(
        hourly: ["wind_speed_10m", "wind_gusts_10m", "wind_direction_10m"]
    )

    /// Stable, filename-safe tag for cache keys (FNV-1a of the field lists).
    var cacheTag: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (hourly.joined(separator: ",") + ";" + daily.joined(separator: ",")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "f" + String(hash, radix: 16)
    }
}

// MARK: - Response shapes

struct OpenMeteoCurrentResponse: Decodable {
    let current: Current
    let hourly: Hourly?

    struct Current: Decodable {
        let temperature_2m: Double
        let relative_humidity_2m: Int
        let pressure_msl: Double?
        let surface_pressure: Double?
        let wind_speed_10m: Double
        let wind_gusts_10m: Double?
        let wind_direction_10m: Int
        let weather_code: Int
        let is_day: Int
        let cloud_cover: Double?
    }

    struct Hourly: Decodable {
        let time: [TimeInterval]
        let pressure_msl: [Double?]?
        let surface_pressure: [Double?]?
        let wind_speed_10m: [Double?]?
        let wind_gusts_10m: [Double?]?
        let wind_direction_10m: [Int?]?
    }
}

struct OpenMeteoForecastResponse: Decodable {
    let timezone: String?
    let utc_offset_seconds: Int?
    let hourly: Hourly?
    let daily: Daily?

    struct Hourly: Decodable {
        let time: [TimeInterval]
        let temperature_2m: [Double?]?
        let pressure_msl: [Double?]?
        let surface_pressure: [Double?]?
        let wind_speed_10m: [Double?]?
        let wind_gusts_10m: [Double?]?
        let wind_direction_10m: [Double?]?
        let cloud_cover: [Double?]?
        let precipitation: [Double?]?
        let weather_code: [Int?]?
    }

    struct Daily: Decodable {
        let time: [TimeInterval]
        let weather_code: [Int?]?
        let temperature_2m_max: [Double?]?
        let temperature_2m_min: [Double?]?
        let precipitation_sum: [Double?]?
        let precipitation_probability_max: [Double?]?
        let wind_speed_10m_max: [Double?]?
        let wind_gusts_10m_max: [Double?]?
        let wind_direction_10m_dominant: [Double?]?
        let sunrise: [TimeInterval?]?
        let sunset: [TimeInterval?]?
    }
}

/// `array[i]` for an optional parallel array that may be shorter than `time`.
@inline(__always)
func element<T>(_ array: [T?]?, _ i: Int) -> T? {
    guard let array, i < array.count else { return nil }
    return array[i]
}
