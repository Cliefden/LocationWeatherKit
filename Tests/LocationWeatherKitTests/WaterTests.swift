import Foundation
import Testing
@testable import LocationWeatherKit

@Suite("USGS water")
struct USGSWaterTests {
    /// Little Falls, Potomac River.
    let latitude = 38.95
    let longitude = -77.12

    @Test func latestURLHasBoxParametersAndProperties() throws {
        let url = try #require(USGSWaterRequest.latestURL(latitude: latitude, longitude: longitude, radiusKm: 25))
        #expect(url.host() == "api.waterdata.usgs.gov")
        #expect(url.path() == "/ogcapi/v1/collections/latest-continuous/items")
        #expect(url.queryValue("parameter_code") == "00060,00065,00010")
        let bbox = try #require(url.queryValue("bbox")).split(separator: ",").compactMap { Double($0) }
        #expect(bbox.count == 4)
        #expect(bbox[0] < longitude && bbox[2] > longitude && bbox[1] < latitude && bbox[3] > latitude)
        #expect(url.queryValue("api_key") == nil)
        #expect(USGSWaterRequest.latestURL(latitude: latitude, longitude: longitude, radiusKm: 25, apiKey: "k")?.queryValue("api_key") == "k")
        #expect(USGSWaterRequest.latestURL(latitude: 95, longitude: 0, radiusKm: 25) == nil)
    }

    @Test func historyAndLocationURLs() throws {
        let history = try #require(USGSWaterRequest.historyURL(gaugeID: "USGS-01646500", parameter: .discharge))
        #expect(history.path() == "/ogcapi/v1/collections/continuous/items")
        #expect(history.queryValue("time") == "PT24H")
        #expect(history.queryValue("monitoring_location_id") == "USGS-01646500")
        let location = try #require(USGSWaterRequest.locationURL(gaugeID: "USGS-01646500"))
        #expect(location.path() == "/ogcapi/v1/collections/monitoring-locations/items/USGS-01646500")
    }

    @Test func parsesLatestSkippingNullValues() throws {
        let readings = try USGSWaterRequest.parseLatest(Fixture.data("usgs-latest"))
        #expect(readings.count == 6)
        #expect(readings.contains { $0.gaugeID == "USGS-01652500" })   // fractional-second timestamp
        #expect(!readings.contains { $0.gaugeID == "USGS-09999999" })
    }

    @Test func nearestPicksClosestFreshFlowGauge() throws {
        let readings = try USGSWaterRequest.parseLatest(Fixture.data("usgs-latest"))
        let gauge = try #require(USGSWaterClient.nearest(
            readings, latitude: latitude, longitude: longitude, radiusKm: 25, maxAge: 6 * 3600, now: utc(12)
        ))
        #expect(gauge.id == "USGS-01646500")
        #expect(gauge.stationNumber == "01646500")
        #expect(gauge.discharge?.value == 2140)
        #expect(gauge.gaugeHeight?.value == 3.5)
        #expect(gauge.waterTemperature?.value == 12.1)
        #expect(gauge.distanceKm < 1)
    }

    @Test func nearestIgnoresStaleTemperatureOnlyAndFarGauges() throws {
        let readings = try USGSWaterRequest.parseLatest(Fixture.data("usgs-latest"))
        // Without 01646500, the stale 01648000 and temperature-only 01651800 don't qualify.
        let others = readings.filter { $0.gaugeID != "USGS-01646500" }
        let gauge = USGSWaterClient.nearest(others, latitude: latitude, longitude: longitude, radiusKm: 25, maxAge: 6 * 3600, now: utc(12))
        #expect(gauge?.id == "USGS-01652500")
        #expect(USGSWaterClient.nearest(others, latitude: latitude, longitude: longitude, radiusKm: 5, maxAge: 6 * 3600, now: utc(12)) == nil)
    }

    @Test("Trend thresholds", arguments: [
        (100.0, 106.0, FlowTrend.rising),
        (100.0, 94.0, FlowTrend.falling),
        (100.0, 104.0, FlowTrend.steady),
        (0.0, 0.04, FlowTrend.steady),
        (0.0, 0.2, FlowTrend.rising),
    ])
    func trendThresholds(older: Double, newer: Double, expected: FlowTrend) {
        #expect(FlowTrend.between(older, newer) == expected)
    }

    @Test func historyIsSortedAndGivesTrend() throws {
        let history = try USGSWaterRequest.parseHistory(Fixture.data("usgs-history"))
        #expect(history.first?.value == 1800)
        #expect(history.last?.value == 2140)
        #expect(USGSWaterClient.trend(from: history) == .rising)
        #expect(USGSWaterClient.trend(from: Array(history.prefix(1))) == nil)
    }

    @Test func clientCombinesNameAndTrendAndCaches() async throws {
        let loader = StubLoader { url in
            if url.path().contains("latest-continuous") { return try .json("usgs-latest") }
            if url.path().contains("monitoring-locations") { return try .json("usgs-location") }
            return try .json("usgs-history")
        }
        let client = USGSWaterClient(loader: loader, now: { utc(12) })
        let gauge = try #require(try await client.nearestGauge(latitude: latitude, longitude: longitude))
        #expect(gauge.name == "POTOMAC RIVER NEAR WASH, DC LITTLE FALLS PUMP STA")
        #expect(gauge.trend == .rising)
        #expect(loader.requests.count == 3)
        #expect(loader.requests.contains { $0.queryValue("parameter_code") == "00060" && $0.path().contains("/continuous/") })

        _ = try await client.nearestGauge(latitude: latitude, longitude: longitude)
        #expect(loader.requests.count == 3)   // cached
    }

    @Test func extrasFailingStillReturnsGauge() async throws {
        let loader = StubLoader { url in
            url.path().contains("latest-continuous") ? try .json("usgs-latest") : .status(503)
        }
        let client = USGSWaterClient(loader: loader, now: { utc(12) })
        let gauge = try await client.nearestGauge(latitude: latitude, longitude: longitude)
        #expect(gauge?.id == "USGS-01646500")
        #expect(gauge?.name == nil)
        #expect(gauge?.trend == nil)
    }

    @Test func outsideUSMakesNoRequest() async throws {
        let loader = StubLoader { _ in .status(500) }
        let client = USGSWaterClient(loader: loader, now: { utc(12) })
        #expect(try await client.nearestGauge(latitude: 59.33, longitude: 18.07) == nil)
        #expect(loader.requests.isEmpty)
        #expect(USGSWaterClient.isPlausiblyCovered(latitude: 61.2, longitude: -149.9))   // Anchorage
        #expect(USGSWaterClient.isPlausiblyCovered(latitude: 21.3, longitude: -157.8))   // Honolulu
    }
}

@Suite("Marine conditions")
struct MarineConditionsTests {
    @Test func parsesSeaSurfaceTemperature() throws {
        let conditions = try #require(try MarineConditionsRequest.parse(Fixture.data("marine-sst"), fetchedAt: utc(12)))
        #expect(conditions.seaSurfaceTemperature == 5.6)
        #expect(conditions.waveHeight == 0.18)
        #expect(conditions.time == utc(10))
    }

    @Test func inlandIsNilAndCached() async throws {
        #expect(try MarineConditionsRequest.parse(Fixture.data("marine-sst-inland"), fetchedAt: utc(12)) == nil)
        let loader = StubLoader { _ in try .json("marine-sst-inland") }
        let client = MarineConditionsClient(loader: loader, now: { utc(12) })
        #expect(try await client.current(latitude: 48.85, longitude: 2.35) == nil)
        #expect(try await client.current(latitude: 48.85, longitude: 2.35) == nil)
        #expect(loader.requests.count == 1)
        #expect(loader.requests.first?.queryValue("current") == "sea_surface_temperature,wave_height")
    }
}

@Suite("Past weather and tides")
struct PastConditionsTests {
    @Test func historicalURLPicksEndpointAndDays() throws {
        let recent = try #require(OpenMeteoRequest.historicalURL(latitude: 59.33, longitude: 18.07, around: utc(10), now: utc(12, day: 30)))
        #expect(recent.host() == "historical-forecast-api.open-meteo.com")
        #expect(recent.queryValue("start_date") == "2026-10-26")
        #expect(recent.queryValue("end_date") == "2026-10-28")

        let old = try #require(OpenMeteoRequest.historicalURL(
            latitude: 59.33, longitude: 18.07, around: Date(timeIntervalSince1970: 1_500_000_000), now: utc(12)
        ))
        #expect(old.host() == "archive-api.open-meteo.com")

        // The end is clamped to today; the future is refused.
        let today = try #require(OpenMeteoRequest.historicalURL(latitude: 59.33, longitude: 18.07, around: utc(10), now: utc(12)))
        #expect(today.queryValue("end_date") == "2026-10-27")
        #expect(OpenMeteoRequest.historicalURL(latitude: 59.33, longitude: 18.07, around: utc(12, day: 2), now: utc(12)) == nil)
    }

    @Test func historicalWeatherIsCachedPerDay() async throws {
        let loader = StubLoader { _ in try .json("openmeteo-forecast") }
        let client = OpenMeteoClient(configuration: .init(pressureBaselineKey: nil), loader: loader, now: { utc(12, day: 30) })
        let weather = try await client.historicalWeather(latitude: 59.33, longitude: 18.07, around: utc(10))
        #expect(!weather.hourly.isEmpty)
        _ = try await client.historicalWeather(latitude: 59.33, longitude: 18.07, around: utc(15))
        #expect(loader.requests.count == 1)
        _ = try await client.historicalWeather(latitude: 59.33, longitude: 18.07, around: utc(10, day: 1))
        #expect(loader.requests.count == 2)
    }

    @Test func pastTidesUseA52HourNOAAWindow() async throws {
        let index = NOAAStationIndex(stations: NOAAStationIndex.decodeCompact((try? Fixture.data("stations-compact")) ?? Data()))
        let loader = StubLoader { url in
            try .json(url.queryValue("interval") == "hilo" ? "noaa-hilo" : "noaa-hourly")
        }
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: index, loader: loader, now: { utc(12, day: 30) })
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466, around: utc(12))
        #expect(tides.source.station?.id == "9414290")
        #expect(loader.requests.allSatisfy { $0.queryValue("begin_date") == "20261026 10:00" })
        #expect(loader.requests.allSatisfy { $0.queryValue("range") == "52" })
    }

    @Test func pastTidesFallBackToDatedModel() async throws {
        let loader = StubLoader { _ in try .json("marine") }
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: NOAAStationIndex(stations: []), loader: loader)
        _ = try await client.fetchTides(latitude: 57.7, longitude: 11.8, around: utc(12))
        let url = try #require(loader.requests.first)
        #expect(url.queryValue("start_date") == "2026-10-26")
        #expect(url.queryValue("end_date") == "2026-10-28")
        #expect(url.queryValue("forecast_days") == nil)
    }
}
