import Foundation

// MARK: - Open-Meteo Marine (sea-surface temperature)

/// Open-Meteo Marine `current=sea_surface_temperature,wave_height` (free, no key).
public enum MarineConditionsRequest {
    public static func url(latitude: Double, longitude: Double) -> URL? {
        guard OpenMeteoRequest.isValid(latitude: latitude, longitude: longitude) else { return nil }
        var components = URLComponents(string: OpenMeteoMarineRequest.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "sea_surface_temperature,wave_height"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return components?.url
    }

    private struct Response: Decodable {
        let current: Current?
        struct Current: Decodable {
            let time: TimeInterval
            let sea_surface_temperature: Double?
            let wave_height: Double?
        }
    }

    /// nil when the point has no sea-surface temperature (inland or ice).
    public static func parse(_ data: Data, fetchedAt: Date) throws -> MarineConditions? {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WeatherError.decodingFailed
        }
        guard let current = decoded.current, let sst = current.sea_surface_temperature else { return nil }
        return MarineConditions(
            seaSurfaceTemperature: sst,
            waveHeight: current.wave_height,
            time: Date(timeIntervalSince1970: current.time),
            fetchedAt: fetchedAt
        )
    }
}

// MARK: - USGS Water Data API (OGC)

/// USGS Water Data OGC API (`api.waterdata.usgs.gov/ogcapi/v1`), the replacement
/// for the WaterServices API USGS retires in February 2027. Free, no key
/// (an optional api.data.gov key raises the rate limit).
public enum USGSWaterRequest {
    public static let base = "https://api.waterdata.usgs.gov/ogcapi/v1/collections"

    public enum Parameter: String, Sendable, CaseIterable {
        /// Discharge, ft³/s.
        case discharge = "00060"
        /// Gauge height, ft.
        case gaugeHeight = "00065"
        /// Water temperature, °C.
        case waterTemperature = "00010"
    }

    /// Latest reading of each parameter for every gauge in a box around the point.
    public static func latestURL(latitude: Double, longitude: Double, radiusKm: Double, apiKey: String? = nil) -> URL? {
        guard OpenMeteoRequest.isValid(latitude: latitude, longitude: longitude), radiusKm > 0 else { return nil }
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * max(0.01, cos(latitude * .pi / 180)))
        let bbox = [longitude - dLon, latitude - dLat, longitude + dLon, latitude + dLat]
            .map { String(format: "%.4f", $0) }
            .joined(separator: ",")
        return url("latest-continuous/items", [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "bbox", value: bbox),
            URLQueryItem(name: "parameter_code", value: Parameter.allCases.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "properties", value: "monitoring_location_id,parameter_code,time,value"),
            URLQueryItem(name: "limit", value: "500"),
        ], apiKey: apiKey)
    }

    /// The last 24 h of one parameter at one gauge.
    public static func historyURL(gaugeID: String, parameter: Parameter, apiKey: String? = nil) -> URL? {
        url("continuous/items", [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "monitoring_location_id", value: gaugeID),
            URLQueryItem(name: "parameter_code", value: parameter.rawValue),
            URLQueryItem(name: "time", value: "PT24H"),
            URLQueryItem(name: "properties", value: "time,value"),
            URLQueryItem(name: "skipGeometry", value: "true"),
            URLQueryItem(name: "limit", value: "1000"),
        ], apiKey: apiKey)
    }

    /// Station metadata (name) for one gauge.
    public static func locationURL(gaugeID: String, apiKey: String? = nil) -> URL? {
        guard let escaped = gaugeID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return url("monitoring-locations/items/\(escaped)", [
            URLQueryItem(name: "f", value: "json"),
            URLQueryItem(name: "skipGeometry", value: "true"),
        ], apiKey: apiKey)
    }

    private static func url(_ path: String, _ items: [URLQueryItem], apiKey: String?) -> URL? {
        var components = URLComponents(string: "\(base)/\(path)")
        var items = items
        if let apiKey, !apiKey.isEmpty { items.append(URLQueryItem(name: "api_key", value: apiKey)) }
        components?.queryItems = items
        return components?.url
    }

    // MARK: Parsing

    /// One latest reading.
    public struct LatestReading: Sendable, Hashable {
        public let gaugeID: String
        public let parameter: Parameter
        public let value: Double
        public let time: Date
        public let latitude: Double
        public let longitude: Double
    }

    private struct FeatureCollection<Properties: Decodable>: Decodable {
        let features: [Feature]
        struct Feature: Decodable {
            let properties: Properties
            let geometry: Geometry?
        }
        struct Geometry: Decodable {
            let coordinates: [Double]
        }
    }

    private struct LatestProperties: Decodable {
        let monitoring_location_id: String
        let parameter_code: String
        let time: String
        let value: String?
    }

    private struct HistoryProperties: Decodable {
        let time: String
        let value: String?
    }

    private struct LocationResponse: Decodable {
        let properties: Properties
        struct Properties: Decodable {
            let monitoring_location_name: String?
        }
    }

    public static func parseLatest(_ data: Data) throws -> [LatestReading] {
        let decoded: FeatureCollection<LatestProperties>
        do {
            decoded = try JSONDecoder().decode(FeatureCollection<LatestProperties>.self, from: data)
        } catch {
            throw WeatherError.decodingFailed
        }
        return decoded.features.compactMap { feature in
            let p = feature.properties
            guard let parameter = Parameter(rawValue: p.parameter_code),
                  let value = p.value.flatMap(Double.init), value.isFinite,
                  let time = parseTime(p.time),
                  let coordinates = feature.geometry?.coordinates, coordinates.count >= 2 else { return nil }
            return LatestReading(
                gaugeID: p.monitoring_location_id, parameter: parameter, value: value, time: time,
                latitude: coordinates[1], longitude: coordinates[0]
            )
        }
    }

    /// Chronological (time, value) pairs.
    public static func parseHistory(_ data: Data) throws -> [(time: Date, value: Double)] {
        let decoded: FeatureCollection<HistoryProperties>
        do {
            decoded = try JSONDecoder().decode(FeatureCollection<HistoryProperties>.self, from: data)
        } catch {
            throw WeatherError.decodingFailed
        }
        return decoded.features
            .compactMap { feature -> (time: Date, value: Double)? in
                guard let time = parseTime(feature.properties.time),
                      let value = feature.properties.value.flatMap(Double.init), value.isFinite else { return nil }
                return (time, value)
            }
            .sorted { $0.time < $1.time }
    }

    public static func parseLocationName(_ data: Data) throws -> String? {
        do {
            return try JSONDecoder().decode(LocationResponse.self, from: data).properties.monitoring_location_name
        } catch {
            throw WeatherError.decodingFailed
        }
    }

    /// ISO 8601 with offset, with or without fractional seconds.
    static func parseTime(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
