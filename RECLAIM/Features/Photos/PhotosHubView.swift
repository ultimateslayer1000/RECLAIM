import SwiftUI

/// Photos tab: similar/duplicate groups and screenshots, per §27.
struct PhotosHubView: View {

    @Environment(AppModel.self) private var model
    @Environment(SelectionStore.self) private var selection
    @State private var section: Section = .similar

    enum Section: String, CaseIterable, Identifiable {
        case similar = "Similar"
        case screenshots = "Screenshots"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)

            Group {
                switch section {
                case .similar:     SimilarPhotosView()
                case .screenshots: ScreenshotsView()
                }
            }
        }
        .screenBackground()
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
