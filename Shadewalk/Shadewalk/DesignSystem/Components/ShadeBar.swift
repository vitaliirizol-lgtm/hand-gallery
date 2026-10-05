import ShadeFeatures
import SwiftUI

/// Horizontal capsule split proportionally into shaded (solid `shade`) and sunny (striped `sun`) runs, in route
/// order. VoiceOver reads it as "Shade along the route, 62 percent shade".
struct ShadeBar: View {
    private let parts: [ShadeBarPart]
    private let shadeFraction: Double
    private let height: CGFloat

    /// Gap between runs, points.
    private let gap: CGFloat = 1.5

    /// Runs from a route's segments (consecutive runs of the same kind are merged).
    init(segments: [RouteSegment], height: CGFloat = 10) {
        let parts = ShadeBarPart.parts(from: segments)
        self.parts = parts
        self.shadeFraction = parts.filter(\.isShaded).reduce(0) { $0 + $1.fraction }
        self.height = height
    }

    /// Two runs (shade first) from an overall shade fraction `[0, 1]`.
    init(shadeFraction: Double, height: CGFloat = 10) {
        let fraction = shadeFraction.isFinite ? min(max(shadeFraction, 0), 1) : 0
        var parts: [ShadeBarPart] = []
        if fraction > 0 { parts.append(ShadeBarPart(id: 0, isShaded: true, fraction: fraction)) }
        if fraction < 1 { parts.append(ShadeBarPart(id: 1, isShaded: false, fraction: 1 - fraction)) }
        self.parts = parts
        self.shadeFraction = fraction
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: gap) {
                ForEach(parts) { part in
                    ShadeBarRun(isShaded: part.isShaded)
                        .frame(width: width(of: part, totalWidth: proxy.size.width))
                }
            }
        }
        .frame(height: height)
        .background(Theme.hairline)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Shade along the route"))
        .accessibilityValue(Text("\(Formatters.percentValue(shadeFraction)) percent shade"))
    }

    private func width(of part: ShadeBarPart, totalWidth: CGFloat) -> CGFloat {
        let gaps = gap * CGFloat(max(0, parts.count - 1))
        let available = max(0, totalWidth - gaps)
        return available * CGFloat(part.fraction)
    }
}

/// One run of a `ShadeBar`; `fraction` of the total length.
struct ShadeBarPart: Identifiable, Hashable {
    let id: Int
    let isShaded: Bool
    let fraction: Double

    /// Merges consecutive segments of the same kind and drops slivers under 0.5 % (renormalised).
    static func parts(from segments: [RouteSegment]) -> [ShadeBarPart] {
        var merged: [(isShaded: Bool, length: Double)] = []
        for segment in segments where segment.length.isFinite && segment.length > 0 {
            if let last = merged.last, last.isShaded == segment.isShaded {
                merged[merged.count - 1].length += segment.length
            } else {
                merged.append((segment.isShaded, segment.length))
            }
        }
        let total = merged.reduce(0) { $0 + $1.length }
        guard total > 0 else { return [] }
        let kept = merged.filter { $0.length / total >= 0.005 }
        let keptTotal = kept.reduce(0) { $0 + $1.length }
        guard keptTotal > 0 else { return [] }
        return kept.enumerated().map { index, run in
            ShadeBarPart(id: index, isShaded: run.isShaded, fraction: run.length / keptTotal)
        }
    }
}

private struct ShadeBarRun: View {
    let isShaded: Bool

    var body: some View {
        if isShaded {
            Rectangle().fill(Theme.shade)
        } else {
            Rectangle()
                .fill(Theme.sun)
                .overlay {
                    DiagonalStripes(spacing: 5)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                }
                .clipped()
        }
    }
}

/// Diagonal hatching used to mark sunny runs (so sun vs. shade never depends on colour alone).
struct DiagonalStripes: Shape {
    var spacing: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return path }
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

#if DEBUG
#Preview("Shade bar") {
    VStack(spacing: 16) {
        ShadeBar(shadeFraction: 0.62)
        ShadeBar(segments: [
            RouteSegment(coordinates: [], length: 220, isShaded: true),
            RouteSegment(coordinates: [], length: 80, isShaded: false),
            RouteSegment(coordinates: [], length: 400, isShaded: true),
            RouteSegment(coordinates: [], length: 150, isShaded: false),
        ], height: 14)
    }
    .padding()
    .background(Theme.canvas)
}
#endif
