import Foundation

/// Builds the pedestrian `WalkGraph` from Overpass elements. See SPEC §4.4.
///
/// Ways are split at nodes used more than once (shared by ≥ 2 walkable ways, or self-intersections) and at way
/// endpoints; `nil` geometry entries split a way into separate pieces. Edges shorter than `minimumEdgeLength` are
/// contracted (their endpoints merged) so connectivity survives. Loops are split at a middle shape point, so no
/// edge starts and ends at the same node. Only the largest connected component is kept and ids are renumbered
/// densely. The result depends only on the set of elements, not on their order.
public enum WalkGraphBuilder {
    /// Edges shorter than this (metres) are contracted away.
    public static let minimumEdgeLength = 0.5

    /// `highway=` values that are walkable (subject to `isWalkable`'s access rules).
    public static let walkableHighwayValues: [String] = [
        "footway", "pedestrian", "path", "steps", "living_street", "residential", "service", "unclassified",
        "track", "cycleway", "bridleway", "corridor", "tertiary", "tertiary_link", "secondary", "secondary_link",
        "primary", "primary_link",
    ]

    /// `highway=` values walkable only with `foot=yes|designated`.
    public static let footRestrictedHighwayValues: [String] = ["motorway", "motorway_link", "trunk", "trunk_link"]

    private static let walkableSet = Set(walkableHighwayValues)
    private static let footRestrictedSet = Set(footRestrictedHighwayValues)
    private static let footAllowedValues: Set<String> = ["yes", "designated", "permissive"]
    private static let footForbiddenValues: Set<String> = ["no", "private", "use_sidepath"]
    private static let coveredValues: Set<String> = ["yes", "arcade", "colonnade", "roof", "booth"]
    private static let pedestrianClasses: Set<WayClass> = [
        .footway, .sidewalk, .crossing, .steps, .pedestrian, .path, .cycleway, .corridor,
    ]

    // MARK: Tag rules

    /// Walkability per SPEC §4.4: walkable `highway` values; motorway/trunk only with `foot=yes|designated`;
    /// bridleway only with `foot=yes|designated|permissive`; never with `foot=no|private|use_sidepath`;
    /// `access=private|no` only with `foot=yes|designated|permissive`; `area=yes` skipped (v1).
    public static func isWalkable(_ tags: [String: String]) -> Bool {
        guard let highway = tags["highway"], tags["area"] != "yes" else { return false }
        let foot = tags["foot"]
        if let foot, footForbiddenValues.contains(foot) { return false }
        let footAllowed = foot.map { footAllowedValues.contains($0) } ?? false
        if footRestrictedSet.contains(highway) {
            guard foot == "yes" || foot == "designated" else { return false }
        } else if highway == "bridleway" {
            guard footAllowed else { return false }
        } else if !walkableSet.contains(highway) {
            return false
        }
        if let access = tags["access"], access == "private" || access == "no", !footAllowed { return false }
        return true
    }

    /// Pedestrian classification of a highway way.
    public static func wayClass(for tags: [String: String]) -> WayClass {
        guard let highway = tags["highway"] else { return .other }
        switch highway {
        case "footway", "path", "cycleway", "bridleway":
            if tags["footway"] == "crossing" || tags["path"] == "crossing" || tags["cycleway"] == "crossing" {
                return .crossing
            }
            if let crossing = tags["crossing"], crossing != "no" { return .crossing }
            if tags["footway"] == "sidewalk" || tags["path"] == "sidewalk" { return .sidewalk }
            switch highway {
            case "footway": return .footway
            case "cycleway": return .cycleway
            default: return .path
            }
        case "steps": return .steps
        case "pedestrian": return .pedestrian
        case "living_street": return .livingStreet
        case "residential": return .residential
        case "service": return .service
        case "track": return .track
        case "unclassified", "tertiary", "tertiary_link": return .minorRoad
        case "secondary", "secondary_link", "primary", "primary_link": return .majorRoad
        case "motorway", "motorway_link", "trunk", "trunk_link": return .majorRoad
        case "corridor": return .corridor
        default: return .other
        }
    }

    /// Covered: `covered=yes|arcade|colonnade|roof|booth`, any `tunnel` (incl. `building_passage`), any `indoor`
    /// other than `no`, and indoor corridors.
    public static func isCovered(_ tags: [String: String]) -> Bool {
        if let covered = tags["covered"], coveredValues.contains(covered) { return true }
        if let tunnel = tags["tunnel"], tunnel != "no" { return true }
        if let indoor = tags["indoor"], indoor != "no" { return true }
        return tags["highway"] == "corridor"
    }

    /// Pedestrian underpass: a tunnel (other than `building_passage`) on a footway-like way, or any tunnel with
    /// `layer < 0`.
    public static func isUnderpass(_ tags: [String: String]) -> Bool {
        guard let tunnel = tags["tunnel"], tunnel != "no" else { return false }
        if let layer = OSMValueParser.number(tags["layer"]), layer < 0 { return true }
        return tunnel != "building_passage" && pedestrianClasses.contains(wayClass(for: tags))
    }

    /// Bridge: any `bridge` value other than `no`.
    public static func isBridge(_ tags: [String: String]) -> Bool {
        guard let bridge = tags["bridge"] else { return false }
        return bridge != "no"
    }

    /// Crossing flags of a node: crossing if `highway=crossing` or `crossing=*` (not `no`); signals if
    /// `highway=traffic_signals`, `crossing=traffic_signals` or `crossing:signals=yes`.
    public static func nodeFlags(_ tags: [String: String]) -> (isCrossing: Bool, hasTrafficSignals: Bool) {
        let crossing = tags["crossing"]
        let isCrossing = crossing != "no" && (tags["highway"] == "crossing" || crossing != nil)
        let signals = tags["highway"] == "traffic_signals" || crossing == "traffic_signals"
            || tags["crossing:signals"] == "yes"
        return (isCrossing, signals)
    }

    // MARK: Build

    /// Builds the graph from all elements of a response: walkable ways (need `nodes` and either aligned
    /// `geometry` or node positions) plus tagged nodes (crossings, signals).
    public static func build(from elements: [OSMElement]) -> WalkGraph {
        var nodeCoordinates: [Int64: GeoCoordinate] = [:]
        var nodeTags: [Int64: [String: String]] = [:]
        for e in elements where e.type == .node {
            if let c = e.coordinate { nodeCoordinates[e.id] = c }
            if !e.tags.isEmpty { nodeTags[e.id] = e.tags }
        }
        let ways = OSMElement.merged(elements.filter { $0.type == .way && isWalkable($0.tags) })
        let runs = makeRuns(ways: ways, nodeCoordinates: nodeCoordinates)
        let attributes = ways.map(WayAttributes.init)

        // Vertices: nodes referenced more than once overall, plus run endpoints.
        var occurrences: [Int64: Int] = [:]
        for run in runs {
            for id in run.ids { occurrences[id, default: 0] += 1 }
        }

        var draft = Draft()
        for run in runs {
            let last = run.ids.count - 1
            var cuts = run.ids.indices.filter { $0 == 0 || $0 == last || occurrences[run.ids[$0], default: 0] > 1 }
            // A closed way joined to the network at one node only: split it in the middle to avoid a self-loop.
            if cuts.count == 2, run.ids.count >= 3, run.ids[0] == run.ids[last] {
                cuts.insert(run.ids.count / 2, at: 1)
            }
            for k in 1..<cuts.count {
                let a = cuts[k - 1], b = cuts[k]
                let from = draft.node(run.ids[a], run.coordinates[a], nodeTags)
                let to = draft.node(run.ids[b], run.coordinates[b], nodeTags)
                let geometry = Array(run.coordinates[a...b])
                draft.edges.append(DraftEdge(from: from, to: to, geometry: geometry,
                                             length: GeoMath.length(of: geometry), way: run.way,
                                             ids: Array(run.ids[a...b])))
            }
        }
        return draft.finish(attributes: attributes, ways: ways, nodeTags: nodeTags)
    }

    // MARK: - Internals

    /// Consecutive known vertices of one walkable way.
    private struct Run {
        let way: Int
        var ids: [Int64] = []
        var coordinates: [GeoCoordinate] = []
    }

    private static func makeRuns(ways: [OSMElement], nodeCoordinates: [Int64: GeoCoordinate]) -> [Run] {
        var runs: [Run] = []
        for (index, way) in ways.enumerated() {
            guard let ids = way.nodes, ids.count >= 2,
                  let geometry = MultipolygonAssembler.coordinates(ofWay: way, nodeCoordinates: nodeCoordinates),
                  geometry.count == ids.count else { continue }
            var run = Run(way: index)
            func flush() {
                if run.ids.count >= 2 { runs.append(run) }
                run = Run(way: index)
            }
            for (id, coordinate) in zip(ids, geometry) {
                guard let coordinate, coordinate.isValid else {
                    flush()
                    continue
                }
                if run.ids.last == id { continue }
                run.ids.append(id)
                run.coordinates.append(coordinate)
            }
            flush()
        }
        return runs
    }

    private struct WayAttributes {
        let wayClass: WayClass
        let name: String?
        let isCovered: Bool
        let isUnderpass: Bool
        let isBridge: Bool

        init(_ way: OSMElement) {
            let tags = way.tags
            wayClass = WalkGraphBuilder.wayClass(for: tags)
            name = [tags["name"], tags["name:en"]].lazy.compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            isCovered = WalkGraphBuilder.isCovered(tags)
            isUnderpass = WalkGraphBuilder.isUnderpass(tags)
            isBridge = WalkGraphBuilder.isBridge(tags)
        }
    }

    private struct DraftNode {
        var osmID: Int64
        var coordinate: GeoCoordinate
        var isCrossing: Bool
        var hasTrafficSignals: Bool
    }

    private struct DraftEdge {
        var from: Int
        var to: Int
        var geometry: [GeoCoordinate]
        var length: Double
        var way: Int
        /// OSM node ids aligned with `geometry`.
        var ids: [Int64]
    }

    private struct Draft {
        var nodes: [DraftNode] = []
        var edges: [DraftEdge] = []
        var index: [Int64: Int] = [:]

        mutating func node(_ id: Int64, _ coordinate: GeoCoordinate, _ tags: [Int64: [String: String]]) -> Int {
            if let i = index[id] { return i }
            let flags = WalkGraphBuilder.nodeFlags(tags[id] ?? [:])
            index[id] = nodes.count
            nodes.append(DraftNode(osmID: id, coordinate: coordinate, isCrossing: flags.isCrossing,
                                   hasTrafficSignals: flags.hasTrafficSignals))
            return nodes.count - 1
        }

        /// Contracts short edges, keeps the largest component and renumbers densely.
        func finish(attributes: [WayAttributes], ways: [OSMElement], nodeTags: [Int64: [String: String]]) -> WalkGraph {
            var nodes = self.nodes
            // 1. Contract edges shorter than the minimum (representative = lowest index). Repeat until stable,
            //    since snapping an edge onto merged endpoints can shorten it below the minimum too.
            var merge = UnionFind(count: nodes.count)
            var changed = true
            while changed {
                changed = false
                for e in edges {
                    let from = merge.find(e.from), to = merge.find(e.to)
                    guard from != to,
                          Self.snapped(e, nodes[from].coordinate, nodes[to].coordinate).length
                            < WalkGraphBuilder.minimumEdgeLength else { continue }
                    merge.union(from, to)
                    if attributes[e.way].wayClass == .crossing { nodes[from].isCrossing = true }
                    changed = true
                }
            }
            for i in nodes.indices {
                let r = merge.find(i)
                guard r != i else { continue }
                nodes[r].isCrossing = nodes[r].isCrossing || nodes[i].isCrossing
                nodes[r].hasTrafficSignals = nodes[r].hasTrafficSignals || nodes[i].hasTrafficSignals
            }
            var kept: [DraftEdge] = []
            kept.reserveCapacity(edges.count)
            for original in edges {
                let from = merge.find(original.from), to = merge.find(original.to)
                // Geometry ends sit exactly on the (possibly merged) node positions.
                var e = Self.snapped(original, nodes[from].coordinate, nodes[to].coordinate)
                e.from = from
                e.to = to
                guard from == to else {
                    kept.append(e)
                    continue
                }
                // Both ends were merged into one node: split the loop at its middle shape point. Shape points
                // are used by this edge only, so the new node's OSM id is unique. Tiny loops are dropped.
                let mid = e.geometry.count / 2
                guard mid > 0, mid < e.geometry.count - 1 else { continue }
                let head = Array(e.geometry[...mid]), tail = Array(e.geometry[mid...])
                let headLength = GeoMath.length(of: head), tailLength = GeoMath.length(of: tail)
                guard min(headLength, tailLength) >= WalkGraphBuilder.minimumEdgeLength else { continue }
                let flags = WalkGraphBuilder.nodeFlags(nodeTags[e.ids[mid]] ?? [:])
                nodes.append(DraftNode(osmID: e.ids[mid], coordinate: e.geometry[mid], isCrossing: flags.isCrossing,
                                       hasTrafficSignals: flags.hasTrafficSignals))
                kept.append(DraftEdge(from: from, to: nodes.count - 1, geometry: head, length: headLength,
                                      way: e.way, ids: Array(e.ids[...mid])))
                kept.append(DraftEdge(from: nodes.count - 1, to: to, geometry: tail, length: tailLength,
                                      way: e.way, ids: Array(e.ids[mid...])))
            }
            guard !kept.isEmpty else { return .empty }

            // 2. Largest connected component: most nodes, then longest total length, then lowest node index.
            var components = UnionFind(count: nodes.count)
            for e in kept { components.union(e.from, e.to) }
            var nodeCount: [Int: Int] = [:]
            var totalLength: [Int: Double] = [:]
            var hasEdge = Array(repeating: false, count: nodes.count)
            for e in kept {
                hasEdge[e.from] = true
                hasEdge[e.to] = true
                totalLength[components.find(e.from), default: 0] += e.length
            }
            for i in nodes.indices where hasEdge[i] { nodeCount[components.find(i), default: 0] += 1 }
            var best: Int?
            for root in nodeCount.keys {
                guard let current = best else { best = root; continue }
                let lhs = (nodeCount[root, default: 0], totalLength[root, default: 0])
                let rhs = (nodeCount[current, default: 0], totalLength[current, default: 0])
                if lhs.0 > rhs.0 || (lhs.0 == rhs.0 && (lhs.1 > rhs.1 || (lhs.1 == rhs.1 && root < current))) {
                    best = root
                }
            }
            guard let bestRoot = best else { return .empty }

            // 3. Dense renumbering in creation order.
            var newIndex = Array(repeating: -1, count: nodes.count)
            var graphNodes: [GraphNode] = []
            for i in nodes.indices where hasEdge[i] && components.find(i) == bestRoot {
                newIndex[i] = graphNodes.count
                let n = nodes[i]
                graphNodes.append(GraphNode(id: graphNodes.count, osmID: n.osmID, coordinate: n.coordinate,
                                            isCrossing: n.isCrossing, hasTrafficSignals: n.hasTrafficSignals))
            }
            var graphEdges: [GraphEdge] = []
            for e in kept where newIndex[e.from] >= 0 {
                let attr = attributes[e.way]
                graphEdges.append(GraphEdge(id: graphEdges.count, from: newIndex[e.from], to: newIndex[e.to],
                                            geometry: e.geometry, length: e.length, wayClass: attr.wayClass,
                                            name: attr.name, wayID: ways[e.way].id, isCovered: attr.isCovered,
                                            isUnderpass: attr.isUnderpass, isBridge: attr.isBridge,
                                            isCrossing: attr.wayClass == .crossing))
            }
            return WalkGraph(nodes: graphNodes, edges: graphEdges)
        }

        /// `e` with its geometry ends moved to `a` / `b` and its length updated.
        private static func snapped(_ e: DraftEdge, _ a: GeoCoordinate, _ b: GeoCoordinate) -> DraftEdge {
            let last = e.geometry.count - 1
            guard e.geometry[0] != a || e.geometry[last] != b else { return e }
            var out = e
            out.geometry[0] = a
            out.geometry[last] = b
            out.length = GeoMath.length(of: out.geometry)
            return out
        }
    }

    /// Disjoint sets whose representative is always the lowest member index.
    private struct UnionFind {
        private var parent: [Int]

        init(count: Int) { parent = Array(0..<count) }

        mutating func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
    }
}
