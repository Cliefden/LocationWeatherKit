import Foundation

/// 16-point compass abbreviations (localized via the package catalog).
public enum Compass {
    /// Index 0…15 for `degrees` (N = 0, NNE = 1, …). Negative / >360 values wrap.
    public static func pointIndex(degrees: Double) -> Int {
        guard degrees.isFinite else { return 0 }
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((normalized + 11.25) / 22.5) % 16
    }

    /// Untranslated abbreviations, for data/telemetry or apps that never localize them.
    public static let englishAbbreviations = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    /// Localized abbreviation for `degrees` (e.g. "NNE", Swedish "NNO").
    public static func abbreviation(degrees: Double) -> String {
        switch pointIndex(degrees: degrees) {
        case 0:  return .lwk("N")
        case 1:  return .lwk("NNE")
        case 2:  return .lwk("NE")
        case 3:  return .lwk("ENE")
        case 4:  return .lwk("E")
        case 5:  return .lwk("ESE")
        case 6:  return .lwk("SE")
        case 7:  return .lwk("SSE")
        case 8:  return .lwk("S")
        case 9:  return .lwk("SSW")
        case 10: return .lwk("SW")
        case 11: return .lwk("WSW")
        case 12: return .lwk("W")
        case 13: return .lwk("WNW")
        case 14: return .lwk("NW")
        default: return .lwk("NNW")
        }
    }

    public static func abbreviation(degrees: Int) -> String {
        abbreviation(degrees: Double(degrees))
    }
}

/// WMO weather interpretation codes, as returned by Open-Meteo's `weather_code`.
public enum WMOWeatherCode {
    public static func description(for code: Int) -> String {
        switch code {
        case 0: return .lwk("Clear sky")
        case 1: return .lwk("Mainly clear")
        case 2: return .lwk("Partly cloudy")
        case 3: return .lwk("Overcast")
        case 45, 48: return .lwk("Foggy")
        case 51, 53, 55: return .lwk("Drizzle")
        case 56, 57: return .lwk("Freezing drizzle")
        case 61, 63, 65: return .lwk("Rain")
        case 66, 67: return .lwk("Freezing rain")
        case 71, 73, 75: return .lwk("Snow")
        case 77: return .lwk("Snow grains")
        case 80, 81, 82: return .lwk("Rain showers")
        case 85, 86: return .lwk("Snow showers")
        case 95: return .lwk("Thunderstorm")
        case 96, 99: return .lwk("Thunderstorm with hail")
        default: return .lwk("Unknown")
        }
    }

    /// SF Symbol name for the code (day/night variants for clear/partly cloudy).
    public static func symbolName(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1: return isDay ? "sun.max.fill" : "moon.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }

    public static func isThunderstorm(_ code: Int) -> Bool {
        (95...99).contains(code)
    }
}

/// Beaufort force (0–12) from a sustained wind speed in knots.
public enum Beaufort {
    public static func force(knots: Double) -> Int {
        switch knots {
        case ..<1:  return 0
        case ..<4:  return 1
        case ..<7:  return 2
        case ..<11: return 3
        case ..<17: return 4
        case ..<22: return 5
        case ..<28: return 6
        case ..<34: return 7
        case ..<41: return 8
        case ..<48: return 9
        case ..<56: return 10
        case ..<64: return 11
        default:    return 12
        }
    }
}
