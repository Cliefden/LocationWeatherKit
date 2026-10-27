import Foundation

/// A place the user saved, or the GPS "Current Location" entry.
///
/// The Codable shape (keys `id`, `name`, `latitude`, `longitude`,
/// `isCurrentLocation`, `createdAt`, `timeZoneIdentifier`) is identical to the
/// Lunker / Sextant / Equinox `SavedLocation`, so existing UserDefaults data,
/// widget payloads and watch contexts decode unchanged.
public struct SavedLocation: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var isCurrentLocation: Bool
    public let createdAt: Date
    /// IANA identifier (e.g. "Europe/Stockholm"); nil until resolved.
    public var timeZoneIdentifier: String?

    public init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        isCurrentLocation: Bool = false,
        createdAt: Date = Date(),
        timeZoneIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentLocation = isCurrentLocation
        self.createdAt = createdAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap { TimeZone(identifier: $0) }
    }

    /// The name persisted for a GPS entry without a resolved place name. It is
    /// stored untranslated (it is data) — show `displayName`, not `name`.
    public static let currentLocationPlaceholderName = "Current Location"

    /// User-facing name: localized "Current Location" for the GPS entry (unless it
    /// carries a real place name), otherwise `name`.
    public var displayName: String {
        if isCurrentLocation && (name.isEmpty || name == Self.currentLocationPlaceholderName) {
            return .lwk("Current Location")
        }
        return name
    }

    /// A GPS "Current Location" entry. Pass `timeZoneIdentifier` when known so
    /// day/time math uses the place's own zone instead of the device zone.
    public static func currentLocation(
        latitude: Double,
        longitude: Double,
        name: String? = nil,
        timeZoneIdentifier: String? = nil
    ) -> SavedLocation {
        SavedLocation(
            name: name ?? currentLocationPlaceholderName,
            latitude: latitude,
            longitude: longitude,
            isCurrentLocation: true,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    /// True when `other` is within `thresholdDegrees` in both latitude and longitude.
    public func isNear(_ other: SavedLocation, thresholdDegrees: Double = 0.01) -> Bool {
        isNear(latitude: other.latitude, longitude: other.longitude, thresholdDegrees: thresholdDegrees)
    }

    public func isNear(latitude: Double, longitude: Double, thresholdDegrees: Double = 0.01) -> Bool {
        abs(self.latitude - latitude) < thresholdDegrees && abs(self.longitude - longitude) < thresholdDegrees
    }
}

/// A geocoding search hit.
public struct LocationSearchResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let country: String?
    public let latitude: Double
    public let longitude: Double
    public let timeZoneIdentifier: String?
    /// Extra placemark fields for apps that map regions (Otta).
    public let isoCountryCode: String?
    public let administrativeArea: String?
    public let subAdministrativeArea: String?
    public let locality: String?

    public init(
        id: UUID = UUID(),
        name: String,
        country: String? = nil,
        latitude: Double,
        longitude: Double,
        timeZoneIdentifier: String? = nil,
        isoCountryCode: String? = nil,
        administrativeArea: String? = nil,
        subAdministrativeArea: String? = nil,
        locality: String? = nil
    ) {
        self.id = id
        self.name = name
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isoCountryCode = isoCountryCode
        self.administrativeArea = administrativeArea
        self.subAdministrativeArea = subAdministrativeArea
        self.locality = locality
    }

    public var timeZone: TimeZone? {
        timeZoneIdentifier.flatMap { TimeZone(identifier: $0) }
    }

    /// "Name, Country".
    public var displayName: String {
        if let country { return "\(name), \(country)" }
        return name
    }

    /// "Locality, Region, Country" without empty parts (Otta's subtitle).
    public var subtitle: String {
        [locality, administrativeArea, country].compactMap { $0 }.joined(separator: ", ")
    }

    public func toSavedLocation() -> SavedLocation {
        SavedLocation(name: name, latitude: latitude, longitude: longitude, timeZoneIdentifier: timeZoneIdentifier)
    }
}
