import Foundation
import CoreLocation

/// Saved locations + the selected one, persisted as JSON in UserDefaults
/// (standard or an App Group suite). Superset of the Lunker / Sextant /
/// Equinox `LocationStore`, minus search (see `LocationSearch`) and minus the
/// app-specific widget / watch writes — those hang off `onChange`.
@MainActor
@Observable
public final class SavedLocationStore {

    public struct Configuration: Sendable {
        /// UserDefaults keys. The defaults match all three apps' existing keys.
        public var locationsKey: String
        public var selectedIDKey: String
        /// Two named places closer than this (both lat and lon, degrees) are duplicates.
        public var duplicateThresholdDegrees: Double
        /// GPS jitter below this (metres) is ignored for the Current Location entry.
        public var currentLocationUpdateThreshold: CLLocationDistance
        /// Moving further than this (metres) drops the Current Location's cached time zone.
        public var timeZoneInvalidationDistance: CLLocationDistance
        /// Resolve a missing time zone when a location is added (Equinox backfill).
        public var resolvesTimeZonesOnAdd: Bool
        /// When there is no GPS entry yet and a saved place sits at the fix, select
        /// that place instead of creating a "Current Location" on top of it (Equinox).
        public var reusesSavedPlaceForFirstFix: Bool

        public init(
            locationsKey: String = "savedLocations",
            selectedIDKey: String = "selectedLocationId",
            duplicateThresholdDegrees: Double = 0.01,
            currentLocationUpdateThreshold: CLLocationDistance = 100,
            timeZoneInvalidationDistance: CLLocationDistance = 50_000,
            resolvesTimeZonesOnAdd: Bool = true,
            reusesSavedPlaceForFirstFix: Bool = false
        ) {
            self.locationsKey = locationsKey
            self.selectedIDKey = selectedIDKey
            self.duplicateThresholdDegrees = duplicateThresholdDegrees
            self.currentLocationUpdateThreshold = currentLocationUpdateThreshold
            self.timeZoneInvalidationDistance = timeZoneInvalidationDistance
            self.resolvesTimeZonesOnAdd = resolvesTimeZonesOnAdd
            self.reusesSavedPlaceForFirstFix = reusesSavedPlaceForFirstFix
        }
    }

    public private(set) var locations: [SavedLocation] = []
    /// Set directly then call `save()`, or use `select(_:)` which saves.
    public var selectedLocationId: UUID?

    /// Called after every `save()` — write widget / watch / App Group data here.
    @ObservationIgnored public var onChange: ((SavedLocationStore) -> Void)?
    /// Called when a background time-zone resolution updated a location
    /// (Equinox clears its solar/moon caches here).
    @ObservationIgnored public var onTimeZoneResolved: ((SavedLocation) -> Void)?

    public let configuration: Configuration
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timeZoneResolver: any TimeZoneResolving
    @ObservationIgnored private let errorReporter: ErrorReporter?
    /// Locations with a time-zone lookup in flight, so repeated calls (every GPS
    /// update while a zone is missing) don't stack geocoder requests.
    @ObservationIgnored private var timeZoneResolutionsInFlight: [UUID: Task<Void, Never>] = [:]

    public init(
        defaults: UserDefaults = .standard,
        configuration: Configuration = Configuration(),
        timeZoneResolver: any TimeZoneResolving = GeocoderTimeZoneResolver(),
        errorReporter: ErrorReporter? = nil
    ) {
        self.defaults = defaults
        self.configuration = configuration
        self.timeZoneResolver = timeZoneResolver
        self.errorReporter = errorReporter
        load()
    }

    /// The selected location, or the first one when nothing (valid) is selected.
    public var selectedLocation: SavedLocation? {
        guard let id = selectedLocationId else { return locations.first }
        return locations.first { $0.id == id } ?? locations.first
    }

    public var currentLocationEntry: SavedLocation? {
        locations.first { $0.isCurrentLocation }
    }

    public var isEmpty: Bool { locations.isEmpty }

    // MARK: - Persistence

    public func save() {
        do {
            defaults.set(try JSONEncoder().encode(locations), forKey: configuration.locationsKey)
        } catch {
            errorReporter?("locations.save", error)
        }
        if let selectedLocationId {
            defaults.set(selectedLocationId.uuidString, forKey: configuration.selectedIDKey)
        } else {
            defaults.removeObject(forKey: configuration.selectedIDKey)
        }
        onChange?(self)
    }

    /// Re-reads from UserDefaults. A corrupt store is reported and left empty
    /// (better than crashing); a stale selected id falls back to the first entry.
    public func load() {
        if let data = defaults.data(forKey: configuration.locationsKey) {
            do {
                locations = try JSONDecoder().decode([SavedLocation].self, from: data)
            } catch {
                errorReporter?("locations.load", error)
                locations = []
            }
        } else {
            locations = []
        }

        if let idString = defaults.string(forKey: configuration.selectedIDKey),
           let id = UUID(uuidString: idString),
           locations.contains(where: { $0.id == id }) {
            selectedLocationId = id
        } else {
            selectedLocationId = locations.first?.id
        }
    }

    // MARK: - Editing

    /// Adds and selects `location`. Returns false when a named place at (nearly)
    /// the same coordinates exists — that place is selected instead. The GPS
    /// Current Location entry never counts as a duplicate (it moves with the user).
    @discardableResult
    public func addLocation(_ location: SavedLocation) -> Bool {
        if let duplicate = locations.first(where: { existing in
            !existing.isCurrentLocation && !location.isCurrentLocation &&
            existing.isNear(location, thresholdDegrees: configuration.duplicateThresholdDegrees)
        }) {
            if selectedLocationId != duplicate.id {
                selectedLocationId = duplicate.id
                save()
            }
            return false
        }

        locations.append(location)
        selectedLocationId = location.id
        save()
        if configuration.resolvesTimeZonesOnAdd, location.timeZoneIdentifier == nil {
            resolveTimezoneIfNeeded(for: location)
        }
        return true
    }

    @discardableResult
    public func addLocation(from result: LocationSearchResult) -> Bool {
        addLocation(result.toSavedLocation())
    }

    /// Replaces the stored entry with the same id (rename, edited coordinates…).
    public func updateLocation(_ location: SavedLocation) {
        guard let index = locations.firstIndex(where: { $0.id == location.id }) else { return }
        locations[index] = location
        save()
    }

    public func select(_ id: UUID) {
        guard locations.contains(where: { $0.id == id }), selectedLocationId != id else { return }
        selectedLocationId = id
        save()
    }

    public func deleteLocation(_ id: UUID) {
        locations.removeAll { $0.id == id }
        if selectedLocationId == id { selectedLocationId = locations.first?.id }
        save()
    }

    public func deleteLocation(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { locations.indices.contains($0) ? locations[$0].id : nil })
        locations.removeAll { ids.contains($0.id) }
        if let selectedLocationId, ids.contains(selectedLocationId) {
            self.selectedLocationId = locations.first?.id
        }
        save()
    }

    /// `Array.move(fromOffsets:toOffset:)` without importing SwiftUI.
    public func moveLocation(from source: IndexSet, to destination: Int) {
        var reordered = locations
        let moving = source.map { reordered[$0] }
        for index in source.sorted().reversed() { reordered.remove(at: index) }
        let adjusted = destination - source.filter { $0 < destination }.count
        for (offset, item) in moving.enumerated() {
            reordered.insert(item, at: adjusted + offset)
        }
        locations = reordered
        save()
    }

    /// Creates or moves the GPS "Current Location" entry.
    ///
    /// - Movement below `currentLocationUpdateThreshold` is ignored (no save, no
    ///   widget reload). Beyond `timeZoneInvalidationDistance` the cached zone is
    ///   dropped and re-resolved.
    /// - A new entry is inserted first and selected. An update moves it without
    ///   touching the selection unless `select` is true (Sextant's
    ///   "Use current location" button passes true).
    public func updateCurrentLocation(latitude: Double, longitude: Double, select: Bool = false) {
        guard latitude.isFinite, longitude.isFinite else { return }

        if let index = locations.firstIndex(where: { $0.isCurrentLocation }) {
            let old = CLLocation(latitude: locations[index].latitude, longitude: locations[index].longitude)
            let distance = old.distance(from: CLLocation(latitude: latitude, longitude: longitude))
            let selectionChanges = select && selectedLocationId != locations[index].id
            guard distance >= configuration.currentLocationUpdateThreshold || selectionChanges else { return }

            if distance >= configuration.currentLocationUpdateThreshold {
                locations[index].latitude = latitude
                locations[index].longitude = longitude
                if distance > configuration.timeZoneInvalidationDistance {
                    locations[index].timeZoneIdentifier = nil
                }
            }
            if select { selectedLocationId = locations[index].id }
            save()
            // Retried on every accepted update while the zone is missing, so a
            // failed geocode doesn't leave the entry zoneless for good.
            if locations[index].timeZoneIdentifier == nil {
                resolveTimezoneIfNeeded(for: locations[index])
            }
        } else {
            if configuration.reusesSavedPlaceForFirstFix,
               let existing = locations.first(where: {
                   $0.isNear(latitude: latitude, longitude: longitude, thresholdDegrees: configuration.duplicateThresholdDegrees)
               }) {
                if selectedLocationId != existing.id {
                    selectedLocationId = existing.id
                    save()
                }
                return
            }
            let entry = SavedLocation.currentLocation(latitude: latitude, longitude: longitude)
            locations.insert(entry, at: 0)
            selectedLocationId = entry.id
            save()
            resolveTimezoneIfNeeded(for: entry)
        }
    }

    // MARK: - Time zones

    /// Resolves and persists the time zone for `location` if it has none.
    /// Safe to call repeatedly — skips entries that already have a zone, and
    /// joins a lookup already in flight instead of stacking another. Returns the
    /// lookup task (await it to know the zone is stored), or nil when skipped.
    @discardableResult
    public func resolveTimezoneIfNeeded(for location: SavedLocation) -> Task<Void, Never>? {
        // Look up the stored entry: the caller's copy may be stale.
        guard let current = locations.first(where: { $0.id == location.id }),
              current.timeZoneIdentifier == nil else { return nil }
        if let inFlight = timeZoneResolutionsInFlight[current.id] { return inFlight }

        let id = current.id
        let latitude = current.latitude
        let longitude = current.longitude
        let resolver = timeZoneResolver
        let task = Task { [weak self] in
            let zone = await resolver.timeZoneIdentifier(latitude: latitude, longitude: longitude)
            guard let self else { return }
            self.timeZoneResolutionsInFlight[id] = nil

            // Re-find by id: the array may have been reordered or edited meanwhile.
            guard let index = self.locations.firstIndex(where: { $0.id == id }),
                  self.locations[index].timeZoneIdentifier == nil else { return }
            guard self.locations[index].isNear(latitude: latitude, longitude: longitude) else {
                // The entry moved while geocoding; resolve for where it is now
                // (and finish only once that lookup has).
                await self.resolveTimezoneIfNeeded(for: self.locations[index])?.value
                return
            }
            // Geocoding failed: the next accepted update (or launch) retries.
            guard let zone else { return }
            self.locations[index].timeZoneIdentifier = zone
            self.save()
            self.onTimeZoneResolved?(self.locations[index])
        }
        timeZoneResolutionsInFlight[id] = task
        return task
    }

    /// Backfills every location missing a time zone (Equinox did this on load).
    /// Lookups run one after another to stay under CLGeocoder's rate limit.
    public func resolveMissingTimeZones() async {
        for location in locations where location.timeZoneIdentifier == nil {
            await resolveTimezoneIfNeeded(for: location)?.value
        }
    }
}
