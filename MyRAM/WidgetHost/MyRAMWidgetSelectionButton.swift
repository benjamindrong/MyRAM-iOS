import SwiftUI

struct MyRAMWidgetSelectionButton: View {
    @ObservedObject var coordinator: MyRAMWidgetHostCoordinator
    let noteID: UUID

    var body: some View {
        if coordinator.isSelected(noteID: noteID) {
            Button {
                coordinator.removeSelection()
            } label: {
                Label("Remove from Widget", systemImage: "rectangle.badge.xmark")
            }
        } else {
            Button {
                coordinator.select(noteID: noteID)
            } label: {
                Label("Use in Widget", systemImage: "rectangle.badge.checkmark")
            }
        }
    }
}
