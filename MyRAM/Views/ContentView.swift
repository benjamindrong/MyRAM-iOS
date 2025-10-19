//
//  ContentView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/18/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Query private var folders: [Folder]
    @State private var selectedFolder: Folder?
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFolder) {
                ForEach(folders) { folder in
                    NavigationLink(folder.name, value: folder)
                }
                .onDelete(perform: deleteFolders)
            }
            .navigationTitle("Folders")
            .toolbar {
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
            }
        } detail: {
            if let folder = selectedFolder {
                NotesListView(vm: NotesViewModel(folder: folder))
            } else {
                Text("Select a folder")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addFolder() {
        let folder = Folder(name: "New Folder")
        context.insert(folder)
        try? context.save()
    }

    private func deleteFolders(at offsets: IndexSet) {
        offsets.map { folders[$0] }.forEach(context.delete)
        try? context.save()
    }
}
