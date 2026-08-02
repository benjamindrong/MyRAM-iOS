import Foundation

struct MyRAMWidgetSnapshotEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let note: MyRAMWidgetNoteSnapshot?

    init(
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date,
        note: MyRAMWidgetNoteSnapshot?
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.note = note
    }
}

struct MyRAMWidgetNoteSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let orderedPinnedTexts: [String]
    let bodyPreviewSource: String
}

enum MyRAMWidgetSnapshotBounds {
    static let maximumTitleUnicodeScalars = 256
    static let maximumPinnedTextRecords = 64
    static let maximumPinnedTextUnicodeScalars = 512
    static let maximumBodyPreviewUnicodeScalars = 8_192

    static func makeNoteSnapshot(
        id: UUID,
        title: String,
        orderedPinnedTexts: [String],
        bodyPreviewSource: String
    ) -> MyRAMWidgetNoteSnapshot {
        let resolvedTitle = boundedDisplayTitle(title)
        let boundedPins = orderedPinnedTexts
            .prefix(maximumPinnedTextRecords)
            .compactMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return prefixWithoutSplittingCharacter(
                    trimmed,
                    maximumUnicodeScalars: maximumPinnedTextUnicodeScalars
                )
            }
        let boundedBody = prefixWithoutSplittingCharacter(
            bodyPreviewSource.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumUnicodeScalars: maximumBodyPreviewUnicodeScalars
        )

        return MyRAMWidgetNoteSnapshot(
            id: id,
            title: resolvedTitle,
            orderedPinnedTexts: boundedPins,
            bodyPreviewSource: boundedBody
        )
    }

    static func boundedDisplayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Untitled" : trimmed
        return prefixWithoutSplittingCharacter(
            resolved,
            maximumUnicodeScalars: maximumTitleUnicodeScalars
        )
    }

    static func validates(_ envelope: MyRAMWidgetSnapshotEnvelope) -> Bool {
        guard envelope.schemaVersion == MyRAMWidgetSnapshotEnvelope.currentSchemaVersion else {
            return false
        }
        guard let note = envelope.note else { return true }
        guard note.title.unicodeScalars.count <= maximumTitleUnicodeScalars,
              !note.title.isEmpty,
              note.orderedPinnedTexts.count <= maximumPinnedTextRecords,
              note.bodyPreviewSource.unicodeScalars.count <= maximumBodyPreviewUnicodeScalars else {
            return false
        }
        return note.orderedPinnedTexts.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.count <= maximumPinnedTextUnicodeScalars
        }
    }

    static func prefixWithoutSplittingCharacter(
        _ value: String,
        maximumUnicodeScalars: Int
    ) -> String {
        guard maximumUnicodeScalars > 0 else { return "" }
        guard value.unicodeScalars.count > maximumUnicodeScalars else { return value }

        var scalarCount = 0
        var result = ""
        for character in value {
            let nextCount = character.unicodeScalars.count
            guard scalarCount + nextCount <= maximumUnicodeScalars else { break }
            result.append(character)
            scalarCount += nextCount
        }
        return result
    }
}
