//
//  ContentView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/18/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        NotesListView(context: context)
    }
}
