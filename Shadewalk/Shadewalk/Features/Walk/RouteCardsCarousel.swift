import ShadeFeatures
import SwiftUI

/// Horizontally paging route cards. Scrolling to a card selects its route; selecting a route elsewhere (map pills)
/// scrolls its card into place.
///
/// Cards leave room for the next one to peek in at the trailing edge; the same room after the last card lets it snap
/// to the leading edge like the others, so the card at the leading edge is always the selected one.
struct RouteCardsCarousel: View {
    let routes: [WalkRoute]
    let selectedRouteID: String?
    var isUpdating: Bool = false
    let onSelect: (WalkRoute) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrolledID: String?
    @State private var containerWidth: CGFloat = 0
    /// Scroll positions reported before this time come from a programmatic scroll and don't select anything.
    @State private var programmaticScrollEnd: Date = .distantPast

    /// Width of the next card peeking in at the trailing edge, points.
    private let peek: CGFloat = 24
    private let spacing: CGFloat = 10

    init(routes: [WalkRoute], selectedRouteID: String?, isUpdating: Bool = false,
         onSelect: @escaping (WalkRoute) -> Void) {
        self.routes = routes
        self.selectedRouteID = selectedRouteID
        self.isUpdating = isUpdating
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(routes) { route in
                    RouteSummaryCard(route: route, isSelected: route.id == selectedRouteID, onSelect: {
                        select(route)
                    })
                    .frame(width: cardWidth)
                    .id(route.id)
                }
            }
            .scrollTargetLayout()
            .padding(.trailing, trailingRoom)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrolledID, anchor: .leading)
        .safeAreaPadding(.horizontal, Theme.screenPadding)
        .scrollClipDisabled()
        .opacity(isUpdating ? 0.55 : 1)
        .overlay {
            if isUpdating {
                updatingBadge
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        containerWidth = width
                    }
            }
        }
        .onAppear {
            scrolledID = selectedRouteID
        }
        .onChange(of: scrolledID) { _, id in
            guard Date() >= programmaticScrollEnd, let id, id != selectedRouteID,
                  let route = routes.first(where: { $0.id == id }) else { return }
            onSelect(route)
        }
        .onChange(of: selectedRouteID) { _, id in
            guard id != scrolledID else { return }
            scrollProgrammatically(to: id, animated: true)
        }
        .onChange(of: routeIDs) { _, _ in
            scrollProgrammatically(to: selectedRouteID, animated: false)
        }
    }

    private var routeIDs: [String] { routes.map(\.id) }

    /// Room for the next card to peek in (and after the last card, so it can reach the leading edge).
    private var trailingRoom: CGFloat {
        routes.count > 1 ? peek + spacing : 0
    }

    private var cardWidth: CGFloat {
        guard containerWidth > 0 else { return 300 }
        return max(220, containerWidth - Theme.screenPadding * 2 - trailingRoom)
    }

    /// Scrolls to a card without its passing neighbours selecting themselves on the way.
    private func scrollProgrammatically(to id: String?, animated: Bool) {
        programmaticScrollEnd = Date().addingTimeInterval(animated && !reduceMotion ? 0.6 : 0.1)
        if animated {
            withMotionAwareAnimation(reduceMotion: reduceMotion) {
                scrolledID = id
            }
        } else {
            scrolledID = id
        }
    }

    private var updatingBadge: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Theme.shade)
            Text("Updating routes…")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }

    private func select(_ route: WalkRoute) {
        onSelect(route)
    }
}

#if DEBUG
#Preview("Route cards") {
    RouteCardsCarousel(routes: PreviewData.samplePlan.routes,
                       selectedRouteID: PreviewData.samplePlan.routes.first?.id) { _ in }
        .padding(.vertical)
        .background(Theme.canvas)
        .previewEnvironment()
}
#endif
