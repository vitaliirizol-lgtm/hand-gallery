import Foundation
import ShadeCore

/// State of a value that is loaded asynchronously.
public enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    /// `message` is user-facing; `error` is set when the failure was a `ShadeError`.
    case failed(message: String, error: ShadeError?)

    /// The loaded value, if any.
    public var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    /// Nothing requested yet (or the request was reset).
    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// A request is in flight.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// The latest request failed.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// User-facing message of a failure.
    public var errorMessage: String? {
        if case let .failed(message, _) = self { return message }
        return nil
    }

    /// The `ShadeError` behind a failure, if it was one.
    public var shadeError: ShadeError? {
        if case let .failed(_, error) = self { return error }
        return nil
    }

    /// Transforms the loaded value, keeping every other state.
    public func map<T>(_ transform: (Value) -> T) -> LoadState<T> {
        switch self {
        case .idle: return .idle
        case .loading: return .loading
        case let .loaded(value): return .loaded(transform(value))
        case let .failed(message, error): return .failed(message: message, error: error)
        }
    }

    /// `.failed` for `error`: a `ShadeError` keeps its case and localized description; other errors use their
    /// localized description.
    public static func failure(_ error: Error) -> LoadState {
        .failed(message: ErrorMessages.message(for: error), error: error as? ShadeError)
    }
}

extension LoadState: Equatable where Value: Equatable {}
extension LoadState: Hashable where Value: Hashable {}
extension LoadState: Sendable where Value: Sendable {}

/// Error → user-facing text.
enum ErrorMessages {
    static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return error.localizedDescription
    }
}

/// Debounce helper shared by the models.
enum Debounce {
    /// Sleeps for `interval` seconds (just checks for cancellation when `interval ≤ 0`).
    /// - Throws: `CancellationError` when the current task is cancelled.
    static func wait(_ interval: TimeInterval) async throws {
        if interval > 0 {
            let nanoseconds = UInt64(min(interval, 86_400) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        try Task.checkCancellation()
    }
}
