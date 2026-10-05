import ShadeFeatures
import SwiftUI

// MARK: - Search capsule

/// Floating "Where to?" field that opens place search.
struct WalkSearchCapsule: View {
    private let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 52

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.shade)
                Text("Where to?")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Image(systemName: "figure.walk")
                    .font(.body)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: height)
            .background(Theme.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Where to?"))
        .accessibilityHint(Text("Search for a destination"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Weather pill

/// Sky, temperature, feels-like and UV index for the area (from `WeatherModel`).
///
/// Picks the widest layout that fits: everything on one line; then "Feels like" shortened to a thermometer glyph;
/// then two lines. The UV band name (the safety information) is never truncated. VoiceOver reads the sky in words and
/// every value.
struct WeatherPill: View {
    @Environment(WeatherModel.self) private var weather
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if let snapshot = weather.current {
            pill(for: snapshot)
        } else if weather.state.isLoading {
            loading
        }
    }

    private func pill(for snapshot: WeatherSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            chrome(Capsule()) {
                HStack(spacing: 8) {
                    skyAndTemperature(snapshot)
                    feelsLikeText(snapshot)
                    uvBadge(snapshot)
                }
                .lineLimit(1)
            }
            chrome(Capsule()) {
                HStack(spacing: 8) {
                    skyAndTemperature(snapshot)
                    feelsLikeGlyph(snapshot)
                    uvBadge(snapshot)
                }
                .lineLimit(1)
            }
            chrome(Theme.controlShape) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        skyAndTemperature(snapshot)
                        feelsLikeGlyph(snapshot)
                    }
                    uvBadge(snapshot)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: snapshot.walkSkyDescription))
        .accessibilityValue(Text(verbatim: accessibilityValue(for: snapshot)))
    }

    private func chrome<ChromeShape: InsettableShape, Content: View>(_ shape: ChromeShape,
                                                                     @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
    }

    private func skyAndTemperature(_ snapshot: WeatherSnapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot.walkSymbolName)
                .symbolRenderingMode(.multicolor)
            Text(verbatim: temperature(snapshot.temperature))
                .font(.metricSmall)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func feelsLikeText(_ snapshot: WeatherSnapshot) -> some View {
        if let feelsLike = snapshot.apparentTemperature {
            Text("Feels like \(temperature(feelsLike, showsUnit: false))")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    /// Compact feels-like: thermometer glyph and value.
    @ViewBuilder
    private func feelsLikeGlyph(_ snapshot: WeatherSnapshot) -> some View {
        if let feelsLike = snapshot.apparentTemperature {
            HStack(spacing: 2) {
                Image(systemName: "thermometer.medium")
                Text(verbatim: temperature(feelsLike, showsUnit: false))
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.inkSecondary)
        }
    }

    @ViewBuilder
    private func uvBadge(_ snapshot: WeatherSnapshot) -> some View {
        if let uvIndex = snapshot.uvIndex {
            uvBadge(index: Formatters.uvIndex(uvIndex))
        }
    }

    /// Coloured dot, "UV 8" and the band name ("Very high"): the band is spelled out, never shown by colour alone.
    private func uvBadge(index: Int) -> some View {
        let level = WalkUVLevel(index: index)
        return HStack(spacing: 4) {
            Circle()
                .fill(level.tint)
                .frame(width: 8, height: 8)
            Text("UV \(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(verbatim: level.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
    }

    /// "31°, Feels like 33°, UV 8, Very high".
    private func accessibilityValue(for snapshot: WeatherSnapshot) -> String {
        var parts = [temperature(snapshot.temperature)]
        if let feelsLike = snapshot.apparentTemperature {
            parts.append(String(localized: "Feels like \(temperature(feelsLike, showsUnit: false))",
                                comment: "Weather pill: apparent temperature, e.g. “Feels like 33°”."))
        }
        if let uvIndex = snapshot.uvIndex {
            let index = Formatters.uvIndex(uvIndex)
            parts.append(String(localized: "UV \(index)", comment: "UV index, e.g. “UV 7”."))
            parts.append(WalkUVLevel(index: index).displayName)
        }
        return parts.formatted(.list(type: .and, width: .narrow))
    }

    private func temperature(_ value: Double, showsUnit: Bool = true) -> String {
        Formatters.temperature(value, units: settings.units, showsUnit: showsUnit)
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Checking the weather…")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Route header

/// From / To card shown while planning: both rows open place search, plus swap and close.
struct RouteHeaderCard: View {
    let origin: Place?
    let destination: Place
    /// Waiting for the first location fix to use as the start.
    var isLocating: Bool = false
    let onEditOrigin: () -> Void
    let onEditDestination: () -> Void
    let onSwap: () -> Void
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var markerSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 36

    init(origin: Place?, destination: Place, isLocating: Bool = false, onEditOrigin: @escaping () -> Void,
         onEditDestination: @escaping () -> Void, onSwap: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.origin = origin
        self.destination = destination
        self.isLocating = isLocating
        self.onEditOrigin = onEditOrigin
        self.onEditDestination = onEditDestination
        self.onSwap = onSwap
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                originRow
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.leading, markerSize + 12)
                destinationRow
            }
            VStack(spacing: 0) {
                circleButton(systemImage: "xmark", action: onClose)
                    .accessibilityLabel(Text("Close route"))
                circleButton(systemImage: "arrow.up.arrow.down", action: onSwap)
                    .accessibilityLabel(Text("Swap start and destination"))
                    .disabled(origin == nil)
            }
        }
        .shadewalkCard(padding: 10)
    }

    // MARK: Rows

    private var originRow: some View {
        Button(action: onEditOrigin) {
            HStack(spacing: 12) {
                originMarker
                VStack(alignment: .leading, spacing: 1) {
                    Text("From")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .textCase(.uppercase)
                    originTitle
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(originAccessibilityLabel)
        .accessibilityHint(Text("Choose a different starting point"))
        .accessibilityAddTraits(.isButton)
    }

    private var destinationRow: some View {
        Button(action: onEditDestination) {
            HStack(spacing: 12) {
                Image(systemName: "flag.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.onShade)
                    .frame(width: markerSize, height: markerSize)
                    .background(Theme.shade, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("To")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .textCase(.uppercase)
                    Text(verbatim: destination.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("To: \(destination.displayName)"))
        .accessibilityHint(Text("Choose a different destination"))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var originMarker: some View {
        if let origin, origin.kind == .currentLocation {
            Image(systemName: "location.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.locator)
                .frame(width: markerSize, height: markerSize)
                .background(Theme.locator.opacity(0.14), in: Circle())
        } else {
            Circle()
                .strokeBorder(Theme.shade, lineWidth: 3)
                .background {
                    Circle().fill(Theme.surface)
                }
                .frame(width: markerSize * 0.55, height: markerSize * 0.55)
                .frame(width: markerSize, height: markerSize)
        }
    }

    @ViewBuilder
    private var originTitle: some View {
        if let origin {
            Text(verbatim: origin.displayName)
                .foregroundStyle(Theme.ink)
        } else if isLocating {
            Text("Finding your location…")
                .foregroundStyle(Theme.inkSecondary)
        } else {
            Text("Choose a starting point")
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var originAccessibilityLabel: Text {
        if let origin {
            return Text("From: \(origin.displayName)")
        }
        if isLocating {
            return Text("From: finding your location")
        }
        return Text("From: choose a starting point")
    }

    /// A 36 pt circle with a 44 pt touch area.
    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.ink)
                .frame(width: buttonSize, height: buttonSize)
                .background(Theme.hairline, in: Circle())
                .frame(width: max(44, buttonSize), height: max(44, buttonSize))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
/// Loads the preview forecast so the pill has something to show.
private struct WeatherPillPreviewHost: View {
    @Environment(WeatherModel.self) private var weather

    var body: some View {
        WeatherPill()
            .task { await weather.load(at: PreviewData.downtown) }
    }
}

#Preview("Walk top bar") {
    VStack(spacing: 12) {
        WalkSearchCapsule {}
        HStack {
            WeatherPillPreviewHost()
            Spacer()
        }
        RouteHeaderCard(origin: Place.localizedCurrentLocation(PreviewData.downtown),
                        destination: PreviewData.destinationPlace,
                        onEditOrigin: {}, onEditDestination: {}, onSwap: {}, onClose: {})
        RouteHeaderCard(origin: nil, destination: PreviewData.destinationPlace, isLocating: true,
                        onEditOrigin: {}, onEditDestination: {}, onSwap: {}, onClose: {})
    }
    .padding()
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
