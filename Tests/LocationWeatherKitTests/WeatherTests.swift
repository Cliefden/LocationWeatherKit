import Foundation
import Testing
@testable import LocationWeatherKit

@Suite("Pressure trend")
struct PressureTrendTests {
    let now = utc(12)

    @Test("History 3 h back decides the trend", arguments: [
        (1013.0, 1010.0, PressureTrend.falling),
        (1010.0, 1013.0, PressureTrend.rising),
        (1012.0, 1013.0, PressureTrend.stable),
        (1011.5, 1013.0, PressureTrend.stable),   // exactly at threshold is stable
    ])
    func historyBaseline(baseline: Double, current: Double, expected: PressureTrend) {
        let history = [
            PressureSample(time: utc(8), pressure: 999),       // older than the 3 h point: ignored
            PressureSample(time: utc(9), pressure: baseline),  // latest ≤ now − 3 h
            PressureSample(time: utc(10), pressure: 900),      // too recent: ignored
        ]
        #expect(PressureTrend.calculate(currentPressure: current, history: history, now: now) == expected)
    }

    @Test func historyWinsOverReadings() {
        let history = [PressureSample(time: utc(9), pressure: 1010)]
        let readings = [PressureSample(time: utc(8), pressure: 1020)]
        #expect(PressureTrend.calculate(currentPressure: 1010, history: history, readings: readings, now: now) == .stable)
    }

    @Test func readingFallbackNeedsMinimumAge() {
        let young = [PressureSample(time: now.addingTimeInterval(-3600), pressure: 1000)]
        #expect(PressureTrend.calculate(currentPressure: 1010, history: [], readings: young, now: now) == .stable)

        let old = [PressureSample(time: now.addingTimeInterval(-2.5 * 3600), pressure: 1000)]
        #expect(PressureTrend.calculate(currentPressure: 1010, history: [], readings: old, now: now) == .rising)
    }

    @Test func noBaselineMeansNoPointInTimeTrend() {
        let history = [PressureSample(time: utc(11), pressure: 1000)]
        #expect(PressureTrend.calculate(at: now, pressure: 1010, history: history) == nil)
        #expect(PressureTrend.calculate(at: now, pressure: 1010, history: history + [PressureSample(time: utc(8), pressure: 1014)]) == .falling)
    }
}

@Suite("Open-Meteo request building")
struct OpenMeteoRequestTests {
    @Test func currentURL() throws {
        let url = try #require(OpenMeteoRequest.currentURL(latitude: 59.3293, longitude: 18.0686))
        #expect(url.host() == "api.open-meteo.com")
        #expect(url.path() == "/v1/forecast")
        #expect(url.queryValue("latitude") == "59.3293")
        #expect(url.queryValue("longitude") == "18.0686")
        let current = try #require(url.queryValue("current")).split(separator: ",").map(String.init)
        for field in ["pressure_msl", "surface_pressure", "wind_gusts_10m", "cloud_cover", "is_day"] {
            #expect(current.contains(field))
        }
        #expect(url.queryValue("hourly")?.contains("surface_pressure") == true)
        #expect(url.queryValue("past_hours") == "24")
        #expect(url.queryValue("forecast_hours") == "24")
        #expect(url.queryValue("timeformat") == "unixtime")
        #expect(url.queryValue("timezone") == "auto")
    }

    @Test func forecastURL() throws {
        let url = try #require(OpenMeteoRequest.forecastURL(latitude: 39.1, longitude: -120.03, days: 14))
        #expect(url.queryValue("forecast_days") == "14")
        #expect(url.queryValue("daily")?.contains("sunrise") == true)
        #expect(url.queryValue("hourly")?.contains("precipitation") == true)
    }

    @Test("Invalid input yields nil", arguments: [
        (Double.nan, 0.0), (0.0, Double.infinity), (91.0, 0.0), (0.0, -181.0),
    ])
    func invalidCoordinates(lat: Double, lon: Double) {
        #expect(OpenMeteoRequest.currentURL(latitude: lat, longitude: lon) == nil)
        #expect(OpenMeteoRequest.forecastURL(latitude: lat, longitude: lon, days: 3) == nil)
    }

    @Test func forecastDaysOutOfRange() {
        #expect(OpenMeteoRequest.forecastURL(latitude: 0, longitude: 0, days: 0) == nil)
        #expect(OpenMeteoRequest.forecastURL(latitude: 0, longitude: 0, days: 17) == nil)
    }
}

@Suite("Open-Meteo decoding")
struct OpenMeteoDecodingTests {
    @Test func currentFixture() throws {
        let weather = try OpenMeteoClient.parseCurrentWeather(try Fixture.data("openmeteo-current"), fetchedAt: utc(12))
        #expect(weather.temperature == 11.4)
        #expect(weather.pressure == 1010)
        #expect(weather.pressureKind == .meanSeaLevel)
        #expect(weather.surfacePressure == 1003)
        #expect(weather.windGusts == 35)
        #expect(weather.humidity == 82)
        #expect(weather.isDay)
        #expect(weather.cloudCover == 90)
        #expect(weather.weatherIcon == "cloud.rain.fill")
        #expect(weather.windDirectionText == "WSW")
        // The null last pressure_msl hour is skipped.
        #expect(weather.pressureHistory.count == 8)

        // Null-speed hour skipped; null gust falls back to speed; null
        // direction carries the previous one forward.
        #expect(weather.windForecast.count == 8)
        let nineOClock = try #require(weather.windForecast.first { $0.time == utc(9) })
        #expect(nineOClock.gusts == 15)
        #expect(nineOClock.direction == 210)
        let onePM = try #require(weather.windForecast.first { $0.time == utc(13) })
        #expect(onePM.direction == 250)
    }

    @Test func surfacePressureKind() throws {
        let weather = try OpenMeteoClient.parseCurrentWeather(
            try Fixture.data("openmeteo-current"), pressureKind: .surface, fetchedAt: utc(12))
        #expect(weather.pressure == 1003)
        #expect(weather.pressureKind == .surface)
        #expect(weather.pressureHistory.count == 9)
    }

    @Test func missingRequestedPressureFallsBack() throws {
        // The no-hourly fixture has only pressure_msl.
        let weather = try OpenMeteoClient.parseCurrentWeather(
            try Fixture.data("openmeteo-current-no-hourly"), pressureKind: .surface, fetchedAt: utc(15))
        #expect(weather.pressureKind == .meanSeaLevel)
        #expect(weather.windGusts == nil)
        #expect(weather.windGustsKnots == weather.windSpeedKnots)
        #expect(weather.pressureHistory.isEmpty)
    }

    @Test func garbageIsDecodingFailed() {
        #expect(throws: WeatherError.decodingFailed) {
            try OpenMeteoClient.parseCurrentWeather(Data("{\"nope\":1}".utf8), fetchedAt: utc(0))
        }
    }

    @Test func forecastFixture() throws {
        let forecast = try OpenMeteoClient.parseForecast(try Fixture.data("openmeteo-forecast"), fetchedAt: utc(0))
        #expect(forecast.timeZoneIdentifier == "Europe/Stockholm")
        #expect(forecast.timeZone?.identifier == "Europe/Stockholm")
        #expect(forecast.hourly.count == 5)
        #expect(forecast.hourly[3].temperature == nil)
        #expect(forecast.hourly[4].precipitation == nil)   // shorter parallel array
        #expect(forecast.hourly[1].weatherCode == 61)
        #expect(forecast.daily.count == 2)
        #expect(forecast.daily[0].dayStart == utc(-1))     // local midnight, CET
        #expect(forecast.daily[0].sunrise == Date(timeIntervalSince1970: 1_793_084_100))
        #expect(forecast.daily[1].temperatureMin == nil)
    }

    @Test func forecastSnapshot() throws {
        let forecast = try OpenMeteoClient.parseForecast(try Fixture.data("openmeteo-forecast"), fetchedAt: utc(0))
        let snap = try #require(forecast.snapshot(at: utc(3.2)))
        #expect(snap.pressure == 1015)
        #expect(snap.pressureTrend == .falling)   // 1018 → 1015 over 3 h
        let early = try #require(forecast.snapshot(at: utc(1)))
        #expect(early.pressureTrend == nil)       // no sample 3 h earlier
        #expect(forecast.snapshot(at: utc(10)) == nil)
    }
}

@Suite("Open-Meteo client")
struct OpenMeteoClientTests {
    @Test func currentWeatherCachesAndComputesTrend() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.tearDown() }
        let clock = TestClock(utc(12))
        let loader = StubLoader { _ in try .json("openmeteo-current") }
        let client = OpenMeteoClient(configuration: .init(pressureBaselineSuiteName: defaults.suiteName),
                                     loader: loader, now: clock.closure)

        let first = try await client.currentWeather(latitude: 59.33, longitude: 18.07)
        #expect(first.pressureTrend == .falling)   // 1013 at 09:00 → 1010
        _ = try await client.currentWeather(latitude: 59.3301, longitude: 18.0701)
        #expect(loader.requests.count == 1)        // same ~100 m cell, cached

        clock.advance(by: 16 * 60)
        _ = try await client.currentWeather(latitude: 59.33, longitude: 18.07)
        #expect(loader.requests.count == 2)        // 15 min lifetime expired
    }

    @Test func surfaceKindTrend() async throws {
        let loader = StubLoader { _ in try .json("openmeteo-current") }
        let client = OpenMeteoClient(
            configuration: .init(pressureKind: .surface, pressureBaselineKey: nil),
            loader: loader, now: { utc(12) })
        let weather = try await client.currentWeather(latitude: 59.33, longitude: 18.07)
        #expect(weather.pressureTrend == .rising)  // 1001 at 09:00 → 1003
    }

    @Test func persistedBaselineSurvivesRelaunch() async throws {
        let defaults = IsolatedDefaults()
        defer { defaults.tearDown() }
        let config = OpenMeteoClient.Configuration(pressureBaselineKey: "test.baselines",
                                                   pressureBaselineSuiteName: defaults.suiteName)

        // First launch at 12:00 records 1010 hPa.
        let first = OpenMeteoClient(configuration: config, loader: StubLoader { _ in try .json("openmeteo-current") },
                                    now: { utc(12) })
        _ = try await first.currentWeather(latitude: 59.33, longitude: 18.07)
        #expect(UserDefaults(suiteName: defaults.suiteName)?.dictionary(forKey: "test.baselines") != nil)

        // Relaunch 3 h later, API returns no hourly history and 1013 hPa.
        let second = OpenMeteoClient(configuration: config, loader: StubLoader { _ in try .json("openmeteo-current-no-hourly") },
                                     now: { utc(15) })
        let weather = try await second.currentWeather(latitude: 59.33, longitude: 18.07)
        #expect(weather.pressureTrend == .rising)

        // A different place has no baseline.
        let elsewhere = try await second.currentWeather(latitude: 39.1, longitude: -120.0)
        #expect(elsewhere.pressureTrend == .stable)
    }

    @Test func httpErrorIsInvalidResponse() async {
        let client = OpenMeteoClient(configuration: .init(pressureBaselineKey: nil), loader: StubLoader { _ in .status(503) })
        await #expect(throws: WeatherError.invalidResponse) {
            try await client.currentWeather(latitude: 1, longitude: 1)
        }
    }

    @Test func decodeErrorIsReported() async {
        let reported = Reported()
        let client = OpenMeteoClient(
            configuration: .init(pressureBaselineKey: nil),
            loader: StubLoader { _ in StubLoader.Response(data: Data("[]".utf8), status: 200) },
            errorReporter: { op, _ in reported.append(op) })
        await #expect(throws: WeatherError.decodingFailed) {
            try await client.currentWeather(latitude: 1, longitude: 1)
        }
        #expect(reported.values == ["weather.decode"])
    }

    @Test func forecastStaleFallbackAndDiskCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lwk-forecast-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock(utc(0))
        let loader = StubLoader { _ in try .json("openmeteo-forecast") }
        let config = OpenMeteoClient.Configuration(forecastDiskCacheDirectory: dir, pressureBaselineKey: nil)
        let client = OpenMeteoClient(configuration: config, loader: loader, now: clock.closure)

        let fresh = try await client.forecast(latitude: 59.33, longitude: 18.07, days: 3)
        #expect(fresh.hourly.count == 5)
        #expect(loader.requests.first?.queryValue("forecast_days") == "3")

        // A new client (relaunch) is served from disk without a request.
        let relaunched = OpenMeteoClient(configuration: config, loader: loader, now: clock.closure)
        _ = try await relaunched.forecast(latitude: 59.33, longitude: 18.07, days: 3)
        #expect(loader.requests.count == 1)

        // Expired + offline → stale copy (under 24 h).
        clock.advance(by: 4 * 3600)
        loader.setRoutes { _ in throw URLError(.notConnectedToInternet) }
        let stale = try await relaunched.forecast(latitude: 59.33, longitude: 18.07, days: 3)
        #expect(stale.fetchedAt == utc(0))

        // Past the stale limit the error surfaces.
        clock.advance(by: 21 * 3600)
        await #expect(throws: URLError.self) {
            try await relaunched.forecast(latitude: 59.33, longitude: 18.07, days: 3)
        }
    }

    @Test func concurrentForecastsShareOneDownload() async throws {
        let loader = StubLoader { _ in try .json("openmeteo-forecast") }
        let client = OpenMeteoClient(configuration: .init(pressureBaselineKey: nil), loader: loader)
        async let a = client.forecast(latitude: 10, longitude: 10, days: 7)
        async let b = client.forecast(latitude: 10, longitude: 10, days: 7)
        _ = try await (a, b)
        #expect(loader.requests.count == 1)
    }
}

@Suite("Weather helpers")
struct WeatherHelperTests {
    @Test("Compass points", arguments: [
        (0.0, 0), (11.2, 0), (11.25, 1), (90, 4), (359, 0), (-90, 12), (725, 0), (202.5, 9),
    ])
    func compass(degrees: Double, index: Int) {
        #expect(Compass.pointIndex(degrees: degrees) == index)
    }

    @Test func beaufort() {
        #expect(Beaufort.force(knots: 0.5) == 0)
        #expect(Beaufort.force(knots: 16.9) == 4)
        #expect(Beaufort.force(knots: 70) == 12)
    }

    @Test func wmo() {
        #expect(WMOWeatherCode.symbolName(for: 0, isDay: false) == "moon.stars.fill")
        #expect(WMOWeatherCode.description(for: 1234) == "Unknown")
        #expect(WMOWeatherCode.isThunderstorm(96))
    }
}

final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func append(_ value: String) { lock.withLock { _values.append(value) } }
    var values: [String] { lock.withLock { _values } }
}
