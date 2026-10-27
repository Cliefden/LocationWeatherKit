# LocationWeatherKit

Shared location stack, Open-Meteo weather and NOAA / Open-Meteo Marine tides for
the outdoor apps (Lunker, Sextant, Equinox, Otta). Survey item §1.7 in
`Celiador/_standard/SHARED_PACKAGES_SURVEY.md`.

- swift-tools 6.0 (Swift 6 language mode), iOS 17 / watchOS 10 / macOS 14 / visionOS 1
- Apple frameworks only (Foundation, CoreLocation, MapKit, Observation); no dependencies
- One library product, `LocationWeatherKit`
- Resources: `Localizable.xcstrings` (strings taken from the Lunker and Sextant catalogs,
  with every language they already translate) and `NOAATideStations.json` (~3,500 NOAA tide stations, 197 KB)
- Tests use Swift Testing, fixture JSON and an injected `HTTPDataLoader`. No test touches the network.

```swift
.package(url: "https://github.com/Cliefden/LocationWeatherKit.git", from: "0.1.0")
// or, during adoption: .package(path: "../LocationWeatherKit")
```

Widget and watch targets that compile `SavedLocation` today need to link the package too.

## API

| Area | Types |
|---|---|
| Location | `LocationProvider`, `SavedLocation`, `LocationSearchResult`, `LocationSearch`, `PlaceNameResolver`, `TimeZoneResolving` / `GeocoderTimeZoneResolver`, `SavedLocationStore` |
| Weather | `OpenMeteoClient`, `OpenMeteoRequest`, `CurrentWeather`, `WeatherForecast`, `HourlyWeatherSample`, `DailyWeatherSample`, `WeatherSnapshot`, `WindSample`, `PressureSample`, `PressureTrend`, `PressureKind`, `WeatherError`, `Compass`, `WMOWeatherCode`, `Beaufort` |
| Tides | `TideClient`, `TideData`, `TideEvent`, `TideSample`, `TideKind`, `TideState`, `TideSource`, `TideError`, `NOAAStation`, `NOAAStationMatch`, `NOAAStationIndex`, `NOAATideRequest`, `OpenMeteoMarineRequest` |
| Support | `TTLCache<Key, Value>`, `DayLocationKey`, `HTTPDataLoader`, `ErrorReporter`, `URLSession.boundedTimeouts()`, `GeoDistance`, `UnitConversion` |

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
store.onChange = { store in WidgetPublisher.publish(store.selectedLocation) }  // app-owned widget/watch write
store.onTimeZoneResolved = { _ in Task { await SolarEventData.clearCache() } }

store.addLocation(result)                      // Bool: false = duplicate, which gets selected instead
store.updateCurrentLocation(latitude:longitude:select:)
store.select(id) / deleteLocation(id) / deleteLocation(at:) / moveLocation(from:to:) / updateLocation(_:)
await store.resolveMissingTimeZones()          // launch-time backfill

let search = LocationSearch()                  // .init(configuration: .init(minimumQueryLength: 2, resultLimit: 8, region: …))
search.search(text)                            // debounced 300 ms; observe results / isSearching / errorMessage
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

let forecast = try await weather.forecast(latitude: lat, longitude: lon, days: 14)  // 3 h cache, coalesced, stale ≤24 h offline
forecast.hourly; forecast.daily; forecast.snapshot(at: catchDate)?.pressureTrend
PressureTrend.calculate(currentPressure:history:readings:now:)                       // the pure rule
```

### TideClient

```swift
let tides = TideClient(configuration: .init(applicationName: "Sextant"))   // maxStationDistanceKm 25 by default
let data = try await tides.fetchTides(latitude: lat, longitude: lon, preferredStationID: pick)
data.source.isModelEstimate; data.source.datumLabel          // "MLLW" / "MSL"
data.nextEvent(after: .now); data.state(at: .now); data.heightRange
TideData.findExtremes(in: samples)
tides.nearbyStations(latitude: lat, longitude: lon)          // picker list, sync, bundled index
// TideError.notCoastal → hide tide UI
```

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
| NOAA station list | mdapi download at runtime, 30-day disk cache, 50 km auto radius, user override | Bundled JSON index, 25 km | **Sextant's bundled index** as a package resource. Lunker's override is a `preferredStationID` parameter; its picker uses `nearbyStations`. `NOAAStationIndex.decodeMDAPI` remains for regenerating the list. The radius is configurable (default 25). |
| NOAA request | hilo plus hourly, −12 h, 84 h, `apiError` handling, H/HH/L/LL | hilo only, −6 h, 78 h, trims whitespace | **Superset**: Lunker's window and hourly heights (`includeNOAAHourlyHeights` can be turned off), plus Sextant's whitespace trim. At least 2 events are required (Sextant; Lunker required 1). |
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

| Replace | With | Call-site edits |
|---|---|---|
| `Models/LocationManager.swift` | `LocationProvider(defaultLatitude: 59.3293, defaultLongitude: 18.0686)` | `currentLocation` / `latitude` / `longitude` (non-optional) → `effectiveLocation!.coordinate…`. Move `AppLog.reportError("location.fix")` into `onError`. |
| `Models/LocationStore.swift` | `SavedLocationStore` + `LocationSearch` | Move `updateWidgetData()` (App Group write, `hasPublishedWidgetData` de-dupe, `WatchSync.push`, `WidgetCenter.reload`) into an app `onChange` handler. Search state: `searchResults` → `search.results`, `searchError` → `search.errorMessage`, `clearSearch()` → `clear()`. Keep the `SCREENSHOT_MODE` Lake Tahoe seed in the app. |
| `Models/SavedLocation.swift` (struct + `LocationSearchResult`) | Package types | Keep the `AppGroup` / `WatchSyncKey` enums and `extension SavedLocation { static let lakeTahoe, stockholm }` in the app. `LocationSearchResult.timeZone` is still available (computed). |
| `Models/PlaceNameResolver.swift` `placeName` | `PlaceNameResolver.placeName` | `migrateCurrentLocationNames(in:)` (SwiftData) stays in the app and calls the package. |
| `Models/WeatherService.swift` | `OpenMeteoClient(configuration: .init(pressureBaselineKey: "lunker.weather.pressureBaselines"))` | `fetchWeather` → `currentWeather`. `WeatherService.WeatherData` → `CurrentWeather`, `.PressureTrend` → `PressureTrend` (`icon` → `symbolName`), `.PressureSample` → `PressureSample`. `WeatherService.pressureTrend(…readings: [(…)])` → `PressureTrend.calculate(…readings: [PressureSample])`. Removing the legacy `lunker.weather.lastPressure*` keys stays in the app. |
| `Models/WeatherForecast.swift` `WeatherForecastService` and `HourlyConditionsSnapshot` | `forecast(…, days: 14)` with `forecastDiskCacheDirectory`; `WeatherForecast.snapshot(at:)` | `HourlyWeatherSample` keeps Lunker's field names (superset), so `WeatherModifier.dailyConditions` compiles unchanged. Disk-cache file names change, so expect one refetch. |
| `Models/TideService.swift` and `Models/NOAATides.swift` (`NOAATideClient`, `NOAATideStation`, `TideSource`) | `TideClient(configuration: .init(applicationName: "Lunker", maxStationDistanceKm: 50))` | Pass `TideStationPreference.stationId(…)` as `preferredStationID`. `NOAATideClient.shared.nearbyStations` (async throws) → `tides.nearbyStations` (sync). `NOAATideStation` → `NOAAStation`. `TideService.TideKind/TideEvent/TideState/TideData/TideError` → top-level types. `samples` tuples → `TideSample`. `heightDisplay` → app extension over `UnitSettings`. The station list no longer downloads; it uses the bundled index, and its names include the state ("…, CA"). |
| `Views/LocationPickerMenu.swift` | stays | Change the type to `SavedLocationStore` and call `store.select(id)` (analytics stays). |

### Sextant

| Replace | With | Call-site edits |
|---|---|---|
| `Models/LocationManager.swift` | `LocationProvider()` (no default, matching onboarding) | Move `reportAuthorizationChange` → `onAuthorizationChange`, and `AppSignals.error("location")` → `onError`. |
| `Models/LocationStore.swift` | `SavedLocationStore` + `LocationSearch` | Move the `widgetLocation` write to `group.com.sextant.crawik` plus the WidgetKit reload into `onChange`. The "Use current location" button → `updateCurrentLocation(…, select: true)`. Ignoring GPS jitter under 100 m and the 50 km zone invalidation are new behavior. A duplicate add now selects the existing entry. Keep the `SCREENSHOT_MODE` seed in the app. |
| `Shared/SavedLocation.swift` | Package types | Keep `static let sanFranciscoBay` / `stockholm` as an app extension. |
| `Models/PlaceNameResolver.swift` | `PlaceNameResolver` | none |
| `Models/WeatherService.swift` | `OpenMeteoClient(configuration: .init(pressureKind: .surface, pressureBaselineKey: "sextant.weather.pressureBaselines"))`, or switch to the MSL default (equal at sea level) | `WindForecastSample(speedKnots, gustKnots, directionDegrees)` → `WindSample` (`speedKnots`, `gustsKnots`, `direction`). `windGusts` is now optional: use `windGustsKnots`. `sailingNote` becomes an app extension on `PressureTrend`. Drop the old `sextant.weather.lastPressure*` keys. |
| `Models/TideService.swift` (`TideService`, `NOAAStationIndex`) | `TideClient(configuration: .init(applicationName: "Sextant"))` | `.noaaStation(id:name:distanceKm:)` → `.noaa(station:distanceKm:)` (`station.id` / `.name`). `.openMeteoModel` → `.model`. `heightDisplay` → `formattedHeight()`. Hourly NOAA heights are now fetched; pass `includeNOAAHourlyHeights: false` to keep hi/lo-only samples. Delete `Resources/NOAATideStations.json` (it ships in the package). |
| `Models/TidalCurrentService.swift` | **stays** (Sextant-specific) | Use `NOAAStationIndex(bundle: .main, resource: "NOAACurrentStations")`. `NOAAStationIndex.Match` → `NOAAStationMatch` (same `id`/`name`/`distanceKm`/`bin`). It can adopt `HTTPDataLoader` for tests. |

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
- **Sextant**: `TidalCurrentService` (NOAA `currents_predictions` + sine-rule interpolation + Open-Meteo currents, `NOAACurrentStations.json`), `PressureTrend.sailingNote`, sailing-quality scoring, the `SharedStore` snapshot and `WatchLink`.
- **Equinox**: the onboarding flag, `SunsetQualityForecaster` (MET Norway), solar/moon calculators, `WatchPayload`.
- **Otta**: country/region detection and mapping, the best-times scorer, its weather condition mapping.

## Notes

- `UserDefaults` is not `Sendable`, so `OpenMeteoClient` takes `pressureBaselineSuiteName` and not a `UserDefaults` instance. `SavedLocationStore` is `@MainActor` and takes the instance directly.
- Three new strings (`LocationProvider.LocationError`) are English-only in the catalog. Everything else reuses the apps' existing translations.
- To regenerate `NOAATideStations.json`, fetch `https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions` and write it in the compact form `{"stations": [[id, name, lat, lon], …]}`.
- Build and test:
  ```sh
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -workspace . -scheme LocationWeatherKit -destination generic/platform=iOS build
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -workspace . -scheme LocationWeatherKit -destination generic/platform=watchOS build
  # also builds for generic/platform=visionOS
  ```
