import Foundation

public enum TideKind: String, Sendable, Codable, CaseIterable {
    case high
    case low

    public var symbolName: String {
        switch self {
        case .high: return "arrow.up.to.line"
        case .low:  return "arrow.down.to.line"
        }
    }
}

/// A high or low water.
public struct TideEvent: Sendable, Hashable, Codable, Identifiable {
    public let kind: TideKind
    public let time: Date
    /// Metres above the source's datum (`TideSource.datumLabel`).
    public let heightMeters: Double

    public var id: String { "\(kind.rawValue)-\(Int(time.timeIntervalSinceReferenceDate / 60))" }

    public init(kind: TideKind, time: Date, heightMeters: Double) {
        self.kind = kind
        self.time = time
        self.heightMeters = heightMeters
    }

    /// "1.2 m" / "3.9 ft" by the locale's measurement system (Sextant's rule).
    /// Lunker formats through its own `UnitSettings` instead.
    public func formattedHeight(locale: Locale = .current) -> String {
        if locale.measurementSystem == .metric {
            return String(format: "%.1f m", heightMeters)
        }
        return String(format: "%.1f ft", heightMeters * UnitConversion.feetPerMeter)
    }
}

/// One sea-level sample (was a `(time:, height:)` tuple in both apps).
public struct TideSample: Sendable, Hashable, Codable {
    public let time: Date
    /// Metres above the source's datum.
    public let height: Double

    public init(time: Date, height: Double) {
        self.time = time
        self.height = height
    }
}

public enum TideState: String, Sendable, Codable, CaseIterable {
    case rising = "Rising"
    case falling = "Falling"
    case high = "High"
    case low = "Low"

    public var localizedName: String {
        switch self {
        case .rising: return .lwk("Rising")
        case .falling: return .lwk("Falling")
        case .high: return .lwk("High")
        case .low: return .lwk("Low")
        }
    }

    public var symbolName: String {
        switch self {
        case .rising:  return "arrow.up.forward"
        case .falling: return "arrow.down.forward"
        case .high:    return "arrow.up.to.line"
        case .low:     return "arrow.down.to.line"
        }
    }
}

/// Where a `TideData` came from. Every surface must label `.model` data as a
/// model estimate (not for navigation).
public enum TideSource: Sendable, Hashable {
    /// Official NOAA CO-OPS harmonic predictions for a station, heights above MLLW.
    case noaa(station: NOAAStation, distanceKm: Double)
    /// Open-Meteo Marine modelled sea level (~8 km grid), heights relative to MSL.
    case model

    public var isModelEstimate: Bool {
        if case .model = self { return true }
        return false
    }

    /// Short datum label for height displays.
    public var datumLabel: String {
        switch self {
        case .noaa: return "MLLW"
        case .model: return "MSL"
        }
    }

    public var station: NOAAStation? {
        if case .noaa(let station, _) = self { return station }
        return nil
    }
}

public struct TideData: Sendable, Hashable {
    /// High/low waters, chronological.
    public let events: [TideEvent]
    /// Sea-level samples, chronological: hourly heights where available (model,
    /// NOAA harmonic stations), else the high/low points themselves.
    public let samples: [TideSample]
    public let fetchedAt: Date
    public let source: TideSource

    public init(events: [TideEvent], samples: [TideSample], fetchedAt: Date, source: TideSource) {
        self.events = events
        self.samples = samples
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Next event strictly after `date`.
    public func nextEvent(after date: Date) -> TideEvent? {
        events.first { $0.time > date }
    }

    /// Most recent event at or before `date`.
    public func previousEvent(before date: Date) -> TideEvent? {
        events.last { $0.time <= date }
    }

    /// "High"/"low" within `slackWindow` of an extreme, otherwise rising/falling
    /// toward the next one. nil past the last event.
    public func state(at date: Date, slackWindow: TimeInterval = 30 * 60) -> TideState? {
        if let nearest = events.min(by: {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }), abs(nearest.time.timeIntervalSince(date)) < slackWindow {
            return nearest.kind == .high ? .high : .low
        }
        guard let next = nextEvent(after: date) else { return nil }
        return next.kind == .high ? .rising : .falling
    }

    /// Lowest/highest sample height, for range displays.
    public var heightRange: ClosedRange<Double>? {
        let heights = (samples.isEmpty ? events.map(\.heightMeters) : samples.map(\.height))
        guard let lo = heights.min(), let hi = heights.max() else { return nil }
        return lo...hi
    }

    /// Local maxima (high) and minima (low) in a sample series, each refined by
    /// a parabola through its three surrounding samples. The parabola uses the
    /// samples' real timestamps, so gaps left by skipped null readings don't skew
    /// the refined time (Lunker's version; Sextant's assumed equal spacing).
    public static func findExtremes(in samples: [TideSample]) -> [TideEvent] {
        guard samples.count >= 3 else { return [] }

        var events: [TideEvent] = []
        for i in 1..<(samples.count - 1) {
            let prev = samples[i - 1].height
            let curr = samples[i].height
            let next = samples[i + 1].height

            let isMax = curr >= prev && curr > next
            let isMin = curr <= prev && curr < next
            guard isMax || isMin else { continue }

            // Vertex of y = a·x² + b·x + curr through (x0, prev), (0, curr),
            // (x2, next), x in seconds relative to the middle sample.
            let x0 = samples[i - 1].time.timeIntervalSince(samples[i].time)
            let x2 = samples[i + 1].time.timeIntervalSince(samples[i].time)
            var offset = 0.0
            var height = curr
            if x0 < 0, x2 > 0 {
                let slope0 = (prev - curr) / x0   // = a·x0 + b
                let slope2 = (next - curr) / x2   // = a·x2 + b
                let a = (slope0 - slope2) / (x0 - x2)
                let b = slope0 - a * x0
                if abs(a) > 1e-15 {
                    offset = max(x0, min(x2, -b / (2 * a)))
                    height = a * offset * offset + b * offset + curr
                }
            }
            events.append(TideEvent(
                kind: isMax ? .high : .low,
                time: samples[i].time.addingTimeInterval(offset),
                heightMeters: height
            ))
        }
        return events
    }
}

public enum TideError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case decodingFailed
    /// Inland: no NOAA station nearby and the model returned no sea level. Hide tide UI.
    case notCoastal

    public var errorDescription: String? {
        switch self {
        case .invalidResponse, .decodingFailed: return .lwk("Tides unavailable. Please try again later.")
        case .notCoastal: return .lwk("No tide data for this location.")
        }
    }
}
