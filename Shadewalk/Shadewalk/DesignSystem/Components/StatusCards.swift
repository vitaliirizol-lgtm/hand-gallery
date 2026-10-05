import SwiftUI

/// Error message in a card with an optional "Try again" action. `message` is already localized
/// (e.g. `state.localizedErrorMessage` or `ErrorText.message(for:)`).
struct ErrorCard: View {
    private let message: String
    private let systemImage: String
    private let retry: (() -> Void)?

    init(message: String, systemImage: String = "exclamationmark.triangle.fill", retry: (() -> Void)? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.retry = retry
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.heat)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button(action: retry) {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.shade)
                }
            }
            Spacer(minLength: 0)
        }
        .shadewalkCard()
        .accessibilityElement(children: .contain)
    }
}

/// Progress indicator with a caption in a card ("Finding shady routes…").
struct LoadingCard: View {
    private let caption: LocalizedStringKey

    init(_ caption: LocalizedStringKey) {
        self.caption = caption
    }

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Theme.shade)
            Text(caption)
                .font(.subheadline)
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
        }
        .shadewalkCard()
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Status cards") {
    VStack(spacing: 16) {
        LoadingCard("Finding shady routes…")
        ErrorCard(message: "Map data is unavailable right now. Check your connection and try again.") {}
    }
    .padding()
    .background(Theme.canvas)
}
#endif
