import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ShadeCore

// MARK: - Helpers (file-private so they can't clash with other test files)

private let mirrorA = URL(string: "https://a.example/api/interpreter")!
private let mirrorB = URL(string: "https://b.example/api/interpreter")!
private let mirrorC = URL(string: "https://c.example/api/interpreter")!
private let okBody = #"{"version":0.6,"generator":"Overpass API","elements":[{"type":"node","id":1,"lat":37.5,"lon":127.0}]}"#
private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

/// Scripted reply for one request.
private enum Reply: Sendable {
    case http(Int, String)
    case failure(URLError.Code)

    static let ok = Reply.http(200, okBody)
}

/// Pops scripted replies per endpoint; the last reply repeats once the script runs out.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [URL: [Reply]]

    init(_ replies: [URL: [Reply]]) { self.replies = replies }

    func next(for url: URL?) -> Reply {
        lock.lock(); defer { lock.unlock() }
        guard let url, var queue = replies[url], let first = queue.first else { return .failure(.cannotFindHost) }
        if queue.count > 1 {
            queue.removeFirst()
            replies[url] = queue
        }
        return first
    }

    var client: StubHTTPClient {
        StubHTTPClient { request in
            switch self.next(for: request.url) {
            case let .http(status, body): return (Data(body.utf8), status)
            case let .failure(code): throw URLError(code)
            }
        }
    }
}

/// Records backoff delays instead of sleeping.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []

    var delays: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _delays
    }

    func record(_ delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _delays.append(delay)
    }
}

/// Mutable clock for TTL tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ now: Date) { _now = now }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); defer { lock.unlock() }; _now = newValue }
    }
}

/// Thread-safe call counter.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Returns the count before incrementing.
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value - 1
    }
}

/// HTTP client whose requests block until `release()`; cancelling the caller fails the request.
private final class GatedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var released = false
    private var cancelled = false
    private var _requestCount = 0

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    func release() {
        lock.lock()
        released = true
        let continuations = waiting
        waiting = []
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    private func cancelWaiting() {
        lock.lock()
        cancelled = true
        let continuations = waiting
        waiting = []
        lock.unlock()
        continuations.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }

    private func recordRequest() {
        lock.lock(); defer { lock.unlock() }
        _requestCount += 1
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: URLError(.cancelled))
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiting()
        }
        let url = request.url ?? mirrorA
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (Data(okBody.utf8), response)
    }
}

/// Polls `condition` every millisecond for up to two seconds.
private func waitUntil(_ condition: @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("condition not met in time", file: file, line: line)
}

private func emptyArea(_ bbox: BoundingBox, _ date: Date) -> AreaData {
    AreaData(bbox: bbox, buildings: [], trees: [], canopies: [], graph: .empty, coolSpots: [], fetchedAt: date)
}

/// Error thrown by fake parsers.
private struct FakeParseError: Error {}

// MARK: - Tests

final class OverpassClientTests: XCTestCase {
    private func makeClient(_ http: HTTPClient, endpoints: [URL] = [mirrorA, mirrorB, mirrorC],
                            cacheDirectory: URL? = nil, cacheTTL: TimeInterval = 7 * 24 * 3600, attempts: Int = 2,
                            now: @escaping @Sendable () -> Date = { fixedNow }, sleeps: SleepLog = SleepLog(),
                            parseArea: @escaping @Sendable (Data, BoundingBox, Date) throws -> AreaData = { _, bbox, date in
                                emptyArea(bbox, date)
                            }) -> OverpassClient {
        OverpassClient(http: http, endpoints: endpoints, cacheDirectory: cacheDirectory, cacheTTL: cacheTTL,
                       maxAttemptsPerEndpoint: attempts, now: now, sleep: { sleeps.record($0) },
                       areaQuery: { "[out:json];area(\($0.overpassString));out;" },
                       coolSpotQuery: { "[out:json];cool(\($0.latitude),\($0.longitude),\(Int($1)));out;" },
                       parseArea: parseArea,
                       parseCoolSpots: { _ in
                           [CoolSpot(id: 7, kind: .drinkingWater, name: "Fountain",
                                     coordinate: GeoCoordinate(latitude: 37.5, longitude: 127))]
                       })
    }

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverpassClientTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func assertThrows(_ expected: ShadeError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ShadeError, expected, file: file, line: line)
        }
    }

    // MARK: Request formatting

    func testRequestFormatting() async throws {
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub)
        let query = "[out:json][timeout:90];\nway[\"highway\"](37.5,127.0,37.6,127.1);out geom;"
        let data = try await client.fetch(query: query)
        XCTAssertEqual(data, Data(okBody.utf8))

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(request.url, mirrorA)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"),
                       "Shadewalk/1.0 (iOS; https://github.com/vitaliirizol-lgtm/hand-gallery)")
        XCTAssertEqual(request.timeoutInterval, 100, accuracy: 5)

        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.hasPrefix("data="))
        let encoded = String(body.dropFirst(5))
        XCTAssertEqual(encoded.removingPercentEncoding, query)
        for raw in ["\n", " ", "\"", "[", "]", ";", "=", "&", "+", ","] {
            XCTAssertFalse(encoded.contains(raw), "unencoded \(raw.debugDescription)")
        }
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = OverpassClient.formBody(for: "a b&c=d+e;\"f\"\n[g]~_.-é")
        XCTAssertEqual(String(data: body, encoding: .utf8), "data=a%20b%26c%3Dd%2Be%3B%22f%22%0A%5Bg%5D~_.-%C3%A9")
    }

    // MARK: Retry and fallback

    func testFallsBackThroughMirrorsInOrder() async throws {
        let script = Script([mirrorA: [.http(503, "busy")], mirrorB: [.http(429, "slow down")], mirrorC: [.ok]])
        let stub = script.client
        let sleeps = SleepLog()
        let client = makeClient(stub, sleeps: sleeps)
        let data = try await client.fetch(query: "q")
        XCTAssertEqual(data, Data(okBody.utf8))
        XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorA, mirrorB, mirrorB, mirrorC])
        // Backoff only between attempts on the same mirror.
        XCTAssertEqual(sleeps.delays, [0.5, 0.5])
    }

    func testRetryCountAndExponentialBackoff() async throws {
        let script = Script([mirrorA: [.http(500, "err"), .http(502, "err"), .http(504, "err")], mirrorB: [.ok]])
        let stub = script.client
        let sleeps = SleepLog()
        let client = makeClient(stub, attempts: 3, sleeps: sleeps)
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorA, mirrorA, mirrorB])
        XCTAssertEqual(sleeps.delays, [0.5, 1.0])
    }

    func testSucceedsOnRetryWithoutTouchingOtherMirrors() async throws {
        let script = Script([mirrorA: [.failure(.timedOut), .ok]])
        let stub = script.client
        let sleeps = SleepLog()
        let client = makeClient(stub, sleeps: sleeps)
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorA])
        XCTAssertEqual(sleeps.delays, [0.5])
    }

    func testNoRetryOnClientError() async throws {
        let script = Script([mirrorA: [.http(400, "<html>syntax error</html>")], mirrorB: [.ok]])
        let stub = script.client
        let sleeps = SleepLog()
        let client = makeClient(stub, attempts: 3, sleeps: sleeps)
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorB])
        XCTAssertEqual(sleeps.delays, [])
    }

    func testSameNonRetryableStatusEverywhereIsBadResponse() async {
        let script = Script([mirrorA: [.http(400, "bad")], mirrorB: [.http(400, "bad")], mirrorC: [.http(400, "bad")]])
        let stub = script.client
        let client = makeClient(stub)
        await assertThrows(.badResponse(status: 400)) { _ = try await client.fetch(query: "q") }
        XCTAssertEqual(stub.requests.count, 3)
    }

    func testMixedFailuresAreNetworkUnavailable() async {
        let script = Script([mirrorA: [.http(400, "bad")], mirrorB: [.http(404, "nope")], mirrorC: [.http(400, "bad")]])
        let client = makeClient(script.client)
        await assertThrows(.networkUnavailable) { _ = try await client.fetch(query: "q") }

        let script2 = Script([mirrorA: [.http(400, "bad")], mirrorB: [.failure(.notConnectedToInternet)], mirrorC: [.http(400, "")]])
        let client2 = makeClient(script2.client)
        await assertThrows(.networkUnavailable) { _ = try await client2.fetch(query: "q") }
    }

    func testAllRetryableFailuresAreNetworkUnavailable() async {
        let script = Script([mirrorA: [.http(503, "")], mirrorB: [.http(429, "")], mirrorC: [.failure(.timedOut)]])
        let stub = script.client
        let sleeps = SleepLog()
        let client = makeClient(stub, sleeps: sleeps)
        await assertThrows(.networkUnavailable) { _ = try await client.fetch(query: "q") }
        XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorA, mirrorB, mirrorB, mirrorC, mirrorC])
        XCTAssertEqual(sleeps.delays, [0.5, 0.5, 0.5])
    }

    func testNoEndpointsIsNetworkUnavailable() async {
        let stub = Script([:]).client
        let client = makeClient(stub, endpoints: [])
        await assertThrows(.networkUnavailable) { _ = try await client.fetch(query: "q") }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testAttemptsAreAtLeastOne() async throws {
        let script = Script([mirrorA: [.http(503, "")], mirrorB: [.ok]])
        let stub = script.client
        let client = makeClient(stub, attempts: 0)
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorB])
    }

    func testOKResponsesThatAreNotUsableJSONAreRetried() async throws {
        let bad = [
            "<!DOCTYPE html><html><body>The server is probably too busy</body></html>",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><osm><remark>runtime error: Query timed out</remark></osm>",
            #"{"version":0.6,"elements":[],"remark":"runtime error: Query timed out in \"query\" at line 3 after 91 seconds."}"#,
            #"{"version":0.6,"elements":[],"remark":"runtime error: Query run out of memory using about 2048 MB of RAM."}"#,
            #"{"version":0.6,"elements":[],"remark":"Dispatcher timeout"}"#,
            #"{"version":0.6,"elements":[{"type":"node","#,
            "",
            "   ",
        ]
        for body in bad {
            let script = Script([mirrorA: [.http(200, body)], mirrorB: [.ok]])
            let stub = script.client
            let client = makeClient(stub)
            let data = try await client.fetch(query: "q")
            XCTAssertEqual(data, Data(okBody.utf8), body)
            XCTAssertEqual(stub.requests.map(\.url), [mirrorA, mirrorA, mirrorB], body)
        }
    }

    func testHarmlessRemarksAreAccepted() async throws {
        let bodies = [
            // OSM tag called "remark" inside an element is not an Overpass error.
            #"{"elements":[{"type":"node","id":1,"tags":{"remark":"runtime error"}}]}"#,
            #"{"elements":[],"remark":"runtime remark: nothing to worry about"}"#,
            "\n  {\"elements\":[]}\n",
        ]
        for body in bodies {
            let script = Script([mirrorA: [.http(200, body)]])
            let stub = script.client
            let data = try await makeClient(stub).fetch(query: "q")
            XCTAssertEqual(data, Data(body.utf8))
            XCTAssertEqual(stub.requests.count, 1, body)
        }
        // A "remark" anywhere forces a full parse, which also catches malformed JSON.
        // (Truncated mid-array, but happens to end with "}".)
        let malformed = #"{"elements":[{"tags":{"remark":"x"}}"#
        let script = Script([mirrorA: [.http(200, malformed)], mirrorB: [.ok]])
        let data = try await makeClient(script.client).fetch(query: "q")
        XCTAssertEqual(data, Data(okBody.utf8))
    }

    func testCancelledBackoffSleepThrowsCancelled() async {
        let script = Script([mirrorA: [.http(503, "")]])
        let stub = script.client
        let client = OverpassClient(http: stub, endpoints: [mirrorA], now: { fixedNow },
                                    sleep: { _ in throw CancellationError() })
        await assertThrows(.cancelled) { _ = try await client.fetch(query: "q") }
        XCTAssertEqual(stub.requests.count, 1)
    }

    // MARK: Caching

    func testMemoryCacheServesRepeatedQueries() async throws {
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub)
        _ = try await client.fetch(query: "q")
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.count, 1)
        _ = try await client.fetch(query: "q2")
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testMemoryCacheExpiresAfterTTL() async throws {
        let clock = TestClock(fixedNow)
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub, cacheTTL: 100, now: { clock.now })
        _ = try await client.fetch(query: "q")
        clock.now = fixedNow.addingTimeInterval(99)
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.count, 1)
        clock.now = fixedNow.addingTimeInterval(100)
        _ = try await client.fetch(query: "q")
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testMemoryCacheIsBounded() async throws {
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub)
        for i in 0...OverpassClient.memoryCacheLimit {
            _ = try await client.fetch(query: "q\(i)")
        }
        let count = stub.requests.count
        _ = try await client.fetch(query: "q\(OverpassClient.memoryCacheLimit)")  // newest: still cached
        XCTAssertEqual(stub.requests.count, count)
        _ = try await client.fetch(query: "q0")  // oldest: evicted
        XCTAssertEqual(stub.requests.count, count + 1)
    }

    func testFailuresAreNotCached() async throws {
        let script = Script([mirrorA: [.http(503, ""), .http(503, ""), .ok]])
        let stub = script.client
        let client = makeClient(stub, endpoints: [mirrorA])
        await assertThrows(.networkUnavailable) { _ = try await client.fetch(query: "q") }
        let data = try await client.fetch(query: "q")
        XCTAssertEqual(data, Data(okBody.utf8))
        XCTAssertEqual(stub.requests.count, 3)
    }

    func testDiskCacheHitMissAndExpiry() async throws {
        let dir = makeTempDirectory()
        let week: TimeInterval = 7 * 24 * 3600

        let first = Script([mirrorA: [.ok]]).client
        _ = try await makeClient(first, cacheDirectory: dir).fetch(query: "q")
        XCTAssertEqual(first.requests.count, 1)
        let file = DiskCache(directory: dir.appendingPathComponent("Overpass")).fileURL(forKey: "q")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // New client (empty memory cache), 6 days later: served from disk.
        let second = Script([mirrorA: [.http(500, "should not be called")]]).client
        let sixDaysLater = fixedNow.addingTimeInterval(6 * 24 * 3600)
        let cached = try await makeClient(second, cacheDirectory: dir, now: { sixDaysLater }).fetch(query: "q")
        XCTAssertEqual(cached, Data(okBody.utf8))
        XCTAssertTrue(second.requests.isEmpty)

        // Different query: disk miss.
        let third = Script([mirrorA: [.ok]]).client
        _ = try await makeClient(third, cacheDirectory: dir, now: { sixDaysLater }).fetch(query: "other")
        XCTAssertEqual(third.requests.count, 1)

        // Past the TTL: refetched and rewritten.
        let fourth = Script([mirrorA: [.ok]]).client
        let expired = fixedNow.addingTimeInterval(week)
        _ = try await makeClient(fourth, cacheDirectory: dir, now: { expired }).fetch(query: "q")
        XCTAssertEqual(fourth.requests.count, 1)
        let rewritten = DiskCache(directory: dir.appendingPathComponent("Overpass"))
            .entry(forKey: "q", maxAge: week, now: expired)
        XCTAssertEqual(rewritten?.date, expired)
    }

    func testNoDiskCacheWithoutDirectory() async throws {
        let first = Script([mirrorA: [.ok]]).client
        _ = try await makeClient(first).fetch(query: "q")
        let second = Script([mirrorA: [.ok]]).client
        _ = try await makeClient(second).fetch(query: "q")
        XCTAssertEqual(second.requests.count, 1)
    }

    // MARK: Coalescing and cancellation

    func testConcurrentIdenticalRequestsAreCoalesced() async throws {
        let gate = GatedHTTPClient()
        let client = makeClient(gate)
        let first = Task { try await client.fetch(query: "q") }
        try await waitUntil { gate.requestCount == 1 }
        let second = Task { try await client.fetch(query: "q") }
        try await waitUntil { await client.waiterCount(for: "q") == 2 }
        XCTAssertEqual(gate.requestCount, 1)

        gate.release()
        let results = try await [first.value, second.value]
        XCTAssertEqual(results, [Data(okBody.utf8), Data(okBody.utf8)])
        XCTAssertEqual(gate.requestCount, 1)
        let waiters = await client.waiterCount(for: "q")
        XCTAssertEqual(waiters, 0)

        // Different queries are separate requests.
        _ = try await client.fetch(query: "other")
        XCTAssertEqual(gate.requestCount, 2)
    }

    func testCancellingOneOfTwoWaitersKeepsSharedFetch() async throws {
        let gate = GatedHTTPClient()
        let client = makeClient(gate)
        let first = Task { try await client.fetch(query: "q") }
        try await waitUntil { gate.requestCount == 1 }
        let second = Task { try await client.fetch(query: "q") }
        try await waitUntil { await client.waiterCount(for: "q") == 2 }

        first.cancel()
        try await waitUntil { await client.waiterCount(for: "q") == 1 }
        gate.release()
        let data = try await second.value
        XCTAssertEqual(data, Data(okBody.utf8))
        XCTAssertEqual(gate.requestCount, 1)
    }

    func testCancellingSoleWaiterCancelsFetchWithoutFallback() async throws {
        let gate = GatedHTTPClient()
        let client = makeClient(gate)
        let task = Task { try await client.fetch(query: "q") }
        try await waitUntil { gate.requestCount == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ShadeError, .cancelled)
        }
        XCTAssertEqual(gate.requestCount, 1, "no retry or mirror fallback after cancellation")
        let waiters = await client.waiterCount(for: "q")
        XCTAssertEqual(waiters, 0)

        // The next caller starts a fresh fetch.
        gate.release()
        let data = try await client.fetch(query: "q")
        XCTAssertEqual(data, Data(okBody.utf8))
        XCTAssertEqual(gate.requestCount, 2)
    }

    // MARK: Area data and cool spots

    func testAreaDataUsesQueryBuilderParserAndClock() async throws {
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub)
        let bbox = BoundingBox(minLatitude: 37.5, minLongitude: 126.9, maxLatitude: 37.6, maxLongitude: 127.0)
        let area = try await client.areaData(for: bbox)
        XCTAssertEqual(area.bbox, bbox)
        XCTAssertEqual(area.fetchedAt, fixedNow)

        let body = try XCTUnwrap(stub.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(String(body.dropFirst(5)).removingPercentEncoding,
                       "[out:json];area(37.500000,126.900000,37.600000,127.000000);out;")

        // Same bbox again: cached, no new request.
        _ = try await client.areaData(for: bbox)
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testCoolSpotsUsesCoolSpotQueryAndParser() async throws {
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub)
        let spots = try await client.coolSpots(near: GeoCoordinate(latitude: 37.5, longitude: 127), radius: 800)
        XCTAssertEqual(spots.map(\.id), [7])
        let body = try XCTUnwrap(stub.requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(String(body.dropFirst(5)).removingPercentEncoding, "[out:json];cool(37.5,127.0,800);out;")
    }

    func testUndecodableResponseIsEvictedFromCaches() async throws {
        let dir = makeTempDirectory()
        let calls = Counter()
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub, cacheDirectory: dir, parseArea: { _, bbox, date in
            if calls.next() == 0 { throw FakeParseError() }
            return emptyArea(bbox, date)
        })
        let bbox = BoundingBox(minLatitude: 1, minLongitude: 2, maxLatitude: 3, maxLongitude: 4)
        do {
            _ = try await client.areaData(for: bbox)
            XCTFail("expected decoding failure")
        } catch {
            guard case .decodingFailed? = error as? ShadeError else { return XCTFail("unexpected \(error)") }
        }
        let query = "[out:json];area(\(bbox.overpassString));out;"
        let file = DiskCache(directory: dir.appendingPathComponent("Overpass")).fileURL(forKey: query)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        _ = try await client.areaData(for: bbox)
        XCTAssertEqual(stub.requests.count, 2, "bad response must be refetched, not served from cache")
    }

    func testDomainParserErrorsPassThroughAndKeepCache() async throws {
        let script = Script([mirrorA: [.ok]])
        let stub = script.client
        let client = makeClient(stub, parseArea: { _, _, _ in throw ShadeError.noWalkableNetwork })
        let bbox = BoundingBox(minLatitude: 1, minLongitude: 2, maxLatitude: 3, maxLongitude: 4)
        await assertThrows(.noWalkableNetwork) { _ = try await client.areaData(for: bbox) }
        await assertThrows(.noWalkableNetwork) { _ = try await client.areaData(for: bbox) }
        XCTAssertEqual(stub.requests.count, 1)
    }
}
