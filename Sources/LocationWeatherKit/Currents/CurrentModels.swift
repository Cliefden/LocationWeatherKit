import Foundation

/// A predicted tidal-current event at a NOAA station.
public enum CurrentEventKind: String, Sendable, Codable, CaseIterable {
    /// Maximum flood.
    case flood
    /// Maximum ebb.
    case ebb
    /// Slack water (the current turns).
    case slack

    /// Event label: "Max flood" / "Max ebb" / "Slack".
    public var localizedName: String {
        switch self {
        case .flood: return .lwk("Max flood")
        case .ebb: return .lwk("Max ebb")
        case .slack: return .lwk("Slack")
        }
    }

    /// Present-tense phase: "Flooding" / "Ebbing" / "Near slack".
    public var phaseName: String {
        switch self {
        case .flood: return .lwk("Flooding")
        case .ebb: return .lwk("Ebbing")
        case .slack: return .lwk("Near slack")
        }
    }
}

/// A predicted max flood / max ebb / slack (NOAA `currents_predictions`, `MAX_SLACK`).
public struct CurrentEvent: Sendable, Hashable, Codable, Identifiable {
    public let kind: CurrentEventKind
    public let time: Date
    /// Knots (0 at slack).
    public let speedKnots: Double
    /// Direction the current flows TOWARD, degrees (nil at slack).
    public let directionDegrees: Int?

    public var id: String { "\(kind.rawValue)-\(Int(time.timeIntervalSinceReferenceDate / 60))" }

    public init(kind: CurrentEventKind, time: Date, speedKnots: Double, directionDegrees: Int?) {
        self.kind = kind
        self.time = time
        self.speedKnots = speedKnots
        self.directionDegrees = directionDegrees
    }
}

/// One point of a current time series (Open-Meteo Marine model, hourly).
public struct CurrentSample: Sendable, Hashable, Codable {
    public let time: Date
    /// Knots.
    public let speedKnots: Double
    /// Direction the current flows TOWARD, degrees.
    public let directionDegrees: Double

    public init(time: Date, speedKnots: Double, directionDegrees: Double) {
        self.time = time
        self.speedKnots = speedKnots
        self.directionDegrees = directionDegrees
    }

    /// The sample closest to `date` (optionally no further than `maxDistance`).
    public static func nearest(in samples: [CurrentSample], to date: Date, maxDistance: TimeInterval? = nil) -> CurrentSample? {
        guard let best = samples.min(by: {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }) else { return nil }
        if let maxDistance, abs(best.time.timeIntervalSince(date)) > maxDistance { return nil }
        return best
    }
}

/// The current at one moment, interpolated from NOAA events or read from the model.
public struct CurrentEstimate: Sendable, Hashable {
    /// Knots.
    public let speedKnots: Double
    /// Direction the current flows TOWARD, degrees.
    public let directionDegrees: Int
    /// Flooding / ebbing / near slack (NOAA only; nil for model data).
    public let phase: CurrentEventKind?

    public init(speedKnots: Double, directionDegrees: Int, phase: CurrentEventKind?) {
        self.speedKnots = speedKnots
        self.directionDegrees = directionDegrees
        self.phase = phase
    }
}

/// Where a `CurrentData` came from. Every surface must label `.model` data as a
/// model estimate ("Model estimate — not for navigation"): the ~8 km ocean model
/// can badly understate tidal streams in channels and harbours.
public enum CurrentSource: Sendable, Hashable {
    /// Official NOAA CO-OPS current predictions for a station (show its name and distance).
    case noaa(station: NOAAStation, distanceKm: Double)
    /// Open-Meteo Marine modelled surface current (~8 km grid).
    case model

    public var isModelEstimate: Bool {
        if case .model = self { return true }
        return false
    }

    public var station: NOAAStation? {
        if case .noaa(let station, _) = self { return station }
        return nil
    }
}

/// Tidal-current set and drift for a coordinate.
public struct CurrentData: Sendable, Hashable {
    /// Knots, now (at `fetchedAt`).
    public let speedKnots: Double
    /// Direction the current flows TOWARD, degrees, now.
    public let directionDegrees: Int
    public let fetchedAt: Date
    public let source: CurrentSource
    /// Flooding / ebbing / near slack now (NOAA only).
    public let phase: CurrentEventKind?
    /// Max flood / max ebb / slack events, chronological, including the ones
    /// before `fetchedAt` that bracket now (NOAA only). See `upcomingEvents(after:)`.
    public let events: [CurrentEvent]
    /// Hourly model series (model only), non-null hours, chronological.
    public let samples: [CurrentSample]

    public init(
        speedKnots: Double,
        directionDegrees: Int,
        fetchedAt: Date,
        source: CurrentSource,
        phase: CurrentEventKind? = nil,
        events: [CurrentEvent] = [],
        samples: [CurrentSample] = []
    ) {
        self.speedKnots = speedKnots
        self.directionDegrees = directionDegrees
        self.fetchedAt = fetchedAt
        self.source = source
        self.phase = phase
        self.events = events
        self.samples = samples
    }

    /// Localized 16-point compass point the current sets toward.
    public var compass: String { Compass.abbreviation(degrees: directionDegrees) }

    /// Events strictly after `date` (Sextant lists the next few).
    public func upcomingEvents(after date: Date) -> [CurrentEvent] {
        events.filter { $0.time > date }
    }

    /// The current at `date`: NOAA events are interpolated with the sine rule
    /// (nil outside the predicted window); model data uses the nearest hourly
    /// sample within `maxSampleDistance`.
    public func estimate(
        at date: Date,
        slackThresholdKnots: Double = 0.2,
        maxSampleDistance: TimeInterval = 90 * 60
    ) -> CurrentEstimate? {
        switch source {
        case .noaa:
            return Self.interpolate(events, at: date, slackThresholdKnots: slackThresholdKnots)
        case .model:
            guard let sample = CurrentSample.nearest(in: samples, to: date, maxDistance: maxSampleDistance) else { return nil }
            return CurrentEstimate(speedKnots: sample.speedKnots,
                                   directionDegrees: Int(sample.directionDegrees.rounded()),
                                   phase: nil)
        }
    }

    /// Current at `date` from the surrounding max/slack events, by NOAA's rule
    /// (Tidal Current Tables, Table 3): from slack toward a maximum the speed
    /// follows sin(90° · t/T), from a maximum toward slack cos(90° · t/T).
    /// Between two maxima with no slack listed (e.g. a double flood) a
    /// half-cosine blend is used. Within `slackThresholdKnots` the phase is
    /// `.slack`. Nil when `date` is not bracketed by events.
    public static func interpolate(
        _ events: [CurrentEvent],
        at date: Date,
        slackThresholdKnots: Double = 0.2
    ) -> CurrentEstimate? {
        guard let nextIndex = events.firstIndex(where: { $0.time >= date }), nextIndex > 0 else { return nil }
        let a = events[nextIndex - 1], b = events[nextIndex]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return nil }
        let f = max(0, min(1, date.timeIntervalSince(a.time) / span))
        func signed(_ e: CurrentEvent) -> Double { e.kind == .ebb ? -e.speedKnots : e.speedKnots }
        let v: Double
        switch (a.kind, b.kind) {
        case (.slack, .slack): v = 0
        case (.slack, _): v = signed(b) * sin(.pi / 2 * f)
        case (_, .slack): v = signed(a) * cos(.pi / 2 * f)
        default: v = signed(a) + (signed(b) - signed(a)) * (1 - cos(.pi * f)) / 2
        }
        let speed = abs(v)
        let phase: CurrentEventKind = speed < slackThresholdKnots ? .slack : (v > 0 ? .flood : .ebb)
        // Direction of the governing maximum (flood or ebb axis).
        let floodDir = [a, b].first { $0.kind == .flood }?.directionDegrees
            ?? events.first { $0.kind == .flood }?.directionDegrees
        let ebbDir = [a, b].first { $0.kind == .ebb }?.directionDegrees
            ?? events.first { $0.kind == .ebb }?.directionDegrees
        guard let direction = (v >= 0 ? floodDir : ebbDir) ?? floodDir ?? ebbDir else { return nil }
        return CurrentEstimate(speedKnots: speed, directionDegrees: direction, phase: phase)
    }
}

public enum CurrentError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case decodingFailed
    /// No NOAA station nearby and the model has no current here (inland, or
    /// outside the ocean model). Hide current UI.
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse, .decodingFailed: return .lwk("Currents unavailable. Please try again later.")
        case .unavailable: return .lwk("No current data for this location.")
        }
    }
}
