import Foundation
import ShadeFeatures

/// The single consumer of `NavigationModel.events`, shared by every follow-mode session.
///
/// `NavigationModel.events` is one `AsyncStream` for the model's whole lifetime, and cancelling the task that iterates
/// an `AsyncStream` finishes it for good. Follow mode is presented and dismissed once per walk, so iterating the model's
/// stream in the screen's `.task` would end it when the first walk closes and leave every later walk without haptics.
/// The relay iterates the model's stream exactly once, in a task of its own that lives as long as the model, and hands
/// each event to the follow-mode screen that is currently listening (`sessionEvents()`).
@MainActor
final class NavigationEventRelay {
    private static var relays: [ObjectIdentifier: NavigationEventRelay] = [:]

    /// The relay for `navigation` (created, and subscribed, on first use).
    static func shared(for navigation: NavigationModel) -> NavigationEventRelay {
        let key = ObjectIdentifier(navigation)
        if let relay = relays[key], relay.navigation === navigation { return relay }
        let relay = NavigationEventRelay(navigation: navigation)
        relays[key] = relay
        return relay
    }

    /// Events kept while no screen is listening (e.g. between `start(route:)` and the screen appearing).
    private static let maxPendingEvents = 8

    private weak var navigation: NavigationModel?
    private var listeners: [UUID: AsyncStream<NavigationEvent>.Continuation] = [:]
    private var pending: [NavigationEvent] = []
    private var subscription: Task<Void, Never>?

    private init(navigation: NavigationModel) {
        self.navigation = navigation
        let events = navigation.events
        subscription = Task { [weak self] in
            for await event in events {
                self?.deliver(event)
            }
        }
    }

    /// Call right before starting a walk: drops events left over from an earlier one.
    func beginSession() {
        pending.removeAll()
    }

    /// Events from now on (plus any received since `beginSession()` while nobody listened). Cancelling the iterating
    /// task ends only this stream, never the model's.
    func sessionEvents() -> AsyncStream<NavigationEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: NavigationEvent.self,
                                                            bufferingPolicy: .bufferingNewest(16))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.listeners[id] = nil
            }
        }
        for event in pending {
            continuation.yield(event)
        }
        pending.removeAll()
        listeners[id] = continuation
        return stream
    }

    private func deliver(_ event: NavigationEvent) {
        guard !listeners.isEmpty else {
            pending.append(event)
            if pending.count > NavigationEventRelay.maxPendingEvents {
                pending.removeFirst(pending.count - NavigationEventRelay.maxPendingEvents)
            }
            return
        }
        for continuation in listeners.values {
            continuation.yield(event)
        }
    }
}
