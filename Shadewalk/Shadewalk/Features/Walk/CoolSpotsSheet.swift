import ShadeFeatures
import SwiftUI

/// Cool spots nearby (water, cool interiors, shelters, parks), nearest first and grouped by kind. Filter chips switch
/// kinds on and off (shared with the map layer); picking a spot plans a shady walk there.
///
/// Loads around the user's position, else around `center` (the visible map area). With neither, it asks to zoom in.
struct CoolSpotsSheet: View {
    private let center: GeoCoordinate?
    private let onPlanRoute: (CoolSpot) -> Void

    @Environment(CoolSpotsModel.self) private var coolSpots
    @Environment(LocationModel.self) private var location
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - center: where to look without a current fix (e.g. the centre of a local map area); nil for none.
    ///   - onPlanRoute: receives the chosen spot (before the sheet dismisses).
    init(center: GeoCoordinate? = nil, onPlanRoute: @escaping (CoolSpot) -> Void) {
        self.center = center
        self.onPlanRoute = onPlanRoute
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filters
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                content
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle("Cool spots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadIfNeeded()
            }
        }
    }

    // MARK: - Filters

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(CoolSpotKind.allCases, id: \.self) { kind in
                    FilterChip(title: chipTitle(for: kind), systemImage: kind.systemImage,
                               isSelected: coolSpots.isShowing(kind), tint: kind.tint) {
                        coolSpots.toggle(kind)
                    }
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private func chipTitle(for kind: CoolSpotKind) -> String {
        guard coolSpots.state.value != nil else { return kind.displayName }
        return String(localized: "\(kind.displayName) · \(coolSpots.count(of: kind))",
                      comment: "Cool-spot filter chip: kind and number of spots, e.g. “Park · 3”.")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch coolSpots.state {
        case .idle:
            if !coolSpots.allItems.isEmpty {
                groupedSections
            } else if loadCenter != nil {
                // `.task` starts the load right away.
                loadingSection
            } else {
                emptySection(title: "Zoom in on the map",
                             message: "Cool spots are found for the area you see. Zoom in a little, then open this list again.")
            }
        case .loading:
            if coolSpots.allItems.isEmpty {
                loadingSection
            } else {
                groupedSections
            }
        case .failed:
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(verbatim: coolSpots.state.localizedErrorMessage ?? ErrorText.message(for: ShadeError.networkUnavailable))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.heat)
                    }
                    .font(.subheadline)
                    Button {
                        retry()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.shade)
                }
                .listRowBackground(Theme.surface)
            }
        case .loaded:
            if coolSpots.allItems.isEmpty {
                emptySection(title: "No cool spots nearby",
                             message: "Move the map to look around another area.")
            } else if coolSpots.items.isEmpty {
                emptySection(title: "Nothing matches these filters",
                             message: "Turn on more kinds of cool spots above.")
            } else {
                groupedSections
            }
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.shade)
                Text("Finding cool spots…")
                    .foregroundStyle(Theme.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            .listRowBackground(Theme.surface)
        }
    }

    private var groupedSections: some View {
        ForEach(visibleKinds, id: \.self) { kind in
            Section {
                ForEach(coolSpots.items.filter { $0.spot.kind == kind }) { item in
                    row(item)
                }
            } header: {
                Label {
                    Text(verbatim: kind.displayName)
                } icon: {
                    Image(systemName: kind.systemImage)
                        .foregroundStyle(kind.tint)
                }
            }
        }
    }

    private var visibleKinds: [CoolSpotKind] {
        CoolSpotKind.allCases.filter { kind in coolSpots.items.contains { $0.spot.kind == kind } }
    }

    private func row(_ item: CoolSpotItem) -> some View {
        Button {
            onPlanRoute(item.spot)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                PlaceRow(title: item.spot.displayName, subtitle: openingHoursText(for: item.spot),
                         systemImage: item.spot.kind.systemImage, tint: item.spot.kind.tint,
                         detail: Formatters.distance(item.distance, units: settings.units))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .accessibilityHint(Text("Plans a shady walk there"))
    }

    /// The raw OSM `opening_hours` syntax isn't readable (nor localized), so only "always open" is shown.
    private func openingHoursText(for spot: CoolSpot) -> String? {
        guard spot.openingHours?.trimmingCharacters(in: .whitespacesAndNewlines) == "24/7" else { return nil }
        return String(localized: "Open 24 hours", comment: "Cool spot that never closes.")
    }

    private func emptySection(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        Section {
            EmptyStateView(systemImage: "thermometer.snowflake", title: title, message: message)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Loading

    /// Where to look: the user's current position, else the visible map area.
    private var loadCenter: GeoCoordinate? {
        location.currentCoordinate() ?? center
    }

    private func loadIfNeeded() async {
        guard coolSpots.state.isIdle, let target = loadCenter else { return }
        await coolSpots.load(near: target)
    }

    private func retry() {
        guard let coordinate = coolSpots.reference ?? loadCenter else { return }
        Task {
            await coolSpots.load(near: coordinate)
        }
    }
}

#if DEBUG
#Preview("Cool spots") {
    CoolSpotsSheet { _ in }
        .previewEnvironment()
}
#endif
