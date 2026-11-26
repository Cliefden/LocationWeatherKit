import Foundation
import CoreLocation
import Testing
@testable import LocationWeatherKit

// 0.1.2: options that let Lunker adopt the package without behaviour changes.

@Suite("Lunker parity: current weather window")
struct CurrentWeatherWindowTests {
    /// Current conditions at `utc(12)` with hourly MSL pressure from `pastHours`
    /// before to `forecastHours` after: 1013 hPa up to 09:00, 1010 after.
    static func payload(pastHours: Int, forecastHours: Int) -> Data {
        let hours = (-pastHours...forecastHours).map { 12 + Double($0) }
        let times = hours.map { String(Int(utc($0).timeIntervalSince1970)) }.joined(separator: ",")
        let pressures = hours.map { $0 <= 9 ? "1013.0" : "1010.0" }.joined(separator: ",")
        let json = """
        {"current":{"temperature_2m":9.0,"relative_humidity_2m":90,"pressure_msl":1010.0,
          "wind_speed_10m":8.0,"wind_direction_10m":10,"weather_code":3,"is_day":1},
         "hourly":{"time":[\(times)],"pressure_msl":[\(pressures)]}}
        """
        return Data(json.utf8)
    }

    @Test func defaultWindowIsUnchanged() async throws {
        let config = OpenMeteoClient.Configuration()
        #expect(config.currentPastHours == 24)
        #expect(config.currentForecastHours == 24)

        let loader = StubLoader { _ in StubLoader.Response(data: Self.payload(pastHours: 24, forecastHours: 24), status: 200) }
        let client = OpenMeteoClient(configuration: .init(pressureBaselineKey: nil), loader: loader, now: { utc(12) })
        _ = try await client.currentWeather(latitude: 59.33, longitude: 18.07)
        let url = try #require(loader.requests.first)
        #expect(url.queryValue("past_hours") == "24")
        #expect(url.queryValue("forecast_hours") == "24")
        #expect(url == OpenMeteoRequest.currentURL(latitude: 59.33, longitude: 18.07))
    }

    @Test func lunkerSeventyTwoHourChartWindow() async throws {
        let loader = StubLoader { _ in StubLoader.Response(data: Self.payload(pastHours: 24, forecastHours: 72), status: 200) }
        let client = OpenMeteoClient(
            configuration: .init(pressureBaselineKey: nil, currentForecastHours: 72),
            loader: loader, now: { utc(12) })
        let weather = try await client.currentWeather(latitude: 59.33, longitude: 18.07)

        let url = try #require(loader.requests.first)
        #expect(url.queryValue("past_hours") == "24")
        #expect(url.queryValue("forecast_hours") == "72")
        #expect(url.queryValue("hourly")?.split(separator: ",").contains("pressure_msl") == true)

        // The chart series spans 24 h back to 72 h ahead…
        #expect(weather.pressureHistory.count == 97)
        #expect(weather.pressureHistory.first?.time == utc(-12))
        #expect(weather.pressureHistory.last?.time == utc(84))
        // …and future hours never feed the 3-hour trend (1013 at 09:00 → 1010).
        #expect(weather.pressureTrend == .falling)
    }

    @Test func pastHoursIsConfigurableToo() async throws {
        let loader = StubLoader { _ in StubLoader.Response(data: Self.payload(pastHours: 6, forecastHours: 0), status: 200) }
        let client = OpenMeteoClient(
            configuration: .init(pressureBaselineKey: nil, currentPastHours: 6, currentForecastHours: 0),
            loader: loader, now: { utc(12) })
        _ = try await client.currentWeather(latitude: 59.33, longitude: 18.07)
        #expect(loader.requests.first?.queryValue("past_hours") == "6")
        #expect(loader.requests.first?.queryValue("forecast_hours") == "0")
    }
}

@Suite("Lunker parity: pressure baselines")
struct LunkerPressureBaselineTests {
    /// Lunker's `WeatherService` stored `[placeKey: [hPa, epochSeconds]]` under
    /// `lunker.weather.pressureBaselines`, place keys `%.2f,%.2f`.
    @Test func readsAndWritesLunkersFormat() async throws {
        let suite = IsolatedDefaults()
        defer { suite.tearDown() }
        let key = "lunker.weather.pressureBaselines"
        suite.defaults.set(["59.33,18.07": [1009.0, utc(12).timeIntervalSince1970]], forKey: key)

        // Relaunch 3 h later; no hourly history in the answer, 1013 hPa now.
        let client = OpenMeteoClient(
            configuration: .init(pressureBaselineKey: key, pressureBaselineSuiteName: suite.suiteName),
            loader: StubLoader { _ in try .json("openmeteo-current-no-hourly") },
            now: { utc(15) })
        let weather = try await client.currentWeather(latitude: 59.3301, longitude: 18.0702)
        #expect(weather.pressureTrend == .rising)   // 1009 → 1013 against Lunker's stored baseline

        let stored = try #require(UserDefaults(suiteName: suite.suiteName)?.dictionary(forKey: key) as? [String: [Double]])
        #expect(stored == ["59.33,18.07": [1009.0, utc(12).timeIntervalSince1970]])   // oldest in-window reading kept
    }
}

@Suite("Lunker parity: point-in-time snapshot")
struct WeatherSnapshotAtTests {
    @Test func matchesForecastSnapshot() throws {
        let forecast = try OpenMeteoClient.parseForecast(try Fixture.data("openmeteo-forecast"), fetchedAt: utc(0))
        for hour in [1.0, 3.0, 3.2, 4.4, 10] {
            #expect(WeatherSnapshot.at(utc(hour), from: forecast.hourly) == forecast.snapshot(at: utc(hour)))
        }
        let surface = try OpenMeteoClient.parseForecast(
            try Fixture.data("openmeteo-forecast"), pressureKind: .surface, fetchedAt: utc(0))
        #expect(WeatherSnapshot.at(utc(3), from: surface.hourly, pressureKind: .surface) == surface.snapshot(at: utc(3)))
    }

    /// Lunker's `HourlyConditionsSnapshot.at` cases (CatchInsightsTests).
    @Test func lunkerRules() throws {
        let start = utc(0)
        let samples = (0..<12).map { hour in
            HourlyWeatherSample(time: start.addingTimeInterval(Double(hour) * 3600),
                                pressure: 1015 - Double(hour), windSpeed: 10 + Double(hour), cloudCover: 50)
        }
        let late = try #require(WeatherSnapshot.at(start.addingTimeInterval(4 * 3600 + 600), from: samples))
        #expect(late.pressure == 1011)
        #expect(late.pressureTrend == .falling)    // −3 hPa over 3 h
        #expect(late.windSpeed == 14)
        let early = try #require(WeatherSnapshot.at(start.addingTimeInterval(3600), from: samples))
        #expect(early.pressureTrend == nil)        // no sample 3 h earlier
        #expect(WeatherSnapshot.at(start.addingTimeInterval(-3 * 3600), from: samples) == nil)
    }
}

@Suite("Lunker parity: tides")
struct LunkerTideTests {
    let index = NOAAStationIndex(stations: NOAAStationIndex.decodeCompact((try? Fixture.data("stations-compact")) ?? Data()))

    static let singleHilo = Data(#"{"predictions":[{"t":"2026-10-27 03:12","v":"1.234","type":"H"}]}"#.utf8)

    func singleEventRoutes(_ url: URL) throws -> StubLoader.Response {
        if url.host() == "api.tidesandcurrents.noaa.gov" {
            return url.queryValue("interval") == "hilo"
                ? StubLoader.Response(data: Self.singleHilo, status: 200)
                : try .json("noaa-hourly")
        }
        return try .json("marine")
    }

    @Test func minimumNOAAEventsDefaultsToTwo() async throws {
        #expect(TideClient.Configuration(applicationName: "X").minimumNOAAEvents == 2)
        let client = TideClient(configuration: .init(applicationName: "Sextant"), stations: index,
                                loader: StubLoader(singleEventRoutes))
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466)
        #expect(tides.source == .model)            // one event is not enough by default
    }

    @Test func lunkerAcceptsASingleNOAAEvent() async throws {
        let client = TideClient(configuration: .init(applicationName: "Lunker", minimumNOAAEvents: 1),
                                stations: index, loader: StubLoader(singleEventRoutes))
        let tides = try await client.fetchTides(latitude: 37.807, longitude: -122.466)
        #expect(tides.source.station?.id == "9414290")
        #expect(tides.events.count == 1)
    }

    @Test func zeroEventsNeverCount() async throws {
        let empty = Data(#"{"predictions":[]}"#.utf8)
        let loader = StubLoader { url in
            url.host() == "api.tidesandcurrents.noaa.gov" ? StubLoader.Response(data: empty, status: 200) : try .json("marine")
        }
        let client = TideClient(configuration: .init(applicationName: "Lunker", minimumNOAAEvents: 0),
                                stations: index, loader: loader)
        #expect(try await client.fetchTides(latitude: 37.807, longitude: -122.466).source == .model)
    }

    @Test func preferredStationLookupIsConsulted() async throws {
        let asked = Reported()
        let loader = StubLoader { url in
            if url.host() == "api.tidesandcurrents.noaa.gov" {
                return try .json(url.queryValue("interval") == "hilo" ? "noaa-hilo" : "noaa-hourly")
            }
            return try .json("marine")
        }
        let client = TideClient(
            configuration: .init(applicationName: "Lunker", maxStationDistanceKm: 50, preferredStationLookup: { lat, lon in
                asked.append(String(format: "%.3f,%.3f", lat, lon))
                return "9414523"
            }),
            stations: index, loader: loader)

        let picked = try await client.fetchTides(latitude: 37.807, longitude: -122.466)
        #expect(picked.source.station?.id == "9414523")
        #expect(asked.values == ["37.807,-122.466"])
        #expect(loader.requests.allSatisfy { $0.queryValue("station") == "9414523" || $0.host() != "api.tidesandcurrents.noaa.gov" })

        // An explicit argument wins over the lookup.
        let explicit = try await client.fetchTides(latitude: 37.807, longitude: -122.466, preferredStationID: "9414750")
        #expect(explicit.source.station?.id == "9414750")
        #expect(asked.values.count == 1)
    }

    @Test func lookupReturningNilMeansNearest() async throws {
        let loader = StubLoader { url in
            if url.host() == "api.tidesandcurrents.noaa.gov" {
                return try .json(url.queryValue("interval") == "hilo" ? "noaa-hilo" : "noaa-hourly")
            }
            return try .json("marine")
        }
        let client = TideClient(configuration: .init(applicationName: "Lunker", preferredStationLookup: { _, _ in nil }),
                                stations: index, loader: loader)
        #expect(try await client.fetchTides(latitude: 37.807, longitude: -122.466).source.station?.id == "9414290")
    }

    /// Lunker showed `NOAATideStation.displayName` ("name, state" from mdapi).
    /// The bundled list folds the state into `name`, so `displayName` reads the same.
    @Test func bundledStationNamesCarryTheState() throws {
        let golden = try #require(NOAAStationIndex.bundledTideStations.station(id: "9414290"))
        #expect(golden.displayName == "SAN FRANCISCO (Golden Gate), CA")
        #expect(golden.state == nil)
    }

    /// Lunker's picker: 120 km, 12 results, nothing outside NOAA coverage.
    @Test func pickerDefaults() {
        let client = TideClient(configuration: .init(applicationName: "Lunker", maxStationDistanceKm: 50))
        let nearby = client.nearbyStations(latitude: 37.8080, longitude: -122.4177)
        #expect(nearby.count == 12)
        #expect(nearby.allSatisfy { $0.distanceKm <= 120 })
        #expect(zip(nearby, nearby.dropFirst()).allSatisfy { $0.distanceKm <= $1.distanceKm })
        #expect(client.nearbyStations(latitude: 59.33, longitude: 18.07).isEmpty)
    }
}

@Suite("Lunker parity: saved locations")
@MainActor
struct LunkerSavedLocationTests {
    let suite = IsolatedDefaults()

    func makeStore() -> SavedLocationStore {
        SavedLocationStore(defaults: suite.defaults,
                           configuration: .init(resolvesTimeZonesOnAdd: false),
                           timeZoneResolver: StubTimeZoneResolver(identifier: nil))
    }

    @Test func seedIsInMemoryOnly() {
        defer { suite.tearDown() }
        let store = makeStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }
        let tahoe = SavedLocation(name: "Lake Tahoe", latitude: 39.0968, longitude: -120.0324)

        #expect(store.seedIfEmpty([tahoe]))
        #expect(store.locations == [tahoe])
        #expect(store.selectedLocation == tahoe)
        #expect(changes == 0)                                       // no widget publish
        #expect(suite.defaults.data(forKey: "savedLocations") == nil)   // not persisted
        #expect(makeStore().locations.isEmpty)

        #expect(!store.seedIfEmpty([SavedLocation(name: "Other", latitude: 1, longitude: 1)]))
        #expect(store.locations == [tahoe])
        #expect(!makeStore().seedIfEmpty([]))
    }

    @Test func seedPersistsOnTheNextEdit() {
        defer { suite.tearDown() }
        let store = makeStore()
        let tahoe = SavedLocation(name: "Lake Tahoe", latitude: 39.0968, longitude: -120.0324)
        store.seedIfEmpty([tahoe])
        store.addLocation(SavedLocation(name: "Mälaren", latitude: 59.4, longitude: 17.2))
        #expect(makeStore().locations.map(\.name) == ["Lake Tahoe", "Mälaren"])
    }

    /// Lunker's widget/watch payload is `JSONEncoder` with `.sortedKeys`; the
    /// package type must produce the same bytes so the app's "payload changed"
    /// check doesn't reload every widget after the update.
    @Test func widgetPayloadBytesMatchLunker() throws {
        let lunkerPayload = #"{"createdAt":783100000,"id":"5A3B1F44-1D2C-4C1E-9C4A-2E7F7C1E0B02","isCurrentLocation":false,"latitude":39.0968,"longitude":-120.0324,"name":"Lake Tahoe","timeZoneIdentifier":"America\/Los_Angeles"}"#
        let decoded = try JSONDecoder().decode(SavedLocation.self, from: Data(lunkerPayload.utf8))
        #expect(decoded.id == UUID(uuidString: "5A3B1F44-1D2C-4C1E-9C4A-2E7F7C1E0B02"))
        #expect(decoded.createdAt == Date(timeIntervalSinceReferenceDate: 783_100_000))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(decoded), as: UTF8.self) == lunkerPayload)

        // No zone: the key is omitted, as Lunker's synthesized Codable did.
        let gps = #"{"createdAt":783100000,"id":"5A3B1F44-1D2C-4C1E-9C4A-2E7F7C1E0B02","isCurrentLocation":true,"latitude":59.3293,"longitude":18.0686,"name":"Current Location"}"#
        let gpsDecoded = try JSONDecoder().decode(SavedLocation.self, from: Data(gps.utf8))
        #expect(gpsDecoded.timeZoneIdentifier == nil)
        #expect(String(decoding: try encoder.encode(gpsDecoded), as: UTF8.self) == gps)
    }

    @Test func searchQueryIsBindable() {
        let search = LocationSearch()
        search.query = "Göteborg"                 // a TextField binding writes here
        #expect(search.query == "Göteborg")
        #expect(!search.isSearching)              // setting alone does not search
        search.clear()
        #expect(search.query.isEmpty)
        #expect(search.results.isEmpty)
        #expect(search.errorMessage == nil)
    }
}

@Suite("Lunker parity: location provider")
@MainActor
struct LunkerLocationProviderTests {
    func deliver(_ error: CLError.Code, to provider: LocationProvider) async {
        provider.locationManager(CLLocationManager(), didFailWithError: CLError(error))
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func locationUnknownIsFilteredByDefault() async {
        let provider = LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686)
        #expect(!provider.reportsLocationUnknownErrors)
        var reported: [CLError.Code] = []
        provider.onError = { reported.append(($0 as? CLError)?.code ?? .network) }

        await deliver(.locationUnknown, to: provider)
        #expect(reported.isEmpty)
        #expect(provider.errorMessage != nil)     // still surfaced as state
        await deliver(.network, to: provider)
        #expect(reported == [.network])
    }

    @Test func lunkerReportsEveryFailure() async {
        let provider = LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686)
        provider.reportsLocationUnknownErrors = true
        var reported: [CLError.Code] = []
        provider.onError = { reported.append(($0 as? CLError)?.code ?? .network) }

        await deliver(.locationUnknown, to: provider)
        #expect(reported == [.locationUnknown])
    }
}
