import Foundation

/// A small in-memory cache whose entries expire `ttl` seconds after they were
/// stored. Generalises Equinox's `EventDataCache<T>` (and the ad-hoc
/// `[String: (data, expiry)]` dictionaries in the Lunker/Sextant services).
///
/// `value(for:orFetch:)` also coalesces concurrent requests for the same key,
/// so two callers asking at once trigger one fetch.
public actor TTLCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let value: Value
        let storedAt: Date
    }

    public let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<Value, any Error>] = [:]

    /// - Parameters:
    ///   - ttl: Seconds an entry stays valid.
    ///   - now: Clock, injectable for tests.
    public init(ttl: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    /// The cached value if it is younger than `ttl`.
    public func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) < ttl else { return nil }
        return entry.value
    }

    /// The cached value regardless of age, with the time it was stored — for
    /// "stale beats nothing" fallbacks when a refresh fails.
    public func staleValue(for key: Key) -> (value: Value, storedAt: Date)? {
        entries[key].map { ($0.value, $0.storedAt) }
    }

    public func set(_ value: Value, for key: Key, storedAt: Date? = nil) {
        entries[key] = Entry(value: value, storedAt: storedAt ?? now())
    }

    public func removeValue(for key: Key) {
        entries[key] = nil
    }

    public func removeAll() {
        entries.removeAll()
    }

    /// Drops every expired entry (the cache never grows past what callers store,
    /// but long-lived caches over many keys can call this occasionally).
    public func removeExpired() {
        let current = now()
        entries = entries.filter { current.timeIntervalSince($0.value.storedAt) < ttl }
    }

    public var count: Int { entries.count }

    /// Returns a fresh cached value, or runs `fetch` once (shared by concurrent
    /// callers for the same key) and caches its result. Errors are not cached.
    public func value(
        for key: Key,
        orFetch fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let cached = value(for: key) { return cached }
        if let task = inFlight[key] { return try await task.value }

        let task = Task { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let fresh = try await task.value
        entries[key] = Entry(value: fresh, storedAt: now())
        return fresh
    }
}

/// Equinox's `EventDataCache` key: calendar-day bucket + ~1 km coordinate +
/// time zone, so a different date, place or a later-backfilled zone recomputes.
public struct DayLocationKey: Hashable, Sendable {
    public let dayBucket: Int
    public let latitudeE2: Int
    public let longitudeE2: Int
    public let timeZoneIdentifier: String

    public init(date: Date, latitude: Double, longitude: Double, timeZoneIdentifier: String) {
        self.dayBucket = Int(date.timeIntervalSinceReferenceDate / 86_400)
        self.latitudeE2 = Int(latitude * 100)
        self.longitudeE2 = Int(longitude * 100)
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
