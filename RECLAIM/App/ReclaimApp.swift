import SwiftUI

@main
struct ReclaimApp: App {

    @State private var model = AppModel()
    @State private var selection = SelectionStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(selection)
                .tint(Theme.Palette.accent)
                // iPhone-first: the brief scopes iPad and Mac out entirely.
                .preferredColorScheme(nil)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Permissions can change in Settings while the app is backgrounded,
            // so they are re-read on every return to foreground.
            model.refreshPermissions()
            model.refreshStorage()
        }
    }
}
