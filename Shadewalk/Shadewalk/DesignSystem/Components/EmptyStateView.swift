import SwiftUI

/// Friendly placeholder for empty lists and screens: icon in a soft circle, title, message, optional action.
struct EmptyStateView: View {
    private let systemImage: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?

    @ScaledMetric(relativeTo: .largeTitle) private var badgeSize: CGFloat = 72

    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey,
         actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(Theme.shade)
                .frame(width: badgeSize, height: badgeSize)
                .background(Theme.shadeSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.shadewalkSecondary)
                    .frame(maxWidth: 280)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Empty state") {
    EmptyStateView(systemImage: "bookmark", title: "No saved places yet",
                   message: "Save Home, Work or favorite spots to plan shady walks in one tap.",
                   actionTitle: "Search places") {}
        .background(Theme.canvas)
}
#endif
