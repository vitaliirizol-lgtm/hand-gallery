import Foundation

/// Immutable routing data derived once from a `WalkGraph` and its per-edge shade: CSR adjacency, projected nodes,
/// per-edge cost inputs and the snapping index.
struct RoutingNetwork: Sendable {
    /// Metres-equivalent added for entering a crossing node (SPEC §4.5).
    static let crossingPenalty = 12.0

    let graph: WalkGraph
    let projection: LocalProjection
    let nodePoints: [Point2D]
    let nodeIsCrossing: [Bool]
    /// Number of incident edges (≥ 3 = junction where the walker has a choice).
    let nodeDegree: [Int]
    /// Edge geometry, always ≥ 2 points, from `edgeFrom` to `edgeTo`.
    let geometries: [[GeoCoordinate]]
    let edgeFrom: [Int]
    let edgeTo: [Int]
    /// Cost length in metres: `edge.length`, or the projected geometry length when that is not a valid number.
    let edgeLength: [Double]
    /// Sun exposure `1 − shade`, clamped to `[0, 1]`.
    let edgeSunny: [Double]
    let edgeClassFactor: [Double]
    let edgeIsSteps: [Bool]
    /// CSR adjacency: edges incident to node `n` are `adjacencyEdge[adjacencyStart[n] ..< adjacencyStart[n + 1]]`.
    let adjacencyStart: [Int]
    let adjacencyEdge: [Int]
    /// Factor `≤ 1` on straight-line distance that keeps the A* heuristic admissible for this data
    /// (every edge costs at least `heuristicScale ×` its projected length).
    let heuristicScale: Double
    let index: EdgeSpatialIndex

    var nodeCount: Int { nodePoints.count }
    var edgeCount: Int { edgeFrom.count }

    init(graph: WalkGraph, edgeShade: [Double]) {
        self.graph = graph
        let nodes = graph.nodes
        let edges = graph.edges
        let proj = LocalProjection(origin: graph.boundingBox?.center ?? GeoCoordinate(latitude: 0, longitude: 0))
        projection = proj
        nodePoints = nodes.map { proj.project($0.coordinate) }
        nodeIsCrossing = nodes.map(\.isCrossing)

        var geoms: [[GeoCoordinate]] = []
        var projected: [[Point2D]] = []
        var from: [Int] = [], to: [Int] = []
        var length: [Double] = [], sunny: [Double] = [], factor: [Double] = [], steps: [Bool] = []
        geoms.reserveCapacity(edges.count); projected.reserveCapacity(edges.count)
        var degree = [Int](repeating: 0, count: nodes.count)
        var scale = 1.0
        for (i, e) in edges.enumerated() {
            let valid = nodes.indices.contains(e.from) && nodes.indices.contains(e.to)
            var g = e.geometry
            if g.count < 2 && valid { g = [nodes[e.from].coordinate, nodes[e.to].coordinate] }
            let pts = proj.project(g)
            var projLen = 0.0
            if pts.count >= 2 { for k in 1..<pts.count { projLen += pts[k - 1].distance(to: pts[k]) } }
            let len = e.length.isFinite && e.length >= 0 ? e.length : projLen
            if valid {
                let chord = nodePoints[e.from].distance(to: nodePoints[e.to])
                let reference = max(projLen, chord)
                if reference > 1e-9 && reference.isFinite { scale = min(scale, len / reference) }
                degree[e.from] += 1
                if e.to != e.from { degree[e.to] += 1 }
            }
            let rawShade = i < edgeShade.count ? edgeShade[i] : 0
            let shade = rawShade.isFinite ? max(0, min(1, rawShade)) : 0
            geoms.append(g)
            projected.append(valid ? pts : [])
            from.append(valid ? e.from : -1)
            to.append(valid ? e.to : -1)
            length.append(len)
            sunny.append(1 - shade)
            factor.append(Self.classFactor(e.wayClass))
            steps.append(e.isSteps)
        }
        geometries = geoms
        edgeFrom = from
        edgeTo = to
        edgeLength = length
        edgeSunny = sunny
        edgeClassFactor = factor
        edgeIsSteps = steps
        nodeDegree = degree
        heuristicScale = max(0, scale) * (1 - 1e-9)

        var start = [Int](repeating: 0, count: nodes.count + 1)
        for n in nodes.indices { start[n + 1] = start[n] + degree[n] }
        var fill = Array(start.dropLast())
        var adj = [Int](repeating: 0, count: start[nodes.count])
        for e in edges.indices where from[e] >= 0 {
            adj[fill[from[e]]] = e
            fill[from[e]] += 1
            if to[e] != from[e] {
                adj[fill[to[e]]] = e
                fill[to[e]] += 1
            }
        }
        adjacencyStart = start
        adjacencyEdge = adj
        index = EdgeSpatialIndex(geometries: projected)
    }

    /// Way-class cost multiplier (SPEC §4.5). Steps use the stairs factor instead (see `AStar.CostModel`).
    static func classFactor(_ c: WayClass) -> Double {
        switch c {
        case .footway, .sidewalk, .pedestrian, .path, .crossing, .corridor, .steps: 1.0
        case .livingStreet, .residential, .service, .track, .cycleway: 1.05
        case .minorRoad, .other: 1.1
        case .majorRoad: 1.2
        }
    }
}

/// A point strictly inside an edge, as found by snapping.
struct EdgePosition: Hashable, Sendable {
    var edge: Int
    var segment: Int
    var fraction: Double
    /// Projected metres from the edge start.
    var along: Double
    var point: Point2D
    var coordinate: GeoCoordinate
}

/// Per-query overlay on a `RoutingNetwork`: temporary virtual nodes at the snapped origin/destination, the
/// sub-edges that split their edges, and the split (disabled) parent edges. Virtual node ids follow the base
/// node ids; virtual edge ids follow the base edge ids.
struct QueryGraph {
    struct VirtualEdge {
        var from: Int
        var to: Int
        /// Runs from `from` to `to`, in the parent edge's direction.
        var geometry: [GeoCoordinate]
        var length: Double
        var parent: Int
    }

    let net: RoutingNetwork
    private(set) var virtualCoordinates: [GeoCoordinate] = []
    private(set) var virtualPoints: [Point2D] = []
    private(set) var virtualEdges: [VirtualEdge] = []
    /// Split parent edges (−1 = unused); a query splits at most two edges.
    private(set) var disabledA = -1
    private(set) var disabledB = -1
    /// Incidences `(node, edge)` of virtual edges.
    private(set) var extraLinks: [(node: Int, edge: Int)] = []

    init(net: RoutingNetwork) { self.net = net }

    var nodeCount: Int { net.nodeCount + virtualPoints.count }

    func point(of node: Int) -> Point2D {
        node < net.nodeCount ? net.nodePoints[node] : virtualPoints[node - net.nodeCount]
    }

    func coordinate(of node: Int) -> GeoCoordinate {
        node < net.nodeCount ? net.graph.nodes[node].coordinate : virtualCoordinates[node - net.nodeCount]
    }

    func endpoints(of edge: Int) -> (from: Int, to: Int) {
        if edge < net.edgeCount { return (net.edgeFrom[edge], net.edgeTo[edge]) }
        let v = virtualEdges[edge - net.edgeCount]
        return (v.from, v.to)
    }

    /// Base edge id an edge belongs to (itself for base edges).
    func parent(of edge: Int) -> Int {
        edge < net.edgeCount ? edge : virtualEdges[edge - net.edgeCount].parent
    }

    /// Geometry of `edge` oriented to start at `node`.
    func geometry(of edge: Int, from node: Int) -> [GeoCoordinate] {
        let (a, _) = endpoints(of: edge)
        let g = edge < net.edgeCount ? net.geometries[edge] : virtualEdges[edge - net.edgeCount].geometry
        return node == a ? g : g.reversed()
    }

    /// True when traversing `edge` from `node` follows the parent edge's geometry direction.
    func isForward(_ edge: Int, from node: Int) -> Bool { endpoints(of: edge).from == node }

    /// Splits `edge` at `positions` (sorted by `along`, distinct, strictly inside the edge) into a chain of
    /// virtual sub-edges and disables the original. Returns the new virtual node ids in position order.
    mutating func split(edge: Int, at positions: [EdgePosition]) -> [Int] {
        let geom = net.geometries[edge]
        let parentProjLen = net.index.projectedLength(of: edge)
        var ids: [Int] = []
        for p in positions {
            ids.append(nodeCount)
            virtualCoordinates.append(p.coordinate)
            virtualPoints.append(p.point)
        }

        struct Cut { var segment: Int; var fraction: Double; var coordinate: GeoCoordinate; var node: Int }
        var cuts = [Cut(segment: 0, fraction: 0, coordinate: geom[0], node: net.edgeFrom[edge])]
        for (p, id) in zip(positions, ids) {
            cuts.append(Cut(segment: p.segment, fraction: p.fraction, coordinate: p.coordinate, node: id))
        }
        cuts.append(Cut(segment: geom.count - 2, fraction: 1, coordinate: geom[geom.count - 1], node: net.edgeTo[edge]))

        for c in 1..<cuts.count {
            let a = cuts[c - 1], b = cuts[c]
            var g = [a.coordinate]
            if a.segment + 1 <= b.segment {
                for k in (a.segment + 1)...b.segment where !Self.nearlyEqual(g[g.count - 1], geom[k]) {
                    g.append(geom[k])
                }
            }
            if g.count > 1 && Self.nearlyEqual(g[g.count - 1], b.coordinate) {
                g[g.count - 1] = b.coordinate
            } else {
                g.append(b.coordinate)
            }
            let pts = net.projection.project(g)
            var subLen = 0.0
            for k in 1..<pts.count { subLen += pts[k - 1].distance(to: pts[k]) }
            let length = parentProjLen > 1e-9
                ? net.edgeLength[edge] * subLen / parentProjLen
                : net.edgeLength[edge] / Double(cuts.count - 1)
            let id = net.edgeCount + virtualEdges.count
            virtualEdges.append(VirtualEdge(from: a.node, to: b.node, geometry: g, length: length, parent: edge))
            extraLinks.append((a.node, id))
            if b.node != a.node { extraLinks.append((b.node, id)) }
        }
        if disabledA < 0 { disabledA = edge } else { disabledB = edge }
        return ids
    }

    /// Coordinates closer than ~0.1 mm.
    static func nearlyEqual(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Bool {
        abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }
}
