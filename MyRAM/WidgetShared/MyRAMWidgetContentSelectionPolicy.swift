import Foundation

enum MyRAMWidgetFamily: Sendable {
    case small
    case medium

    var contentLineBudget: Int {
        switch self {
        case .small: 3
        case .medium: 4
        }
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
    let bodyLineLimit: Int
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
                message: MyRAMWidgetRenderModel.updateRequiredMessage,
                bodyLineLimit: family.contentLineBudget
            )
        }
    }

    func renderModel(
        from envelope: MyRAMWidgetSnapshotEnvelope,
        family: MyRAMWidgetFamily,
        platform: MyRAMWidgetPlatform
    ) -> MyRAMWidgetRenderModel {
        guard let note = envelope.note else {
            return stableState(
                .noSelection,
                message: MyRAMWidgetRenderModel.noSelectionMessage,
                bodyLineLimit: family.contentLineBudget
            )
        }

        let pins = note.orderedPinnedTexts.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let body = note.bodyPreviewSource
        let budget = family.contentLineBudget
        let fittingPins = Array(pins.prefix(budget))
        let allPinsFit = fittingPins.count == pins.count
        let remainingLines = allPinsFit ? max(0, budget - fittingPins.count) : 0
        let bodyText = allPinsFit && remainingLines > 0 && !body.isEmpty ? body : nil

        if fittingPins.isEmpty, bodyText == nil {
            return MyRAMWidgetRenderModel(
                title: note.title,
                pinnedTexts: [],
                bodyText: MyRAMWidgetRenderModel.emptyNoteMessage,
                bodyLineLimit: budget,
                state: .emptyNote,
                noteURL: MyRAMWidgetDeepLink.url(noteID: note.id, platform: platform)
            )
        }

        return MyRAMWidgetRenderModel(
            title: note.title,
            pinnedTexts: fittingPins,
            bodyText: bodyText,
            bodyLineLimit: bodyText == nil ? 0 : remainingLines,
            state: .content,
            noteURL: MyRAMWidgetDeepLink.url(noteID: note.id, platform: platform)
        )
    }

    private func stableState(
        _ state: MyRAMWidgetRenderState,
        message: String,
        bodyLineLimit: Int
    ) -> MyRAMWidgetRenderModel {
        MyRAMWidgetRenderModel(
            title: "",
            pinnedTexts: [],
            bodyText: message,
            bodyLineLimit: bodyLineLimit,
            state: state,
            noteURL: nil
        )
    }
}
