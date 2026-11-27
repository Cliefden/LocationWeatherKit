import Foundation

/// Sea-surface conditions from the Open-Meteo Marine model.
public struct MarineConditions: Sendable, Hashable, Codable {
    /// Sea-surface temperature (°C).
    public var seaSurfaceTemperature: Double
    /// Significant wave height (m), when the model has it.
    public var waveHeight: Double?
    /// Time of the model value.
    public var time: Date
    public var fetchedAt: Date

    public init(seaSurfaceTemperature: Double, waveHeight: Double?, time: Date, fetchedAt: Date) {
        self.seaSurfaceTemperature = seaSurfaceTemperature
        self.waveHeight = waveHeight
        self.time = time
        self.fetchedAt = fetchedAt
    }
}

/// A USGS stream gauge with its latest readings.
public struct RiverGauge: Sendable, Hashable, Codable, Identifiable {
    /// "USGS-01646500".
    public var id: String
    /// USGS station name, e.g. "POTOMAC RIVER NEAR WASH, DC LITTLE FALLS PUMP STA". nil when the
    /// metadata request failed.
    public var name: String?
    public var latitude: Double
    public var longitude: Double
    public var distanceKm: Double
    /// Discharge (ft³/s).
    public var discharge: Reading?
    /// Gauge height (ft).
    public var gaugeHeight: Reading?
    /// Water temperature (°C).
    public var waterTemperature: Reading?
    /// Change over the last ~24 h of discharge (or gauge height when the gauge
    /// has no discharge). nil when the history request failed.
    public var trend: FlowTrend?

    public init(
        id: String, name: String?, latitude: Double, longitude: Double, distanceKm: Double,
        discharge: Reading?, gaugeHeight: Reading?, waterTemperature: Reading?, trend: FlowTrend?
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.distanceKm = distanceKm
        self.discharge = discharge
        self.gaugeHeight = gaugeHeight
        self.waterTemperature = waterTemperature
        self.trend = trend
    }

    public struct Reading: Sendable, Hashable, Codable {
        public var value: Double
        public var time: Date

        public init(value: Double, time: Date) {
            self.value = value
            self.time = time
        }
    }

    /// The station number without the agency prefix ("01646500").
    public var stationNumber: String {
        id.hasPrefix("USGS-") ? String(id.dropFirst(5)) : id
    }

    /// The gauge's page on waterdata.usgs.gov.
    public var webURL: URL? {
        URL(string: "https://waterdata.usgs.gov/monitoring-location/\(id)/")
    }

    /// Gauge height in metres.
    public var gaugeHeightMeters: Double? {
        gaugeHeight.map { $0.value / UnitConversion.feetPerMeter }
    }

    /// Discharge in m³/s.
    public var dischargeCubicMeters: Double? {
        discharge.map { $0.value * 0.028_316_846_6 }
    }
}

/// Direction of a river's flow over the last day.
public enum FlowTrend: String, Sendable, Hashable, Codable {
    case rising
    case steady
    case falling

    /// ±5 % (of the older value) counts as steady; a zero baseline uses ±0.05 absolute.
    public static func between(_ older: Double, _ newer: Double) -> FlowTrend {
        let threshold = abs(older) > 0.000_1 ? abs(older) * 0.05 : 0.05
        if newer - older > threshold { return .rising }
        if older - newer > threshold { return .falling }
        return .steady
    }
}
