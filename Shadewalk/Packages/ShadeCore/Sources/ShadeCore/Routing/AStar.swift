import Foundation

/// Binary min-heap of `(key, node)` used as the A* open set (lazy deletion: stale entries are skipped on pop).
/// Equal keys pop in ascending node order so searches are deterministic.
struct NodeHeap {
    private struct Entry {
        var key: Double
        var node: Int
    }

    private var entries: [Entry] = []

    init(capacity: Int = 0) { entries.reserveCapacity(capacity) }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    private static func less(_ a: Entry, _ b: Entry) -> Bool {
        a.key < b.key || (a.key == b.key && a.node < b.node)
    }

    mutating func push(_ key: Double, _ node: Int) {
        entries.append(Entry(key: key, node: node))
        var i = entries.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard Self.less(entries[i], entries[parent]) else { break }
            entries.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (key: Double, node: Int)? {
        guard let top = entries.first else { return nil }
        let last = entries.removeLast()
        if !entries.isEmpty {
            entries[0] = last
            var i = 0
            let n = entries.count
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < n && Self.less(entries[l], entries[m]) { m = l }
                if r < n && Self.less(entries[r], entries[m]) { m = r }
                if m == i { break }
                entries.swapAt(i, m)
                i = m
            }
        }
        return (top.key, top.node)
    }
}

/// A* over a `QueryGraph` with the SPEC §4.5 cost model.
enum AStar {
    /// One traversed edge (query-graph ids).
    struct Step: Hashable, Sendable {
        var edge: Int
        var from: Int
        var to: Int
    }

    /// Edge cost: `(length × classFactor + 12 m per crossing node entered) × (shade + (1 − shade) × (1 + k))`.
    /// Steps use `stairsFactor` in place of the class factor. All factors are ≥ 1, so the straight-line
    /// heuristic stays admissible.
    struct CostModel: Hashable, Sendable {
        /// Sun penalty `k` (0 = fastest).
        var sunPenalty: Double
        /// 1.4, or 6 when avoiding stairs.
        var stairsFactor: Double

        init(sunPenalty: Double, avoidStairs: Bool) {
            self.sunPenalty = max(0, sunPenalty)
            self.stairsFactor = avoidStairs ? 6 : 1.4
        }
    }

    /// Cheapest path from `start` to `goal`, or nil if unreachable. Empty when `start == goal`.
    static func shortestPath(in q: QueryGraph, from start: Int, to goal: Int, cost: CostModel) -> [Step]? {
        guard start != goal else { return [] }
        let net = q.net
        let baseNodes = net.nodeCount, baseEdges = net.edgeCount
        let total = q.nodeCount
        guard start >= 0, start < total, goal >= 0, goal < total else { return nil }

        let adjStart = net.adjacencyStart, adjEdge = net.adjacencyEdge
        let edgeFrom = net.edgeFrom, edgeTo = net.edgeTo, edgeLength = net.edgeLength
        let edgeSunny = net.edgeSunny, classFactor = net.edgeClassFactor, isSteps = net.edgeIsSteps
        let nodeIsCrossing = net.nodeIsCrossing, nodePoints = net.nodePoints
        let virtualEdges = q.virtualEdges, virtualPoints = q.virtualPoints, extraLinks = q.extraLinks
        let disabledA = q.disabledA, disabledB = q.disabledB
        let k = cost.sunPenalty, stairsFactor = cost.stairsFactor
        let hScale = net.heuristicScale
        let goalPoint = q.point(of: goal)

        @inline(__always) func h(_ v: Int) -> Double {
            let p = v < baseNodes ? nodePoints[v] : virtualPoints[v - baseNodes]
            return hScale * p.distance(to: goalPoint)
        }

        var g = [Double](repeating: .infinity, count: total)
        var via = [Int](repeating: -1, count: total)
        var closed = [Bool](repeating: false, count: total)
        var heap = NodeHeap(capacity: 1024)
        g[start] = 0
        heap.push(h(start), start)

        @inline(__always) func relax(_ u: Int, _ gu: Double, _ e: Int, _ v: Int) {
            guard v != u, !closed[v] else { return }
            let parent: Int, len: Double
            if e < baseEdges {
                parent = e; len = edgeLength[e]
            } else {
                parent = virtualEdges[e - baseEdges].parent; len = virtualEdges[e - baseEdges].length
            }
            let mult = isSteps[parent] ? stairsFactor : classFactor[parent]
            let crossing = v < baseNodes && nodeIsCrossing[v] ? RoutingNetwork.crossingPenalty : 0
            let c = gu + (len * mult + crossing) * (1 + k * edgeSunny[parent])
            if c < g[v] {
                g[v] = c
                via[v] = e
                heap.push(c + h(v), v)
            }
        }

        while let (_, u) = heap.pop() {
            if closed[u] { continue }
            closed[u] = true
            if u == goal { break }
            let gu = g[u]
            if u < baseNodes {
                for i in adjStart[u]..<adjStart[u + 1] {
                    let e = adjEdge[i]
                    if e == disabledA || e == disabledB { continue }
                    relax(u, gu, e, edgeFrom[e] == u ? edgeTo[e] : edgeFrom[e])
                }
            }
            for link in extraLinks where link.node == u {
                let ve = virtualEdges[link.edge - baseEdges]
                relax(u, gu, link.edge, ve.from == u ? ve.to : ve.from)
            }
        }

        guard g[goal].isFinite else { return nil }
        var steps: [Step] = []
        var v = goal
        while v != start {
            let e = via[v]
            guard e >= 0, steps.count <= total else { return nil }
            let (a, b) = q.endpoints(of: e)
            let u = a == v ? b : a
            steps.append(Step(edge: e, from: u, to: v))
            v = u
        }
        return steps.reversed()
    }
}
