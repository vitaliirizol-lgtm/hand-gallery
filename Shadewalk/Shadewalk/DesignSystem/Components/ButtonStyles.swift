import SwiftUI

/// Full-width filled button (Start, Get started). Use `.buttonStyle(.shadewalkPrimary)`.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.shade

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, tint: tint)
    }
}

/// Full-width soft button (Save, Try again): label on a faint `tint` fill. Use `.buttonStyle(.shadewalkSecondary)`.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.shade
    /// Label colour; nil uses `tint`. Pass the tint's readable variant (`Theme.shadeInk`, `Theme.heatInk`) so the
    /// label keeps at least 4.5:1 against the tinted fill.
    var labelColor: Color?

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration, tint: tint, labelColor: labelColor ?? tint)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var shadewalkPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var shadewalkSecondary: SecondaryButtonStyle {
        SecondaryButtonStyle(tint: Theme.shade, labelColor: Theme.shadeInk)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onShade)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(isEnabled ? 1 : 0.4), in: Theme.controlShape)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : Theme.quickSpring, value: configuration.isPressed)
            .contentShape(Theme.controlShape)
    }
}

private struct SecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let labelColor: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(labelColor)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(tint.opacity(0.14), in: Theme.controlShape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : Theme.quickSpring, value: configuration.isPressed)
            .contentShape(Theme.controlShape)
    }
}

#if DEBUG
#Preview("Buttons") {
    VStack(spacing: 12) {
        Button("Start") {}
            .buttonStyle(.shadewalkPrimary)
        Button("Save") {}
            .buttonStyle(.shadewalkSecondary)
        Button("Disabled") {}
            .buttonStyle(.shadewalkPrimary)
            .disabled(true)
    }
    .padding()
    .background(Theme.canvas)
}
#endif
