import ShadeFeatures
import SwiftUI

/// Seat side tab (SPEC F8): which side of a bus, tram or train stays out of the sun.
///
/// The inputs live in `SeatSideModel`; changing any of them clears the previous advice, so the result on screen always
/// matches the trip above it. "Now" keeps the departure pinned to the current time until the user picks a time.
struct SeatSideView: View {
    @Environment(SeatSideModel.self) private var seatSide
    @Environment(LocationModel.self) private var location
    @Environment(\.scenePhase) private var scenePhase

    @State private var editingEnd: SeatSideTripEnd?
    /// The departure follows the clock until the user picks a time.
    @State private var followsNow = true

    /// A "now" departure older than this moves to the current time when the screen shows again.
    private static let staleNowInterval: TimeInterval = 10 * 60
    /// A "now" departure older than this moves to the current time before computing.
    private static let computeNowTolerance: TimeInterval = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing + 4) {
                    Text("Find the side of the bus, tram or train that stays out of the sun.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SeatSideTripForm(editingEnd: $editingEnd, followsNow: $followsNow)
                    findButton
                    result
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .motionAwareAnimation(value: seatSide.state)
            }
            .background(Theme.canvas)
            .navigationTitle("Seat side")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $editingEnd) { end in
                placeSearch(for: end)
            }
        }
        .onAppear {
            prepare()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshNowIfStale() }
        }
    }

    // MARK: - Find

    private var findButton: some View {
        VStack(spacing: 8) {
            Button {
                compute()
            } label: {
                Label("Find the shady side", systemImage: "sun.max.fill")
            }
            .buttonStyle(.shadewalkPrimary)
            .disabled(!seatSide.canCompute || seatSide.state.isLoading)
            if !seatSide.canCompute {
                Text("Choose where you get on and off.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Result

    @ViewBuilder
    private var result: some View {
        switch seatSide.state {
        case .idle:
            SeatSideExplainerCard(vehicle: seatSide.vehicle)
                .transition(.opacity)
        case .loading:
            LoadingCard("Following the sun along your trip…")
                .transition(.opacity)
        case let .loaded(advice):
            SeatSideResultView(advice: advice,
                               vehicle: seatSide.vehicle,
                               path: seatSide.path,
                               tripDuration: seatSide.tripDuration ?? advice.duration,
                               cloudCover: seatSide.cloudCover)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        case .failed:
            errorCard
                .transition(.opacity)
        }
    }

    private var errorCard: some View {
        ErrorCard(message: seatSide.state.localizedErrorMessage
                    ?? String(localized: "Something went wrong. Please try again.", comment: "Generic error message."),
                  systemImage: seatSide.state.shadeError?.systemImage ?? "exclamationmark.triangle.fill",
                  retry: seatSide.state.isRetryableFailure ? retryAction : nil)
    }

    private var retryAction: () -> Void {
        return { compute() }
    }

    // MARK: - Place search

    private func placeSearch(for end: SeatSideTripEnd) -> some View {
        PlaceSearchView(title: end.searchTitle, prompt: "Search for a stop, place or address",
                        allowsCurrentLocation: true) { place in
            switch end {
            case .from: seatSide.from = place
            case .to: seatSide.to = place
            }
        }
    }

    // MARK: - Actions

    /// Starts from the user's location when nothing is set yet, and keeps a "now" departure current.
    private func prepare() {
        if seatSide.from == nil, let coordinate = location.currentCoordinate() {
            seatSide.from = Place.localizedCurrentLocation(coordinate)
        }
        refreshNowIfStale()
    }

    private func refreshNowIfStale() {
        guard followsNow, abs(seatSide.departure.timeIntervalSinceNow) > Self.staleNowInterval else { return }
        seatSide.departure = Date()
    }

    private func compute() {
        if followsNow, abs(seatSide.departure.timeIntervalSinceNow) > Self.computeNowTolerance {
            seatSide.departure = Date()
        }
        Task { await seatSide.compute() }
    }
}

#if DEBUG
/// Preview wiring for the Seat side screen.
private enum SeatSidePreviewSupport {
    /// Both ends set (idle until "Find the shady side" is tapped).
    @MainActor
    static func tripEnvironment() -> AppEnvironment {
        let environment = AppEnvironment.preview()
        environment.seatSide.from = PreviewData.originPlace
        environment.seatSide.to = PreviewData.places[3]
        environment.seatSide.vehicle = .tram
        return environment
    }
}

#Preview("Seat side") {
    SeatSideView()
        .previewEnvironment()
}

#Preview("Seat side – trip set") {
    SeatSideView()
        .previewEnvironment(SeatSidePreviewSupport.tripEnvironment())
}
#endif
