import Foundation

/// Builds a `WalkRoute` (geometry, shade runs, metrics, maneuvers, cool spots) from an A* path.
struct RouteAssembler: Sendable {
    /// Cool spots within this distance of the route are listed, metres.
    static let coolSpotRadius = 40.0
    /// Extra time per street crossing, seconds.
    static let crossingDelay: TimeInterval = 10
    /// Walking speed on stairs relative to the normal speed.
    static let stairsSpeedFactor = 0.6

    let network: RoutingNetwork
    let shadeRuns: WalkRouter.ShadeRunsProvider?
    let coolSpots: [CoolSpot]
    /// `coolSpots` projected with `network.projection`.
    let coolSpotPoints: [Point2D]

    init(network: RoutingNetwork, shadeRuns: WalkRouter.ShadeRunsProvider?, coolSpots: [CoolSpot]) {
        self.network = network
        self.shadeRuns = shadeRuns
        self.coolSpots = coolSpots
        coolSpotPoints = coolSpots.map { network.projection.project($0.coordinate) }
    }

    /// A traversed piece of the route: a (sub-)edge, or a straight access leg to/from the network.
    struct Leg {
        var geometry: [GeoCoordinate]
        var name: String?
        var isAccess = false
        var isSteps = false
        var isUnderpass = false
        var isCrossingEdge = false
        /// Covered way (arcade, tunnel, indoor): always shaded.
        var isCovered = false
        /// `1 − shade` of the (parent) edge; access legs: 1.
        var sunny = 1.0
        /// Base edge id and traversal direction (for the route id); −1 for access legs.
        var parent = -1
        var forward = true
        var endsAtCrossingNode = false
        var endsAtJunction = false
    }

    /// Legs for `steps` (starting at `startNode`) with optional straight access legs at either end. A route that
    /// never leaves its start point gets a single one-point leg so it still has a coordinate.
    static func legs(for steps: [AStar.Step], from startNode: Int, in query: QueryGraph, originLeg: [GeoCoordinate]?,
                     destinationLeg: [GeoCoordinate]?) -> [Leg] {
        let network = query.net
        var out: [Leg] = []
        if let originLeg { out.append(Leg(geometry: originLeg, isAccess: true)) }
        for step in steps {
            let parent = query.parent(of: step.edge)
            let e = network.graph.edges[parent]
            let v = step.to
            let isBase = v < network.nodeCount
            out.append(Leg(geometry: query.geometry(of: step.edge, from: step.from),
                           name: e.name,
                           isSteps: network.edgeIsSteps[parent],
                           isUnderpass: e.isUnderpass,
                           isCrossingEdge: e.isCrossing || e.wayClass == .crossing,
                           isCovered: e.isCovered,
                           sunny: network.edgeSunny[parent],
                           parent: parent,
                           forward: query.isForward(step.edge, from: step.from),
                           endsAtCrossingNode: isBase && network.nodeIsCrossing[v],
                           endsAtJunction: isBase && network.nodeDegree[v] >= 3))
        }
        if let destinationLeg { out.append(Leg(geometry: destinationLeg, isAccess: true)) }
        if out.isEmpty { out.append(Leg(geometry: [query.coordinate(of: startNode)], isAccess: true)) }
        return out
    }

    func assemble(legs: [Leg], profile: RouteProfile, profiles: [RouteProfile], preferences: RoutingPreferences,
                  sun: SunPosition, departure: Date) -> WalkRoute {
        // Geometry: concatenate legs, dropping consecutive duplicates; remember where each leg starts.
        var coords: [GeoCoordinate] = []
        var legStart: [Int] = []
        for leg in legs {
            for (j, c) in leg.geometry.enumerated() {
                if let last = coords.last, QueryGraph.nearlyEqual(last, c) {
                    if j == 0 { legStart.append(coords.count - 1) }
                    continue
                }
                coords.append(c)
                if j == 0 { legStart.append(coords.count - 1) }
            }
            if leg.geometry.isEmpty { legStart.append(max(0, coords.count - 1)) }
        }
        let cumulative = GeoMath.cumulativeDistances(of: coords)
        let distance = cumulative.last ?? 0
        func legEnd(_ i: Int) -> Int { i + 1 < legs.count ? legStart[i + 1] : max(0, coords.count - 1) }
        func legLength(_ i: Int) -> Double {
            guard !coords.isEmpty else { return 0 }
            return max(0, cumulative[legEnd(i)] - cumulative[legStart[i]])
        }

        // Shade runs.
        var segments: [RouteSegment] = []
        if let shadeRuns, coords.count >= 2, distance > 0 {
            segments = coverAwareRuns(shadeRuns, legs: legs, coords: coords, legStart: legStart, legEnd: legEnd,
                                      cumulative: cumulative, sun: sun)
        }
        if segments.isEmpty {
            segments = majoritySegments(legs: legs, coords: coords, legStart: legStart, legEnd: legEnd,
                                        cumulative: cumulative, sunIsUp: sun.isUp)
        }
        let shaded = segments.filter(\.isShaded).reduce(0) { $0 + $1.length }
        let sunny = segments.filter { !$0.isShaded }.reduce(0) { $0 + $1.length }
        let shadeTotal = shaded + sunny
        let shadeFraction = shadeTotal > 0 ? shaded / shadeTotal : (sun.isUp ? 0 : 1)

        // Counters (network legs only).
        let crossings = Self.crossingCount(legs.filter { !$0.isAccess })
        var stairs = 0, underpasses = 0
        var stairsLength = 0.0
        var prev: Leg?
        for (i, leg) in legs.enumerated() where !leg.isAccess {
            if leg.isSteps {
                stairsLength += legLength(i)
                if !(prev?.isSteps ?? false) { stairs += 1 }
            }
            if leg.isUnderpass && !(prev?.isUnderpass ?? false) { underpasses += 1 }
            prev = leg
        }

        // Time.
        let speed = preferences.walkingSpeed.isFinite && preferences.walkingSpeed > 0
            ? preferences.walkingSpeed : RoutingPreferences.default.walkingSpeed
        let stairsSlowdown = stairsLength / speed * (1 / Self.stairsSpeedFactor - 1)
        let duration = distance / speed + stairsSlowdown + Double(crossings) * Self.crossingDelay
        let shadedDuration = shadeTotal > 0 ? duration * shaded / shadeTotal : duration * shadeFraction
        let stride = preferences.strideLength.isFinite && preferences.strideLength > 0
            ? preferences.strideLength : RoutingPreferences.default.strideLength

        // Maneuvers.
        var maneuverLegs: [ManeuverBuilder.Leg] = []
        for (i, leg) in legs.enumerated() {
            let prev: Leg? = i > 0 ? legs[i - 1] : nil
            maneuverLegs.append(ManeuverBuilder.Leg(startIndex: legStart[i], name: leg.name, isAccess: leg.isAccess,
                                                    isSteps: leg.isSteps, isUnderpass: leg.isUnderpass,
                                                    isCrossingEdge: leg.isCrossingEdge,
                                                    startsAtCrossingNode: prev?.endsAtCrossingNode ?? false,
                                                    startsAtJunction: prev?.endsAtJunction ?? false))
        }
        let maneuvers = ManeuverBuilder.build(coordinates: coords, cumulative: cumulative, legs: maneuverLegs)

        return WalkRoute(id: "\(profile.rawValue)-\(Self.routeHash(legs))",
                         profile: profile,
                         profiles: profiles,
                         coordinates: coords,
                         segments: segments,
                         distance: distance,
                         duration: duration,
                         stepCount: Int((distance / stride).rounded()),
                         shadeFraction: shadeFraction,
                         shadedDistance: shaded,
                         sunnyDistance: sunny,
                         shadedDuration: shadedDuration,
                         sunnyDuration: duration - shadedDuration,
                         crossingCount: crossings,
                         stairsCount: stairs,
                         underpassCount: underpasses,
                         maneuvers: maneuvers,
                         coolSpotIDs: coolSpotIDs(near: coords, cumulative: cumulative),
                         elevation: nil,
                         departure: departure,
                         sun: sun)
    }

    /// Street crossings along network legs (in order). Each maximal run of crossing edges counts the crossing
    /// nodes entered at its start, inside it and at its end (a crossing way split at the road node is one crossing;
    /// one way over a dual carriageway is two), and at least one. Crossing nodes away from crossing edges count once
    /// each. The start node of the route is not entered, so it never counts.
    static func crossingCount(_ legs: [Leg]) -> Int {
        var count = 0
        var n = 0
        while n < legs.count {
            guard legs[n].isCrossingEdge else {
                let nextIsCrossingEdge = n + 1 < legs.count && legs[n + 1].isCrossingEdge
                if legs[n].endsAtCrossingNode && !nextIsCrossingEdge { count += 1 }
                n += 1
                continue
            }
            var m = n
            while m + 1 < legs.count && legs[m + 1].isCrossingEdge { m += 1 }
            var nodes = n > 0 && legs[n - 1].endsAtCrossingNode ? 1 : 0
            for x in n...m where legs[x].endsAtCrossingNode { nodes += 1 }
            count += max(1, nodes)
            n = m + 1
        }
        return count
    }

    /// `shadeRuns` over the route, except that covered legs are always shaded (the shade engine only sees
    /// buildings and trees). Without covered legs this is one `shadeRuns` call over the whole polyline.
    private func coverAwareRuns(_ shadeRuns: WalkRouter.ShadeRunsProvider, legs: [Leg], coords: [GeoCoordinate],
                                legStart: [Int], legEnd: (Int) -> Int, cumulative: [Double],
                                sun: SunPosition) -> [RouteSegment] {
        guard legs.contains(where: \.isCovered) else { return shadeRuns(coords, sun) }
        // Maximal coordinate ranges of covered / open legs (legs are contiguous).
        var spans: [(lo: Int, hi: Int, covered: Bool)] = []
        for (i, leg) in legs.enumerated() {
            let lo = legStart[i], hi = legEnd(i)
            guard hi > lo else { continue }
            if let last = spans.last, last.covered == leg.isCovered {
                spans[spans.count - 1].hi = hi
            } else {
                spans.append((lo, hi, leg.isCovered))
            }
        }
        var out: [RouteSegment] = []
        for span in spans {
            let piece = Array(coords[span.lo...span.hi])
            let runs = span.covered
                ? [RouteSegment(coordinates: piece, length: cumulative[span.hi] - cumulative[span.lo], isShaded: true)]
                : shadeRuns(piece, sun)
            for run in runs {
                if let last = out.last, last.isShaded == run.isShaded {
                    let shared = run.coordinates.first == last.coordinates.last
                    out[out.count - 1].coordinates.append(contentsOf: run.coordinates.dropFirst(shared ? 1 : 0))
                    out[out.count - 1].length += run.length
                } else {
                    out.append(run)
                }
            }
        }
        return out
    }

    /// Each leg coloured by its majority shade (access legs sunny while the sun is up); equal neighbours merged.
    private func majoritySegments(legs: [Leg], coords: [GeoCoordinate], legStart: [Int], legEnd: (Int) -> Int,
                                  cumulative: [Double], sunIsUp: Bool) -> [RouteSegment] {
        var out: [RouteSegment] = []
        for (i, leg) in legs.enumerated() {
            let lo = legStart[i], hi = legEnd(i)
            guard hi > lo else { continue }
            let isShaded = !sunIsUp || (!leg.isAccess && leg.sunny <= 0.5)
            let length = cumulative[hi] - cumulative[lo]
            if let last = out.last, last.isShaded == isShaded {
                out[out.count - 1].coordinates.append(contentsOf: coords[(lo + 1)...hi])
                out[out.count - 1].length += length
            } else {
                out.append(RouteSegment(coordinates: Array(coords[lo...hi]), length: length, isShaded: isShaded))
            }
        }
        return out
    }

    /// Ids of cool spots within `coolSpotRadius` of the polyline, ordered by where the route passes them.
    func coolSpotIDs(near coords: [GeoCoordinate], cumulative: [Double]) -> [Int64] {
        guard !coolSpots.isEmpty, !coords.isEmpty else { return [] }
        let pts = network.projection.project(coords)
        guard let bounds = Geometry2D.bounds(pts) else { return [] }
        let r = Self.coolSpotRadius
        var found: [(along: Double, id: Int64)] = []
        var seen = Set<Int64>()
        for (i, spot) in coolSpots.enumerated() {
            let p = coolSpotPoints[i]
            guard p.x >= bounds.min.x - r, p.x <= bounds.max.x + r,
                  p.y >= bounds.min.y - r, p.y <= bounds.max.y + r else { continue }
            var best = pts[0].distance(to: p), bestAlong = 0.0
            if pts.count >= 2 {
                for j in 0..<(pts.count - 1) {
                    let a = pts[j], b = pts[j + 1]
                    if p.x < min(a.x, b.x) - r || p.x > max(a.x, b.x) + r ||
                        p.y < min(a.y, b.y) - r || p.y > max(a.y, b.y) + r { continue }
                    let (t, q) = Geometry2D.closestPointOnSegment(p, a, b)
                    let d = q.distance(to: p)
                    if d < best {
                        best = d
                        bestAlong = cumulative[j] + (cumulative[j + 1] - cumulative[j]) * t
                    }
                }
            }
            if best <= r, seen.insert(spot.id).inserted { found.append((bestAlong, spot.id)) }
        }
        return found.sorted { $0.along != $1.along ? $0.along < $1.along : $0.id < $1.id }.map(\.id)
    }

    /// FNV-1a over the traversed base edge ids and directions, as 16 hex digits.
    static func routeHash(_ legs: [Leg]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for leg in legs where !leg.isAccess {
            let v = (UInt64(bitPattern: Int64(leg.parent)) << 1) | (leg.forward ? 0 : 1)
            for byte in 0..<8 {
                h ^= (v >> UInt64(8 * byte)) & 0xff
                h = h &* 0x0000_0100_0000_01b3
            }
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
