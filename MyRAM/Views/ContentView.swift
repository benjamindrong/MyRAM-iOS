//
//  ContentView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/18/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var state: NotesListState

    @MainActor
    init() {
        let state = NotesListState(context: PersistenceManager.shared.context)
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
        NotesListView(state: state)
    }
}
