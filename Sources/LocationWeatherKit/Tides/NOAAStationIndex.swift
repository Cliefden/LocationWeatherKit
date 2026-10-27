import Foundation

/// A NOAA CO-OPS prediction station (tides, or currents with a depth `bin`).
public struct NOAAStation: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    /// Two-letter state (mdapi lists only; the bundled list folds it into `name`).
    public var state: String?
    /// Current-meter depth bin (current-prediction stations only).
    public var bin: Int?

    public init(id: String, name: String, latitude: Double, longitude: Double, state: String? = nil, bin: Int? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.state = state
        self.bin = bin
    }

    public var displayName: String {
        if let state, !state.isEmpty { return "\(name), \(state)" }
        return name
    }
}

/// A station with its distance from the query point.
public struct NOAAStationMatch: Sendable, Hashable, Identifiable {
    public let station: NOAAStation
    public let distanceKm: Double

    public var id: String { station.id }
    public var name: String { station.name }
    public var bin: Int? { station.bin }

    public init(station: NOAAStation, distanceKm: Double) {
        self.station = station
        self.distanceKm = distanceKm
    }
}

/// Nearest-station lookup over an in-memory station list (Sextant's approach).
///
/// `bundledTideStations` is a snapshot of NOAA's ~3,500 tide-prediction stations
/// (~200 KB, package resource), so no network round-trip is needed just to decide
/// whether a location is covered. Regenerate it from
/// `https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions`
/// (compact form: `{"stations": [[id, name, lat, lon], …]}`).
/// Apps can build other indexes (e.g. Sextant's current stations) with
/// `init(bundle:resource:)` or `init(stations:)`.
public final class NOAAStationIndex: Sendable {
    /// NOAA tide-prediction stations bundled with this package (decoded on first use).
    public static let bundledTideStations = NOAAStationIndex(bundle: .module, resource: "NOAATideStations")

    public let stations: [NOAAStation]

    public init(stations: [NOAAStation]) {
        self.stations = stations
    }

    /// Loads `resource.json` in the compact `{"stations": [[id, name, lat, lon, bin?], …]}`
    /// form; empty when missing or malformed.
    public convenience init(bundle: Bundle, resource: String) {
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            self.init(stations: [])
            return
        }
        self.init(stations: Self.decodeCompact(data))
    }

    /// Decodes `{"stations": [[id, name, lat, lon, bin?], …]}`.
    public static func decodeCompact(_ data: Data) -> [NOAAStation] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["stations"] as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count >= 4,
                  let id = row[0] as? String,
                  let name = row[1] as? String,
                  let lat = (row[2] as? NSNumber)?.doubleValue,
                  let lon = (row[3] as? NSNumber)?.doubleValue else { return nil }
            let bin = row.count >= 5 ? (row[4] as? NSNumber)?.intValue : nil
            return NOAAStation(id: id, name: name, latitude: lat, longitude: lon, bin: bin)
        }
    }

    private struct MDAPIResponse: Decodable {
        let stations: [Station]
        struct Station: Decodable {
            let id: String
            let name: String
            let lat: Double
            let lng: Double
            let state: String?
        }
    }

    /// Decodes the full mdapi `stations.json` response (Lunker downloaded this at runtime).
    public static func decodeMDAPI(_ data: Data) throws -> [NOAAStation] {
        try JSONDecoder().decode(MDAPIResponse.self, from: data).stations.map {
            NOAAStation(id: $0.id, name: $0.name, latitude: $0.lat, longitude: $0.lng, state: $0.state)
        }
    }

    public func station(id: String) -> NOAAStation? {
        stations.first { $0.id == id }
    }

    /// The closest station within `maxDistanceKm`, or nil.
    public func nearest(latitude: Double, longitude: Double, maxDistanceKm: Double) -> NOAAStationMatch? {
        nearby(latitude: latitude, longitude: longitude, radiusKm: maxDistanceKm, limit: 1).first
    }

    /// Stations within `radiusKm`, closest first (Lunker's station picker).
    public func nearby(latitude: Double, longitude: Double, radiusKm: Double, limit: Int) -> [NOAAStationMatch] {
        guard latitude.isFinite, longitude.isFinite, limit > 0 else { return [] }
        // Cheap latitude-band prefilter before the haversine; 1° lat ≈ 111 km.
        let latWindow = radiusKm / 111.0 + 0.01
        return stations
            .lazy
            .filter { abs($0.latitude - latitude) <= latWindow }
            .map { NOAAStationMatch(station: $0, distanceKm: GeoDistance.haversineKm(latitude, longitude, $0.latitude, $0.longitude)) }
            .filter { $0.distanceKm <= radiusKm }
            .sorted { $0.distanceKm < $1.distanceKm }
            .prefix(limit)
            .map { $0 }
    }

    /// Cheap pre-check: is the point anywhere NOAA publishes stations (the Americas,
    /// US Pacific territories, the Aleutians)? Lets callers skip the lookup elsewhere.
    public static func isPlausiblyCovered(latitude: Double, longitude: Double) -> Bool {
        if longitude <= -60 && latitude >= -20 && latitude <= 75 { return true }
        if longitude >= 130 && latitude >= -20 && latitude <= 30 { return true }   // Guam, CNMI, Wake
        if longitude >= 165 && latitude >= 50 { return true }                      // western Aleutians
        return false
    }
}
