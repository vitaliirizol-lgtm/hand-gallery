import ShadeFeatures
import SwiftUI

// Original onboarding illustrations, drawn with Canvas from simple shapes in the Shadewalk palette:
// shade = green, sun = orange; sunny stretches are dashed or striped so they never rely on colour alone.
// Renderers are plain enums (no view state), so the Canvas closures only capture values.

// MARK: - Tile

/// Rounded tile behind every illustration.
private struct OnboardingIllustrationTile: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(LinearGradient(colors: [Theme.shadeSoft, Theme.surface], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: Theme.sheetCornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.sheetCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.sheetCornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
    }
}

// MARK: - 1. Concept

/// Page 1: a footpath winds out of the sun into the shadows of street trees; the walker is in the shade.
struct OnboardingConceptIllustration: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    OnboardingConceptRenderer.draw(in: &context, size: size)
                }
                walker
                    .position(OnboardingConceptRenderer.walkerPosition(in: proxy.size))
            }
        }
        .modifier(OnboardingIllustrationTile())
        .accessibilityHidden(true)
    }

    private var walker: some View {
        Image(systemName: "figure.walk")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Theme.onShade)
            .frame(width: 40, height: 40)
            .background(Theme.shade, in: Circle())
            .overlay {
                Circle().strokeBorder(Theme.surface, lineWidth: 3)
            }
            .shadow(color: Theme.cardShadow, radius: 6, x: 0, y: 3)
    }
}

private enum OnboardingConceptRenderer {
    /// Tree in unit coordinates; `radius` is a fraction of the shorter side.
    struct Tree {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
    }

    // Footpath: one cubic Bézier in unit coordinates, bottom right → top left.
    static let start = CGPoint(x: 0.82, y: 1.04)
    static let control1 = CGPoint(x: 0.98, y: 0.60)
    static let control2 = CGPoint(x: 0.04, y: 0.62)
    static let end = CGPoint(x: 0.22, y: -0.04)

    /// The first three shade the middle of the path; the last stands in the corner.
    static let trees: [Tree] = [
        Tree(x: 0.71, y: 0.55, radius: 0.11),
        Tree(x: 0.57, y: 0.45, radius: 0.12),
        Tree(x: 0.44, y: 0.35, radius: 0.10),
        Tree(x: 0.12, y: 0.80, radius: 0.09),
    ]
    /// Part of the path (0–1) inside the tree shadows.
    static let shadedFrom: CGFloat = 0.34
    static let shadedTo: CGFloat = 0.72
    static let walkerFraction: CGFloat = 0.52
    static let sunCenter = CGPoint(x: 0.85, y: 0.17)

    static func walkerPosition(in size: CGSize) -> CGPoint {
        pathPoint(at: walkerFraction, in: size)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let unit = min(size.width, size.height)
        let path = footpath(in: size)
        let pathWidth = unit * 0.13

        // Footpath with a soft edge.
        context.stroke(path, with: .color(Theme.inkSecondary.opacity(0.2)),
                       style: StrokeStyle(lineWidth: pathWidth + 3, lineCap: .round))
        context.stroke(path, with: .color(Theme.surface), style: StrokeStyle(lineWidth: pathWidth, lineCap: .round))

        // Tree shadows, cast away from the sun (top right) and merged so overlaps aren't darker.
        var shadows = Path()
        for tree in trees {
            let center = CGPoint(x: tree.x * size.width - unit * 0.12, y: tree.y * size.height + unit * 0.10)
            let radiusX = unit * tree.radius * 1.35
            let radiusY = unit * tree.radius * 1.1
            shadows.addEllipse(in: CGRect(x: center.x - radiusX, y: center.y - radiusY,
                                          width: radiusX * 2, height: radiusY * 2))
        }
        context.fill(shadows, with: .color(Color.black.opacity(0.2)))

        // Route: sunny stretches dashed orange, the shaded stretch solid green (as on the map).
        let routeWidth = unit * 0.035
        let sunnyStyle = StrokeStyle(lineWidth: routeWidth, lineCap: .round,
                                     dash: [routeWidth * 1.6, routeWidth * 1.3])
        context.stroke(path.trimmedPath(from: 0, to: shadedFrom), with: .color(Theme.sun), style: sunnyStyle)
        context.stroke(path.trimmedPath(from: shadedTo, to: 1), with: .color(Theme.sun), style: sunnyStyle)
        context.stroke(path.trimmedPath(from: shadedFrom, to: shadedTo), with: .color(Theme.shade),
                       style: StrokeStyle(lineWidth: routeWidth, lineCap: .round))

        // Crowns with a highlight towards the sun.
        for tree in trees {
            let center = CGPoint(x: tree.x * size.width, y: tree.y * size.height)
            let radius = unit * tree.radius
            context.fill(OnboardingPainter.circle(center: center, radius: radius), with: .color(Theme.shade))
            let highlightCenter = CGPoint(x: center.x + radius * 0.3, y: center.y - radius * 0.3)
            context.fill(OnboardingPainter.circle(center: highlightCenter, radius: radius * 0.45),
                         with: .color(Color.white.opacity(0.18)))
        }

        OnboardingPainter.drawSun(in: &context,
                                  center: CGPoint(x: sunCenter.x * size.width, y: sunCenter.y * size.height),
                                  radius: unit * 0.075)
    }

    static func footpath(in size: CGSize) -> Path {
        var path = Path()
        path.move(to: scaled(start, in: size))
        path.addCurve(to: scaled(end, in: size), control1: scaled(control1, in: size),
                      control2: scaled(control2, in: size))
        return path
    }

    /// Point on the footpath at parameter `t` (0–1).
    static func pathPoint(at t: CGFloat, in size: CGSize) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        let x = a * start.x + b * control1.x + c * control2.x + d * end.x
        let y = a * start.y + b * control1.y + c * control2.y + d * end.y
        return CGPoint(x: x * size.width, y: y * size.height)
    }

    private static func scaled(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

// MARK: - 2. How it works

/// Page 2 and "How shade is calculated": the sun travels along its arc over a row of buildings and a tree; their
/// shadows sweep across the footpath below (green = shade, striped orange = sun). The sun moves only while `isActive`
/// and Reduce Motion is off.
struct OnboardingShadowIllustration: View {
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = isActive && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
            Canvas { [progress = OnboardingShadowRenderer.progress(at: timeline.date, animated: animates)]
                context, size in
                OnboardingShadowRenderer.draw(in: &context, size: size, progress: progress)
            }
        }
        .modifier(OnboardingIllustrationTile())
        .accessibilityHidden(true)
    }
}

private enum OnboardingShadowRenderer {
    /// Building in unit coordinates: left / right edge and height (fraction of the height).
    struct Block {
        let x0: CGFloat
        let x1: CGFloat
        let height: CGFloat
    }

    static let blocks: [Block] = [
        Block(x0: 0.10, x1: 0.24, height: 0.34),
        Block(x0: 0.36, x1: 0.52, height: 0.48),
        Block(x0: 0.64, x1: 0.75, height: 0.24),
    ]
    static let treeX: CGFloat = 0.87
    /// Crown centre above the ground, fraction of the height.
    static let treeCrownHeight: CGFloat = 0.25
    /// Crown radius, fraction of the shorter side.
    static let treeRadius: CGFloat = 0.075
    /// Sun position without animation: mid-morning, shadows falling to the right.
    static let restingProgress: Double = 0.2

    /// 0 = low on the left, 1 = low on the right; eases back and forth every 10 s (`restingProgress` when not
    /// animated).
    static func progress(at date: Date, animated: Bool) -> Double {
        guard animated else { return restingProgress }
        let period = 10.0
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.5 - 0.4 * cos(phase * 2 * Double.pi)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, progress: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let width = size.width
        let height = size.height
        let unit = min(width, height)
        let ground = height * 0.72
        let arcCenter = CGPoint(x: width / 2, y: ground)
        let radiusX = width * 0.44
        let radiusY = ground - height * 0.12
        let clamped = min(max(progress, 0), 1)
        let angle = CGFloat.pi * CGFloat(0.9 - 0.8 * clamped)
        let sun = CGPoint(x: arcCenter.x + radiusX * cos(angle), y: arcCenter.y - radiusY * sin(angle))

        drawArc(in: &context, center: arcCenter, radiusX: radiusX, radiusY: radiusY)
        context.fill(OnboardingPainter.circle(center: sun, radius: unit * 0.13), with: .color(Theme.sun.opacity(0.14)))
        OnboardingPainter.drawSun(in: &context, center: sun, radius: unit * 0.055)

        // Sunlight is parallel: every shadow falls the same way, away from the sun, with length = height × cot(elevation),
        // the elevation being read off the drawn sun.
        let horizontal = sun.x - arcCenter.x
        let rise = max(ground - sun.y, 1)
        let direction: CGFloat = horizontal < 0 ? 1 : -1
        let spread = min(abs(horizontal) / rise, 4)

        // Shade: a faint wedge in the air and a run on the footpath for every building and the tree.
        var wedges = Path()
        var runs: [ClosedRange<CGFloat>] = []
        for block in blocks {
            let x0 = block.x0 * width
            let x1 = block.x1 * width
            let blockHeight = block.height * height
            let top = ground - blockHeight
            let length = blockHeight * spread
            if direction > 0 {
                addWedge(to: &wedges, from: CGPoint(x: x1, y: top), base: x1, tip: x1 + length, ground: ground)
                runs.append(x0...(x1 + length))
            } else {
                addWedge(to: &wedges, from: CGPoint(x: x0, y: top), base: x0, tip: x0 - length, ground: ground)
                runs.append((x0 - length)...x1)
            }
        }
        let crown = CGPoint(x: treeX * width, y: ground - treeCrownHeight * height)
        let crownRadius = unit * treeRadius
        let shadowCenter = crown.x + direction * (ground - crown.y) * spread
        wedges.move(to: CGPoint(x: crown.x - crownRadius, y: crown.y))
        wedges.addLine(to: CGPoint(x: shadowCenter - crownRadius, y: ground))
        wedges.addLine(to: CGPoint(x: shadowCenter + crownRadius, y: ground))
        wedges.addLine(to: CGPoint(x: crown.x + crownRadius, y: crown.y))
        wedges.closeSubpath()
        runs.append((shadowCenter - crownRadius)...(shadowCenter + crownRadius))
        context.fill(wedges, with: .color(Color.black.opacity(0.07)))

        drawBlocks(in: &context, width: width, height: height, ground: ground)

        // Tree.
        let trunk = CGRect(x: crown.x - 2, y: crown.y, width: 4, height: ground - crown.y)
        context.fill(Path(roundedRect: trunk, cornerRadius: 2), with: .color(Theme.inkSecondary))
        context.fill(OnboardingPainter.circle(center: crown, radius: crownRadius), with: .color(Theme.shade))

        // Ground.
        var groundLine = Path()
        groundLine.move(to: CGPoint(x: 0, y: ground))
        groundLine.addLine(to: CGPoint(x: width, y: ground))
        context.stroke(groundLine, with: .color(Theme.inkSecondary.opacity(0.35)), lineWidth: 1)

        drawFootpath(in: &context, width: width, height: height, ground: ground, shadeRuns: runs)
    }

    // MARK: Parts

    private static func drawArc(in context: inout GraphicsContext, center: CGPoint, radiusX: CGFloat,
                                radiusY: CGFloat) {
        var arc = Path()
        let steps = 48
        for step in 0...steps {
            let angle = CGFloat.pi * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: center.x + radiusX * cos(angle), y: center.y - radiusY * sin(angle))
            if step == 0 {
                arc.move(to: point)
            } else {
                arc.addLine(to: point)
            }
        }
        context.stroke(arc, with: .color(Theme.sun.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
    }

    private static func drawBlocks(in context: inout GraphicsContext, width: CGFloat, height: CGFloat,
                                   ground: CGFloat) {
        for block in blocks {
            let rect = CGRect(x: block.x0 * width, y: ground - block.height * height,
                              width: (block.x1 - block.x0) * width, height: block.height * height)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Theme.inkSecondary))
            var windows = Path()
            let columns = rect.width > 60 ? 3 : 2
            let windowWidth = rect.width * 0.16
            let windowHeight = min(8, rect.height * 0.08)
            var y = rect.minY + 8
            while y + windowHeight < rect.maxY - 6 {
                for column in 0..<columns {
                    let x = rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(columns) - windowWidth / 2
                    windows.addRect(CGRect(x: x, y: y, width: windowWidth, height: windowHeight))
                }
                y += windowHeight + 7
            }
            context.fill(windows, with: .color(Theme.surface.opacity(0.55)))
        }
    }

    /// Sidewalk strip in front of the buildings: striped orange where sunny, green where shaded.
    private static func drawFootpath(in context: inout GraphicsContext, width: CGFloat, height: CGFloat,
                                     ground: CGFloat, shadeRuns: [ClosedRange<CGFloat>]) {
        let stripHeight = max(10, height * 0.07)
        let strip = CGRect(x: width * 0.04, y: ground + height * 0.07, width: width * 0.92, height: stripHeight)
        let stripPath = Path(roundedRect: strip, cornerRadius: stripHeight / 2)
        context.drawLayer { layer in
            layer.clip(to: stripPath)
            layer.fill(stripPath, with: .color(Theme.sun))
            layer.stroke(OnboardingPainter.stripes(in: strip, spacing: 6), with: .color(Color.white.opacity(0.45)),
                         lineWidth: 1.5)
            for run in shadeRuns {
                let rect = CGRect(x: run.lowerBound, y: strip.minY, width: run.upperBound - run.lowerBound,
                                  height: strip.height)
                layer.fill(Path(rect), with: .color(Theme.shade))
            }
        }
    }

    private static func addWedge(to path: inout Path, from corner: CGPoint, base: CGFloat, tip: CGFloat,
                                 ground: CGFloat) {
        path.move(to: corner)
        path.addLine(to: CGPoint(x: tip, y: ground))
        path.addLine(to: CGPoint(x: base, y: ground))
        path.closeSubpath()
    }

}

// MARK: - 3. Location

/// Page 3: a small street grid with building shadows, a shady route starting at a pulsing location puck. The pulse
/// runs only while `isActive` and Reduce Motion is off.
struct OnboardingLocationIllustration: View {
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = isActive && !reduceMotion
        GeometryReader { proxy in
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
                    Canvas { [pulse = OnboardingLocationRenderer.pulse(at: timeline.date, animated: animates)]
                        context, size in
                        OnboardingLocationRenderer.draw(in: &context, size: size, pulse: pulse)
                    }
                }
                puck
                    .position(OnboardingLocationRenderer.puckPosition(in: proxy.size))
            }
        }
        .modifier(OnboardingIllustrationTile())
        .accessibilityHidden(true)
    }

    private var puck: some View {
        Image(systemName: "location.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.onShade)
            .frame(width: 36, height: 36)
            .background(Theme.shade, in: Circle())
            .overlay {
                Circle().strokeBorder(Theme.surface, lineWidth: 3)
            }
            .shadow(color: Theme.cardShadow, radius: 6, x: 0, y: 3)
    }
}

private enum OnboardingLocationRenderer {
    /// Street centre lines (unit coordinates).
    static let streetRows: [CGFloat] = [0.30, 0.66]
    static let streetColumns: [CGFloat] = [0.30, 0.70]
    static let puck = CGPoint(x: 0.30, y: 0.66)

    static func puckPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: puck.x * size.width, y: puck.y * size.height)
    }

    /// 0 → 1 every 2.2 s (a fixed ring when not animated).
    static func pulse(at date: Date, animated: Bool) -> Double {
        guard animated else { return 0.45 }
        let period = 2.2
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, pulse: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let width = size.width
        let height = size.height
        let unit = min(width, height)
        let streetWidth = unit * 0.1

        // Streets.
        var streets = Path()
        for row in streetRows {
            streets.move(to: CGPoint(x: 0, y: row * height))
            streets.addLine(to: CGPoint(x: width, y: row * height))
        }
        for column in streetColumns {
            streets.move(to: CGPoint(x: column * width, y: 0))
            streets.addLine(to: CGPoint(x: column * width, y: height))
        }
        context.stroke(streets, with: .color(Theme.surface), lineWidth: streetWidth)

        // Blocks and the shadows they cast onto the streets (sun to the top right).
        let blocks = blockRects(width: width, height: height, streetWidth: streetWidth, margin: unit * 0.03)
        var shadows = Path()
        var buildings = Path()
        for block in blocks {
            shadows.addRoundedRect(in: block.offsetBy(dx: -unit * 0.05, dy: unit * 0.055),
                                   cornerSize: CGSize(width: 6, height: 6))
            buildings.addRoundedRect(in: block, cornerSize: CGSize(width: 6, height: 6))
        }
        context.fill(shadows, with: .color(Color.black.opacity(0.13)))
        context.fill(buildings, with: .color(Theme.inkSecondary.opacity(0.3)))

        // Route from the puck: shade (solid green), a sunny crossing (dashed orange), shade again.
        let routeWidth = unit * 0.03
        let start = CGPoint(x: streetColumns[0] * width, y: streetRows[1] * height)
        let corner1 = CGPoint(x: streetColumns[0] * width, y: streetRows[0] * height)
        let corner2 = CGPoint(x: streetColumns[1] * width, y: streetRows[0] * height)
        let finish = CGPoint(x: streetColumns[1] * width, y: -height * 0.05)
        let solid = StrokeStyle(lineWidth: routeWidth, lineCap: .round, lineJoin: .round)
        let dashed = StrokeStyle(lineWidth: routeWidth, lineCap: .round, dash: [routeWidth * 1.6, routeWidth * 1.3])
        context.stroke(segment(start, corner1), with: .color(Theme.shade), style: solid)
        context.stroke(segment(corner1, corner2), with: .color(Theme.sun), style: dashed)
        context.stroke(segment(corner2, finish), with: .color(Theme.shade), style: solid)

        // Pulse around the puck.
        let phase = CGFloat(min(max(pulse, 0), 1))
        let ringRadius = unit * (0.07 + 0.16 * phase)
        context.fill(OnboardingPainter.circle(center: start, radius: ringRadius),
                     with: .color(Theme.shade.opacity(Double(0.32 * (1 - phase)))))
        context.fill(OnboardingPainter.circle(center: start, radius: unit * 0.075),
                     with: .color(Theme.shade.opacity(0.18)))
    }

    private static func segment(_ from: CGPoint, _ to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    /// The nine blocks between the streets (outer ones run off the tile).
    private static func blockRects(width: CGFloat, height: CGFloat, streetWidth: CGFloat,
                                   margin: CGFloat) -> [CGRect] {
        let inset = streetWidth / 2 + margin
        var xEdges: [CGFloat] = [-width * 0.2]
        xEdges.append(contentsOf: streetColumns.map { column in column * width })
        xEdges.append(width * 1.2)
        var yEdges: [CGFloat] = [-height * 0.2]
        yEdges.append(contentsOf: streetRows.map { row in row * height })
        yEdges.append(height * 1.2)
        var rects: [CGRect] = []
        for i in 0..<(xEdges.count - 1) {
            for j in 0..<(yEdges.count - 1) {
                let minX = xEdges[i] + inset
                let maxX = xEdges[i + 1] - inset
                let minY = yEdges[j] + inset
                let maxY = yEdges[j + 1] - inset
                guard maxX > minX, maxY > minY else { continue }
                rects.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
        }
        return rects
    }
}

// MARK: - Shared drawing

private enum OnboardingPainter {
    static func circle(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// Disc with eight short rays.
    static func drawSun(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        var rays = Path()
        for index in 0..<8 {
            let angle = CGFloat(index) * CGFloat.pi / 4
            let inner = radius * 1.45
            let outer = radius * 2.0
            rays.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            rays.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        context.stroke(rays, with: .color(Theme.sun),
                       style: StrokeStyle(lineWidth: max(1.5, radius * 0.22), lineCap: .round))
        context.fill(circle(center: center, radius: radius), with: .color(Theme.sun))
    }

    /// Diagonal hatching across `rect` (the app's "sunny" pattern).
    static func stripes(in rect: CGRect, spacing: CGFloat) -> Path {
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
#Preview("Onboarding illustrations") {
    ScrollView {
        VStack(spacing: 20) {
            OnboardingConceptIllustration()
                .frame(height: 240)
            OnboardingShadowIllustration()
                .frame(height: 240)
            OnboardingLocationIllustration()
                .frame(height: 240)
        }
        .padding()
    }
    .background(Theme.canvas)
}
#endif
