// swift-tools-version: 6.0
import PackageDescription

// Shared location stack, Open-Meteo weather and NOAA / Open-Meteo Marine tides
// for the outdoor apps (Lunker, Sextant, Equinox, Otta). Apple frameworks only
// (Foundation, CoreLocation, MapKit, Observation), no external dependencies.
// See _standard/SHARED_PACKAGES_SURVEY.md §1.7 and README.md.
//
// Resources: Localizable.xcstrings (strings resolved against `Bundle.module`)
// and NOAATideStations.json (bundled NOAA CO-OPS tide-prediction station list).
let package = Package(
    name: "LocationWeatherKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "LocationWeatherKit", targets: ["LocationWeatherKit"]),
    ],
    targets: [
        .target(
            name: "LocationWeatherKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LocationWeatherKitTests",
            dependencies: ["LocationWeatherKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
