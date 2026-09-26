import SwiftUI

/// Tab shell plus the persistent review bar.
struct RootView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection

    @State private var tab: Tab = .home
    @State private var showingReview = false
    @State private var outcome: CleanupOutcome?

    enum Tab: Hashable { case home, photos, videos, contacts }

    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else {
                shell
            }
        }
        .animation(Theme.Motion.standard, value: model.needsOnboarding)
    }

    private var shell: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tab) {
                NavigationStack {
                    DashboardView(onOpenCategory: { category in
                        tab = destination(for: category)
                    })
                }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

                NavigationStack { PhotosHubView() }
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle.angled") }
                    .tag(Tab.photos)

                NavigationStack { LargeVideosView() }
                    .tabItem { Label("Videos", systemImage: "film.stack") }
                    .tag(Tab.videos)

                NavigationStack { DuplicateContactsView() }
                    .tabItem { Label("Contacts", systemImage: "person.2") }
                    .tag(Tab.contacts)
            }

            // Persistent entry point to Review whenever anything is selected.
            if selection.hasSelection {
                ReviewBar { showingReview = true }
                    .padding(.horizontal, Theme.Space.md)
                    // Clear the tab bar so the bar never obscures it.
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.standard, value: selection.hasSelection)
        .sheet(isPresented: $showingReview) {
            ReviewView { finished in
                outcome = finished
                showingReview = false
            }
        }
        .fullScreenCover(item: $outcome) { finished in
            CleanupCompleteView(outcome: finished) { outcome = nil }
        }
        .task {
            model.startObservingLibrary()
            if model.results.isEmpty && !model.isScanning {
                await model.runScan()
                selection.reconcile(with: model.results)
            }
        }
    }

    private func destination(for category: CleanupCategory) -> Tab {
        switch category {
        case .similarPhotos, .screenshots: return .photos
        case .largeVideos:                 return .videos
        case .duplicateContacts:           return .contacts
        }
    }
}

extension CleanupOutcome: Identifiable {
    // Stable within a presentation; a new outcome always replaces the old one.
    var id: String {
        "\(totalItemsRemoved)-\(bytesReclaimed)-\(failures.count)-\(wasCancelledByUser)"
    }
}
