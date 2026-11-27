# Changelog

0.1.x releases are additive: code written against 0.1.0 compiles and behaves the same.

## 0.1.4 (2026-11-27)

Past conditions and water data, for Lunker's catch log and water card.

### Added

- `OpenMeteoClient.historicalWeather(latitude:longitude:around:)`: hourly weather for the UTC
  day before through the day after a past moment (use `snapshot(at:)`), from the
  historical-forecast API (2022 on) or the ERA5 archive (earlier). Cached per ~1 km and UTC day.
  URL builder: `OpenMeteoRequest.historicalURL(latitude:longitude:around:now:)`.
- `TideClient.fetchTides(latitude:longitude:around:preferredStationID:)`: tides for the 52 hours
  around a past or future moment (NOAA window, else the dated sea-level model). Not cached.
  URL builder: `OpenMeteoMarineRequest.seaLevelURL(latitude:longitude:from:to:)`.
- `MarineConditionsClient` / `MarineConditions` / `MarineConditionsRequest`: current sea-surface
  temperature and wave height (Open-Meteo Marine); nil inland. Cached per ~1 km for an hour.
- `USGSWaterClient` / `RiverGauge` / `FlowTrend` / `USGSWaterRequest`: the nearest live USGS
  stream gauge within 25 km (discharge, gauge height, water temperature, 24 h trend, station
  name) from the USGS Water Data OGC API — the replacement for WaterServices, which USGS retires
  on 2027-02-22. US only; readings older than 6 h are ignored. Cached for 30 minutes.
- Tests: `WaterTests` (USGS URLs, parsing, nearest-gauge choice, trend, caching; marine parsing;
  past weather endpoints and day ranges; past tide windows).

### Compatibility

- Nothing existing changes. `fetchNOAA` gained optional window arguments (internal).

## 0.1.3 (2026-11-26)

Moves code that Equinox kept three copies of (app, widget, watch) into the package.

### Added

- `SavedLocationStore.persistedSelection(defaults:configuration:)` and
  `persistedLocations(defaults:configuration:)`: nonisolated, read-only access to what the store
  persisted, for `TimelineProvider`s, complications and background tasks that can't create the
  `@MainActor` store. Same selection rule as `selectedLocation` (stored id, else first); missing
  or corrupt data reads as empty / nil. `load()` now shares their decoding.
- `TimeZone.approximate(forLongitude:)`: a fixed-offset zone at 15° per hour (no DST). Non-finite
  input returns `.current`.
- `SavedLocation.resolvedTimeZone`: the device zone for the GPS entry, else the stored IANA zone,
  else `TimeZone.approximate(forLongitude:)`. Never nil.
- `GeoDistance.destination(latitude:longitude:bearing:distanceKm:)`: great-circle destination
  point (6371 km sphere), longitude normalized to [−180, 180).
- Tests: `ReadOnlyAccessTests` (persisted selection, zone fallback, destination).

### Compatibility

- Nothing existing changes. An app's own `TimeZone.approximate(forLongitude:)` (Equinox) shadows
  the package's until it is deleted.

## 0.1.2 (2026-11-26)

Gaps found in a behavioural diff against Lunker's current location / weather / tide code
(including Lunker changes made after the package was cut: the 72 h pressure chart window).

### Added

- `OpenMeteoClient.Configuration.currentPastHours` / `currentForecastHours` (default 24 / 24):
  the hourly window `currentWeather` requests (`past_hours` / `forecast_hours`), so
  `CurrentWeather.pressureHistory` / `windForecast` can feed a chart reaching further ahead
  (Lunker: 24 / 72). The trend still uses the latest sample at least 3 h before now.
- `WeatherSnapshot.at(_:from:pressureKind:maxDistance:)`: the `snapshot(at:)` rule on a bare
  `[HourlyWeatherSample]` (Lunker's `HourlyConditionsSnapshot.at(_:from:)`).
  `WeatherForecast.snapshot(at:)` now delegates to it (same results).
- `TideClient.Configuration.minimumNOAAEvents` (default 2): fewest NOAA high/low events a
  response needs before the model is tried instead (Lunker: 1; 0 still requires one).
- `TideClient.Configuration.preferredStationLookup` (default nil): consulted by `fetchTides`
  when no `preferredStationID` is passed, so every call site honours a saved station pick
  (Lunker's `TideStationPreference`). An explicit argument wins; nil from the lookup means nearest.
- `LocationProvider.reportsLocationUnknownErrors` (default false): also pass
  `CLError.locationUnknown` to `onError` (Lunker reported every failure as `location.fix`).
- `SavedLocationStore.seedIfEmpty(_:)`: in-memory seed for an empty store (screenshot builds);
  not saved and no `onChange` until the next edit.
- `LocationSearch.query` is now settable, so a `TextField` can bind to it (setting it does not
  search by itself; pair it with `onChange` → `search(_:)`).
- Tests: `LunkerParityTests` (window, Lunker-format pressure baselines, snapshot rule, single-event
  NOAA answers, station lookup, bundled station names, picker defaults, in-memory seed, widget
  payload bytes, bindable query, `locationUnknown` reporting).

### Compatibility

- Defaults reproduce 0.1.1 exactly: the same current-conditions URL (24 / 24), 2 NOAA events,
  no station lookup, `.locationUnknown` filtered. `query` keeps its name and type.

## 0.1.1 (2026-11-25)

Gaps found while adopting the package in Sextant.

### Added

- **Tidal currents** (`Currents/`): `TidalCurrentClient` — NOAA CO-OPS `currents_predictions`
  (`MAX_SLACK`) for the preferred or nearest station within 10 km, with the current now
  interpolated by NOAA's sine rule, falling back to the Open-Meteo Marine model
  (`ocean_current_velocity` / `ocean_current_direction`). `fetchCurrent(latitude:longitude:preferredStationID:)`,
  `modelCurrents(latitude:longitude:days:)` (hourly model series for routers), `station(…)`,
  `nearbyStations(…)`, `clearCache()`. Models: `CurrentData` (`estimate(at:)`,
  `upcomingEvents(after:)`, `interpolate(_:at:slackThresholdKnots:)`), `CurrentEvent`,
  `CurrentEventKind` (`localizedName`, `phaseName`), `CurrentSample` (`nearest(in:to:maxDistance:)`),
  `CurrentEstimate`, `CurrentSource` (`.noaa(station:distanceKm:)` / `.model`, `isModelEstimate`),
  `CurrentError`. Requests: `NOAACurrentRequest.predictionsURL(stationID:bin:begin:hours:application:)` /
  `parsePredictions(_:slackThresholdKnots:)`, `OpenMeteoMarineRequest.currentsURL(latitude:longitude:forecastDays:)` /
  `parseCurrents(_:)`. Resource: `NOAACurrentStations.json` as `NOAAStationIndex.bundledCurrentStations`.
  8 new strings, translated for every catalog language.
- `OpenMeteoForecastFields` (`.all`, `.wind`, custom `init(hourly:daily:)`) and a `fields:` parameter
  (default `.all`) on `OpenMeteoClient.forecast(latitude:longitude:days:fields:)` and
  `OpenMeteoRequest.forecastURL(latitude:longitude:days:fields:)`. Subsets get their own cache entry;
  the full set keeps the 0.1.0 cache key (memory and disk).
- `WeatherForecast.pressureKind`; `pressureHistory` and `snapshot(at:)` trends follow
  `OpenMeteoClient.Configuration.pressureKind` (was always MSL). `OpenMeteoClient.parseForecast(_:pressureKind:fetchedAt:)`
  (default `.meanSeaLevel`). `HourlyWeatherSample.pressure(of:)`, `WeatherSnapshot.pressureKind` /
  `selectedPressure`. `WeatherSnapshot.pressure` and `HourlyWeatherSample.pressure` stay MSL.
- `SavedLocationStore.Configuration.noJitterFilter` (= 0) and `filtersCurrentLocationJitter`.
  A literal `currentLocationUpdateThreshold: 0` keeps working.
- `Compass.abbreviation(degrees:localized:)` for `Double` and `Int` (`false` → English point).
- `reportsTransportErrors` (default `true`) on `OpenMeteoClient.Configuration`, `TideClient.Configuration`,
  `TidalCurrentClient.Configuration` and `LocationSearch.Configuration`: when `false`, `NSURLErrorDomain`
  and `CancellationError` failures are not sent to `errorReporter` (still thrown).
  `TransportError.isTransportError(_:)` exposes the rule.

### Compatibility

- Defaults reproduce 0.1.0 exactly: MSL forecast pressure, full forecast field set, jitter filter on,
  localized compass, transport errors reported.
- 0.1.0 forecast disk-cache files (no `pressureKind`) still decode; they are re-stamped with the
  client's configured kind on read.

## 0.1.0

Initial release: location stack, Open-Meteo weather, NOAA / Open-Meteo Marine tides.
