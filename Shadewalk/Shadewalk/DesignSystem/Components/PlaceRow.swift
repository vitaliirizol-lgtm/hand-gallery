import ShadeFeatures
import SwiftUI

/// List row for a place or suggestion: tinted icon badge, name, subtitle and an optional trailing detail
/// (e.g. a distance).
struct PlaceRow: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let tint: Color
    private let detail: String?

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    init(title: String, subtitle: String?, systemImage: String, tint: Color = Theme.shade, detail: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
    }

    /// Row for a `Place` (icon and tint from its kind).
    init(place: Place, detail: String? = nil) {
        self.init(title: place.displayName, subtitle: place.subtitle, systemImage: place.kind.systemImage,
                  tint: place.kind.tint, detail: detail)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: badgeSize, height: badgeSize)
                .background(tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let detail {
                Text(verbatim: detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
