import Foundation
import CoreLocation
import Testing
@testable import LocationWeatherKit

@Suite("Saved location model")
struct SavedLocationModelTests {
    @Test func decodesLegacyAppPayload() throws {
        let locations = try JSONDecoder().decode([SavedLocation].self, from: try Fixture.data("saved-locations-legacy"))
        #expect(locations.count == 2)
        #expect(locations[0].isCurrentLocation)
        #expect(locations[0].timeZone?.identifier == "Europe/Stockholm")
        #expect(locations[1].timeZoneIdentifier == nil)
        #expect(locations[1].createdAt == Date(timeIntervalSinceReferenceDate: 783_100_000))
    }

    @Test func roundTrips() throws {
        let original = SavedLocation(name: "Mälaren", latitude: 59.4, longitude: 17.2, timeZoneIdentifier: "Europe/Stockholm")
        let decoded = try JSONDecoder().decode(SavedLocation.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func displayName() {
        #expect(SavedLocation.currentLocation(latitude: 0, longitude: 0).displayName == "Current Location")
        #expect(SavedLocation.currentLocation(latitude: 0, longitude: 0, name: "Bromma").displayName == "Bromma")
        #expect(SavedLocation(name: "Current Location", latitude: 0, longitude: 0).displayName == "Current Location")
    }

    @Test func searchResult() {
        let result = LocationSearchResult(name: "Göteborg", country: "Sweden", latitude: 57.7, longitude: 11.97,
                                          timeZoneIdentifier: "Europe/Stockholm", administrativeArea: "Västra Götaland",
                                          locality: "Göteborg")
        #expect(result.displayName == "Göteborg, Sweden")
        #expect(result.subtitle == "Göteborg, Västra Götaland, Sweden")
        let saved = result.toSavedLocation()
        #expect(saved.name == "Göteborg")
        #expect(saved.timeZoneIdentifier == "Europe/Stockholm")
        #expect(!saved.isCurrentLocation)
    }
}

@Suite("Saved location store")
@MainActor
struct SavedLocationStoreTests {
    let suite = IsolatedDefaults()

    func makeStore(zone: String? = "Europe/Stockholm",
                   configuration: SavedLocationStore.Configuration = .init()) -> SavedLocationStore {
        SavedLocationStore(defaults: suite.defaults, configuration: configuration,
                           timeZoneResolver: StubTimeZoneResolver(identifier: zone))
    }

    @Test func persistsAndReloads() throws {
        defer { suite.tearDown() }
        let store = makeStore()
        let tahoe = SavedLocation(name: "Lake Tahoe", latitude: 39.0968, longitude: -120.0324, timeZoneIdentifier: "America/Los_Angeles")
        let malaren = SavedLocation(name: "Mälaren", latitude: 59.4, longitude: 17.2, timeZoneIdentifier: "Europe/Stockholm")
        #expect(store.addLocation(tahoe))
        #expect(store.addLocation(malaren))
        #expect(store.selectedLocation == malaren)

        store.select(tahoe.id)
        let reloaded = makeStore()
        #expect(reloaded.locations == [tahoe, malaren])
        #expect(reloaded.selectedLocationId == tahoe.id)

        // Existing app keys are used, so data written by the apps today loads.
        #expect(suite.defaults.data(forKey: "savedLocations") != nil)
        #expect(suite.defaults.string(forKey: "selectedLocationId") == tahoe.id.uuidString)
    }

    @Test func loadsDataWrittenByTheApps() throws {
        defer { suite.tearDown() }
        suite.defaults.set(try Fixture.data("saved-locations-legacy"), forKey: "savedLocations")
        suite.defaults.set("5A3B1F44-1D2C-4C1E-9C4A-2E7F7C1E0B02", forKey: "selectedLocationId")
        let store = makeStore()
        #expect(store.locations.count == 2)
        #expect(store.selectedLocation?.name == "Lake Tahoe")
    }

    @Test func staleSelectionFallsBackToFirst() {
        defer { suite.tearDown() }
        let store = makeStore()
        store.addLocation(SavedLocation(name: "A", latitude: 1, longitude: 1, timeZoneIdentifier: "GMT"))
        suite.defaults.set(UUID().uuidString, forKey: "selectedLocationId")
        let reloaded = makeStore()
        #expect(reloaded.selectedLocationId == reloaded.locations.first?.id)
    }

    @Test func corruptStoreStartsEmptyAndReports() {
        defer { suite.tearDown() }
        suite.defaults.set(Data("garbage".utf8), forKey: "savedLocations")
        let reported = Reported()
        let store = SavedLocationStore(defaults: suite.defaults, timeZoneResolver: StubTimeZoneResolver(identifier: nil),
                                       errorReporter: { op, _ in reported.append(op) })
        #expect(store.locations.isEmpty)
        #expect(store.selectedLocationId == nil)
        #expect(reported.values == ["locations.load"])
    }

    @Test func duplicateSelectsExisting() {
        defer { suite.tearDown() }
        let store = makeStore()
        let a = SavedLocation(name: "A", latitude: 59.0, longitude: 18.0, timeZoneIdentifier: "GMT")
        let b = SavedLocation(name: "B", latitude: 40.0, longitude: -74.0, timeZoneIdentifier: "GMT")
        store.addLocation(a)
        store.addLocation(b)
        #expect(!store.addLocation(SavedLocation(name: "A again", latitude: 59.005, longitude: 18.005)))
        #expect(store.locations.count == 2)
        #expect(store.selectedLocationId == a.id)

        // The GPS entry never counts as a duplicate.
        store.updateCurrentLocation(latitude: 59.0, longitude: 18.0)
        #expect(store.locations.count == 3)
    }

    @Test func deleteAndMove() {
        defer { suite.tearDown() }
        let store = makeStore()
        let ids = (0..<4).map { i -> UUID in
            let loc = SavedLocation(name: "L\(i)", latitude: Double(i * 10), longitude: 0, timeZoneIdentifier: "GMT")
            store.addLocation(loc)
            return loc.id
        }
        store.moveLocation(from: IndexSet(integer: 0), to: 3)
        #expect(store.locations.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])

        store.select(ids[3])
        store.deleteLocation(ids[3])
        #expect(store.selectedLocationId == ids[1])
        store.deleteLocation(at: IndexSet([0, 1]))
        #expect(store.locations.map(\.id) == [ids[0]])
        #expect(store.selectedLocationId == ids[0])
    }

    @Test func currentLocationThresholds() async {
        defer { suite.tearDown() }
        let store = makeStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }

        store.updateCurrentLocation(latitude: 59.3293, longitude: 18.0686)
        let entry = store.currentLocationEntry
        #expect(store.locations.first?.isCurrentLocation == true)
        #expect(store.selectedLocationId == entry?.id)
        #expect(changes == 1)

        // Resolve the zone for the new entry.
        await store.resolveMissingTimeZones()
        #expect(store.currentLocationEntry?.timeZoneIdentifier == "Europe/Stockholm")
        let afterZone = changes

        // ~50 m jitter is ignored entirely (no save → no widget reload).
        store.updateCurrentLocation(latitude: 59.3297, longitude: 18.0686)
        #expect(changes == afterZone)
        #expect(store.currentLocationEntry?.latitude == 59.3293)

        // ~1 km move updates coordinates but keeps the zone.
        store.updateCurrentLocation(latitude: 59.3383, longitude: 18.0686)
        #expect(store.currentLocationEntry?.latitude == 59.3383)
        #expect(store.currentLocationEntry?.timeZoneIdentifier == "Europe/Stockholm")

        // > 50 km drops the zone and re-resolves it.
        store.updateCurrentLocation(latitude: 57.7089, longitude: 11.9746)
        #expect(store.currentLocationEntry?.timeZoneIdentifier == nil)
        await store.resolveMissingTimeZones()
        #expect(store.currentLocationEntry?.timeZoneIdentifier == "Europe/Stockholm")
    }

    @Test func updateDoesNotStealSelectionUnlessAsked() {
        defer { suite.tearDown() }
        let store = makeStore()
        store.updateCurrentLocation(latitude: 59.3293, longitude: 18.0686)
        let gpsID = store.currentLocationEntry?.id
        let tahoe = SavedLocation(name: "Tahoe", latitude: 39.1, longitude: -120.0, timeZoneIdentifier: "GMT")
        store.addLocation(tahoe)

        store.updateCurrentLocation(latitude: 59.40, longitude: 18.0686)
        #expect(store.selectedLocationId == tahoe.id)

        // Same position, but the caller asks to select it (Sextant's button).
        store.updateCurrentLocation(latitude: 59.40, longitude: 18.0686, select: true)
        #expect(store.selectedLocationId == gpsID)
    }

    @Test func addResolvesMissingZoneAndNotifies() async throws {
        defer { suite.tearDown() }
        let store = makeStore(zone: "America/Los_Angeles")
        var resolved: [String] = []
        store.onTimeZoneResolved = { resolved.append($0.name) }
        let tahoe = SavedLocation(name: "Tahoe", latitude: 39.1, longitude: -120.0)
        store.addLocation(tahoe)
        await store.resolveMissingTimeZones()   // waits for the lookup started by add
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.locations.first?.timeZoneIdentifier == "America/Los_Angeles")
        #expect(resolved == ["Tahoe"])
        #expect(makeStore().locations.first?.timeZoneIdentifier == "America/Los_Angeles")
    }

    @Test func failedLookupLeavesZoneNil() async {
        defer { suite.tearDown() }
        let store = makeStore(zone: nil, configuration: .init(resolvesTimeZonesOnAdd: false))
        store.addLocation(SavedLocation(name: "Nowhere", latitude: 0, longitude: 0))
        await store.resolveMissingTimeZones()
        #expect(store.locations.first?.timeZoneIdentifier == nil)
    }

    @Test func firstFixReusesSavedPlaceWhenConfigured() {
        defer { suite.tearDown() }
        let store = makeStore(configuration: .init(reusesSavedPlaceForFirstFix: true))
        let home = SavedLocation(name: "Stockholm", latitude: 59.3293, longitude: 18.0686, timeZoneIdentifier: "Europe/Stockholm")
        let other = SavedLocation(name: "Tahoe", latitude: 39.1, longitude: -120.0, timeZoneIdentifier: "GMT")
        store.addLocation(home)
        store.addLocation(other)
        store.updateCurrentLocation(latitude: 59.330, longitude: 18.069)
        #expect(store.currentLocationEntry == nil)
        #expect(store.selectedLocationId == home.id)
    }

    @Test func customKeys() {
        defer { suite.tearDown() }
        let config = SavedLocationStore.Configuration(locationsKey: "custom.locations", selectedIDKey: "custom.selected")
        let store = makeStore(configuration: config)
        store.addLocation(SavedLocation(name: "A", latitude: 1, longitude: 1, timeZoneIdentifier: "GMT"))
        #expect(suite.defaults.data(forKey: "custom.locations") != nil)
        #expect(suite.defaults.data(forKey: "savedLocations") == nil)
    }
}

@Suite("Location provider")
@MainActor
struct LocationProviderTests {
    @Test func defaultLocationIsAParameter() {
        let none = LocationProvider()
        #expect(none.defaultLocation == nil)
        #expect(none.effectiveLocation == nil || none.hasLocation)

        let stockholm = LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686)
        if !stockholm.hasLocation {
            #expect(stockholm.effectiveLocation?.coordinate.latitude == 59.3293)
        }
    }

    @Test func errorDescriptions() {
        #expect(LocationProvider.LocationError.timedOut.errorDescription == "Finding your location timed out.")
    }
}
