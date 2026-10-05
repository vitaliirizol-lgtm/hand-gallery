import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `HTTPClient` backed by `URLSession`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation lacks the async API on older toolchains; bridge explicitly.
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, let response {
                    cont.resume(returning: (data, response))
                } else {
                    cont.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
        #else
        let (data, response) = try await session.data(for: request)
        #endif
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Canned-response `HTTPClient` for tests and previews.
public final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)

    private let handler: Handler
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Requests received so far, in order.
    public var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (data, status) = try handler(request)
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }
}
