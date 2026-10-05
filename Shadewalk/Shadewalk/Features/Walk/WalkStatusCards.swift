import ShadeFeatures
import SwiftUI

/// One-line information card with an icon ("The sun is down — every route is in the shade.").
struct WalkInfoBanner: View {
    private let systemImage: String
    private let message: LocalizedStringKey
    private let tint: Color

    init(systemImage: String, message: LocalizedStringKey, tint: Color = Theme.shade) {
        self.systemImage = systemImage
        self.message = message
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: Theme.controlShape)
        .overlay {
            Theme.controlShape.strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Explains why walks can't start from the user's position and offers the fix.
struct WalkLocationCard: View {
    enum Reason: Hashable {
        /// The user hasn't been asked yet.
        case notDetermined
        /// Denied or restricted: only Settings can change it.
        case denied
    }

    let reason: Reason
    let onAllow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: reason == .denied ? "location.slash.fill" : "location.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.shade)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .font(.sectionTitle)
                        .foregroundStyle(Theme.ink)
                    message
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            actionButton
        }
        .shadewalkCard()
    }

    private var title: Text {
        switch reason {
        case .notDetermined: return Text("Start from where you are")
        case .denied: return Text("Location is off")
        }
    }

    private var message: Text {
        switch reason {
        case .notDetermined:
            return Text("Share your location to start shady walks from here, or choose a starting point above.")
        case .denied:
            return Text("Turn on location access in Settings to start walks from where you are, or choose a starting point.")
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch reason {
        case .notDetermined:
            Button(action: onAllow) {
                Label("Use my location", systemImage: "location.fill")
            }
            .buttonStyle(.shadewalkSecondary)
        case .denied:
            Button(action: onOpenSettings) {
                Label("Open Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.shadewalkSecondary)
        }
    }
}

/// Placeholder shaped like a route card while routes are computed.
struct RouteSkeletonCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.shade)
                Text("Reading the shadows…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 10) {
                bone(width: 150, height: 26)
                bone(width: 190, height: 12)
                Capsule()
                    .fill(Theme.hairline)
                    .frame(height: 10)
                HStack(spacing: 6) {
                    bone(width: 84, height: 24, capsule: true)
                    bone(width: 70, height: 24, capsule: true)
                    bone(width: 92, height: 24, capsule: true)
                }
            }
            .opacity(isPulsing ? 0.45 : 1)
            .accessibilityHidden(true)
        }
        .shadewalkCard()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private func bone(width: CGFloat, height: CGFloat, capsule: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: capsule ? height / 2 : 6, style: .continuous)
            .fill(Theme.hairline)
            .frame(width: width, height: height)
    }
}

#if DEBUG
#Preview("Walk status cards") {
    ScrollView {
        VStack(spacing: 12) {
            WalkInfoBanner(systemImage: "moon.stars.fill", message: "The sun is down — every route is in the shade.")
            WalkLocationCard(reason: .denied, onAllow: {}, onOpenSettings: {})
            WalkLocationCard(reason: .notDetermined, onAllow: {}, onOpenSettings: {})
            RouteSkeletonCard()
        }
        .padding()
    }
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
