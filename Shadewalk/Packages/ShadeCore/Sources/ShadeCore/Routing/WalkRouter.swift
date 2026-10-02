import Foundation

/// Shade-aware A* router over a `WalkGraph`. See SPEC §4.5.
///
/// Immutable after init (the snapping index and adjacency are built once); every query works on its own
/// overlay, so one router can serve concurrent requests.
public final class WalkRouter: @unchecked Sendable {
    /// Splits a route polyline into consecutive shaded / sunny runs (normally `ShadeEngine.shadeRuns`).
    public typealias ShadeRunsProvider = @Sendable (_ polyline: [GeoCoordinate], _ sun: SunPosition) -> [RouteSegment]

    /// Max distance from origin / destination to the walk network, metres.
    public static let maxSnapDistance = 250.0
    /// Straight access legs to / from the network are only added when longer than this, metres.
    public static let minAccessLegLength = 1.0
    /// Sun penalties `k` tried for the shadiest route.
    public static let shadiestSunPenalties: [Double] = [0.5, 1, 2, 4, 8, 16]
    /// Sun penalty `k` of the balanced route.
    public static let balancedSunPenalty = 1.0
    /// A snap closer than this (along the edge) to an edge end uses that node instead of a virtual node, metres.
    static let nodeSnapTolerance = 0.5

    private let network: RoutingNetwork
    private let assembler: RouteAssembler

    /// - Parameters:
    ///   - edgeShade: shade fraction per edge id (`count == graph.edges.count`).
    ///   - shadeEngine: used to split the final geometry into shaded/sunny runs; if nil, each edge is coloured by
    ///     its majority shade.
    ///   - coolSpots: used to fill `WalkRoute.coolSpotIDs` (within 40 m of the route).
    public init(graph: WalkGraph, edgeShade: [Double], shadeEngine: ShadeEngine?, coolSpots: [CoolSpot] = []) {
        let runs: ShadeRunsProvider? = shadeEngine.map { engine in
            { @Sendable polyline, sun in engine.shadeRuns(along: polyline, sun: sun) }
        }
        network = RoutingNetwork(graph: graph, edgeShade: edgeShade)
        assembler = RouteAssembler(network: network, shadeRuns: runs, coolSpots: coolSpots)
    }

    /// Like `init(graph:edgeShade:shadeEngine:coolSpots:)`, with the shade-run computation supplied directly.
    /// - Parameter shadeRuns: splits the final route polyline into shaded/sunny runs; if nil (or it returns no
    ///   runs), each edge is coloured by its majority `edgeShade` and access legs count as sunny.
    public init(graph: WalkGraph, edgeShade: [Double], coolSpots: [CoolSpot] = [], shadeRuns: ShadeRunsProvider?) {
        network = RoutingNetwork(graph: graph, edgeShade: edgeShade)
        assembler = RouteAssembler(network: network, shadeRuns: shadeRuns, coolSpots: coolSpots)
    }

    /// Single route for `profile` (`.shadiest` uses the detour-capped search; `.balanced` falls back to the
    /// fastest route when the k = 1 route exceeds the detour cap).
    /// - Throws: `ShadeError.originTooFarFromNetwork`, `.destinationTooFarFromNetwork`, `.noRouteFound`,
    ///   `.noWalkableNetwork` (graph without edges).
    public func route(from origin: GeoCoordinate, to destination: GeoCoordinate, profile: RouteProfile,
                      preferences: RoutingPreferences, sun: SunPosition, departure: Date) throws -> WalkRoute {
        let session = try Session(network: network, origin: origin, destination: destination, preferences: preferences)
        let candidate: Candidate
        switch profile {
        case .fastest: candidate = try session.fastest()
        case .balanced: candidate = try session.balanced() ?? session.fastest()
        case .shadiest: candidate = try session.shadiest()
        }
        return assembler.assemble(legs: candidate.legs, profile: profile, profiles: [profile],
                                  preferences: preferences, sun: sun, departure: departure)
    }

    /// Deduplicated alternatives ordered shadiest → balanced → fastest.
    ///
    /// Routes with the same edge sequence are merged into one whose `profiles` lists every profile it satisfies
    /// and whose `profile` is the first of shadiest > balanced > fastest. Balanced is only offered when the k = 1
    /// route is within the detour cap.
    public func alternatives(from origin: GeoCoordinate, to destination: GeoCoordinate,
                             preferences: RoutingPreferences, sun: SunPosition, departure: Date) throws -> [WalkRoute] {
        let session = try Session(network: network, origin: origin, destination: destination, preferences: preferences)
        var groups: [(candidate: Candidate, profiles: [RouteProfile])] = []
        func add(_ c: Candidate, _ p: RouteProfile) {
            if let i = groups.firstIndex(where: { $0.candidate.edgeKey == c.edgeKey }) {
                groups[i].profiles.append(p)
            } else {
                groups.append((c, [p]))
            }
        }
        add(try session.shadiest(), .shadiest)
        if let balanced = try session.balanced() { add(balanced, .balanced) }
        add(try session.fastest(), .fastest)
        return groups.map { group in
            assembler.assemble(legs: group.candidate.legs, profile: group.profiles[0], profiles: group.profiles,
                               preferences: preferences, sun: sun, departure: departure)
        }
    }

    // MARK: - Query session

    /// One A* result with the metrics used to pick profiles.
    fileprivate struct Candidate {
        var sunPenalty: Double
        /// Query-graph edge ids, the identity used for de-duplication.
        var edgeKey: [Int]
        var legs: [RouteAssembler.Leg]
        /// Route length including access legs, metres.
        var distance: Double
        /// Sun-exposed metres on the network (`Σ length × (1 − shade)`).
        var sunnyMeters: Double
    }

    /// Snapped origin/destination plus cached searches for one request.
    fileprivate final class Session {
        let network: RoutingNetwork
        let preferences: RoutingPreferences
        private let query: QueryGraph
        private let start: Int
        private let goal: Int
        private let originLeg: [GeoCoordinate]?
        private let destinationLeg: [GeoCoordinate]?
        private var cache: [Double: Candidate] = [:]

        init(network: RoutingNetwork, origin: GeoCoordinate, destination: GeoCoordinate,
             preferences: RoutingPreferences) throws {
            self.network = network
            self.preferences = preferences
            guard network.edgeCount > 0 else { throw ShadeError.noWalkableNetwork }
            guard origin.isValid, let o = Self.snap(origin, in: network) else { throw ShadeError.originTooFarFromNetwork }
            guard destination.isValid, let d = Self.snap(destination, in: network) else {
                throw ShadeError.destinationTooFarFromNetwork
            }

            var q = QueryGraph(net: network)
            let s: Int, g: Int
            switch (o, d) {
            case let (.node(a), .node(b)):
                (s, g) = (a, b)
            case let (.node(a), .position(p)):
                (s, g) = (a, q.split(edge: p.edge, at: [p])[0])
            case let (.position(p), .node(b)):
                (s, g) = (q.split(edge: p.edge, at: [p])[0], b)
            case let (.position(p), .position(r)) where p.edge != r.edge:
                s = q.split(edge: p.edge, at: [p])[0]
                g = q.split(edge: r.edge, at: [r])[0]
            case let (.position(p), .position(r)):
                if abs(p.along - r.along) <= WalkRouter.nodeSnapTolerance {
                    s = q.split(edge: p.edge, at: [p])[0]
                    g = s
                } else if p.along < r.along {
                    let ids = q.split(edge: p.edge, at: [p, r])
                    (s, g) = (ids[0], ids[1])
                } else {
                    let ids = q.split(edge: p.edge, at: [r, p])
                    (s, g) = (ids[1], ids[0])
                }
            }
            query = q
            start = s
            goal = g
            originLeg = Self.accessLeg(from: origin, to: q.coordinate(of: s))
            destinationLeg = Self.accessLeg(from: q.coordinate(of: g), to: destination)
        }

        private enum Snap {
            case node(Int)
            case position(EdgePosition)
        }

        private static func snap(_ c: GeoCoordinate, in network: RoutingNetwork) -> Snap? {
            let p = network.projection.project(c)
            guard let hit = network.index.nearest(to: p, within: WalkRouter.maxSnapDistance) else { return nil }
            let along = network.index.distanceAlong(edge: hit.edge, segment: hit.segment, fraction: hit.fraction)
            let length = network.index.projectedLength(of: hit.edge)
            if along <= WalkRouter.nodeSnapTolerance { return .node(network.edgeFrom[hit.edge]) }
            if length - along <= WalkRouter.nodeSnapTolerance { return .node(network.edgeTo[hit.edge]) }
            return .position(EdgePosition(edge: hit.edge, segment: hit.segment, fraction: hit.fraction, along: along,
                                          point: hit.point, coordinate: network.projection.unproject(hit.point)))
        }

        private static func accessLeg(from a: GeoCoordinate, to b: GeoCoordinate) -> [GeoCoordinate]? {
            GeoMath.distance(a, b) > WalkRouter.minAccessLegLength ? [a, b] : nil
        }

        /// Longest acceptable route for the shadiest / balanced profiles.
        private func detourCap() throws -> Double {
            let f = preferences.maxDetourFraction
            let fraction = f.isFinite ? max(0, f) : 0
            return try fastest().distance * (1 + fraction) + 1e-6
        }

        func candidate(sunPenalty k: Double) throws -> Candidate {
            if let c = cache[k] { return c }
            let cost = AStar.CostModel(sunPenalty: k, avoidStairs: preferences.avoidStairs)
            guard let steps = AStar.shortestPath(in: query, from: start, to: goal, cost: cost) else {
                throw ShadeError.noRouteFound
            }
            let legs = RouteAssembler.legs(for: steps, from: start, in: query, originLeg: originLeg,
                                           destinationLeg: destinationLeg)
            var distance = 0.0, sunny = 0.0
            for leg in legs {
                let len = GeoMath.length(of: leg.geometry)
                distance += len
                if !leg.isAccess { sunny += len * leg.sunny }
            }
            let c = Candidate(sunPenalty: k, edgeKey: steps.map(\.edge), legs: legs, distance: distance, sunnyMeters: sunny)
            cache[k] = c
            return c
        }

        func fastest() throws -> Candidate { try candidate(sunPenalty: 0) }

        /// The k = 1 route, or nil when it exceeds the detour cap.
        func balanced() throws -> Candidate? {
            let c = try candidate(sunPenalty: WalkRouter.balancedSunPenalty)
            return c.distance <= (try detourCap()) ? c : nil
        }

        /// Fewest sunny metres among the fastest route and the capped k-routes (ties: shorter, then lower k).
        func shadiest() throws -> Candidate {
            let cap = try detourCap()
            var best = try fastest()
            for k in WalkRouter.shadiestSunPenalties {
                let c = try candidate(sunPenalty: k)
                guard c.distance <= cap else { continue }
                let fewerSunny = c.sunnyMeters < best.sunnyMeters - 1e-6
                let tieButShorter = abs(c.sunnyMeters - best.sunnyMeters) <= 1e-6 && c.distance < best.distance - 1e-6
                if fewerSunny || tieButShorter { best = c }
            }
            return best
        }
    }
}
