//
//  ContentView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/18/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var state = NotesListState(context: PersistenceManager.shared.context)

    var body: some View {
        NotesListView(state: state)
    }
}
