import Foundation

extension TimeZone {
    /// A fixed-offset zone for a longitude at 15° per hour, rounded to the
    /// nearest whole hour.
    ///
    /// It ignores daylight saving time and political borders, so it can be about
    /// an hour off. Use it only as an offline fallback until the real IANA zone
    /// is known (see `SavedLocation.resolvedTimeZone`).
    public static func approximate(forLongitude longitude: Double) -> TimeZone {
        guard longitude.isFinite else { return .current }
        let hours = Int((longitude / 15.0).rounded())
        return TimeZone(secondsFromGMT: hours * 3600) ?? .current
    }
}
