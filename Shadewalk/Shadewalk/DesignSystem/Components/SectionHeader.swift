import SwiftUI

/// Section title with an optional leading icon and trailing text action ("Cool spots · Show all").
struct SectionHeader: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?

    init(_ title: LocalizedStringKey, systemImage: String? = nil, actionTitle: LocalizedStringKey? = nil,
         action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.shade)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.shade)
            }
        }
    }
}
