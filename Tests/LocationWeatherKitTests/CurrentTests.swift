import Foundation
import Testing
@testable import LocationWeatherKit

/// 2026-10-27 hh:mm GMT.
private func gmt(_ hour: Int, _ minute: Int) -> Date {
    utc(Double(hour) + Double(minute) / 60)
}

@Suite("Current requests and decoding")
struct CurrentDecodingTests {
    @Test func noaaURL() throws {
        let url = try #require(NOAACurrentRequest.predictionsURL(
            stationID: "SFB1201", bin: 13, begin: utc(-3), hours: 56, application: "Sextant"))
        #expect(url.host() == "api.tidesandcurrents.noaa.gov")
        #expect(url.queryValue("product") == "currents_predictions")
        #expect(url.queryValue("interval") == "MAX_SLACK")
        #expect(url.queryValue("station") == "SFB1201")
        #expect(url.queryValue("bin") == "13")
        #expect(url.queryValue("units") == "english")
        #expect(url.queryValue("time_zone") == "gmt")
        #expect(url.queryValue("begin_date") == "20261026 21:00")
        #expect(url.queryValue("range") == "56")
        #expect(url.queryValue("application") == "Sextant")

        let noBin = try #require(NOAACurrentRequest.predictionsURL(
            stationID: "ACT0091", bin: nil, begin: utc(0), hours: 56, application: "Sextant"))
        #expect(noBin.queryValue("bin") == nil)
    }

    @Test func parseMaxSlack() throws {
        let events = try NOAACurrentRequest.parsePredictions(try Fixture.data("noaa-currents"))
        #expect(events.count == 5)                                    // bad date dropped
        #expect(events.map(\.kind) == [.ebb, .slack, .flood, .slack, .ebb])   // sorted
        #expect(events[0].time == gmt(1, 28))
        #expect(events[0].speedKnots == 2.19)
        #expect(events[0].directionDegrees == 40)                     // ebb → meanEbbDir
        #expect(events[1].directionDegrees == nil)                    // slack has no set
        #expect(events[1].speedKnots == 0)
        #expect(events[2].speedKnots == 1.81)                         // padded string accepted
        #expect(events[2].directionDegrees == 210)                    // flood → meanFloodDir
        #expect(events[4].directionDegrees == 40)                     // "40.4" string, rounded
    }

    @Test func parseErrors() throws {
        #expect(throws: NOAATideRequest.NOAAError.apiError("No Predictions data was found. Please make sure the Datum input is valid.")) {
            try NOAACurrentRequest.parsePredictions(try Fixture.data("noaa-error"))
        }
        #expect(throws: NOAATideRequest.NOAAError.invalidResponse) {
            try NOAACurrentRequest.parsePredictions(Data("[]".utf8))
        }
    }

    @Test func untypedRowsAreClassifiedBySpeed() throws {
        let json = #"{"current_predictions":{"cp":[{"Time":"2026-10-27 00:00","Velocity_Major":0.1},{"Time":"2026-10-27 03:00","Velocity_Major":-1.2,"meanEbbDir":95}]}}"#
        let events = try NOAACurrentRequest.parsePredictions(Data(json.utf8))
        #expect(events.map(\.kind) == [.slack, .ebb])
        #expect(events[1].directionDegrees == 95)
    }

    @Test func marineCurrentsURL() throws {
        let url = try #require(OpenMeteoMarineRequest.currentsURL(latitude: 57.7, longitude: 11.9, forecastDays: 3))
        #expect(url.host() == "marine-api.open-meteo.com")
        #expect(url.queryValue("hourly") == "ocean_current_velocity,ocean_current_direction")
        #expect(url.queryValue("forecast_days") == "3")
        #expect(url.queryValue("timeformat") == "unixtime")
        #expect(url.queryValue("timezone") == "GMT")
        #expect(OpenMeteoMarineRequest.currentsURL(latitude: 57.7, longitude: 11.9)?.queryValue("forecast_days") == "1")
        #expect(OpenMeteoMarineRequest.currentsURL(latitude: .nan, longitude: 0) == nil)
        #expect(OpenMeteoMarineRequest.currentsURL(latitude: 0, longitude: 0, forecastDays: 0) == nil)
    }

    @Test func parseMarineCurrents() throws {
        let currents = try OpenMeteoMarineRequest.parseCurrents(try Fixture.data("marine-currents"))
        #expect(currents.samples.count == 4)                          // null velocity / direction hours skipped
        #expect(!currents.allNull)
        #expect(currents.samples[1].time == utc(1))
        #expect(abs(currents.samples[1].speedKnots - 1.0) < 0.001)    // 1.852 km/h → 1 kt
        #expect(currents.samples[1].directionDegrees == 180.4)

        let inland = try OpenMeteoMarineRequest.parseCurrents(try Fixture.data("marine-currents-inland"))
        #expect(inland.samples.isEmpty)
        #expect(inland.allNull)

        #expect(throws: CurrentError.decodingFailed) { try OpenMeteoMarineRequest.parseCurrents(Data("{}".utf8)) }
    }
}

@Suite("Current interpolation")
struct CurrentInterpolationTests {
    let events: [CurrentEvent] = (try? NOAACurrentRequest.parsePredictions(Fixture.data("noaa-currents"))) ?? []

    @Test func atAnEventItsOwnValue() throws {
        let atMax = try #require(CurrentData.interpolate(events, at: gmt(6, 33)))
        #expect(abs(atMax.speedKnots - 1.81) < 1e-6)
        #expect(atMax.directionDegrees == 210)
        #expect(atMax.phase == .flood)
    }

    @Test func sineRuleFromSlackTowardMax() throws {
        let slack = gmt(4, 18), max = gmt(6, 33)
        let mid = slack.addingTimeInterval(max.timeIntervalSince(slack) / 2)
        let rising = try #require(CurrentData.interpolate(events, at: mid))
        #expect(abs(rising.speedKnots - 1.81 * sin(Double.pi / 4)) < 1e-6)
        #expect(rising.phase == .flood)
    }

    @Test func ebbTowardSlack() throws {
        let ebbing = try #require(CurrentData.interpolate(events, at: gmt(2, 0)))
        #expect(ebbing.directionDegrees == 40)
        #expect(ebbing.phase == .ebb)
        #expect(ebbing.speedKnots < 2.19)
        #expect(abs(ebbing.speedKnots - 2.19 * cos(.pi / 2 * (32.0 / 170.0))) < 1e-6)
    }

    @Test func slackAndOutsideWindow() throws {
        #expect(try #require(CurrentData.interpolate(events, at: gmt(10, 18))).phase == .slack)
        #expect(CurrentData.interpolate(events, at: gmt(0, 0)) == nil)        // before the first event
        #expect(CurrentData.interpolate(events, at: gmt(14, 0)) == nil)       // after the last
        #expect(CurrentData.interpolate([], at: gmt(5, 0)) == nil)
    }

    @Test func doubleFloodBlendsBetweenMaxima() throws {
        let double = [
            CurrentEvent(kind: .flood, time: utc(0), speedKnots: 2, directionDegrees: 100),
            CurrentEvent(kind: .flood, time: utc(2), speedKnots: 1, directionDegrees: 100),
        ]
        let mid = try #require(CurrentData.interpolate(double, at: utc(1)))
        #expect(abs(mid.speedKnots - 1.5) < 1e-9)
        #expect(mid.directionDegrees == 100)
    }

    @Test func dataEstimateAndUpcoming() throws {
        let station = NOAAStation(id: "ACT0091", name: "Eastport", latitude: 44.9, longitude: -66.98, bin: 1)
        let noaa = CurrentData(speedKnots: 1, directionDegrees: 210, fetchedAt: utc(5),
                               source: .noaa(station: station, distanceKm: 2), phase: .flood, events: events)
        #expect(noaa.upcomingEvents(after: utc(5)).map(\.kind) == [.flood, .slack, .ebb])
        #expect(noaa.estimate(at: gmt(6, 33))?.directionDegrees == 210)
        #expect(!noaa.source.isModelEstimate)
        #expect(noaa.source.station == station)

        let samples = [CurrentSample(time: utc(0), speedKnots: 0.5, directionDegrees: 89.6),
                       CurrentSample(time: utc(1), speedKnots: 0.8, directionDegrees: 120)]
        let model = CurrentData(speedKnots: 0.5, directionDegrees: 90, fetchedAt: utc(0), source: .model, samples: samples)
        #expect(model.source.isModelEstimate)
        #expect(model.source.station == nil)
        #expect(model.estimate(at: utc(0.4)) == CurrentEstimate(speedKnots: 0.5, directionDegrees: 90, phase: nil))
        #expect(model.estimate(at: utc(0.8))?.speedKnots == 0.8)
        #expect(model.estimate(at: utc(5)) == nil)                     // > 90 min from any sample
        #expect(CurrentSample.nearest(in: samples, to: utc(5))?.time == utc(1))
        #expect(CurrentSample.nearest(in: [], to: utc(5)) == nil)
    }

    @Test func labels() {
        #expect(CurrentEventKind.flood.localizedName == "Max flood")
        #expect(CurrentEventKind.slack.phaseName == "Near slack")
        #expect(CurrentError.unavailable.errorDescription == "No current data for this location.")
        let data = CurrentData(speedKnots: 1, directionDegrees: 225, fetchedAt: utc(0), source: .model)
        #expect(data.compass == Compass.abbreviation(degrees: 225))
    }
}

@Suite("Tidal current client")
struct TidalCurrentClientTests {
    let index = NOAAStationIndex(stations: [
        NOAAStation(id: "SFB1201", name: "Golden Gate Bridge", latitude: 37.8117, longitude: -122.4717, bin: 13),
        NOAAStation(id: "SFB1203", name: "Alcatraz Island", latitude: 37.8267, longitude: -122.4233, bin: 26),
    ])

    func routes(_ url: URL) throws -> StubLoader.Response {
        url.host() == "api.tidesandcurrents.noaa.gov" ? try .json("noaa-currents") : try .json("marine-currents")
    }

    @Test func noaaStationPreferredAndInterpolated() async throws {
        let loader = StubLoader(routes)
        let client = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                        loader: loader, now: { utc(5) })
        let data = try await client.fetchCurrent(latitude: 37.8120, longitude: -122.4720)

        guard case .noaa(let station, let km) = data.source else {
            Issue.record("expected NOAA source, got \(data.source)")
            return
        }
        #expect(station.id == "SFB1201")
        #expect(km < 1)
        #expect(data.phase == .flood)                                   // between slack 04:18 and flood 06:33
        #expect(data.directionDegrees == 210)
        let expected = 1.81 * sin(.pi / 2 * (42.0 / 135.0))
        #expect(abs(data.speedKnots - expected) < 1e-6)
        #expect(data.events.count == 5)
        #expect(data.samples.isEmpty)

        let request = try #require(loader.requests.first)
        #expect(request.queryValue("bin") == "13")
        #expect(request.queryValue("begin_date") == "20261026 21:00")   // 8 h lookback
        #expect(request.queryValue("range") == "56")
        #expect(request.queryValue("application") == "Sextant")

        _ = try await client.fetchCurrent(latitude: 37.8120, longitude: -122.4720)
        #expect(loader.requests.count == 1)                             // cached
    }

    @Test func stationSelection() {
        let client = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                        loader: StubLoader(routes))
        #expect(client.station(latitude: 37.8267, longitude: -122.4233)?.id == "SFB1203")
        #expect(client.station(latitude: 37.8267, longitude: -122.4233, preferredStationID: "SFB1201")?.id == "SFB1201")
        #expect(client.station(latitude: 37.5, longitude: -122.2) == nil)                // > 10 km
        #expect(client.station(latitude: 59.3, longitude: 18.1) == nil)                  // outside NOAA coverage
        #expect(client.nearbyStations(latitude: 37.8117, longitude: -122.4717).map(\.id) == ["SFB1201", "SFB1203"])
    }

    @Test func noaaOutsideWindowFallsBackToModel() async throws {
        let reported = Reported()
        let loader = StubLoader(routes)
        // 20:00: after the last predicted event, so NOAA can't bracket now.
        let client = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                        loader: loader, errorReporter: { op, _ in reported.append(op) }, now: { utc(20) })
        let data = try await client.fetchCurrent(latitude: 37.8120, longitude: -122.4720)
        #expect(data.source == .model)
        #expect(reported.values == ["currents.noaa"])
    }

    @Test func offlineNOAAReportingIsConfigurable() async throws {
        for reportsTransport in [true, false] {
            let reported = Reported()
            let loader = StubLoader { url in
                if url.host() == "api.tidesandcurrents.noaa.gov" { throw URLError(.timedOut) }
                return try .json("marine-currents")
            }
            let client = TidalCurrentClient(
                configuration: .init(applicationName: "Sextant", reportsTransportErrors: reportsTransport),
                stations: index, loader: loader, errorReporter: { op, _ in reported.append(op) }, now: { utc(1.2) })
            let data = try await client.fetchCurrent(latitude: 37.8120, longitude: -122.4720)
            #expect(data.source.isModelEstimate)
            #expect(reported.values == (reportsTransport ? ["currents.noaa"] : []))
        }
    }

    @Test func modelCurrentNow() async throws {
        let loader = StubLoader(routes)
        let client = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                        loader: loader, now: { utc(1.2) })
        let data = try await client.fetchCurrent(latitude: 57.7, longitude: 11.9)
        #expect(data.source == .model)
        #expect(data.phase == nil)
        #expect(data.events.isEmpty)
        #expect(abs(data.speedKnots - 1.0) < 0.001)                     // nearest hour (01:00)
        #expect(data.directionDegrees == 180)
        #expect(data.samples.count == 4)
        #expect(loader.requests.map { $0.host() } == ["marine-api.open-meteo.com"])
        #expect(loader.requests.first?.queryValue("forecast_days") == "1")
    }

    @Test func modelSeriesForRouters() async throws {
        let loader = StubLoader(routes)
        let client = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index, loader: loader)
        let series = try await client.modelCurrents(latitude: 57.7, longitude: 11.9, days: 3)
        #expect(series.count == 4)
        #expect(loader.requests.first?.queryValue("forecast_days") == "3")
        _ = try await client.modelCurrents(latitude: 57.7, longitude: 11.9, days: 3)
        #expect(loader.requests.count == 1)                              // cached
        // Even next to a NOAA station the series is the model.
        _ = try await client.modelCurrents(latitude: 37.8120, longitude: -122.4720, days: 3)
        #expect(loader.requests.last?.host() == "marine-api.open-meteo.com")
    }

    @Test func unavailableIsRememberedThenRetried() async throws {
        let clock = TestClock(utc(0))
        let loader = StubLoader { _ in try .json("marine-currents-inland") }
        let client = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                        loader: loader, now: clock.closure)

        await #expect(throws: CurrentError.unavailable) { try await client.fetchCurrent(latitude: 61, longitude: 15) }
        await #expect(throws: CurrentError.unavailable) { try await client.fetchCurrent(latitude: 61, longitude: 15) }
        await #expect(throws: CurrentError.unavailable) { try await client.modelCurrents(latitude: 61, longitude: 15) }
        #expect(loader.requests.count == 1)

        clock.advance(by: 25 * 3600)
        await #expect(throws: CurrentError.unavailable) { try await client.fetchCurrent(latitude: 61, longitude: 15) }
        #expect(loader.requests.count == 2)
    }

    @Test func badPayloadAndHTTPErrors() async {
        let reported = Reported()
        let garbage = TidalCurrentClient(
            configuration: .init(applicationName: "Sextant"), stations: index,
            loader: StubLoader { _ in StubLoader.Response(data: Data("{}".utf8), status: 200) },
            errorReporter: { op, _ in reported.append(op) })
        await #expect(throws: CurrentError.decodingFailed) { try await garbage.fetchCurrent(latitude: 57.7, longitude: 11.9) }
        #expect(reported.values == ["currents.decode"])

        let down = TidalCurrentClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                      loader: StubLoader { _ in .status(503) })
        await #expect(throws: CurrentError.invalidResponse) { try await down.fetchCurrent(latitude: 57.7, longitude: 11.9) }
    }

    @Test func bundledCurrentStationsCoverGoldenGate() throws {
        let bundled = NOAAStationIndex.bundledCurrentStations
        #expect(bundled.stations.count > 2000)
        let match = try #require(bundled.nearest(latitude: 37.8199, longitude: -122.4783, maxDistanceKm: 10))
        #expect(match.bin != nil)
        #expect(bundled.nearest(latitude: 59.3, longitude: 18.1, maxDistanceKm: 10) == nil)
    }
}
