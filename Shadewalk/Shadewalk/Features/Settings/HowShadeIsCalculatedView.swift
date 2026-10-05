import ShadeFeatures
import SwiftUI

/// "How shade is calculated": the ingredients (sun, buildings, trees, covered ways), how a route is chosen, and the
/// known limitations. Pushed from Settings › About.
struct HowShadeIsCalculatedView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing + 4) {
                OnboardingShadowIllustration(isActive: true)
                    .frame(height: 200)
                Text("Shadewalk builds a picture of the shade for the moment you set off, then looks for the route that keeps you in it.")
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ShadeExplainerTopic(systemImage: "sun.max.fill", tint: Theme.sun,
                                    title: "Where the sun is",
                                    message: "For your departure time and place, Shadewalk works out the sun’s direction and height in the sky, accurate to a fraction of a degree.")
                ShadeExplainerTopic(systemImage: "building.2.fill", tint: Theme.inkSecondary,
                                    title: "Buildings",
                                    message: "Building outlines and heights come from OpenStreetMap. A spot is shaded when a building stands between it and the sun and is tall enough to block it.")
                ShadeExplainerTopic(systemImage: "tree.fill", tint: Theme.shade,
                                    title: "Trees and parks",
                                    message: "Single trees, rows of trees and woods add their canopy, shifted away from the sun just like a real shadow.")
                ShadeExplainerTopic(systemImage: "umbrella.fill", tint: Theme.shade,
                                    title: "Covered walkways",
                                    message: "Arcades, colonnades, tunnels and indoor passages always count as shade.")
                ShadeExplainerTopic(systemImage: "point.topleft.down.curvedto.point.bottomright.up", tint: Theme.shade,
                                    title: "Choosing the route",
                                    message: "Every street is checked every few steps. Shadewalk compares the shadiest, a balanced and the fastest route, and only suggests a longer one if it stays within your shade preference.")
                limitations
                Text("Map data © OpenStreetMap contributors. Weather and elevation by Open-Meteo.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, Theme.spacing)
        }
        .background(Theme.canvas)
        .navigationTitle("How shade is calculated")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Good to know", systemImage: "info.circle.fill")
            VStack(alignment: .leading, spacing: 10) {
                bullet("Missing building heights are estimated from the number of floors or the type of building.")
                bullet("Temporary shade, such as awnings, umbrellas or parked trucks, isn’t known.")
                bullet("Tree sizes are estimates, and trees missing from the map aren’t counted.")
                bullet("Clouds aren’t used for route shade. The sky icon in the weather pill shows how cloudy it is.")
                bullet("Map data is added by volunteers, so detail varies from street to street.")
            }
        }
        .shadewalkCard()
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Theme.sun)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One ingredient of the shade model: tinted icon badge, title and explanation in a card.
private struct ShadeExplainerTopic: View {
    let systemImage: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 40

    init(systemImage: String, tint: Color, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: badgeSize, height: badgeSize)
                .background(tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.sectionTitle)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .shadewalkCard()
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("How shade is calculated") {
    NavigationStack {
        HowShadeIsCalculatedView()
    }
    .previewEnvironment()
}
#endif
