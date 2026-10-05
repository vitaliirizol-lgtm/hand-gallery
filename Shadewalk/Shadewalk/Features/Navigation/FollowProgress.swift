import Foundation
import ShadeFeatures

// Pure follow-mode state derived from navigation progress (no SwiftUI, so it is easy to reason about).

/// Where the walker is relative to the shade.
enum FollowShadeStatus: Equatable {
    /// The sun is below the horizon for this walk.
    case sunDown
    /// No more sun between here and the destination.
    case shadeToTheEnd
    /// In shade now; `sunAhead` metres until the next sunny stretch (nil when there is none or it is unknown).
    case inShade(sunAhead: Double?)
    /// In the sun for another `length` metres.
    case inSun(length: Double)

    /// Status from the latest progress, or from the start of the route before the first fix.
    init(route: WalkRoute, progress: RouteProgress?) {
        guard route.sun.isUp else {
            self = .sunDown
            return
        }
        let isInShade: Bool
        let distanceToNextSun: Double?
        let nextSunLength: Double?
        let remainingSunny: Double
        if let progress {
            isInShade = progress.isInShade
            distanceToNextSun = progress.distanceToNextSun
            nextSunLength = progress.nextSunLength
            remainingSunny = progress.remainingSunnyDistance
        } else {
            let state = RouteShadeRuns(route: route).state(at: 0)
            isInShade = state.isInShade
            distanceToNextSun = state.distanceToNextSun
            nextSunLength = state.nextSunLength
            remainingSunny = state.remainingSunnyDistance
        }
        if remainingSunny < 1 {
            self = .shadeToTheEnd
        } else if isInShade {
            self = .inShade(sunAhead: distanceToNextSun)
        } else {
            self = .inSun(length: nextSunLength ?? remainingSunny)
        }
    }
}

/// Distance walked during one follow-mode session, split into shade and sun.
struct FollowWalkedDistance: Equatable {
    /// Metres walked.
    var total: Double = 0
    /// Metres walked in the shade.
    var shaded: Double = 0
    private var routeID: String?
    private var lastAlong: Double?

    /// Adds the progress made along `route` since the previous update on it, split exactly by the route's shaded and
    /// sunny runs. The first update on a route (start, reroute) only sets the reference; backward moves and
    /// implausible jumps are ignored.
    mutating func record(_ progress: RouteProgress?, on route: WalkRoute?) {
        guard let progress, let route else { return }
        let previous = routeID == route.id ? lastAlong : nil
        routeID = route.id
        lastAlong = progress.distanceAlong
        guard let previous else { return }
        let delta = progress.distanceAlong - previous
        guard delta > 0, delta < 250 else { return }
        total += delta
        shaded += FollowWalkedDistance.shadedLength(of: route, from: previous, to: progress.distanceAlong)
    }

    /// Shaded metres of `route` between `start` and `end` metres along its polyline.
    static func shadedLength(of route: WalkRoute, from start: Double, to end: Double) -> Double {
        guard end > start else { return 0 }
        return RouteShadeRuns(route: route).runs.reduce(0) { sum, run in
            guard run.isShaded else { return sum }
            return sum + max(0, min(run.end, end) - max(run.start, start))
        }
    }
}

/// What the arrival sheet shows.
struct FollowArrivalSummary: Identifiable {
    let id = UUID()
    /// Whole minutes walked in the shade.
    let shadeMinutes: Int
    /// Share of the walk in the shade, `[0, 1]`.
    let shadeFraction: Double

    init(route: WalkRoute, walked: FollowWalkedDistance) {
        let speed = WalkGeometry.averageSpeed(of: route)
        if walked.total >= 20 {
            shadeMinutes = max(0, Int((walked.shaded / speed / 60).rounded()))
            shadeFraction = min(1, max(0, walked.shaded / walked.total))
        } else {
            // Barely any tracked progress (e.g. the GPS caught up only at the end): fall back to the plan.
            let planned = route.shadedDuration.isFinite ? route.shadedDuration : 0
            shadeMinutes = max(0, Int((planned / 60).rounded()))
            shadeFraction = route.shadeFraction.isFinite ? min(1, max(0, route.shadeFraction)) : 0
        }
    }
}
