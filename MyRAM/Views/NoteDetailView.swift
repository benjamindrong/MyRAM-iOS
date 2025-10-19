//
//  NoteDetailView.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import SwiftUI

struct NoteDetailView: View {
    let note: Note

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(note.title)
                    .font(.title2)
                    .bold()
                Text(note.content)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Note Detail")
    }
}
