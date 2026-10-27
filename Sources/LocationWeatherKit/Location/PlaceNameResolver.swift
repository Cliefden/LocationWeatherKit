import Foundation
import CoreLocation

/// Reverse geocoding helpers (CLGeocoder).
public enum PlaceNameResolver {

    public enum Strategy: Sendable {
        /// The water body when the point is on one ("Mälaren", "The Solent"),
        /// otherwise the locality (Lunker, Sextant).
        case waterFirst
        /// Locality → sub-administrative area → name (Otta).
        case localityFirst
    }

    /// Best name for a coordinate, or nil when geocoding fails (e.g. offline).
    public static func placeName(
        latitude: Double,
        longitude: Double,
        strategy: Strategy = .waterFirst
    ) async -> String? {
        guard let placemark = await placemark(latitude: latitude, longitude: longitude) else { return nil }
        return name(from: placemark, strategy: strategy)
    }

    public static func name(from placemark: CLPlacemark, strategy: Strategy) -> String? {
        switch strategy {
        case .waterFirst:
            return placemark.inlandWater ?? placemark.ocean ?? placemark.locality ?? placemark.name
        case .localityFirst:
            return placemark.locality ?? placemark.subAdministrativeArea ?? placemark.name
        }
    }

    /// IANA time zone for a coordinate, or nil when geocoding fails.
    public static func timeZoneIdentifier(latitude: Double, longitude: Double) async -> String? {
        await placemark(latitude: latitude, longitude: longitude)?.timeZone?.identifier
    }

    /// The first reverse-geocoded placemark, or nil.
    public static func placemark(latitude: Double, longitude: Double) async -> CLPlacemark? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        return try? await CLGeocoder().reverseGeocodeLocation(location).first
    }
}

/// Resolves a coordinate's time zone. `SavedLocationStore` uses this seam so
/// tests (and apps with their own geocoder) can substitute it.
public protocol TimeZoneResolving: Sendable {
    func timeZoneIdentifier(latitude: Double, longitude: Double) async -> String?
}

/// The default resolver: CLGeocoder reverse geocoding.
public struct GeocoderTimeZoneResolver: TimeZoneResolving {
    public init() {}

    public func timeZoneIdentifier(latitude: Double, longitude: Double) async -> String? {
        await PlaceNameResolver.timeZoneIdentifier(latitude: latitude, longitude: longitude)
    }
}
