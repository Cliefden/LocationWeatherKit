import Foundation
import MapKit

/// Debounced MKLocalSearch place search with observable state for a search
/// field. Lunker/Sextant/Equinox kept this inside `LocationStore`; it is split
/// out so a store can be used without search and vice versa.
@MainActor
@Observable
public final class LocationSearch {

    public struct Configuration: Sendable {
        public var debounce: Duration
        /// Queries shorter than this (after trimming) clear the results (Otta uses 2).
        public var minimumQueryLength: Int
        /// Cap on returned results (nil = all; Otta uses 8).
        public var resultLimit: Int?
        /// Ranking bias region (not a hard filter); Otta biases to northern Europe.
        public var region: MKCoordinateRegion?
        public var resultTypes: MKLocalSearch.ResultType

        public init(
            debounce: Duration = .milliseconds(300),
            minimumQueryLength: Int = 1,
            resultLimit: Int? = nil,
            region: MKCoordinateRegion? = nil,
            resultTypes: MKLocalSearch.ResultType = .address
        ) {
            self.debounce = debounce
            self.minimumQueryLength = minimumQueryLength
            self.resultLimit = resultLimit
            self.region = region
            self.resultTypes = resultTypes
        }
    }

    public private(set) var query: String = ""
    public private(set) var results: [LocationSearchResult] = []
    public private(set) var isSearching = false
    /// Localized, user-facing message for the last failure (nil on success).
    public private(set) var errorMessage: String?

    public let configuration: Configuration
    @ObservationIgnored private let errorReporter: ErrorReporter?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(configuration: Configuration = Configuration(), errorReporter: ErrorReporter? = nil) {
        self.configuration = configuration
        self.errorReporter = errorReporter
    }

    /// Debounced search; cancels any in-flight query.
    public func search(_ query: String) {
        self.query = query
        task?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= max(1, configuration.minimumQueryLength) else {
            results = []
            isSearching = false
            errorMessage = nil
            return
        }

        isSearching = true
        errorMessage = nil
        let configuration = self.configuration
        task = Task { [weak self] in
            try? await Task.sleep(for: configuration.debounce)
            guard !Task.isCancelled else { return }
            do {
                let found = try await Self.results(for: trimmed, configuration: configuration)
                guard !Task.isCancelled, let self else { return }
                self.results = found
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                // "No results" isn't a failure worth reporting.
                if (error as? MKError)?.code != .placemarkNotFound {
                    self.errorReporter?("locations.search", error)
                }
                self.errorMessage = Self.friendlyErrorMessage(for: error)
                self.results = []
                self.isSearching = false
            }
        }
    }

    public func clear() {
        task?.cancel()
        query = ""
        results = []
        errorMessage = nil
        isSearching = false
    }

    /// One-shot search without observable state.
    public static func results(
        for query: String,
        configuration: Configuration = Configuration()
    ) async throws -> [LocationSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = configuration.resultTypes
        if let region = configuration.region { request.region = region }

        let response = try await MKLocalSearch(request: request).start()
        var items = response.mapItems
        if let limit = configuration.resultLimit { items = Array(items.prefix(limit)) }
        return items.map { item in
            let placemark = item.placemark
            return LocationSearchResult(
                name: item.name ?? placemark.locality ?? query,
                country: placemark.country,
                latitude: placemark.coordinate.latitude,
                longitude: placemark.coordinate.longitude,
                timeZoneIdentifier: item.timeZone?.identifier ?? placemark.timeZone?.identifier,
                isoCountryCode: placemark.isoCountryCode,
                administrativeArea: placemark.administrativeArea,
                subAdministrativeArea: placemark.subAdministrativeArea,
                locality: placemark.locality
            )
        }
    }

    /// Localized message for MapKit / URL errors.
    public static func friendlyErrorMessage(for error: any Error) -> String {
        if let mkError = error as? MKError {
            switch mkError.code {
            case .placemarkNotFound: return .lwk("No locations found. Try a different search.")
            case .serverFailure: return .lwk("Server error. Please try again.")
            case .loadingThrottled: return .lwk("Too many requests. Please wait a moment.")
            default: return .lwk("Search failed. Please try again.")
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet: return .lwk("No internet connection. Check your network.")
            case NSURLErrorTimedOut: return .lwk("Search timed out. Please try again.")
            default: return .lwk("Network error. Please try again.")
            }
        }
        return .lwk("Search failed. Please try again.")
    }
}
