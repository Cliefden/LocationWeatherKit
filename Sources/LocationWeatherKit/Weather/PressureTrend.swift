import Foundation

/// One barometric reading.
public struct PressureSample: Sendable, Hashable, Codable, Identifiable {
    public let time: Date
    /// hPa.
    public let pressure: Double

    public var id: Date { time }

    public init(time: Date, pressure: Double) {
        self.time = time
        self.pressure = pressure
    }
}

/// Three-hour barometric tendency. App-specific guidance text (Lunker's
/// `fishingNote`, Sextant's `sailingNote`) stays in the apps as extensions.
public enum PressureTrend: String, Sendable, Codable, CaseIterable {
    case rising = "Rising"
    case falling = "Falling"
    case stable = "Stable"

    /// Change over the trend span (hPa) beyond which the glass is rising/falling.
    public static let threshold = 1.5
    /// The span the trend is measured over.
    public static let span: TimeInterval = 3 * 3600
    /// The local-reading fallback only compares against a reading at least this
    /// old — readings minutes apart against a 3-hour threshold would call noise a trend.
    public static let minimumBaselineAge: TimeInterval = 2.5 * 3600

    public var localizedName: String {
        switch self {
        case .rising: return .lwk("Rising")
        case .falling: return .lwk("Falling")
        case .stable: return .lwk("Stable")
        }
    }

    public var symbolName: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .stable: return "arrow.right"
        }
    }

    /// Trend for a pressure change over the span.
    public static func trend(forChange diff: Double) -> PressureTrend {
        if diff > threshold { return .rising }
        if diff < -threshold { return .falling }
        return .stable
    }

    /// Pure trend rule (Lunker's, shared by both apps after adoption).
    ///
    /// Prefers the real 3-hour delta from the hourly `history` (latest sample at
    /// least 3 h before `now`). Otherwise falls back to the oldest locally
    /// recorded reading — but only when it is at least `minimumBaselineAge` old,
    /// else `.stable`.
    public static func calculate(
        currentPressure: Double,
        history: [PressureSample],
        readings: [PressureSample] = [],
        now: Date
    ) -> PressureTrend {
        if let baseline = history
            .filter({ $0.time <= now.addingTimeInterval(-span) })
            .max(by: { $0.time < $1.time }) {
            return trend(forChange: currentPressure - baseline.pressure)
        }

        guard let oldest = readings.min(by: { $0.time < $1.time }),
              now.timeIntervalSince(oldest.time) >= minimumBaselineAge else {
            return .stable
        }
        return trend(forChange: currentPressure - oldest.pressure)
    }

    /// Trend at `time` from an hourly series alone, or nil when the series has
    /// no sample at least 3 h earlier (no baseline means no trend, not "stable").
    public static func calculate(at time: Date, pressure: Double, history: [PressureSample]) -> PressureTrend? {
        guard history.contains(where: { $0.time <= time.addingTimeInterval(-span) }) else { return nil }
        return calculate(currentPressure: pressure, history: history, now: time)
    }
}

/// Per-place local pressure readings used as a trend fallback when Open-Meteo
/// returns no hourly history. Keyed on a ~1 km grid so switching locations never
/// compares one place's pressure against another's. Persisted (oldest in-window
/// reading per place) so the first fetch after a relaunch still has a baseline.
struct PressureBaselineStore {
    /// Wider than the 3 h span so a reading 2.5–4 h old can serve as baseline.
    static let window: TimeInterval = 4 * 3600

    private let defaults: UserDefaults?
    private let key: String
    private var readings: [String: [PressureSample]] = [:]

    init(defaults: UserDefaults?, key: String, now: Date) {
        self.defaults = defaults
        self.key = key
        guard let defaults,
              let stored = defaults.dictionary(forKey: key) as? [String: [Double]] else { return }
        for (place, pair) in stored where pair.count == 2 {
            let time = Date(timeIntervalSince1970: pair[1])
            if now.timeIntervalSince(time) < Self.window {
                readings[place] = [PressureSample(time: time, pressure: pair[0])]
            }
        }
    }

    static func placeKey(latitude: Double, longitude: Double) -> String {
        CoordinateKey.make(latitude, longitude, decimals: 2)
    }

    /// Records `pressure` for the place and returns its in-window readings.
    mutating func record(_ pressure: Double, place: String, now: Date) -> [PressureSample] {
        var list = readings[place] ?? []
        list.append(PressureSample(time: now, pressure: pressure))
        list = list.filter { now.timeIntervalSince($0.time) < Self.window }
        readings[place] = list
        return list
    }

    func persist(now: Date) {
        guard let defaults else { return }
        var stored: [String: [Double]] = [:]
        for (place, list) in readings {
            guard let oldest = list.first(where: { now.timeIntervalSince($0.time) < Self.window }) else { continue }
            stored[place] = [oldest.pressure, oldest.time.timeIntervalSince1970]
        }
        defaults.set(stored, forKey: key)
    }
}
