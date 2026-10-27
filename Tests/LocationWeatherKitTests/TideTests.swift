import Foundation
import Testing
@testable import LocationWeatherKit

@Suite("Tide extremes")
struct FindExtremesTests {
    @Test func tooFewSamples() {
        #expect(TideData.findExtremes(in: []).isEmpty)
        #expect(TideData.findExtremes(in: [TideSample(time: utc(0), height: 1), TideSample(time: utc(1), height: 2)]).isEmpty)
    }

    @Test func refinesSinusoidPeakBetweenSamples() throws {
        // Semi-diurnal-ish tide with a high at 02:30 and low at 08:42.
        let period = 12.42 * 3600
        let peak = utc(2.5)
        let samples = (0..<12).map { h -> TideSample in
            let t = utc(Double(h))
            return TideSample(time: t, height: cos(2 * .pi * t.timeIntervalSince(peak) / period))
        }
        let events = TideData.findExtremes(in: samples)
        #expect(events.map(\.kind) == [.high, .low])
        let high = try #require(events.first)
        #expect(abs(high.time.timeIntervalSince(peak)) < 5 * 60)
        #expect(abs(high.heightMeters - 1) < 0.02)
        let low = events[1]
        #expect(abs(low.time.timeIntervalSince(peak.addingTimeInterval(period / 2))) < 5 * 60)
    }

    @Test func unequalSpacingUsesRealTimestamps() throws {
        // Parabola y = 1 − ((t − 2h)/1h)² sampled at 0 h, 1.5 h and 4 h (a gap
        // where a null reading was skipped). The vertex is exactly 02:00.
        func y(_ hours: Double) -> Double { 1 - pow(hours - 2, 2) }
        let samples = [0.0, 1.5, 4.0].map { TideSample(time: utc($0), height: y($0)) }
        let event = try #require(TideData.findExtremes(in: samples).first)
        #expect(event.kind == .high)
        #expect(abs(event.time.timeIntervalSince(utc(2))) < 1)
        #expect(abs(event.heightMeters - 1) < 1e-9)
    }

    @Test func plateauCountsOnce() {
        let heights = [0.0, 1.0, 1.0, 0.0]
        let samples = heights.enumerated().map { TideSample(time: utc(Double($0.offset)), height: $0.element) }
        let events = TideData.findExtremes(in: samples)
        #expect(events.count == 1)
        #expect(events.first?.kind == .high)
    }
}

@Suite("Tide state")
struct TideStateTests {
    let data = TideData(
        events: [
            TideEvent(kind: .high, time: utc(3), heightMeters: 1.2),
            TideEvent(kind: .low, time: utc(9), heightMeters: -0.1),
            TideEvent(kind: .high, time: utc(15), heightMeters: 1.1),
        ],
        samples: [],
        fetchedAt: utc(0),
        source: .model
    )

    @Test func nextEventIsStrictlyAfter() {
        #expect(data.nextEvent(after: utc(0))?.time == utc(3))
        #expect(data.nextEvent(after: utc(3))?.time == utc(9))
        #expect(data.nextEvent(after: utc(16)) == nil)
        #expect(data.previousEvent(before: utc(9))?.kind == .low)
    }

    @Test("State at time", arguments: [
        (0.0, TideState.rising),
        (2.6, TideState.high),     // within 30 min of the high
        (3.49, TideState.high),
        (3.6, TideState.falling),
        (8.7, TideState.low),
        (12.0, TideState.rising),
    ])
    func state(hour: Double, expected: TideState) {
        #expect(data.state(at: utc(hour)) == expected)
    }

    @Test func noStatePastLastEvent() {
        #expect(data.state(at: utc(20)) == nil)
    }

    @Test func rangeAndSourceLabels() {
        #expect(data.heightRange == -0.1...1.2)
        #expect(TideSource.model.isModelEstimate)
        #expect(TideSource.model.datumLabel == "MSL")
        let station = NOAAStation(id: "1", name: "X", latitude: 0, longitude: 0)
        #expect(TideSource.noaa(station: station, distanceKm: 3).datumLabel == "MLLW")
        #expect(TideSource.noaa(station: station, distanceKm: 3).station == station)
    }

    @Test func heightFormatting() {
        let event = TideEvent(kind: .high, time: utc(0), heightMeters: 1.0)
        #expect(event.formattedHeight(locale: Locale(identifier: "sv_SE")) == "1.0 m")
        #expect(event.formattedHeight(locale: Locale(identifier: "en_US")) == "3.3 ft")
    }
}

@Suite("Tide requests and decoding")
struct TideDecodingTests {
    @Test func noaaURL() throws {
        let url = try #require(NOAATideRequest.predictionsURL(
            stationID: "9414290", interval: .hourly, begin: utc(1.5), hours: 84, application: "Lunker"))
        #expect(url.host() == "api.tidesandcurrents.noaa.gov")
        #expect(url.queryValue("station") == "9414290")
        #expect(url.queryValue("begin_date") == "20261027 01:30")
        #expect(url.queryValue("interval") == "h")
        #expect(url.queryValue("range") == "84")
        #expect(url.queryValue("datum") == "MLLW")
        #expect(url.queryValue("time_zone") == "gmt")
        #expect(url.queryValue("units") == "metric")
        #expect(url.queryValue("application") == "Lunker")
    }

    @Test func marineURL() throws {
        let url = try #require(OpenMeteoMarineRequest.seaLevelURL(latitude: 57.7, longitude: 11.9))
        #expect(url.host() == "marine-api.open-meteo.com")
        #expect(url.queryValue("hourly") == "sea_level_height_msl")
        #expect(url.queryValue("forecast_days") == "3")
        #expect(url.queryValue("timezone") == "GMT")
        #expect(OpenMeteoMarineRequest.seaLevelURL(latitude: .nan, longitude: 0) == nil)
    }

    @Test func parseHilo() throws {
        let predictions = try NOAATideRequest.parsePredictions(try Fixture.data("noaa-hilo"))
        #expect(predictions.count == 4)                       // bad date dropped
        #expect(predictions.map(\.kind) == [.high, .low, .high, .low])   // sorted; HH/LL accepted
        #expect(predictions[0].time == utc(3.2))
        #expect(predictions[1].height == -0.105)              // whitespace trimmed
    }

    @Test func parseHourly() throws {
        let predictions = try NOAATideRequest.parsePredictions(try Fixture.data("noaa-hourly"))
        #expect(predictions.count == 6)
        #expect(predictions.allSatisfy { $0.kind == nil })
    }

    @Test func parseAPIError() throws {
        let data = try Fixture.data("noaa-error")
        #expect(throws: NOAATideRequest.NOAAError.apiError("No Predictions data was found. Please make sure the Datum input is valid.")) {
            try NOAATideRequest.parsePredictions(data)
        }
    }

    @Test func parseMarine() throws {
        let sea = try OpenMeteoMarineRequest.parseSeaLevel(try Fixture.data("marine"))
        #expect(sea.samples.count == 11)                      // null 06:00 skipped
        #expect(sea.samples.first?.time == utc(0))            // parsed as GMT
        #expect(!sea.allNull)
        let inland = try OpenMeteoMarineRequest.parseSeaLevel(try Fixture.data("marine-inland"))
        #expect(inland.samples.isEmpty)
        #expect(inland.allNull)
    }
}

@Suite("NOAA station index")
struct NOAAStationIndexTests {
    let index = NOAAStationIndex(stations: NOAAStationIndex.decodeCompact((try? Fixture.data("stations-compact")) ?? Data()))

    @Test func decodeCompact() {
        #expect(index.stations.count == 4)                    // malformed row dropped
        #expect(index.station(id: "SFB1201")?.bin == 13)
    }

    @Test func decodeMDAPI() throws {
        let stations = try NOAAStationIndex.decodeMDAPI(try Fixture.data("mdapi-stations"))
        #expect(stations.count == 2)
        #expect(stations[0].displayName == "San Francisco, CA")
    }

    @Test func nearestAndNearby() throws {
        let match = try #require(index.nearest(latitude: 37.807, longitude: -122.466, maxDistanceKm: 25))
        #expect(match.id == "9414290")
        #expect(match.distanceKm < 0.2)
        #expect(index.nearest(latitude: 36.0, longitude: -122.466, maxDistanceKm: 25) == nil)

        let nearby = index.nearby(latitude: 37.807, longitude: -122.466, radiusKm: 120, limit: 3)
        #expect(nearby.map(\.id) == ["9414290", "SFB1201", "9414750"])
        #expect(zip(nearby, nearby.dropFirst()).allSatisfy { $0.distanceKm <= $1.distanceKm })
    }

    @Test func bundledListLoads() throws {
        let bundled = NOAAStationIndex.bundledTideStations
        #expect(bundled.stations.count > 3000)
        let sf = try #require(bundled.nearest(latitude: 37.8063, longitude: -122.4659, maxDistanceKm: 5))
        #expect(sf.distanceKm < 5)
    }

    @Test func coverage() {
        #expect(NOAAStationIndex.isPlausiblyCovered(latitude: 37.8, longitude: -122.4))
        #expect(NOAAStationIndex.isPlausiblyCovered(latitude: 13.4, longitude: 144.7))    // Guam
        #expect(!NOAAStationIndex.isPlausiblyCovered(latitude: 59.3, longitude: 18.1))    // Stockholm
    }

    @Test func distance() {
        // Stockholm → Gothenburg ≈ 397 km.
        let km = GeoDistance.haversineKm(59.3293, 18.0686, 57.7089, 11.9746)
        #expect(abs(km - 397) < 5)
    }
}

@Suite("Tide client")
struct TideClientTests {
    let index = NOAAStationIndex(stations: NOAAStationIndex.decodeCompact((try? Fixture.data("stations-compact")) ?? Data()))

    func noaaRoutes(_ url: URL) throws -> StubLoader.Response {
        if url.host() == "api.tidesandcurrents.noaa.gov" {
            return try .json(url.queryValue("interval") == "hilo" ? "noaa-hilo" : "noaa-hourly")
        }
        return try .json("marine")
    }

    @Test func noaaStationPreferred() async throws {
        let loader = StubLoader(noaaRoutes)
        let client = TideClient(configuration: .init(applicationName: "Sextant"), stations: index, loader: loader, now: { utc(12) })
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466)

        guard case .noaa(let station, let km) = tides.source else {
            Issue.record("expected NOAA source, got \(tides.source)")
            return
        }
        #expect(station.id == "9414290")
        #expect(km < 1)
        #expect(tides.events.count == 4)
        #expect(tides.samples.count == 6)                    // hourly heights
        #expect(loader.requests.count == 2)
        #expect(loader.requests.allSatisfy { $0.queryValue("begin_date") == "20261027 00:00" })   // 12 h lookback
        #expect(loader.requests.allSatisfy { $0.queryValue("application") == "Sextant" })

        _ = try await client.fetchTides(latitude: 37.807, longitude: -122.466)
        #expect(loader.requests.count == 2)                  // cached
    }

    @Test func preferredStationOverridesNearest() async throws {
        let loader = StubLoader(noaaRoutes)
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: index, loader: loader)
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466, preferredStationID: "9414523")
        #expect(tides.source.station?.id == "9414523")
        #expect(client.station(latitude: 37.807, longitude: -122.466, preferredStationID: "nope")?.id == "9414290")
    }

    @Test func hiloOnlyWhenHourlyDisabled() async throws {
        let loader = StubLoader(noaaRoutes)
        let client = TideClient(configuration: .init(applicationName: "Sextant", includeNOAAHourlyHeights: false),
                                stations: index, loader: loader)
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466)
        #expect(loader.requests.count == 1)
        #expect(tides.samples.map(\.time) == tides.events.map(\.time))
    }

    @Test func noaaFailureFallsBackToModel() async throws {
        let reported = Reported()
        let loader = StubLoader { url in
            url.host() == "api.tidesandcurrents.noaa.gov" ? .status(500) : try .json("marine")
        }
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: index, loader: loader,
                                errorReporter: { op, _ in reported.append(op) })
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466)
        #expect(tides.source == .model)
        #expect(tides.events.map(\.kind) == [.high, .low])
        #expect(reported.values == ["tides.noaa"])
    }

    @Test func outsideCoverageGoesStraightToModel() async throws {
        let loader = StubLoader(noaaRoutes)
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: index, loader: loader)
        let tides = try await client.fetchTides(latitude: 57.7, longitude: 11.9)
        #expect(tides.source.isModelEstimate)
        #expect(loader.requests.map { $0.host() } == ["marine-api.open-meteo.com"])
    }

    @Test func inlandIsRememberedThenRetried() async throws {
        let clock = TestClock(utc(0))
        let loader = StubLoader { _ in try .json("marine-inland") }
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: index, loader: loader, now: clock.closure)

        await #expect(throws: TideError.notCoastal) { try await client.fetchTides(latitude: 61, longitude: 15) }
        await #expect(throws: TideError.notCoastal) { try await client.fetchTides(latitude: 61, longitude: 15) }
        #expect(loader.requests.count == 1)

        clock.advance(by: 25 * 3600)
        await #expect(throws: TideError.notCoastal) { try await client.fetchTides(latitude: 61, longitude: 15) }
        #expect(loader.requests.count == 2)
    }

    @Test func badMarinePayloadIsDecodingFailed() async {
        let loader = StubLoader { _ in StubLoader.Response(data: Data("{}".utf8), status: 200) }
        let client = TideClient(configuration: .init(applicationName: "Lunker"), stations: index, loader: loader)
        await #expect(throws: TideError.decodingFailed) { try await client.fetchTides(latitude: 57.7, longitude: 11.9) }
    }
}
