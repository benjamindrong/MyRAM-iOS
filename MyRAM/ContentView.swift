import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var state: NotesListState
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init(state: NotesListState) {
        _state = StateObject(wrappedValue: state)
        let viewModel = state.viewModel
        NoteEditorLifecycleDurabilityRegistry.shared.install(
            waitForDurability: { [weak viewModel] noteID in
                guard let viewModel else { return false }
                return await viewModel.awaitEditorLifecyclePersistence(noteID: noteID)
            },
            retryRetained: { [weak viewModel] in
                viewModel?.retryAllEditorLifecyclePersistence()
            }
        )
    }

    var body: some View {
        Group {
            if state.bootstrapState == .ready {
                NotesListView(state: state)
            } else {
                bootstrapStatusView
            }
        }
        .task {
            await state.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            state.handleScenePhase(newPhase)
        }
    }

    @ViewBuilder
    private var bootstrapStatusView: some View {
        switch state.bootstrapState {
        case .initializing:
            ProgressView("Opening MyRAM…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Unable to Open MyRAM",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .ready:
            EmptyView()
        }
    }
}
