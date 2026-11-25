import Foundation

/// NOAA CO-OPS datagetter `product=currents_predictions` (free, no key).
///
/// Requested as `interval=MAX_SLACK` — the only form subordinate stations
/// support — giving max flood / max ebb / slack events in knots (GMT).
public enum NOAACurrentRequest {
    public static let endpoint = NOAATideRequest.endpoint

    /// - Parameters:
    ///   - bin: The station's current-meter depth bin (`NOAAStation.bin`); omitted when nil.
    ///   - application: Identifies the app to NOAA (`application=`), e.g. "Sextant".
    public static func predictionsURL(
        stationID: String,
        bin: Int?,
        begin: Date,
        hours: Int,
        application: String
    ) -> URL? {
        var components = URLComponents(string: endpoint)
        var items = [
            URLQueryItem(name: "product", value: "currents_predictions"),
            URLQueryItem(name: "application", value: application),
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "begin_date", value: gmtFormatter("yyyyMMdd HH:mm").string(from: begin)),
            URLQueryItem(name: "range", value: String(hours)),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "interval", value: "MAX_SLACK"),
            URLQueryItem(name: "units", value: "english"),   // knots
            URLQueryItem(name: "format", value: "json"),
        ]
        if let bin { items.append(URLQueryItem(name: "bin", value: String(bin))) }
        components?.queryItems = items
        return components?.url
    }

    private struct Response: Decodable {
        let current_predictions: Predictions?
        let error: APIError?

        struct Predictions: Decodable {
            let cp: [Prediction]
        }

        struct Prediction: Decodable {
            let time: String
            let velocityMajor: FlexibleDouble
            let meanFloodDir: FlexibleDouble?
            let meanEbbDir: FlexibleDouble?
            let kind: String?

            enum CodingKeys: String, CodingKey {
                case time = "Time"
                case velocityMajor = "Velocity_Major"
                case meanFloodDir, meanEbbDir
                case kind = "Type"
            }
        }

        struct APIError: Decodable {
            let message: String
        }
    }

    /// CO-OPS sends numbers, but occasionally as strings; accept both.
    private struct FlexibleDouble: Decodable {
        let value: Double?
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let string = try? container.decode(String.self) {
                value = Double(string.trimmingCharacters(in: .whitespaces))
            } else {
                value = nil
            }
        }
    }

    /// Decodes a `MAX_SLACK` payload into chronological events. `Velocity_Major`
    /// is signed: positive = flood (toward `meanFloodDir`), negative = ebb
    /// (toward `meanEbbDir`). Rows without a usable time or velocity are dropped.
    /// Throws `NOAATideRequest.NOAAError` (`.apiError` for `{"error": …}`).
    public static func parsePredictions(_ data: Data, slackThresholdKnots: Double = 0.2) throws -> [CurrentEvent] {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw NOAATideRequest.NOAAError.invalidResponse
        }
        if let error = decoded.error { throw NOAATideRequest.NOAAError.apiError(error.message) }
        guard let rows = decoded.current_predictions?.cp else { throw NOAATideRequest.NOAAError.invalidResponse }

        let formatter = gmtFormatter("yyyy-MM-dd HH:mm")
        return rows.compactMap { row in
            guard let time = formatter.date(from: row.time),
                  let v = row.velocityMajor.value, v.isFinite else { return nil }
            let kind: CurrentEventKind
            switch row.kind?.lowercased() {
            case "flood": kind = .flood
            case "ebb": kind = .ebb
            case "slack": kind = .slack
            default: kind = abs(v) < slackThresholdKnots ? .slack : (v > 0 ? .flood : .ebb)
            }
            let direction: Double? = kind == .slack ? nil : (v >= 0 ? row.meanFloodDir?.value : row.meanEbbDir?.value)
            return CurrentEvent(
                kind: kind,
                time: time,
                speedKnots: kind == .slack ? 0 : abs(v),
                directionDegrees: direction.map { Int($0.rounded()) }
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func gmtFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Open-Meteo Marine currents

extension OpenMeteoMarineRequest {
    /// `ocean_current_velocity` / `ocean_current_direction` hourly for
    /// `forecastDays` days (from 00:00 GMT today), unix times.
    public static func currentsURL(latitude: Double, longitude: Double, forecastDays: Int = 1) -> URL? {
        guard OpenMeteoRequest.isValid(latitude: latitude, longitude: longitude), (1...16).contains(forecastDays) else {
            return nil
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "ocean_current_velocity,ocean_current_direction"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return components?.url
    }

    /// Parsed marine currents: the non-null hours (km/h converted to knots),
    /// plus whether every hour was null (inland / outside the ocean model).
    public struct Currents: Sendable, Hashable {
        public let samples: [CurrentSample]
        public let allNull: Bool
    }

    private struct CurrentsResponse: Decodable {
        let hourly: Hourly
        struct Hourly: Decodable {
            let time: [TimeInterval]
            let ocean_current_velocity: [Double?]?
            let ocean_current_direction: [Double?]?
        }
    }

    /// Decodes a `currentsURL` payload. Velocity arrives in km/h (Open-Meteo's
    /// default) and is converted to knots; direction is where the current flows TOWARD.
    public static func parseCurrents(_ data: Data) throws -> Currents {
        let decoded: CurrentsResponse
        do {
            decoded = try JSONDecoder().decode(CurrentsResponse.self, from: data)
        } catch {
            throw CurrentError.decodingFailed
        }
        let hourly = decoded.hourly
        var samples: [CurrentSample] = []
        for (i, epoch) in hourly.time.enumerated() {
            guard let velocity = element(hourly.ocean_current_velocity, i),
                  let direction = element(hourly.ocean_current_direction, i),
                  velocity.isFinite, direction.isFinite else { continue }
            samples.append(CurrentSample(
                time: Date(timeIntervalSince1970: epoch),
                speedKnots: velocity * UnitConversion.knotsPerKmh,
                directionDegrees: direction
            ))
        }
        let allNull = !hourly.time.isEmpty && samples.isEmpty
        return Currents(samples: samples, allNull: allNull)
    }
}
