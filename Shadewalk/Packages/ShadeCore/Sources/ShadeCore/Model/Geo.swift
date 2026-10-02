import Foundation

/// WGS-84 coordinate in degrees.
public struct GeoCoordinate: Hashable, Codable, Sendable, CustomStringConvertible {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    public var description: String {
        String(format: "(%.6f, %.6f)", latitude, longitude)
    }
}

/// Axis-aligned latitude/longitude box.
public struct BoundingBox: Hashable, Codable, Sendable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    /// Smallest box containing all coordinates. Returns nil for an empty sequence.
    public init?<S: Sequence>(coordinates: S) where S.Element == GeoCoordinate {
        var minLat = Double.infinity, minLon = Double.infinity
        var maxLat = -Double.infinity, maxLon = -Double.infinity
        var any = false
        for c in coordinates {
            any = true
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        guard any else { return nil }
        self.init(minLatitude: minLat, minLongitude: minLon, maxLatitude: maxLat, maxLongitude: maxLon)
    }

    public var center: GeoCoordinate {
        GeoCoordinate(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }

    /// East-west extent in metres (measured at the centre latitude).
    public var widthMeters: Double {
        GeoMath.metersPerDegreeLongitude(at: center.latitude) * (maxLongitude - minLongitude)
    }

    /// North-south extent in metres.
    public var heightMeters: Double {
        GeoMath.metersPerDegreeLatitude * (maxLatitude - minLatitude)
    }

    public func contains(_ c: GeoCoordinate) -> Bool {
        c.latitude >= minLatitude && c.latitude <= maxLatitude &&
            c.longitude >= minLongitude && c.longitude <= maxLongitude
    }

    /// True if `other` lies entirely inside this box.
    public func contains(_ other: BoundingBox) -> Bool {
        other.minLatitude >= minLatitude && other.maxLatitude <= maxLatitude &&
            other.minLongitude >= minLongitude && other.maxLongitude <= maxLongitude
    }

    public func intersects(_ other: BoundingBox) -> Bool {
        !(other.minLatitude > maxLatitude || other.maxLatitude < minLatitude ||
            other.minLongitude > maxLongitude || other.maxLongitude < minLongitude)
    }

    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(minLatitude: min(minLatitude, other.minLatitude),
                    minLongitude: min(minLongitude, other.minLongitude),
                    maxLatitude: max(maxLatitude, other.maxLatitude),
                    maxLongitude: max(maxLongitude, other.maxLongitude))
    }

    /// Grows the box by `meters` on every side.
    public func expanded(byMeters meters: Double) -> BoundingBox {
        let dLat = meters / GeoMath.metersPerDegreeLatitude
        let dLon = meters / max(GeoMath.metersPerDegreeLongitude(at: center.latitude), 1e-6)
        return BoundingBox(minLatitude: max(-90, minLatitude - dLat), minLongitude: max(-180, minLongitude - dLon),
                           maxLatitude: min(90, maxLatitude + dLat), maxLongitude: min(180, maxLongitude + dLon))
    }

    /// Grows the box (around its centre) so each side is at least `meters` long.
    public func ensuringMinimumSize(meters: Double) -> BoundingBox {
        let padW = max(0, (meters - widthMeters) / 2)
        let padH = max(0, (meters - heightMeters) / 2)
        let dLat = padH / GeoMath.metersPerDegreeLatitude
        let dLon = padW / max(GeoMath.metersPerDegreeLongitude(at: center.latitude), 1e-6)
        return BoundingBox(minLatitude: minLatitude - dLat, minLongitude: minLongitude - dLon,
                           maxLatitude: maxLatitude + dLat, maxLongitude: maxLongitude + dLon)
    }

    /// Overpass bbox filter order: south,west,north,east.
    public var overpassString: String {
        String(format: "%.6f,%.6f,%.6f,%.6f", minLatitude, minLongitude, maxLatitude, maxLongitude)
    }
}

/// Planar point in metres (x = east, y = north) in a `LocalProjection`.
public struct Point2D: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public static let zero = Point2D(x: 0, y: 0)

    public static func + (a: Point2D, b: Point2D) -> Point2D { Point2D(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point2D, b: Point2D) -> Point2D { Point2D(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Point2D, s: Double) -> Point2D { Point2D(x: a.x * s, y: a.y * s) }
    public static func * (s: Double, a: Point2D) -> Point2D { Point2D(x: a.x * s, y: a.y * s) }
    public static prefix func - (a: Point2D) -> Point2D { Point2D(x: -a.x, y: -a.y) }

    public func dot(_ o: Point2D) -> Double { x * o.x + y * o.y }
    /// z-component of the 3D cross product.
    public func cross(_ o: Point2D) -> Double { x * o.y - y * o.x }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public func distance(to o: Point2D) -> Double { (self - o).length }

    public var normalized: Point2D {
        let l = length
        return l > 0 ? Point2D(x: x / l, y: y / l) : .zero
    }
}

/// Local equirectangular projection around `origin`. Accurate for areas of a few kilometres.
public struct LocalProjection: Hashable, Sendable {
    public let origin: GeoCoordinate
    private let metersPerDegLat: Double
    private let metersPerDegLon: Double

    public init(origin: GeoCoordinate) {
        self.origin = origin
        metersPerDegLat = GeoMath.metersPerDegreeLatitude
        metersPerDegLon = max(GeoMath.metersPerDegreeLongitude(at: origin.latitude), 1e-6)
    }

    public func project(_ c: GeoCoordinate) -> Point2D {
        Point2D(x: (c.longitude - origin.longitude) * metersPerDegLon,
                y: (c.latitude - origin.latitude) * metersPerDegLat)
    }

    public func project(_ cs: [GeoCoordinate]) -> [Point2D] { cs.map(project) }

    public func unproject(_ p: Point2D) -> GeoCoordinate {
        GeoCoordinate(latitude: origin.latitude + p.y / metersPerDegLat,
                      longitude: origin.longitude + p.x / metersPerDegLon)
    }

    public func unproject(_ ps: [Point2D]) -> [GeoCoordinate] { ps.map(unproject) }
}
