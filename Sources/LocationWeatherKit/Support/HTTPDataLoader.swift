import Foundation

/// The one network seam every client in this package uses. `URLSession`
/// conforms; tests inject a stub that serves fixture JSON, so no test ever
/// touches the network.
public protocol HTTPDataLoader: Sendable {
    func loadData(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoader {
    public func loadData(from url: URL) async throws -> (Data, URLResponse) {
        try await data(from: url, delegate: nil)
    }

    /// A session with bounded timeouts, so a stalled request fails promptly
    /// instead of spinning for the system default of 60 s+ (Lunker's setup).
    public static func boundedTimeouts(request: TimeInterval = 15, resource: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = resource
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// Reports a non-fatal error to the app's logging/telemetry (e.g. `AppLog.reportError`).
/// The first argument is a short, stable operation name such as `"weather.decode"`.
public typealias ErrorReporter = @Sendable (_ operation: String, _ error: any Error) -> Void

enum HTTPStatus {
    /// True for any 2xx response.
    static func isSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

/// Unit conversions shared by the weather and tide models.
public enum UnitConversion {
    public static let knotsPerKmh = 0.539957
    public static let inHgPerHPa = 0.02953
    public static let feetPerMeter = 3.28084
}

/// Coordinate-rounded cache keys. `%.3f` ≈ 100 m (weather, tides); `%.2f` ≈ 1 km
/// (forecast, pressure baselines).
enum CoordinateKey {
    static func make(_ latitude: Double, _ longitude: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f,%.\(decimals)f", latitude, longitude)
    }
}

extension String {
    /// Looks the key up in this package's string catalog.
    static func lwk(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}

/// Great-circle distance.
public enum GeoDistance {
    public static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r
        let dLon = (lon2 - lon1) * r
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 6371.0 * 2 * atan2(h.squareRoot(), (1 - h).squareRoot())
    }
}
