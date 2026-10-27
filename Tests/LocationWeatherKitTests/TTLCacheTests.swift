import Foundation
import Testing
@testable import LocationWeatherKit

@Suite("TTL cache")
struct TTLCacheTests {
    @Test func expiresAfterTTL() async {
        let clock = TestClock(utc(0))
        let cache = TTLCache<String, Int>(ttl: 300, now: clock.closure)
        await cache.set(1, for: "a")
        #expect(await cache.value(for: "a") == 1)

        clock.advance(by: 299)
        #expect(await cache.value(for: "a") == 1)
        clock.advance(by: 1)
        #expect(await cache.value(for: "a") == nil)
        #expect(await cache.staleValue(for: "a")?.value == 1)
        #expect(await cache.staleValue(for: "a")?.storedAt == utc(0))
    }

    @Test func removeAndPrune() async {
        let clock = TestClock(utc(0))
        let cache = TTLCache<Int, String>(ttl: 60, now: clock.closure)
        await cache.set("old", for: 1)
        clock.advance(by: 90)
        await cache.set("new", for: 2)
        await cache.removeExpired()
        #expect(await cache.count == 1)
        await cache.removeValue(for: 2)
        #expect(await cache.value(for: 2) == nil)
        await cache.set("x", for: 3)
        await cache.removeAll()
        #expect(await cache.count == 0)
    }

    @Test func backdatedEntry() async {
        let clock = TestClock(utc(1))
        let cache = TTLCache<String, Int>(ttl: 3600, now: clock.closure)
        await cache.set(5, for: "k", storedAt: utc(0))
        #expect(await cache.value(for: "k") == nil)
    }

    @Test func fetchCoalescesAndCaches() async throws {
        let cache = TTLCache<String, Int>(ttl: 60)
        let counter = Reported()
        let fetch: @Sendable () async throws -> Int = {
            counter.append("fetch")
            try await Task.sleep(for: .milliseconds(50))
            return 42
        }
        async let a = cache.value(for: "k", orFetch: fetch)
        async let b = cache.value(for: "k", orFetch: fetch)
        let (x, y) = try await (a, b)
        #expect(x == 42 && y == 42)
        #expect(try await cache.value(for: "k", orFetch: fetch) == 42)
        #expect(counter.values.count == 1)
    }

    @Test func fetchErrorsAreNotCached() async throws {
        let cache = TTLCache<String, Int>(ttl: 60)
        await #expect(throws: URLError.self) {
            try await cache.value(for: "k") { throw URLError(.timedOut) }
        }
        #expect(try await cache.value(for: "k") { 7 } == 7)
    }

    @Test func dayLocationKey() {
        let a = DayLocationKey(date: utc(1), latitude: 59.3293, longitude: 18.0686, timeZoneIdentifier: "Europe/Stockholm")
        let b = DayLocationKey(date: utc(23), latitude: 59.3299, longitude: 18.0611, timeZoneIdentifier: "Europe/Stockholm")
        let nextDay = DayLocationKey(date: utc(1, day: 1), latitude: 59.3293, longitude: 18.0686, timeZoneIdentifier: "Europe/Stockholm")
        let otherZone = DayLocationKey(date: utc(1), latitude: 59.3293, longitude: 18.0686, timeZoneIdentifier: "GMT")
        #expect(a == b)
        #expect(a != nextDay)
        #expect(a != otherZone)
    }
}
