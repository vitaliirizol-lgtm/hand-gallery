import ShadeFeatures
import SwiftUI
import UIKit

/// Onboarding pages, in order.
enum OnboardingPage: Int, CaseIterable, Identifiable, Hashable {
    case concept, howItWorks, location

    var id: Int { rawValue }
}

/// Three-page introduction (SPEC F11): the idea, how the shade is worked out, and location permission.
///
/// Pages swipe (TabView, page style) with Shadewalk-tinted page dots underneath; the buttons stay put below. Finishing
/// sets `SettingsStore.hasCompletedOnboarding`, which makes `RootView` show the tabs. "Allow location" asks for
/// permission and finishes once the user has answered the system prompt.
struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LocationModel.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var page: OnboardingPage = .concept
    /// "Allow location" was tapped; finish once the permission is decided.
    @State private var isAwaitingPermission = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                OnboardingConceptPage()
                    .tag(OnboardingPage.concept)
                OnboardingHowItWorksPage(isCurrent: page == .howItWorks)
                    .tag(OnboardingPage.howItWorks)
                OnboardingLocationPage(isCurrent: page == .location)
                    .tag(OnboardingPage.location)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            OnboardingPageDots(current: page)
                .padding(.top, 8)
                .padding(.bottom, 16)
            VStack(spacing: 6) {
                primaryButton
                secondaryButton
            }
            .padding(.horizontal, Theme.screenPadding + 8)
            .padding(.bottom, 8)
        }
        .background(Theme.canvas)
        .onChange(of: location.authorization) { _, authorization in
            if isAwaitingPermission, authorization != .notDetermined {
                finish()
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var primaryButton: some View {
        switch page {
        case .concept, .howItWorks:
            Button {
                advance()
            } label: {
                Text("Continue")
            }
            .buttonStyle(.shadewalkPrimary)
        case .location:
            if location.isAuthorized {
                Button {
                    finish()
                } label: {
                    Text("Start walking")
                }
                .buttonStyle(.shadewalkPrimary)
            } else if location.canRequestAuthorization {
                Button {
                    allowLocation()
                } label: {
                    Label("Allow location", systemImage: "location.fill")
                }
                .buttonStyle(.shadewalkPrimary)
            } else {
                Button {
                    finish()
                } label: {
                    Text("Continue without location")
                }
                .buttonStyle(.shadewalkPrimary)
            }
        }
    }

    /// Always present (hidden when unused) so the pages above don't change height.
    @ViewBuilder
    private var secondaryButton: some View {
        switch page {
        case .concept, .howItWorks:
            textButton("Skip") {
                skip()
            }
        case .location:
            if location.isAuthorized {
                textButton("Not now") {}
                    .hidden()
            } else if location.canRequestAuthorization {
                textButton("Not now") {
                    finish()
                }
            } else {
                textButton("Open Settings") {
                    openSystemSettings()
                }
            }
        }
    }

    private func textButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func advance() {
        guard let next = OnboardingPage(rawValue: page.rawValue + 1) else { return }
        withMotionAwareAnimation(reduceMotion: reduceMotion) {
            page = next
        }
    }

    /// Skips the explanations, not the permission page (which has its own "Not now").
    private func skip() {
        withMotionAwareAnimation(reduceMotion: reduceMotion) {
            page = .location
        }
    }

    private func allowLocation() {
        isAwaitingPermission = true
        location.requestAuthorization()
        // Already decided (or answered synchronously): nothing to wait for.
        if !location.canRequestAuthorization {
            finish()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func finish() {
        isAwaitingPermission = false
        settings.hasCompletedOnboarding = true
    }
}

// MARK: - Pages

/// Illustration, title and message, scrolling when the text is large.
private struct OnboardingPageLayout<Illustration: View, Extra: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let illustration: Illustration
    let extra: Extra

    init(title: LocalizedStringKey, message: LocalizedStringKey, @ViewBuilder illustration: () -> Illustration,
         @ViewBuilder extra: () -> Extra) {
        self.title = title
        self.message = message
        self.illustration = illustration()
        self.extra = extra()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                illustration
                    .frame(maxWidth: 380)
                    .frame(height: 250)
                VStack(spacing: 12) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.body)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                extra
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct OnboardingConceptPage: View {
    var body: some View {
        OnboardingPageLayout(
            title: "Walk in the shade",
            message: "Shadewalk plans walking routes that keep you out of the hot sun, without sending you on long detours.") {
            OnboardingConceptIllustration()
        } extra: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    legend
                }
                VStack(spacing: 8) {
                    legend
                }
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        ChipView("Shady stretches", systemImage: "leaf.fill")
        ChipView("Sunny stretches", systemImage: "sun.max.fill", tint: Theme.sun)
    }
}

private struct OnboardingHowItWorksPage: View {
    let isCurrent: Bool

    var body: some View {
        OnboardingPageLayout(
            title: "How it works",
            message: "For the moment you leave, Shadewalk works out where the sun will be and lets buildings and trees cast their shadows across the streets. Then it finds the shadiest way through.") {
            OnboardingShadowIllustration(isActive: isCurrent)
        } extra: {
            VStack(alignment: .leading, spacing: 14) {
                ingredient(systemImage: "sun.max.fill", tint: Theme.sun,
                           text: "The sun’s position for the minute you set off")
                ingredient(systemImage: "building.2.fill", tint: Theme.inkSecondary,
                           text: "Building heights from OpenStreetMap")
                ingredient(systemImage: "tree.fill", tint: Theme.shade,
                           text: "Trees, parks and covered walkways")
            }
            .frame(maxWidth: 380, alignment: .leading)
        }
    }

    private func ingredient(systemImage: String, tint: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct OnboardingLocationPage: View {
    let isCurrent: Bool

    @Environment(LocationModel.self) private var location

    var body: some View {
        OnboardingPageLayout(title: "Start from where you are", message: message) {
            OnboardingLocationIllustration(isActive: isCurrent)
        } extra: {
            ChipView("No account, no tracking", systemImage: "hand.raised.fill")
        }
    }

    private var message: LocalizedStringKey {
        switch location.authorization {
        case .authorized:
            return "Location is on. Your walks will start right where you are."
        case .notDetermined:
            return "Allow location so routes start where you are and you can follow along as you walk. It’s only used to plan and guide your walks."
        case .denied, .restricted:
            return "Location is off. You can still search for a starting point, or turn location on in Settings at any time."
        }
    }
}

// MARK: - Page dots

/// Shadewalk-tinted page indicator: the current page is a longer green capsule.
private struct OnboardingPageDots: View {
    let current: OnboardingPage

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { page in
                Capsule()
                    .fill(page == current ? Theme.shade : Theme.inkSecondary.opacity(0.3))
                    .frame(width: page == current ? 22 : 8, height: 8)
            }
        }
        .motionAwareAnimation(Theme.quickSpring, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page \(current.rawValue + 1) of \(OnboardingPage.allCases.count)"))
    }
}

#if DEBUG
private enum OnboardingPreviewSupport {
    /// Fresh install: location not asked yet.
    @MainActor
    static func freshEnvironment() -> AppEnvironment {
        AppEnvironment(store: InMemoryKeyValueStore(),
                       routePlanning: FakeRoutePlanner(),
                       overlayProvider: FakeOverlayProvider(),
                       coolSpotProvider: FakeCoolSpots(),
                       weatherProvider: FakeWeather(),
                       drivingPaths: FakeDrivingPaths(),
                       locationProvider: FakeLocationProvider(authorization: .notDetermined, coordinate: nil),
                       placeSearch: FakePlaceSearch(),
                       now: { PreviewData.referenceDate },
                       timeZone: PreviewData.timeZone)
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .previewEnvironment(OnboardingPreviewSupport.freshEnvironment())
}

#Preview("Onboarding – location on") {
    OnboardingView()
        .previewEnvironment(AppEnvironment.preview(onboarded: false))
}
#endif
