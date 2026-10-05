import ShadeFeatures
import SwiftUI
import UIKit

/// Settings tab (SPEC F10): shade preference, walking speed, stairs, units, the default shade overlay, location access,
/// the introduction and "About" with data attribution.
///
/// Every control writes straight into `SettingsStore` (persisted at once). `AppEnvironment` already mirrors the routing
/// preferences into the planner and navigation models; `applySettings()` is called on every change as well so the
/// planner is up to date even before its observation loop runs (it is idempotent).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationModel.self) private var location
    @Environment(\.openURL) private var openURL

    @State private var isConfirmingReset = false

    private static let openStreetMapCopyrightURL = URL(string: "https://www.openstreetmap.org/copyright")
    private static let openMeteoURL = URL(string: "https://open-meteo.com")

    var body: some View {
        NavigationStack {
            Form {
                shadePreferenceSection
                mapAndUnitsSection
                locationSection
                helpSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle("Settings")
            .confirmationDialog("Restore default settings?", isPresented: $isConfirmingReset,
                                titleVisibility: .visible) {
                Button("Restore defaults", role: .destructive) {
                    settings.resetToDefaults()
                }
            } message: {
                Text("Shade preference, walking speed, stairs, units and the shade overlay go back to their defaults. Your saved places stay.")
            }
        }
        .onChange(of: settings.settings) {
            app.applySettings()
        }
    }

    // MARK: - Shade preference

    private var shadePreferenceSection: some View {
        @Bindable var store = settings
        return Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(detourCaption)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(value: $store.maxDetourFraction, in: AppSettings.maxDetourRange, step: 0.05) {
                    Text("Maximum detour")
                } minimumValueLabel: {
                    Image(systemName: "hare.fill")
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(Theme.shade)
                        .accessibilityHidden(true)
                }
                .tint(Theme.shade)
                .sensoryFeedback(.selection, trigger: settings.maxDetourFraction)
                .accessibilityValue(Text(detourAccessibilityValue))
            }
            .padding(.vertical, 6)
            Picker(selection: $store.walkingSpeed) {
                ForEach(WalkingSpeed.allCases) { speed in
                    Label(speed.displayName, systemImage: speed.systemImage)
                        .tag(speed)
                }
            } label: {
                Label("Walking speed", systemImage: "figure.walk")
            }
            Toggle(isOn: $store.avoidStairs) {
                Label("Avoid stairs", systemImage: "figure.stairs")
            }
        } header: {
            Text("Shade preference")
        } footer: {
            Text("Shadier routes can be longer. Shadewalk only suggests one if it’s at most this much longer than the fastest route. Walking speed sets your times; avoiding stairs keeps routes step-free where possible.")
        }
        .listRowBackground(Theme.surface)
    }

    private var detourCaption: LocalizedStringKey {
        guard Formatters.percentValue(settings.maxDetourFraction) > 0 else {
            return "Never walk further for shade"
        }
        let percent = Formatters.percent(settings.maxDetourFraction)
        return "Accept up to \(percent) longer walks for more shade"
    }

    private var detourAccessibilityValue: LocalizedStringKey {
        guard Formatters.percentValue(settings.maxDetourFraction) > 0 else {
            return "No detour"
        }
        let percent = Formatters.percent(settings.maxDetourFraction)
        return "Up to \(percent) longer"
    }

    // MARK: - Map & units

    private var mapAndUnitsSection: some View {
        @Bindable var store = settings
        return Section {
            Picker(selection: $store.units) {
                ForEach(UnitPreference.allCases) { unit in
                    Text(verbatim: unit.displayName)
                        .tag(unit)
                }
            } label: {
                Label("Units", systemImage: "ruler")
            }
            Toggle(isOn: $store.showShadeOverlayByDefault) {
                Label("Show shade overlay by default", systemImage: "square.3.layers.3d")
            }
        } header: {
            Text("Map & units")
        } footer: {
            Text("Automatic units follow your iPhone’s region. The shade overlay setting applies the next time Shadewalk starts.")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Location

    private var locationSection: some View {
        Section {
            LabeledContent {
                Text(locationStatus)
                    .foregroundStyle(Theme.inkSecondary)
            } label: {
                Label {
                    Text("Location access")
                } icon: {
                    Image(systemName: locationStatusSymbol)
                        .foregroundStyle(locationStatusTint)
                }
            }
            if location.canRequestAuthorization {
                Button {
                    location.requestAuthorization()
                } label: {
                    Label("Allow location", systemImage: "location.fill")
                }
            } else {
                Button {
                    openSystemSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text(locationFooter)
        }
        .listRowBackground(Theme.surface)
    }

    private var locationStatus: LocalizedStringKey {
        switch location.authorization {
        case .authorized: return "While using the app"
        case .notDetermined: return "Not set"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        }
    }

    private var locationStatusSymbol: String {
        switch location.authorization {
        case .authorized: return "location.fill"
        case .notDetermined: return "location"
        case .denied, .restricted: return "location.slash.fill"
        }
    }

    private var locationStatusTint: Color {
        switch location.authorization {
        case .authorized: return Theme.shade
        case .notDetermined: return Theme.inkSecondary
        case .denied, .restricted: return Theme.heat
        }
    }

    private var locationFooter: LocalizedStringKey {
        switch location.authorization {
        case .authorized:
            return "Routes start where you are, and follow mode guides you along the way."
        case .notDetermined:
            return "Allow location so routes start where you are and you can follow along as you walk."
        case .denied:
            return "Location is off. You can still search for a starting point, or turn it on in Settings."
        case .restricted:
            return "Location is restricted on this iPhone, for example by Screen Time. You can still search for a starting point."
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            Button {
                settings.hasCompletedOnboarding = false
            } label: {
                Label("Replay introduction", systemImage: "sparkles")
            }
            Button {
                isConfirmingReset = true
            } label: {
                Label("Restore default settings", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Help")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: versionText)
            NavigationLink {
                HowShadeIsCalculatedView()
            } label: {
                Label("How shade is calculated", systemImage: "sun.max")
            }
            if let url = Self.openStreetMapCopyrightURL {
                Link(destination: url) {
                    Label("Map data © OpenStreetMap contributors", systemImage: "map")
                }
            }
            if let url = Self.openMeteoURL {
                Link(destination: url) {
                    Label("Weather & elevation: Open-Meteo", systemImage: "cloud.sun")
                }
            }
            privacyNote
        } header: {
            Text("About")
        } footer: {
            Text("Place search and transit paths use Apple Maps.")
        }
        .listRowBackground(Theme.surface)
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Privacy", systemImage: "hand.raised.fill")
                .font(.body.weight(.semibold))
            Text("Shadewalk has no accounts and no tracking. Saved places and settings stay on this iPhone. To plan a walk, only the area around it is sent to OpenStreetMap’s Overpass service and to Open-Meteo.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "1.0 (1)".
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .previewEnvironment()
}
#endif
