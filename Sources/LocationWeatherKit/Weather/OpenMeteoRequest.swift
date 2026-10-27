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
    public static func forecastURL(latitude: Double, longitude: Double, days: Int) -> URL? {
        guard isValid(latitude: latitude, longitude: longitude), (1...16).contains(days) else { return nil }
        return url([
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: forecastHourlyFields.joined(separator: ",")),
            URLQueryItem(name: "daily", value: forecastDailyFields.joined(separator: ",")),
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "auto"),
        ])
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
