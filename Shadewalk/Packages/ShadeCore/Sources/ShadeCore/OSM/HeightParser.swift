import Foundation

/// Parsers for numeric OSM tag values (heights, levels, layers).
public enum OSMValueParser {
    /// Parses a length in metres: `12`, `12 m`, `12.5m`, `12,5`, `40'`, `40 ft`, `12'6"`, `350 cm`.
    /// For `;`-separated lists only the first value is used. Returns nil for empty, negative or unparseable values.
    public static func length(_ raw: String?) -> Double? {
        guard let text = firstValue(raw), let (value, rest) = leadingNumber(text), value >= 0 else { return nil }
        let unit = rest.trimmingCharacters(in: .whitespaces)
        switch unit {
        case "", "m", "meter", "meters", "metre", "metres":
            return value
        case "ft", "feet", "foot", "'", "′":
            return value * feet
        case "cm":
            return value / 100
        case "in", "\"", "″":
            return value * inches
        default:
            // Feet and inches, e.g. 12'6" or 12' 6".
            guard let first = unit.first, first == "'" || first == "′" else { return nil }
            let tail = String(unit.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let (inch, inchRest) = leadingNumber(tail), inch >= 0,
                  ["", "\"", "″", "in"].contains(inchRest.trimmingCharacters(in: .whitespaces)) else { return nil }
            return value * feet + inch * inches
        }
    }

    /// Leading number of the first `;`-separated value (`3`, `3.5`, `2,5`, `-1`, `4;5` → 4). Nil if none.
    public static func number(_ raw: String?) -> Double? {
        guard let text = firstValue(raw) else { return nil }
        return leadingNumber(text)?.value
    }

    private static let feet = 0.3048
    private static let inches = 0.0254

    private static func firstValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let text = first.trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? nil : text
    }

    /// Splits `text` into a leading decimal number (optional sign, `.` or `,` as decimal separator) and the rest.
    private static func leadingNumber(_ text: String) -> (value: Double, rest: String)? {
        let chars = Array(text)
        var i = 0
        var literal = ""
        if i < chars.count, chars[i] == "-" || chars[i] == "+" {
            literal.append(chars[i])
            i += 1
        }
        var digits = 0
        var sawSeparator = false
        while i < chars.count {
            let ch = chars[i]
            if ch.isASCII, ch.isNumber {
                literal.append(ch)
                digits += 1
            } else if (ch == "." || ch == ","), !sawSeparator, i + 1 < chars.count, chars[i + 1].isASCII,
                      chars[i + 1].isNumber {
                literal.append(".")
                sawSeparator = true
            } else {
                break
            }
            i += 1
        }
        guard digits > 0, let value = Double(literal), value.isFinite else { return nil }
        return (value, String(chars[i...]))
    }
}

/// Building heights derived from OSM tags.
public struct OSMBuildingHeights: Hashable, Sendable {
    /// Roof-top height, metres, clamped to `[2, 500]`.
    public var height: Double
    /// Underside height, metres (0 = solid to the ground); always below `height`.
    public var minHeight: Double
    /// Open structure (roof, carport, canopy, `walls=no`).
    public var isRoofOnly: Bool

    /// Memberwise initialiser; values are stored as given.
    public init(height: Double, minHeight: Double, isRoofOnly: Bool) {
        self.height = height
        self.minHeight = minHeight
        self.isRoofOnly = isRoofOnly
    }

    /// Metres per `building:levels` / `building:min_level` storey.
    public static let metersPerLevel = 3.2
    /// Metres per `roof:levels` storey.
    public static let metersPerRoofLevel = 1.5
    /// Height clamp range, metres.
    public static let minimumHeight = 2.0
    public static let maximumHeight = 500.0
    /// Defaults for open structures without explicit heights, metres.
    public static let roofOnlyDefaultHeight = 4.0
    public static let roofOnlyDefaultMinHeight = 2.5

    /// `building=` values that are open structures.
    public static let roofOnlyBuildingValues: Set<String> = ["roof", "carport", "canopy"]

    /// Resolves heights per SPEC §4.4: `height`, else `building:levels × 3.2 + roof:levels × 1.5`, else a default
    /// by building type; `min_height`, else `building:min_level × 3.2`.
    public init(tags: [String: String]) {
        let type = tags["building"] ?? "yes"
        let roofOnly = Self.roofOnlyBuildingValues.contains(type) || tags["walls"] == "no"

        var height: Double
        if let h = OSMValueParser.length(tags["height"]), h > 0 {
            height = h
        } else if let levels = OSMValueParser.number(tags["building:levels"]), levels > 0 {
            let roofLevels = max(0, OSMValueParser.number(tags["roof:levels"]) ?? 0)
            height = levels * Self.metersPerLevel + roofLevels * Self.metersPerRoofLevel
        } else {
            height = roofOnly ? Self.roofOnlyDefaultHeight : Self.defaultHeight(forBuildingType: type)
        }
        height = min(Self.maximumHeight, max(Self.minimumHeight, height))

        var minHeight: Double
        if let m = OSMValueParser.length(tags["min_height"]) {
            minHeight = m
        } else if let minLevel = OSMValueParser.number(tags["building:min_level"]), minLevel > 0 {
            minHeight = minLevel * Self.metersPerLevel
        } else {
            minHeight = roofOnly ? Self.roofOnlyDefaultMinHeight : 0
        }
        // Keep the solid part at least 0.5 m thick.
        minHeight = max(0, min(minHeight, height - 0.5))

        self.init(height: height, minHeight: minHeight, isRoofOnly: roofOnly)
    }

    /// Default height by `building=` value (SPEC §4.4).
    public static func defaultHeight(forBuildingType type: String) -> Double {
        switch type {
        case "house", "detached", "residential", "terrace", "semidetached_house": return 7
        case "apartments": return 18
        case "commercial", "office", "retail", "hotel": return 14
        case "garage", "garages", "shed", "kiosk", "carport", "hut": return 3
        case "roof": return 4
        default: return 9
        }
    }
}
