import SwiftUI

/// Surface card: 20 pt continuous corners, `surface` fill, soft shadow.
struct ShadewalkCardModifier: ViewModifier {
    var padding: CGFloat
    var fillsWidth: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: fillsWidth ? CGFloat.infinity : nil, alignment: .leading)
            .background(Theme.surface, in: Theme.cardShape)
            .overlay {
                Theme.cardShape.strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 6)
    }
}

extension View {
    /// Wraps the view in a Shadewalk card. `fillsWidth` stretches it to the available width (leading-aligned).
    func shadewalkCard(padding: CGFloat = Theme.cardPadding, fillsWidth: Bool = true) -> some View {
        modifier(ShadewalkCardModifier(padding: padding, fillsWidth: fillsWidth))
    }
}
