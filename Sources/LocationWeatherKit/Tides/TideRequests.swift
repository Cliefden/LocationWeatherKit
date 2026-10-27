import Foundation

/// NOAA CO-OPS datagetter `product=predictions` (free, no key).
public enum NOAATideRequest {
    public static let endpoint = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"

    public enum Interval: String, Sendable {
        /// High/low predictions (all stations).
        case hilo
        /// Hourly heights (harmonic stations only — subordinate stations publish hi/lo only).
        case hourly = "h"
    }

    /// One NOAA prediction. `kind` is set for hi/lo, nil for hourly heights.
    public struct Prediction: Sendable, Hashable {
        public let time: Date
        /// Metres above MLLW.
        public let height: Double
        public let kind: TideKind?

        public init(time: Date, height: Double, kind: TideKind?) {
            self.time = time
            self.height = height
            self.kind = kind
        }
    }

    public enum NOAAError: Error, Sendable, Equatable {
        case invalidResponse
        /// The API answered with `{"error": {"message": …}}` (e.g. unknown station).
        case apiError(String)
    }

    /// - Parameters:
    ///   - application: Identifies the app to NOAA (`application=`), e.g. "Lunker".
    public static func predictionsURL(
        stationID: String,
        interval: Interval,
        begin: Date,
        hours: Int,
        application: String
    ) -> URL? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "product", value: "predictions"),
            URLQueryItem(name: "application", value: application),
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "begin_date", value: requestDateFormatter().string(from: begin)),
            URLQueryItem(name: "range", value: String(hours)),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "interval", value: interval.rawValue),
            URLQueryItem(name: "units", value: "metric"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    private struct Response: Decodable {
        let predictions: [Item]?
        let error: APIError?

        struct Item: Decodable {
            let t: String
            let v: String
            let type: String?
        }

        struct APIError: Decodable {
            let message: String
        }
    }

    /// Decodes a predictions response (times in GMT, "yyyy-MM-dd HH:mm"),
    /// chronological. Accepts H/HH/L/LL types and whitespace-padded values.
    public static func parsePredictions(_ data: Data) throws -> [Prediction] {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NOAAError.invalidResponse
        }
        if let error = decoded.error { throw NOAAError.apiError(error.message) }
        guard let items = decoded.predictions else { throw NOAAError.invalidResponse }

        let formatter = responseDateFormatter()
        return items.compactMap { item in
            guard let time = formatter.date(from: item.t),
                  let height = Double(item.v.trimmingCharacters(in: .whitespaces)) else { return nil }
            let kind: TideKind?
            switch item.type?.uppercased() {
            case "H", "HH": kind = .high
            case "L", "LL": kind = .low
            default:        kind = nil
            }
            return Prediction(time: time, height: height, kind: kind)
        }
        .sorted { $0.time < $1.time }
    }

    private static func requestDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyyMMdd HH:mm"
        return formatter
    }

    private static func responseDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}

/// Open-Meteo Marine API `sea_level_height_msl` (free, no key) — the model fallback.
public enum OpenMeteoMarineRequest {
    public static let endpoint = "https://marine-api.open-meteo.com/v1/marine"

    public static func seaLevelURL(latitude: Double, longitude: Double, forecastDays: Int = 3) -> URL? {
        guard OpenMeteoRequest.isValid(latitude: latitude, longitude: longitude) else { return nil }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "sea_level_height_msl"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return components?.url
    }

    /// Parsed marine payload: the non-null samples, plus whether every value was
    /// null (the definite "inland" answer).
    public struct SeaLevel: Sendable, Hashable {
        public let samples: [TideSample]
        public let allNull: Bool
    }

    private struct Response: Decodable {
        let hourly: Hourly
        struct Hourly: Decodable {
            let time: [String]
            let sea_level_height_msl: [Double?]
        }
    }

    /// Times are requested in GMT without an offset ("yyyy-MM-dd'T'HH:mm"), so
    /// they are parsed as GMT regardless of the device zone.
    public static func parseSeaLevel(_ data: Data) throws -> SeaLevel {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TideError.decodingFailed
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")

        var samples: [TideSample] = []
        for (i, timeString) in decoded.hourly.time.enumerated() {
            guard i < decoded.hourly.sea_level_height_msl.count,
                  let height = decoded.hourly.sea_level_height_msl[i],
                  let time = formatter.date(from: timeString) else { continue }
            samples.append(TideSample(time: time, height: height))
        }
        let allNull = !decoded.hourly.time.isEmpty && decoded.hourly.sea_level_height_msl.allSatisfy { $0 == nil }
        return SeaLevel(samples: samples, allNull: allNull)
    }
}
