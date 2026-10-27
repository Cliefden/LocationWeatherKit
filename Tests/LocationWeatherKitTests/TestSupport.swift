import Foundation
@testable import LocationWeatherKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }
}

/// 2026-10-27T00:00:00Z.
let referenceMidnight = Date(timeIntervalSince1970: 1_793_059_200)

func utc(_ hour: Double, day: Double = 0) -> Date {
    referenceMidnight.addingTimeInterval(day * 86_400 + hour * 3600)
}

/// A settable clock shared between the test and the code under test.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    var closure: @Sendable () -> Date { { [self] in self.now } }
}

/// Serves canned responses chosen by a routing closure and records every URL.
final class StubLoader: HTTPDataLoader, @unchecked Sendable {
    struct Response {
        let data: Data
        let status: Int
        static func json(_ fixture: String) throws -> Response { Response(data: try Fixture.data(fixture), status: 200) }
        static func status(_ code: Int) -> Response { Response(data: Data(), status: code) }
    }

    private let lock = NSLock()
    private var routes: (URL) throws -> Response
    private var _requests: [URL] = []

    init(_ routes: @escaping (URL) throws -> Response) {
        self.routes = routes
    }

    var requests: [URL] { lock.withLock { _requests } }

    func setRoutes(_ routes: @escaping (URL) throws -> Response) {
        lock.withLock { self.routes = routes }
    }

    func loadData(from url: URL) async throws -> (Data, URLResponse) {
        let route = lock.withLock { () -> (URL) throws -> Response in
            _requests.append(url)
            return routes
        }
        let response = try route(url)
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response.data, http)
    }
}

extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// An isolated UserDefaults suite, removed by `tearDown()`.
struct IsolatedDefaults {
    let suiteName = "LocationWeatherKitTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

struct StubTimeZoneResolver: TimeZoneResolving {
    let identifier: String?
    func timeZoneIdentifier(latitude: Double, longitude: Double) async -> String? { identifier }
}
