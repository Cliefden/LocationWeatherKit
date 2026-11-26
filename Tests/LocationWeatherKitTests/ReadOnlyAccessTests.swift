import Foundation
import Testing
@testable import LocationWeatherKit

@Suite("Read-only selection (widgets, complications)")
struct PersistedSelectionTests {
    let suite = IsolatedDefaults()

    private func write(_ locations: [SavedLocation], selected: UUID?) throws {
        suite.defaults.set(try JSONEncoder().encode(locations), forKey: "savedLocations")
        if let selected {
            suite.defaults.set(selected.uuidString, forKey: "selectedLocationId")
        }
    }

    @Test func emptyStoreReadsNil() {
        defer { suite.tearDown() }
        #expect(SavedLocationStore.persistedLocations(defaults: suite.defaults).isEmpty)
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == nil)
    }

    @Test func readsStoredSelection() throws {
        defer { suite.tearDown() }
        let a = SavedLocation(name: "A", latitude: 1, longitude: 1)
        let b = SavedLocation(name: "B", latitude: 2, longitude: 2)
        try write([a, b], selected: b.id)
        #expect(SavedLocationStore.persistedLocations(defaults: suite.defaults) == [a, b])
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == b)
    }

    @Test func staleOrMissingSelectionFallsBackToFirst() throws {
        defer { suite.tearDown() }
        let a = SavedLocation(name: "A", latitude: 1, longitude: 1)
        try write([a], selected: nil)
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == a)
        try write([a], selected: UUID())
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == a)
    }

    @Test func corruptDataReadsEmpty() {
        defer { suite.tearDown() }
        suite.defaults.set(Data("garbage".utf8), forKey: "savedLocations")
        #expect(SavedLocationStore.persistedLocations(defaults: suite.defaults).isEmpty)
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == nil)
    }

    @Test func honoursCustomKeys() throws {
        defer { suite.tearDown() }
        let a = SavedLocation(name: "A", latitude: 1, longitude: 1)
        let config = SavedLocationStore.Configuration(locationsKey: "locs", selectedIDKey: "sel")
        suite.defaults.set(try JSONEncoder().encode([a]), forKey: "locs")
        suite.defaults.set(a.id.uuidString, forKey: "sel")
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults, configuration: config) == a)
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == nil)
    }

    @Test @MainActor func matchesTheStoresSelection() throws {
        defer { suite.tearDown() }
        let store = SavedLocationStore(defaults: suite.defaults, timeZoneResolver: StubTimeZoneResolver(identifier: "GMT"))
        let a = SavedLocation(name: "A", latitude: 1, longitude: 1, timeZoneIdentifier: "GMT")
        let b = SavedLocation(name: "B", latitude: 2, longitude: 2, timeZoneIdentifier: "GMT")
        store.addLocation(a)
        store.addLocation(b)
        store.select(a.id)
        #expect(SavedLocationStore.persistedSelection(defaults: suite.defaults) == store.selectedLocation)
    }
}

@Suite("Time zone fallback")
struct ResolvedTimeZoneTests {
    @Test func approximateRoundsToWholeHours() {
        #expect(TimeZone.approximate(forLongitude: 18.07).secondsFromGMT() == 3600)
        #expect(TimeZone.approximate(forLongitude: -122.4).secondsFromGMT() == -8 * 3600)
        #expect(TimeZone.approximate(forLongitude: 0).secondsFromGMT() == 0)
        #expect(TimeZone.approximate(forLongitude: 7.4).secondsFromGMT() == 0)
        #expect(TimeZone.approximate(forLongitude: 7.6).secondsFromGMT() == 3600)
        #expect(TimeZone.approximate(forLongitude: 179.9).secondsFromGMT() == 12 * 3600)
    }

    @Test func nonFiniteLongitudeFallsBackToCurrent() {
        #expect(TimeZone.approximate(forLongitude: .nan) == .current)
    }

    @Test func resolvedPrefersDeviceZoneThenIANAThenApproximation() {
        let gps = SavedLocation.currentLocation(latitude: 35, longitude: 139, timeZoneIdentifier: "Asia/Tokyo")
        #expect(gps.resolvedTimeZone == .current)

        let tokyo = SavedLocation(name: "Tokyo", latitude: 35.68, longitude: 139.69, timeZoneIdentifier: "Asia/Tokyo")
        #expect(tokyo.resolvedTimeZone.identifier == "Asia/Tokyo")

        let unresolved = SavedLocation(name: "Somewhere", latitude: 35.68, longitude: 139.69)
        #expect(unresolved.resolvedTimeZone.secondsFromGMT() == 9 * 3600)

        let bogus = SavedLocation(name: "Bogus", latitude: 0, longitude: -45, timeZoneIdentifier: "Not/AZone")
        #expect(bogus.resolvedTimeZone.secondsFromGMT() == -3 * 3600)
    }
}

@Suite("Great-circle destination")
struct GeoDestinationTests {
    @Test func zeroDistanceIsTheStart() {
        let p = GeoDistance.destination(latitude: 59.33, longitude: 18.07, bearing: 123, distanceKm: 0)
        #expect(abs(p.latitude - 59.33) < 1e-9)
        #expect(abs(p.longitude - 18.07) < 1e-9)
    }

    @Test func roundTripsWithHaversine() {
        for bearing in stride(from: 0.0, to: 360, by: 45) {
            let p = GeoDistance.destination(latitude: 59.33, longitude: 18.07, bearing: bearing, distanceKm: 100)
            let back = GeoDistance.haversineKm(59.33, 18.07, p.latitude, p.longitude)
            #expect(abs(back - 100) < 1e-6)
        }
    }

    @Test func dueNorthOneDegreeOfArc() {
        let km = 6371.0 * .pi / 180
        let p = GeoDistance.destination(latitude: 10, longitude: 20, bearing: 0, distanceKm: km)
        #expect(abs(p.latitude - 11) < 1e-9)
        #expect(abs(p.longitude - 20) < 1e-9)
    }

    @Test func wrapsAcrossTheAntimeridian() {
        let p = GeoDistance.destination(latitude: 0, longitude: 179.5, bearing: 90, distanceKm: 6371.0 * .pi / 180)
        #expect(abs(p.longitude - (-179.5)) < 1e-9)
        #expect(p.longitude >= -180 && p.longitude < 180)
    }
}
