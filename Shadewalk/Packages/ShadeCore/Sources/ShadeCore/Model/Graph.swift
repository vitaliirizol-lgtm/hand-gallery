import Foundation

/// Pedestrian-relevant classification of an OSM way.
public enum WayClass: String, Codable, Sendable, Hashable, CaseIterable {
    case footway, sidewalk, pedestrian, path, steps, crossing
    case livingStreet, residential, service, track, cycleway
    /// unclassified / tertiary (+ links)
    case minorRoad
    /// secondary / primary (+ links)
    case majorRoad
    case corridor
    case other
}

public struct GraphNode: Hashable, Codable, Sendable, Identifiable {
    /// Dense index into `WalkGraph.nodes`.
    public var id: Int
    public var osmID: Int64
    public var coordinate: GeoCoordinate
    /// Node is a pedestrian crossing (`highway=crossing`, `crossing=*`).
    public var isCrossing: Bool
    /// Crossing controlled by traffic signals.
    public var hasTrafficSignals: Bool

    public init(id: Int, osmID: Int64, coordinate: GeoCoordinate, isCrossing: Bool = false, hasTrafficSignals: Bool = false) {
        self.id = id
        self.osmID = osmID
        self.coordinate = coordinate
        self.isCrossing = isCrossing
        self.hasTrafficSignals = hasTrafficSignals
    }
}

/// Undirected edge between two graph nodes.
public struct GraphEdge: Hashable, Codable, Sendable, Identifiable {
    /// Dense index into `WalkGraph.edges`.
    public var id: Int
    public var from: Int
    public var to: Int
    /// Geometry from `nodes[from].coordinate` to `nodes[to].coordinate` inclusive (≥ 2 points).
    public var geometry: [GeoCoordinate]
    /// Metres.
    public var length: Double
    public var wayClass: WayClass
    public var name: String?
    public var wayID: Int64
    /// covered=yes/arcade/colonnade, tunnel=*, indoor=yes, building passage.
    public var isCovered: Bool
    /// Pedestrian underpass (tunnel on a footway, or layer < 0).
    public var isUnderpass: Bool
    public var isBridge: Bool
    /// footway=crossing / highway=crossing segment.
    public var isCrossing: Bool

    public var isSteps: Bool { wayClass == .steps }

    public init(id: Int, from: Int, to: Int, geometry: [GeoCoordinate], length: Double, wayClass: WayClass,
                name: String? = nil, wayID: Int64 = 0, isCovered: Bool = false, isUnderpass: Bool = false,
                isBridge: Bool = false, isCrossing: Bool = false) {
        self.id = id
        self.from = from
        self.to = to
        self.geometry = geometry
        self.length = length
        self.wayClass = wayClass
        self.name = name
        self.wayID = wayID
        self.isCovered = isCovered
        self.isUnderpass = isUnderpass
        self.isBridge = isBridge
        self.isCrossing = isCrossing
    }

    /// The node at the other end of the edge.
    public func other(_ node: Int) -> Int { node == from ? to : from }

    /// Geometry oriented to start at `node`.
    public func geometry(startingAt node: Int) -> [GeoCoordinate] {
        node == from ? geometry : geometry.reversed()
    }
}

/// Undirected pedestrian graph.
public struct WalkGraph: Sendable {
    public private(set) var nodes: [GraphNode]
    public private(set) var edges: [GraphEdge]
    /// Edge ids incident to each node.
    public private(set) var adjacency: [[Int]]

    public init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodes = nodes
        self.edges = edges
        var adj = Array(repeating: [Int](), count: nodes.count)
        for e in edges {
            adj[e.from].append(e.id)
            if e.to != e.from { adj[e.to].append(e.id) }
        }
        adjacency = adj
    }

    public static let empty = WalkGraph(nodes: [], edges: [])

    public var isEmpty: Bool { edges.isEmpty }

    /// `(edge, neighbour node)` pairs for `node`.
    public func neighbors(of node: Int) -> [(edge: GraphEdge, node: Int)] {
        adjacency[node].map { id in
            let e = edges[id]
            return (e, e.other(node))
        }
    }

    public var boundingBox: BoundingBox? { BoundingBox(coordinates: nodes.map(\.coordinate)) }
}
