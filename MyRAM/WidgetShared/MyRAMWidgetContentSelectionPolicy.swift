import Foundation

enum MyRAMWidgetFamily: Sendable {
    case small
    case medium
}

struct MyRAMWidgetLayoutPolicy: Equatable, Sendable {
    let contentMarginScale: CGFloat
    let rootSpacing: CGFloat
    let pinSpacing: CGFloat

    init(family _: MyRAMWidgetFamily, platform _: MyRAMWidgetPlatform) {
        contentMarginScale = 0.5
        rootSpacing = 4
        pinSpacing = 4
    }
}

enum MyRAMWidgetPinnedRowPresentationMode: Equatable, Sendable {
    case filled
    case outlined
}

struct MyRAMWidgetPinnedRowPresentationPolicy: Sendable {
    func presentationMode(isFullColor: Bool) -> MyRAMWidgetPinnedRowPresentationMode {
        isFullColor ? .filled : .outlined
    }
}

enum MyRAMWidgetRenderState: Equatable, Sendable {
    case content
    case noSelection
    case emptyNote
    case updateRequired
}

struct MyRAMWidgetRenderModel: Equatable, Sendable {
    let title: String
    let pinnedTexts: [String]
    let bodyText: String?
    let state: MyRAMWidgetRenderState
    let noteURL: URL?

    static let noSelectionMessage = "Choose a note in MyRAM."
    static let emptyNoteMessage = "This note is empty."
    static let updateRequiredMessage = "Open MyRAM to update this widget."
}

struct MyRAMWidgetContentSelectionPolicy: Sendable {
    func renderModel(
        from readResult: MyRAMWidgetSnapshotReadResult,
        family: MyRAMWidgetFamily,
        platform: MyRAMWidgetPlatform
    ) -> MyRAMWidgetRenderModel {
        switch readResult {
        case .snapshot(let envelope):
            return renderModel(from: envelope, family: family, platform: platform)
        case .missing, .inaccessible, .unsupportedVersion, .malformed:
            return stableState(
                .updateRequired,
                message: MyRAMWidgetRenderModel.updateRequiredMessage
            )
        }
    }

    func renderModel(
        from envelope: MyRAMWidgetSnapshotEnvelope,
        family _: MyRAMWidgetFamily,
        platform: MyRAMWidgetPlatform
    ) -> MyRAMWidgetRenderModel {
        guard let note = envelope.note else {
            return stableState(
                .noSelection,
                message: MyRAMWidgetRenderModel.noSelectionMessage
            )
        }

        let pins = note.orderedPinnedTexts.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let body = note.bodyPreviewSource
        let bodyText = body.isEmpty ? nil : body

        if pins.isEmpty, bodyText == nil {
            return MyRAMWidgetRenderModel(
                title: note.title,
                pinnedTexts: [],
                bodyText: MyRAMWidgetRenderModel.emptyNoteMessage,
                state: .emptyNote,
                noteURL: MyRAMWidgetDeepLink.url(noteID: note.id, platform: platform)
            )
        }

        return MyRAMWidgetRenderModel(
            title: note.title,
            pinnedTexts: pins,
            bodyText: bodyText,
            state: .content,
            noteURL: MyRAMWidgetDeepLink.url(noteID: note.id, platform: platform)
        )
    }

    private func stableState(
        _ state: MyRAMWidgetRenderState,
        message: String
    ) -> MyRAMWidgetRenderModel {
        MyRAMWidgetRenderModel(
            title: "",
            pinnedTexts: [],
            bodyText: message,
            state: state,
            noteURL: nil
        )
    }
}
