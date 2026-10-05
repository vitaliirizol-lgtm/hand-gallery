import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Overpass API client with mirror fallback, retry/backoff and disk cache. See SPEC §2.
///
/// `fetch(query:)` looks in the in-memory cache, then the disk cache, then tries each endpoint in order (up to
/// `maxAttemptsPerEndpoint` attempts each, with exponential backoff). Concurrent identical requests share one fetch.
public actor OverpassClient: AreaDataProviding, CoolSpotProviding {
    public static let defaultEndpoints: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    /// Sent with every request (Overpass operators ask clients to identify themselves).
    public static let userAgent = "Shadewalk/1.0 (iOS; https://github.com/vitaliirizol-lgtm/hand-gallery)"
    /// Per-request timeout; a little above the `[timeout:90]` the area query asks the server for.
    public static let requestTimeout: TimeInterval = 100
    /// Delay before the second attempt on an endpoint; doubles for each further attempt.
    public static let retryBaseDelay: TimeInterval = 0.5
    /// Max raw responses kept in memory (area responses can be several MB each).
    static let memoryCacheLimit = 16

    private let http: HTTPClient
    private let endpoints: [URL]
    private let diskCache: DiskCache?
    private let cacheTTL: TimeInterval
    private let maxAttemptsPerEndpoint: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let areaQuery: @Sendable (BoundingBox) -> String
    private let coolSpotQuery: @Sendable (GeoCoordinate, Double) -> String
    private let parseArea: @Sendable (Data, BoundingBox, Date) throws -> AreaData
    private let parseCoolSpots: @Sendable (Data) throws -> [CoolSpot]

    private struct MemoryEntry {
        var data: Data
        var storedAt: Date
    }

    private struct InFlight {
        var id: Int
        var task: Task<Data, Error>
        var waiters: Int
    }

    private var memory: [String: MemoryEntry] = [:]
    /// Memory-cache keys, least recently stored first.
    private var memoryOrder: [String] = []
    private var inFlight: [String: InFlight] = [:]
    private var nextRequestID = 0
    private var didPruneDisk = false

    /// - Parameters:
    ///   - cacheDirectory: on-disk cache root; nil disables disk caching. Responses go in its `Overpass` subfolder.
    ///   - cacheTTL: seconds a cached response stays valid (default 7 days).
    ///   - maxAttemptsPerEndpoint: attempts per mirror before moving to the next one (at least 1).
    ///   - now: clock, injectable for tests.
    ///   - sleep: backoff delay in seconds; injectable so tests don't actually wait.
    ///   - areaQuery, coolSpotQuery: Overpass QL builders (default `OverpassQueryBuilder`).
    ///   - parseArea, parseCoolSpots: response parsers (default `OSMAreaParser`).
    public init(http: HTTPClient, endpoints: [URL] = OverpassClient.defaultEndpoints, cacheDirectory: URL? = nil,
                cacheTTL: TimeInterval = 7 * 24 * 3600, maxAttemptsPerEndpoint: Int = 2,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                },
                areaQuery: @escaping @Sendable (BoundingBox) -> String = { OverpassQueryBuilder.areaQuery(for: $0) },
                coolSpotQuery: @escaping @Sendable (GeoCoordinate, Double) -> String = {
                    OverpassQueryBuilder.coolSpotQuery(near: $0, radius: $1)
                },
                parseArea: @escaping @Sendable (Data, BoundingBox, Date) throws -> AreaData = {
                    try OSMAreaParser.parse($0, bbox: $1, fetchedAt: $2)
                },
                parseCoolSpots: @escaping @Sendable (Data) throws -> [CoolSpot] = { try OSMAreaParser.parseCoolSpots($0) }) {
        self.http = http
        self.endpoints = endpoints
        self.diskCache = cacheDirectory.map { DiskCache(directory: $0.appendingPathComponent("Overpass", isDirectory: true)) }
        self.cacheTTL = cacheTTL
        self.maxAttemptsPerEndpoint = max(1, maxAttemptsPerEndpoint)
        self.now = now
        self.sleep = sleep
        self.areaQuery = areaQuery
        self.coolSpotQuery = coolSpotQuery
        self.parseArea = parseArea
        self.parseCoolSpots = parseCoolSpots
    }

    /// Raw Overpass JSON for `query` (cached by query text).
    ///
    /// Throws `ShadeError.networkUnavailable` when every endpoint failed, `ShadeError.badResponse` when every
    /// endpoint rejected the query with the same non-retryable status, and `ShadeError.cancelled` when cancelled.
    /// A shared fetch is cancelled only once every caller waiting on it has been cancelled.
    public func fetch(query: String) async throws -> Data {
        if let cached = memoryHit(query) { return cached }

        let id: Int
        let task: Task<Data, Error>
        if var existing = inFlight[query] {
            existing.waiters += 1
            inFlight[query] = existing
            id = existing.id
            task = existing.task
        } else {
            nextRequestID += 1
            let newID = nextRequestID
            id = newID
            task = Task { try await self.load(query: query, requestID: newID) }
            inFlight[query] = InFlight(id: newID, task: task, waiters: 1)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.waiterCancelled(query: query, requestID: id) }
        }
    }

    /// Parsed area data for `bbox` (parsing runs off the actor so other fetches aren't blocked).
    public nonisolated func areaData(for bbox: BoundingBox) async throws -> AreaData {
        let query = areaQuery(bbox)
        let data = try await fetch(query: query)
        do {
            return try parseArea(data, bbox, now())
        } catch {
            throw await parseFailure(error, query: query)
        }
    }

    /// Cool-spot POIs within `radius` metres of `coordinate`.
    public nonisolated func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        let query = coolSpotQuery(coordinate, radius)
        let data = try await fetch(query: query)
        do {
            return try parseCoolSpots(data)
        } catch {
            throw await parseFailure(error, query: query)
        }
    }

    /// Drops `query` from the memory and disk caches.
    public func invalidate(query: String) {
        removeFromMemory(query)
        diskCache?.remove(key: query)
    }

    /// Number of callers currently awaiting the shared fetch for `query` (0 if none). For tests.
    func waiterCount(for query: String) -> Int {
        inFlight[query]?.waiters ?? 0
    }

    // MARK: - Loading

    /// Disk cache, then network. Runs inside the shared task for `query`.
    private func load(query: String, requestID: Int) async throws -> Data {
        defer { finish(query: query, requestID: requestID) }
        if let disk = diskCache {
            if !didPruneDisk {
                didPruneDisk = true
                disk.prune(maxAge: cacheTTL, now: now())
            }
            if let entry = disk.entry(forKey: query, maxAge: cacheTTL, now: now()) {
                storeInMemory(query, data: entry.data, storedAt: entry.date)
                return entry.data
            }
        }
        let data = try await fetchFromNetwork(query: query)
        let storedAt = now()
        storeInMemory(query, data: data, storedAt: storedAt)
        diskCache?.write(key: query, data: data, date: storedAt)
        return data
    }

    private func finish(query: String, requestID: Int) {
        if inFlight[query]?.id == requestID { inFlight[query] = nil }
    }

    private func waiterCancelled(query: String, requestID: Int) {
        guard var entry = inFlight[query], entry.id == requestID else { return }
        entry.waiters -= 1
        if entry.waiters > 0 {
            inFlight[query] = entry
        } else {
            // Nobody wants the result any more; later callers start a fresh fetch.
            inFlight[query] = nil
            entry.task.cancel()
        }
    }

    private enum AttemptFailure {
        /// Transport error (URLError, timeout, …).
        case transport
        /// 2xx whose body is not usable Overpass JSON.
        case invalidBody
        case status(Int, retryable: Bool)
    }

    /// Mirror/retry loop. Nonisolated so response validation (possibly a full JSON parse) doesn't block the actor.
    private nonisolated func fetchFromNetwork(query: String) async throws -> Data {
        let body = Self.formBody(for: query)
        var failures: [AttemptFailure] = []
        for endpoint in endpoints {
            let request = Self.makeRequest(endpoint: endpoint, body: body)
            for attempt in 0..<maxAttemptsPerEndpoint {
                if attempt > 0 {
                    let delay = Self.retryBaseDelay * Double(1 << min(attempt - 1, 20))
                    do { try await sleep(delay) } catch { throw ShadeError.cancelled }
                }
                if Task.isCancelled { throw ShadeError.cancelled }

                let failure: AttemptFailure
                do {
                    let (data, response) = try await http.data(for: request)
                    let status = response.statusCode
                    if (200..<300).contains(status) {
                        if Self.isUsableOverpassJSON(data) { return data }
                        failure = .invalidBody
                    } else {
                        failure = .status(status, retryable: Self.isRetryable(status: status))
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw ShadeError.cancelled }
                    failure = .transport
                }
                failures.append(failure)
                // A non-retryable rejection won't change on retry: move straight to the next mirror.
                if case .status(_, retryable: false) = failure { break }
            }
        }
        throw Self.finalError(for: failures)
    }

    /// `badResponse(status)` when every failure was the same non-retryable status, else `networkUnavailable`.
    private static func finalError(for failures: [AttemptFailure]) -> ShadeError {
        var commonStatus: Int?
        for failure in failures {
            guard case let .status(status, retryable: false) = failure,
                  commonStatus == nil || commonStatus == status else { return .networkUnavailable }
            commonStatus = status
        }
        return commonStatus.map { .badResponse(status: $0) } ?? .networkUnavailable
    }

    /// Maps a parser error to a `ShadeError`, evicting the cached response when it couldn't be decoded.
    private func parseFailure(_ error: Error, query: String) -> Error {
        switch error {
        case ShadeError.decodingFailed:
            invalidate(query: query)
            return error
        case is ShadeError:
            return error
        default:
            // A response the parser can't read must not stay cached for a week.
            invalidate(query: query)
            return ShadeError.decodingFailed(String(describing: error))
        }
    }

    // MARK: - Memory cache

    private func memoryHit(_ query: String) -> Data? {
        guard let entry = memory[query] else { return nil }
        let age = now().timeIntervalSince(entry.storedAt)
        guard age >= 0, age < cacheTTL else {
            removeFromMemory(query)
            return nil
        }
        return entry.data
    }

    private func storeInMemory(_ query: String, data: Data, storedAt: Date) {
        if memory.updateValue(MemoryEntry(data: data, storedAt: storedAt), forKey: query) != nil {
            memoryOrder.removeAll { $0 == query }
        }
        memoryOrder.append(query)
        while memoryOrder.count > Self.memoryCacheLimit {
            memory[memoryOrder.removeFirst()] = nil
        }
    }

    private func removeFromMemory(_ query: String) {
        if memory.removeValue(forKey: query) != nil {
            memoryOrder.removeAll { $0 == query }
        }
    }

    // MARK: - Request / response helpers

    static func makeRequest(endpoint: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// `data=<query>` with everything except RFC 3986 unreserved characters percent-encoded.
    static func formBody(for query: String) -> Data {
        Data(("data=" + percentEncode(query)).utf8)
    }

    static func percentEncode(_ string: String) -> String {
        let hexDigits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(string.utf8.count * 3)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(byte)
            default:
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// True if `data` looks like a complete Overpass JSON object without a runtime-error/timeout remark.
    /// Overpass reports overload as HTML/XML pages, and query timeouts as JSON with a top-level `remark`.
    static func isUsableOverpassJSON(_ data: Data) -> Bool {
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }
        guard let first = data.first(where: { !isSpace($0) }), first == UInt8(ascii: "{"),
              let last = data.last(where: { !isSpace($0) }), last == UInt8(ascii: "}") else { return false }
        // Cheap path for the common case: no remark anywhere, so skip a full parse of a multi-MB body.
        guard data.range(of: Data("\"remark\"".utf8)) != nil else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        if let remark = dictionary["remark"] as? String {
            let lower = remark.lowercased()
            if lower.contains("runtime error") || lower.contains("timeout") || lower.contains("timed out") {
                return false
            }
        }
        return true
    }
}
