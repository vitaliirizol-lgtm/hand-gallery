import Foundation

/// Turns a routed path into turn-by-turn maneuvers (SPEC §4.5).
///
/// One maneuver at most per node, by priority: take stairs > enter underpass > cross street > turn.
/// Turn angles compare the bearings over ~10 m before and after the node: < 20° straight, < 45° slight,
/// < 135° turn, < 170° sharp, else U-turn. Straight-ahead is only announced when the street name changes,
/// and slight bends only at junctions (or on a name change). Nodes joining an access leg are covered by
/// depart / arrive.
enum ManeuverBuilder {
    /// One traversed piece of the route (a graph edge, or a straight access leg).
    struct Leg: Hashable, Sendable {
        /// Index of the leg's first coordinate in the route polyline.
        var startIndex: Int
        var name: String?
        var isAccess: Bool = false
        var isSteps: Bool = false
        var isUnderpass: Bool = false
        var isCrossingEdge: Bool = false
        /// The node at the start of this leg is a crossing node.
        var startsAtCrossingNode: Bool = false
        /// The node at the start of this leg is a junction (≥ 3 incident edges).
        var startsAtJunction: Bool = false
    }

    /// Distance over which in/out bearings are measured, metres.
    static let bearingWindow = 10.0
    /// Below this many metres of polyline on either side of a node, no turn angle is computed.
    static let minBearingSpan = 0.5

    /// - Parameters:
    ///   - coordinates: the route polyline.
    ///   - cumulative: `GeoMath.cumulativeDistances(of: coordinates)`.
    ///   - legs: in route order, `startIndex` non-decreasing.
    static func build(coordinates: [GeoCoordinate], cumulative: [Double], legs: [Leg]) -> [Maneuver] {
        guard let first = coordinates.first, let last = coordinates.last,
              cumulative.count == coordinates.count else { return [] }
        let total = cumulative[cumulative.count - 1]
        let networkLegs = legs.filter { !$0.isAccess }
        var out = [Maneuver(kind: .depart, streetName: networkLegs.first?.name, distanceFromStart: 0, coordinate: first)]
        var currentStreet = networkLegs.first?.name

        for i in legs.indices.dropFirst() {
            let leg = legs[i], prev = legs[i - 1]
            guard !leg.isAccess, !prev.isAccess, coordinates.indices.contains(leg.startIndex) else { continue }
            let d = cumulative[leg.startIndex]
            let nameChanged = leg.name != nil && leg.name != currentStreet
            var kind: ManeuverKind?
            if leg.isSteps && !prev.isSteps {
                kind = .takeStairs
            } else if leg.isUnderpass && !prev.isUnderpass {
                kind = .enterUnderpass
            } else if leg.isCrossingEdge && !prev.isCrossingEdge {
                kind = .crossStreet
            } else if leg.startsAtCrossingNode && !leg.isCrossingEdge && !prev.isCrossingEdge {
                kind = .crossStreet
            } else if let turn = turnKind(coordinates: coordinates, cumulative: cumulative, nodeIndex: leg.startIndex,
                                          total: total) {
                switch turn {
                case .continueStraight: kind = nameChanged ? .continueStraight : nil
                case .slightLeft, .slightRight: kind = leg.startsAtJunction || nameChanged ? turn : nil
                default: kind = turn
                }
            } else if nameChanged {
                kind = .continueStraight
            }
            if let kind {
                out.append(Maneuver(kind: kind, streetName: leg.name, distanceFromStart: d,
                                    coordinate: coordinates[leg.startIndex]))
            }
            if let name = leg.name { currentStreet = name }
        }

        out.append(Maneuver(kind: .arrive, streetName: networkLegs.last?.name, distanceFromStart: total, coordinate: last))
        return out
    }

    /// Bucket for a signed turn angle in degrees (positive = right).
    static func turnKind(angle: Double) -> ManeuverKind {
        let m = abs(angle)
        let right = angle > 0
        if m < 20 { return .continueStraight }
        if m < 45 { return right ? .slightRight : .slightLeft }
        if m < 135 { return right ? .right : .left }
        if m < 170 { return right ? .sharpRight : .sharpLeft }
        return .uTurn
    }

    /// Turn at polyline vertex `nodeIndex`, or nil when there is too little geometry on either side.
    static func turnKind(coordinates: [GeoCoordinate], cumulative: [Double], nodeIndex: Int, total: Double) -> ManeuverKind? {
        let d = cumulative[nodeIndex]
        let back = min(bearingWindow, d), ahead = min(bearingWindow, total - d)
        guard back >= minBearingSpan, ahead >= minBearingSpan else { return nil }
        let node = coordinates[nodeIndex]
        let before = point(coordinates: coordinates, cumulative: cumulative, at: d - back)
        let after = point(coordinates: coordinates, cumulative: cumulative, at: d + ahead)
        let inBearing = GeoMath.bearing(from: before, to: node)
        let outBearing = GeoMath.bearing(from: node, to: after)
        return turnKind(angle: GeoMath.angleDifference(from: inBearing, to: outBearing))
    }

    /// Coordinate `distance` metres along the polyline (binary search over `cumulative`).
    static func point(coordinates: [GeoCoordinate], cumulative: [Double], at distance: Double) -> GeoCoordinate {
        let n = coordinates.count
        if distance <= 0 || n == 1 { return coordinates[0] }
        if distance >= cumulative[n - 1] { return coordinates[n - 1] }
        var lo = 0, hi = n - 1 // invariant: cumulative[lo] <= distance < cumulative[hi]
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        let t = span > 0 ? (distance - cumulative[lo]) / span : 0
        return GeoMath.interpolate(coordinates[lo], coordinates[hi], fraction: t)
    }
}
