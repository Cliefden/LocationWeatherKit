import Foundation
import CoreLocation

/// Observable CLLocationManager wrapper: authorization, one-shot fixes, and an
/// async `currentLocation(timeout:)`.
///
/// Replaces the identical Lunker / Sextant / Equinox `LocationManager` and
/// covers Otta's `CurrentLocationProvider.getCurrentLocation()`. There is no
/// built-in fallback place: pass `defaultLocation` if the app wants one.
@MainActor
@Observable
public final class LocationProvider: NSObject {

    public enum LocationError: LocalizedError, Sendable, Equatable {
        /// Access is denied or restricted.
        case notAuthorized
        /// Core Location reported a failure.
        case unavailable
        /// No fix arrived within the timeout.
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .notAuthorized: return .lwk("Location access is turned off.")
            case .unavailable: return .lwk("Couldn't determine your location.")
            case .timedOut: return .lwk("Finding your location timed out.")
            }
        }
    }

    /// The freshest fix received (nil until the first one).
    public private(set) var location: CLLocation?
    public private(set) var authorizationStatus: CLAuthorizationStatus
    public private(set) var isLoading = false
    /// The last Core Location failure (cleared when a new request starts).
    public private(set) var lastError: (any Error)?

    /// The app's fallback when there is no fix (e.g. Stockholm for Equinox). nil = none.
    public let defaultLocation: CLLocation?

    /// Called on every real authorization transition (old, new) — Sextant reports
    /// permission telemetry here.
    @ObservationIgnored public var onAuthorizationChange: ((CLAuthorizationStatus, CLAuthorizationStatus) -> Void)?
    /// Called for Core Location failures except the transient `.locationUnknown`.
    @ObservationIgnored public var onError: ((any Error) -> Void)?

    /// Request a fix automatically as soon as access is granted (the apps' behaviour).
    @ObservationIgnored public var requestsLocationOnAuthorization: Bool

    @ObservationIgnored private let manager: CLLocationManager
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<CLLocation, any Error>] = [:]
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - desiredAccuracy: Default 1 km — enough for weather, tides and sun times, and fast.
    ///   - defaultLocation: Fallback for `effectiveLocation`; nil means none.
    public init(
        desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyKilometer,
        defaultLocation: CLLocation? = nil,
        requestsLocationOnAuthorization: Bool = true
    ) {
        let manager = CLLocationManager()
        manager.desiredAccuracy = desiredAccuracy
        self.manager = manager
        self.defaultLocation = defaultLocation
        self.requestsLocationOnAuthorization = requestsLocationOnAuthorization
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// Convenience for a fallback given as coordinates.
    public convenience init(defaultLatitude: Double, defaultLongitude: Double) {
        self.init(defaultLocation: CLLocation(latitude: defaultLatitude, longitude: defaultLongitude))
    }

    // MARK: - State

    public var isAuthorized: Bool { Self.isAuthorized(authorizationStatus) }

    public var isAccessDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    public var hasLocation: Bool { location != nil }

    /// The fix, else `defaultLocation`.
    public var effectiveLocation: CLLocation? { location ?? defaultLocation }

    /// Localized description of `lastError`.
    public var errorMessage: String? { lastError?.localizedDescription }

    // MARK: - Requests

    public func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Fire-and-forget fix; observe `location`. Asks for permission first when
    /// it hasn't been granted (the fix follows the grant).
    public func requestLocation() {
        guard isAuthorized else {
            if authorizationStatus == .notDetermined { requestPermission() }
            return
        }
        isLoading = true
        lastError = nil
        manager.requestLocation()
    }

    /// Awaits a fix.
    ///
    /// - Returns `location` immediately when it is younger than `maximumAge`.
    /// - When permission is undetermined, prompts and waits for the answer.
    /// - Throws `.notAuthorized` if access is (or becomes) denied, `.unavailable`
    ///   on a Core Location failure, `.timedOut` after `timeout`, or
    ///   `CancellationError` when the calling task is cancelled.
    /// Concurrent callers share one Core Location request.
    public func currentLocation(
        timeout: Duration = .seconds(15),
        maximumAge: TimeInterval = 0
    ) async throws -> CLLocation {
        if maximumAge > 0, let location, -location.timestamp.timeIntervalSinceNow <= maximumAge {
            return location
        }
        if isAccessDenied { throw LocationError.notAuthorized }

        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, any Error>) in
                waiters[id] = continuation
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(id, with: .failure(LocationError.timedOut))
                }
                if isAuthorized {
                    requestLocation()
                } else {
                    requestPermission()   // the grant triggers requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, with: .failure(CancellationError()))
            }
        }
    }

    // MARK: - Internals

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        #if os(macOS)
        return status == .authorizedAlways
        #elseif os(visionOS)
        return status == .authorizedWhenInUse
        #else
        return status == .authorizedWhenInUse || status == .authorizedAlways
        #endif
    }

    private func finish(_ id: UUID, with result: Result<CLLocation, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishAll(with result: Result<CLLocation, any Error>) {
        for id in Array(waiters.keys) { finish(id, with: result) }
    }

    fileprivate func handle(locations: [CLLocation]) {
        isLoading = false
        // Core Location delivers oldest-first; the last is the freshest fix.
        guard let fresh = locations.last else {
            finishAll(with: .failure(LocationError.unavailable))
            return
        }
        location = fresh
        finishAll(with: .success(fresh))
    }

    fileprivate func handle(error: any Error) {
        isLoading = false
        lastError = error
        if (error as? CLError)?.code != .locationUnknown { onError?(error) }
        let mapped: LocationError = (error as? CLError)?.code == .denied ? .notAuthorized : .unavailable
        finishAll(with: .failure(mapped))
    }

    fileprivate func handle(authorization status: CLAuthorizationStatus) {
        let previous = authorizationStatus
        authorizationStatus = status
        if previous != status { onAuthorizationChange?(previous, status) }

        if Self.isAuthorized(status) {
            if requestsLocationOnAuthorization || !waiters.isEmpty { requestLocation() }
        } else if status == .denied || status == .restricted {
            isLoading = false
            finishAll(with: .failure(LocationError.notAuthorized))
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations: locations) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor in self.handle(error: error) }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handle(authorization: status) }
    }
}
