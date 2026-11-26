# LocationWeatherKit

Shared location stack, Open-Meteo weather and NOAA / Open-Meteo Marine tides and
tidal currents for the outdoor apps (Lunker, Sextant, Equinox, Otta). Survey item §1.7 in
`Celiador/_standard/SHARED_PACKAGES_SURVEY.md`.

- swift-tools 6.0 (Swift 6 language mode), iOS 17 / watchOS 10 / macOS 14 / visionOS 1
- Apple frameworks only (Foundation, CoreLocation, MapKit, Observation); no dependencies
- One library product, `LocationWeatherKit`
- Resources: `Localizable.xcstrings` (strings taken from the Lunker and Sextant catalogs,
  with every language they already translate), `NOAATideStations.json` (~3,500 NOAA tide stations, 197 KB)
  and `NOAACurrentStations.json` (~2,600 NOAA current stations, 161 KB)
- Tests use Swift Testing, fixture JSON and an injected `HTTPDataLoader`. No test touches the network.
- Changes per version: [CHANGELOG.md](CHANGELOG.md). 0.1.x releases are additive only.

```swift
.package(url: "https://github.com/Cliefden/LocationWeatherKit.git", from: "0.1.0")
// or, during adoption: .package(path: "../LocationWeatherKit")
```

Widget and watch targets that compile `SavedLocation` today need to link the package too.

## API

| Area | Types |
|---|---|
| Location | `LocationProvider`, `SavedLocation`, `LocationSearchResult`, `LocationSearch`, `PlaceNameResolver`, `TimeZoneResolving` / `GeocoderTimeZoneResolver`, `SavedLocationStore` |
| Weather | `OpenMeteoClient`, `OpenMeteoRequest`, `OpenMeteoForecastFields`, `CurrentWeather`, `WeatherForecast`, `HourlyWeatherSample`, `DailyWeatherSample`, `WeatherSnapshot`, `WindSample`, `PressureSample`, `PressureTrend`, `PressureKind`, `WeatherError`, `Compass`, `WMOWeatherCode`, `Beaufort` |
| Tides | `TideClient`, `TideData`, `TideEvent`, `TideSample`, `TideKind`, `TideState`, `TideSource`, `TideError`, `NOAAStation`, `NOAAStationMatch`, `NOAAStationIndex`, `NOAATideRequest`, `OpenMeteoMarineRequest` |
| Currents | `TidalCurrentClient`, `CurrentData`, `CurrentEvent`, `CurrentEventKind`, `CurrentSample`, `CurrentEstimate`, `CurrentSource`, `CurrentError`, `NOAACurrentRequest`, `OpenMeteoMarineRequest.currentsURL` / `parseCurrents`, `NOAAStationIndex.bundledCurrentStations` |
| Support | `TTLCache<Key, Value>`, `DayLocationKey`, `HTTPDataLoader`, `ErrorReporter`, `TransportError`, `URLSession.boundedTimeouts()`, `GeoDistance`, `UnitConversion` |

### LocationProvider

```swift
@State private var location = LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686) // or LocationProvider()

location.requestPermission()
location.requestLocation()                    // fire-and-forget; observe `location`
let fix = try await location.currentLocation(timeout: .seconds(10), maximumAge: 300)
location.effectiveLocation                    // fix ?? defaultLocation (nil when neither)
location.isAuthorized / isAccessDenied / isLoading / errorMessage
location.onAuthorizationChange = { old, new in /* permission telemetry */ }
location.onError = { AppLog.reportError("location.fix", $0) }   // .locationUnknown already filtered out
location.reportsLocationUnknownErrors = true  // 0.1.2: pass .locationUnknown to onError too (Lunker's telemetry)
```

`currentLocation()` prompts for permission when the status is undetermined and waits
for the answer. Concurrent callers share one request. It throws
`LocationError.notAuthorized`, `.unavailable` or `.timedOut`, or `CancellationError`.

### SavedLocationStore and LocationSearch

```swift
let store = SavedLocationStore(
    defaults: UserDefaults(suiteName: "group.com.equinox.shared")!,   // default .standard
    configuration: .init(),                    // keys "savedLocations" / "selectedLocationId" = today's keys
    errorReporter: { AppLog.reportError($0, $1, logger: AppLog.persistence) }
)
// Sextant: every "Use current location" fix moves the GPS entry (no 100 m jitter filter).
// .init(currentLocationUpdateThreshold: SavedLocationStore.Configuration.noJitterFilter)   // 0 still works; check `filtersCurrentLocationJitter`
store.onChange = { store in WidgetPublisher.publish(store.selectedLocation) }  // app-owned widget/watch write
store.onTimeZoneResolved = { _ in Task { await SolarEventData.clearCache() } }

store.addLocation(result)                      // Bool: false = duplicate, which gets selected instead
store.updateCurrentLocation(latitude:longitude:select:)
store.select(id) / deleteLocation(id) / deleteLocation(at:) / moveLocation(from:to:) / updateLocation(_:)
await store.resolveMissingTimeZones()          // launch-time backfill
store.seedIfEmpty([.lakeTahoe])                // 0.1.2: in-memory seed (SCREENSHOT_MODE), not saved, no onChange

let search = LocationSearch()                  // .init(configuration: .init(minimumQueryLength: 2, resultLimit: 8, region: …))
search.search(text)                            // debounced 300 ms; observe results / isSearching / errorMessage
TextField("Search", text: $search.query)       // 0.1.2: `query` is settable; pair with
    .onChange(of: search.query) { search.search($1) }   // (setting it alone doesn't search; clear() resets it)
let hits = try await LocationSearch.results(for: "Göteborg")   // one-shot

let name = await PlaceNameResolver.placeName(latitude: lat, longitude: lon)   // water body first
```

### OpenMeteoClient

```swift
let weather = OpenMeteoClient(
    configuration: .init(
        pressureKind: .meanSeaLevel,                       // or .surface
        forecastDiskCacheDirectory: URL.cachesDirectory.appending(path: "WeatherForecast"),
        pressureBaselineKey: "lunker.weather.pressureBaselines"  // same storage format as Lunker → baselines carry over
    ),
    errorReporter: { AppLog.reportError($0, $1) }
)
let now = try await weather.currentWeather(latitude: lat, longitude: lon)   // 15 min cache per ~100 m
now.pressure; now.pressureTrend; now.windGustsKnots; now.beaufortForce; now.windForecast; now.weatherIcon
now.pressureHistory   // hourly, 24 h back … 24 h ahead; 0.1.2: .init(currentPastHours:currentForecastHours:) (Lunker: 24 / 72)

let forecast = try await weather.forecast(latitude: lat, longitude: lon, days: 14)  // 3 h cache, coalesced, stale ≤24 h offline
forecast.hourly; forecast.daily; forecast.snapshot(at: catchDate)?.pressureTrend
forecast.pressureKind; forecast.pressureHistory   // follow `pressureKind` (.surface → surface_pressure); MSL by default
forecast.hourly[0].pressure(of: .surface); snapshot.selectedPressure                 // `pressure` stays MSL
WeatherSnapshot.at(catchDate, from: hourlySamples)                                   // 0.1.2: same rule on a bare series
PressureTrend.calculate(currentPressure:history:readings:now:)                       // the pure rule

// Field subset, e.g. a router sampling a grid of cells (hourly wind only, no daily block; cached per subset):
let wind = try await weather.forecast(latitude: lat, longitude: lon, days: 3, fields: .wind)
// or .init(hourly: ["wind_speed_10m", "wind_direction_10m"], daily: [])
```

Plain transport failures (offline, timeouts, cancellation) can be kept out of `errorReporter`
with `reportsTransportErrors: false` on `OpenMeteoClient.Configuration`,
`TideClient.Configuration`, `TidalCurrentClient.Configuration` and
`LocationSearch.Configuration` (default `true`, the 0.1.0 behaviour). They are still thrown.
`TransportError.isTransportError(_:)` is the rule (`NSURLErrorDomain` or `CancellationError`).

`Compass.abbreviation(degrees:)` is localized; `Compass.abbreviation(degrees:localized: false)`
returns the English point (Sextant shows compass points untranslated).

### TideClient

```swift
let tides = TideClient(configuration: .init(applicationName: "Sextant"))   // maxStationDistanceKm 25 by default
let data = try await tides.fetchTides(latitude: lat, longitude: lon, preferredStationID: pick)
data.source.isModelEstimate; data.source.datumLabel          // "MLLW" / "MSL"
data.nextEvent(after: .now); data.state(at: .now); data.heightRange
TideData.findExtremes(in: samples)
tides.nearbyStations(latitude: lat, longitude: lon)          // picker list, sync, bundled index
// TideError.notCoastal → hide tide UI

// 0.1.2: let every fetchTides call honour the user's saved station pick, and
// accept a NOAA answer with a single high/low (Lunker's rules):
TideClient(configuration: .init(applicationName: "Lunker", maxStationDistanceKm: 50, minimumNOAAEvents: 1,
                                preferredStationLookup: { TideStationPreference.stationId(latitude: $0, longitude: $1) }))
```

An explicit `preferredStationID` argument wins over `preferredStationLookup`; a lookup
returning nil means "nearest".

### TidalCurrentClient

```swift
let currents = TidalCurrentClient(configuration: .init(applicationName: "Sextant"))   // NOAA station within 10 km by default
let now = try await currents.fetchCurrent(latitude: lat, longitude: lon, preferredStationID: pick)
now.speedKnots; now.directionDegrees; now.compass; now.phase       // phase: .flood / .ebb / .slack (NOAA only)
now.source.isModelEstimate                                         // true → show "Model estimate — not for navigation"
if case .noaa(let station, let km) = now.source { /* show station.name and km */ }
now.upcomingEvents(after: .now)                                    // max flood / max ebb / slack (NOAA)
now.estimate(at: date)                                             // sine-rule (NOAA) or nearest model hour
event.kind.localizedName; phase.phaseName                          // "Max flood" / "Flooding" (localized)
CurrentData.interpolate(events, at: date)                          // the pure NOAA rule
currents.nearbyStations(latitude: lat, longitude: lon)             // picker list, bundled index

let series = try await currents.modelCurrents(latitude: lat, longitude: lon, days: 3)   // router: hourly model, knots, cached
CurrentSample.nearest(in: series, to: time)
// CurrentError.unavailable → hide current UI (no station, no model current; remembered 24 h)
```

NOAA: `currents_predictions`, `interval=MAX_SLACK` (the only form subordinate stations
support), `units=english` (knots), the station's `bin`, from 8 h before now for 56 h.
Weak-and-variable stations are not in the bundled list. Any NOAA failure (including
"now" outside the predicted window) falls back to the model and is reported as
`currents.noaa`. Model: Open-Meteo Marine `ocean_current_velocity` (km/h, converted to
knots) / `ocean_current_direction` (toward), ~8 km grid — it can badly understate tidal
streams in channels and harbours, so always label it.

### TTLCache

```swift
let cache = TTLCache<DayLocationKey, SolarEventData>(ttl: 300)
let key = DayLocationKey(date: date, latitude: lat, longitude: lon, timeZoneIdentifier: tz)
if let hit = await cache.value(for: key) { … }
let value = try await cache.value(for: key) { try await compute() }   // concurrent callers share one fetch
```

## Behavioral differences between the Lunker and Sextant copies (and which one was kept)

| Topic | Lunker | Sextant | Package |
|---|---|---|---|
| Pressure field | `pressure_msl` | `surface_pressure` | Both are fetched. `pressureKind` picks one; the default is MSL. |
| Trend fallback (no hourly history) | Per place (~1 km), 4 h window, baseline must be ≥2.5 h old, persisted per place | One global baseline, 3 h window, any 2 readings (minutes apart counts) | **Lunker's.** Sextant's could compare places with each other and report noise as a trend. |
| HTTP | 2xx, bounded 15/30 s session, decode errors → `.decodingFailed` | `== 200`, `URLSession.shared`, raw `DecodingError` thrown | **Lunker's** |
| Gusts and wind forecast | none | `wind_gusts_10m` plus hourly wind (direction carried forward over nulls) | **Superset.** Gusts are optional; `WindSample` stores km/h and has knots accessors. |
| Cloud cover | yes | no | Superset (optional) |
| Compass text | Localized (catalog keys) | English array | Localized from the package catalog. `Compass.englishAbbreviations` is available too. |
| `findExtremes` | Parabola through the real timestamps (correct when a null hour left a gap) | Assumes equal spacing (uses the next interval only) | **Lunker's**. A test covers unequal spacing. |
| NOAA station list | mdapi download at runtime, 30-day disk cache, 50 km auto radius, user override | Bundled JSON index, 25 km | **Sextant's bundled index** as a package resource. Lunker's override is a `preferredStationID` parameter; its picker uses `nearbyStations`. `NOAAStationIndex.decodeMDAPI` remains for regenerating the list. The radius is configurable (default 25). Checked against the live mdapi list on 2026-11-26: same 3,502 ids, and every bundled `name` equals Lunker's `displayName` ("name, ST"). |
| NOAA request | hilo plus hourly, −12 h, 84 h, `apiError` handling, H/HH/L/LL | hilo only, −6 h, 78 h, trims whitespace | **Superset**: Lunker's window and hourly heights (`includeNOAAHourlyHeights` can be turned off), plus Sextant's whitespace trim. At least 2 events are required by default (Sextant); `minimumNOAAEvents: 1` is Lunker's rule (0.1.2). When hourly heights are unavailable `samples` holds the hi/lo points (Lunker left it empty; it never reads `samples`). |
| Inland memo | Expires after 24 h, set only for all-null answers, checked after the NOAA attempt | Permanent, set on any sparse answer, checked first | **Lunker's** |
| Marine decode error | `.decodingFailed` | raw error | Lunker's |
| `TideSource` | `.noaa(station:distanceKm:)` / `.model` | `.noaaStation(id:name:distanceKm:)` / `.openMeteoModel`, plus `isModelEstimate`, `datumLabel` | Lunker's shape plus Sextant's accessors |
| Tide height text | `UnitSettings` (app) | `Locale.measurementSystem` | `formattedHeight(locale:)` (Sextant's rule). Lunker keeps its own extension. |
| `addLocation` | Returns Bool, selects the duplicate, GPS entry exempt | Silent no-op on duplicate | **Lunker's** |
| `updateCurrentLocation` | 100 m jitter filter, 50 km zone invalidation, keeps the selection | ~1 km (0.01°) zone invalidation, always selects the GPS entry, no jitter filter | **Lunker's**, plus a `select:` parameter for Sextant's "Use current location" button |
| Zone resolution | In-flight guard, coordinates rechecked after the await, retried | Fire and forget | **Lunker's**. The in-flight task is joined, never stacked. |
| `LocationManager` fix | `locations.last` | `locations.last` | Same (Equinox and Otta used `.first`, which was a bug) |
| Search error strings | `String(localized:)` | Hard-coded English | Localized |

## Per-app adoption map

All apps keep the existing UserDefaults keys and `SavedLocation` JSON shape, so no data migration is needed.

### Lunker

Needs 0.1.2 for an unchanged experience (72 h pressure chart, station pick everywhere,
single-event NOAA answers, `location.fix` telemetry, in-memory screenshot seed, bindable search text).

| Replace | With | Call-site edits |
|---|---|---|
| `Models/LocationManager.swift` | `LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686)` + `onError = { AppLog.reportError("location.fix", $0) }` + `reportsLocationUnknownErrors = true` | `currentLocation` / `latitude` / `longitude` (non-optional) → `effectiveLocation!.coordinate…` (or a two-line app extension). `location`, `authorizationStatus`, `hasLocation`, `isLoading`, `errorMessage`, `requestPermission()`, `requestLocation()` keep their names. |
| `Models/LocationStore.swift` | `SavedLocationStore(configuration: .init(resolvesTimeZonesOnAdd: false), errorReporter: { AppLog.reportError($0, $1, logger: AppLog.persistence) })` + `LocationSearch(errorReporter: { AppLog.reportError($0, $1) })` | Move `updateWidgetData()` (App Group write, `hasPublishedWidgetData` de-dupe, `WatchSync.push`, `AppGroup.store.reloadWidgets()`) into an app `onChange` handler; MainTabView's direct calls call the same app function. `isFirstLaunch` → `isEmpty`. Search: `searchQuery` → `search.query` (bindable), `searchResults` → `search.results`, `searchError` → `search.errorMessage`, `clearSearch()` → `clear()`. `SCREENSHOT_MODE`: `store.seedIfEmpty([.lakeTahoe])` (not persisted, like Lunker's seed). |
| `Models/SavedLocation.swift` (struct + `LocationSearchResult`) | Package types | Keep the `AppGroup` / `WatchSyncKey` enums and `extension SavedLocation { static let lakeTahoe, stockholm }` in the app. JSON keys and the `.sortedKeys` widget payload bytes are identical (tested). `LocationSearchResult.timeZone` is still available (computed). The widget, watch app and watch widget targets must link the package. |
| `Models/PlaceNameResolver.swift` `placeName` | `PlaceNameResolver.placeName` | `migrateCurrentLocationNames(in:)` + `legacyCurrentLocationName` (SwiftData) stay in the app; rename the app enum (e.g. `CatchPlaceNameMigration`) or call `LocationWeatherKit.PlaceNameResolver` — an app type of the same name shadows the package's. |
| `Models/WeatherService.swift` | One shared `OpenMeteoClient(configuration: .init(forecastDiskCacheDirectory: URL.cachesDirectory.appending(path: "WeatherForecast", directoryHint: .isDirectory), pressureBaselineKey: "lunker.weather.pressureBaselines", currentForecastHours: 72), errorReporter: { AppLog.reportError($0, $1) })` | `fetchWeather` → `currentWeather`. `WeatherService.WeatherData` → `CurrentWeather`, `.PressureTrend` → `PressureTrend` (`icon` → `symbolName`), `.PressureSample` → `PressureSample`. `WeatherService.pressureTrend(…readings: [(…)])` → `PressureTrend.calculate(…readings: [PressureSample])`. `FishingCondition`, `fishingCondition`, `fishingNote` and removing the legacy `lunker.weather.lastPressure*` keys stay in the app. Baselines carry over (same key and format, tested). |
| `Models/WeatherForecast.swift` `WeatherForecastService` and `HourlyConditionsSnapshot` | the same client's `forecast(…, days: 14)`; `WeatherForecast.snapshot(at:)` / `WeatherSnapshot.at(_:from:)` | `HourlyWeatherSample` keeps Lunker's field names (superset), so `WeatherModifier.dailyConditions` compiles unchanged; `dailyConditions(latitude:longitude:timeZone:)` and `forecastDays = 14` stay in the app as a thin wrapper over `forecast.hourly`. Disk-cache file names and format change, so expect one refetch. |
| `Models/TideService.swift` and `Models/NOAATides.swift` (`NOAATideClient`, `NOAATideStation`, `TideSource`) | One shared `TideClient(configuration: .init(applicationName: "Lunker", maxStationDistanceKm: 50, minimumNOAAEvents: 1, preferredStationLookup: { TideStationPreference.stationId(latitude: $0, longitude: $1) }), errorReporter: { AppLog.reportError($0, $1) })` | `TideStationPreference` stays in the app (key `lunker.tides.stationOverrides`); with the lookup, `fetchTides` call sites need no change. `NOAATideClient.shared.nearbyStations` (async throws) → `tides.nearbyStations` (sync, 120 km / 12). `NOAATideClient.NearbyStation` → `NOAAStationMatch`, `NOAATideStation` → `NOAAStation`. `TideService.TideKind/TideEvent/TideState/TideData/TideError` → top-level types (`icon` → `symbolName`). `samples` tuples → `TideSample`. `heightDisplay` → app extension over `UnitSettings`. The station list no longer downloads; the bundled index has the same stations and display names. |
| `Views/LocationPickerMenu.swift` | stays | Change the type to `SavedLocationStore` and call `store.select(id)` (analytics stays). |

What Lunker users can still notice with that configuration:

- One forecast refetch after the update: the old `Caches/WeatherForecast/<lat>,<lon>.json` files
  (`{fetchedAt, samples}`) are not read; the package writes `<lat>,<lon>_14.json`. Offline on
  the first launch after updating, there is no stale forecast to fall back on. The old files and
  `Caches/noaa-tide-stations.json` are orphaned (the app may delete them once).
- The current-conditions request also asks for `surface_pressure`, gusts and hourly wind (unused by
  Lunker; a slightly larger response). Coordinates outside ±90/±180 now fail fast as `invalidResponse`.
- Clearing the search text also clears a shown search error (Lunker kept it).
- Telemetry: the reported error value for `tides.decode` / `weatherForecast.decode` is the package's
  `TideError.decodingFailed` / `WeatherError.decodingFailed` instead of the raw `DecodingError`
  (operation names unchanged). Station-list download failures (`tides.noaa`,
  `tides.noaaStationCacheWrite`) no longer occur.

### Sextant

| Replace | With | Call-site edits |
|---|---|---|
| `Models/LocationManager.swift` | `LocationProvider()` (no default, matching onboarding) | Move `reportAuthorizationChange` → `onAuthorizationChange`, and `AppSignals.error("location")` → `onError`. |
| `Models/LocationStore.swift` | `SavedLocationStore` + `LocationSearch` | Move the `widgetLocation` write to `group.com.sextant.crawik` plus the WidgetKit reload into `onChange`. The "Use current location" button → `updateCurrentLocation(…, select: true)`. Ignoring GPS jitter under 100 m and the 50 km zone invalidation are new behavior. A duplicate add now selects the existing entry. Keep the `SCREENSHOT_MODE` seed in the app. |
| `Shared/SavedLocation.swift` | Package types | Keep `static let sanFranciscoBay` / `stockholm` as an app extension. |
| `Models/PlaceNameResolver.swift` | `PlaceNameResolver` | none |
| `Models/WeatherService.swift` | `OpenMeteoClient(configuration: .init(pressureKind: .surface, pressureBaselineKey: "sextant.weather.pressureBaselines"))`, or switch to the MSL default (equal at sea level) | `WindForecastSample(speedKnots, gustKnots, directionDegrees)` → `WindSample` (`speedKnots`, `gustsKnots`, `direction`). `windGusts` is now optional: use `windGustsKnots`. `sailingNote` becomes an app extension on `PressureTrend`. Drop the old `sextant.weather.lastPressure*` keys. |
| `Models/TideService.swift` (`TideService`, `NOAAStationIndex`) | `TideClient(configuration: .init(applicationName: "Sextant"))` | `.noaaStation(id:name:distanceKm:)` → `.noaa(station:distanceKm:)` (`station.id` / `.name`). `.openMeteoModel` → `.model`. `heightDisplay` → `formattedHeight()`. Hourly NOAA heights are now fetched; pass `includeNOAAHourlyHeights: false` to keep hi/lo-only samples. Delete `Resources/NOAATideStations.json` (it ships in the package). |
| `Models/TidalCurrentService.swift` | `TidalCurrentClient(configuration: .init(applicationName: "Sextant", reportsTransportErrors: false))` (0.1.1) | Same rules (10 km, `MAX_SLACK`, 8 h / 56 h, sine rule, 0.2 kt slack). `.noaaStation(id:name:distanceKm:)` → `.noaa(station:distanceKm:)`, `.openMeteoModel` → `.model`. `events` now include the past events that bracket now: use `upcomingEvents(after: .now)`. `CurrentEventKind.localizedName` / `phaseName` ship in the package. `compass` is localized: use `Compass.abbreviation(degrees:localized: false)` for English. `parseNOAA`/`interpolate`/`noaaURL` → `NOAACurrentRequest.parsePredictions` / `CurrentData.interpolate` / `NOAACurrentRequest.predictionsURL`. Delete `Resources/NOAACurrentStations.json` (`NOAAStationIndex.bundledCurrentStations`). Unlike Sextant, an all-null model answer is retried after 24 h. |
| Routing `OpenMeteoForecastSampler` | `weather.forecast(…, days: 3, fields: .wind)` + `currents.modelCurrents(…, days: 3)` (0.1.1) | Drops the daily block and non-wind hourly fields per grid cell, and the private marine decoder. |
| `currentLocationUpdateThreshold: 0` | `SavedLocationStore.Configuration.noJitterFilter` (0.1.1) | Same behaviour. |
| `reportPackageError` URL-domain filter | `reportsTransportErrors: false` on each client's configuration (0.1.1) | Also skips `CancellationError`. |
| `extension Compass { static func english(degrees:) }` | `Compass.abbreviation(degrees:localized: false)` (0.1.1) | none |

### Equinox

| Replace | With | Call-site edits |
|---|---|---|
| `Models/LocationManager.swift` | `LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686)` | The "Location access is off — showing Stockholm" message becomes app UI driven by `isAccessDenied`. The fix now uses `locations.last` (it was `.first`). |
| `Models/LocationStore.swift` | `SavedLocationStore(defaults: UserDefaults(suiteName: "group.com.equinox.shared")!, configuration: .init(reusesSavedPlaceForFirstFix: true))` + `LocationSearch` | `hasCompletedOnboarding` / `completeOnboarding()` (key `hasCompletedOnboarding`) stay in the app. Call them after add or GPS update, or from `onChange`. The load-time zone backfill becomes `await store.resolveMissingTimeZones()` at launch. Note that the package also resolves the GPS entry, which Equinox skipped. Cache clearing goes in `onTimeZoneResolved`. The `location.removed` analytics wraps `deleteLocation`. A stale selected id now falls back to the first entry (Equinox kept a dangling id). |
| `Models/SavedLocation.swift` | Package types | Keep `static let stockholm` as an extension. `currentLocation(...)` now stores the untranslated placeholder, and `displayName` localizes it. Names saved in a localized form earlier still display as stored. |
| `Models/EventDataCache.swift` | `TTLCache<DayLocationKey, T>(ttl: 300)` | `get(date:…)` / `set` → `value(for: DayLocationKey(...))` / `set(_:for:)`. `clear()` → `removeAll()`. |

## Otta divergence notes (adopt selectively; don't force)

Otta's location model is a different domain. Its `SavedLocation` has `lan`, `country`,
fixed-UUID defaults, and no `isCurrentLocation` / `createdAt` / `timeZoneIdentifier`. Its
store is never empty, persists via `didSet`, refuses to delete the last entry, and
de-duplicates by name **or** coordinates. Region codes are mapped from placemark fields
for each country. **Keep Otta's `LocationStore` and `SavedLocation`.** Pieces that fit:

- `CurrentLocationProvider.getCurrentLocation()` → `LocationProvider.currentLocation(timeout:)`, created with `desiredAccuracy: kCLLocationAccuracyHundredMeters, requestsLocationOnAuthorization: false`. Otta threw `requestInProgress` for concurrent calls; the package shares the request instead. Its prompt/result analytics map onto `onAuthorizationChange`.
- `LocationSearch` → `LocationSearch.results(for:configuration: .init(minimumQueryLength: 2, resultLimit: 8, region: <northern Europe>))`. The results carry `isoCountryCode`, `administrativeArea`, `subAdministrativeArea` and `locality`, so Otta's `Lan`/`Bundesland`/… mapping can run on them. `subtitle` matches Otta's format.
- `resolvePlace` naming → `PlaceNameResolver.name(from:strategy: .localityFirst)` / `PlaceNameResolver.placemark(...)`.
- `WeatherService`: Otta requests wind in **m/s** (`wind_speed_unit=ms`), uses `surface_pressure`, 1–7 days, and drops hours with any null field (an 8-point compass). `OpenMeteoClient.forecast` returns km/h with nullable fields, so the conversion (÷3.6) and the drop-incomplete-rows rule would sit in Otta. The gain is small, so keeping Otta's client is reasonable.

## Stays in the apps (domain-specific)

- **Lunker**: `FishingCondition` / `fishingCondition`, `PressureTrend.fishingNote`, `WeatherModifier` (`DailyWeatherConditions` aggregation, factors, `DayForecast`), solunar scoring, `TideStationPreference`, `PlaceNameResolver.migrateCurrentLocationNames`, `UnitSettings` height formatting, `AppGroup`/`WatchSync` widget and watch publishing, `LocationPickerMenu`.
- **Sextant**: `PressureTrend.sailingNote`, sailing-quality scoring, the routing `ForecastSampler` grid/snapping, the `SharedStore` snapshot and `WatchLink`. (Tidal currents moved into the package in 0.1.1: `TidalCurrentClient`.)
- **Equinox**: the onboarding flag, `SunsetQualityForecaster` (MET Norway), solar/moon calculators, `WatchPayload`.
- **Otta**: country/region detection and mapping, the best-times scorer, its weather condition mapping.

## Notes

- `UserDefaults` is not `Sendable`, so `OpenMeteoClient` takes `pressureBaselineSuiteName` and not a `UserDefaults` instance. `SavedLocationStore` is `@MainActor` and takes the instance directly.
- Three new strings (`LocationProvider.LocationError`) are English-only in the catalog. Everything else reuses the apps' existing translations.
- To regenerate `NOAATideStations.json`, fetch `https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions` and write it in the compact form `{"stations": [[id, name, lat, lon], …]}`.
- To regenerate `NOAACurrentStations.json`, fetch `…/mdapi/prod/webapi/stations.json?type=currentpredictions`, drop weak-and-variable stations, keep the shallowest bin per station, and write `{"stations": [[id, name, lat, lon, bin], …]}`.
- The currents strings (`Max flood`, `Max ebb`, `Slack`, `Flooding`, `Ebbing`, `Near slack` and the two `CurrentError` messages) are translated for every catalog language; sv/de/fr/es come from Sextant's catalog, the rest are machine translations that a native reviewer should check (nautical terms).
- Build and test:
  ```sh
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -workspace . -scheme LocationWeatherKit -destination generic/platform=iOS build
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -workspace . -scheme LocationWeatherKit -destination generic/platform=watchOS build
  # also builds for generic/platform=visionOS
  ```
