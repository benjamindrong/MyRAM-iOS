import Foundation
import NearbySyncCore
import SwiftData

struct SyncConflictRestoreResult {
    var conflicts: [SyncConflictVersion]
    var resolution: SyncTextConflictResolution
    var note: Note?
    var folder: Folder?
    var pinnedThought: PinnedThought?
    var shouldRefreshActiveNote = false
}

enum MyRAMSyncConflictResolutionError: Error, Equatable {
    case conflictUnavailable
    case duplicateResolution
    case modelSaveFailed
    case baselinePersistenceFailed
    case metadataPublicationFailed
    case terminalPersistenceFailed
}

@MainActor
final class MyRAMSyncConflictService {
    private let context: ModelContext
    private let store: SyncConflictStore
    private let saveOperation: (ModelContext) throws -> Void
    private var resolvingConflictIDs: Set<UUID> = []

    init(
        context: ModelContext,
        store: SyncConflictStore,
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.store = store
        self.saveOperation = saveOperation
    }

    func activeConflicts() -> [SyncConflictVersion] {
        store.activeConflicts()
    }

    func activeConflicts(for note: Note, in conflicts: [SyncConflictVersion]) -> [SyncConflictVersion] {
        store.activeConflicts().filter { conflict in
            conflict.noteID == note.id || (conflict.entityType == .note && conflict.entityID == note.id)
        }
    }

    func keepLocal(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        resolve(
            conflict,
            choice: .keepLocal(
                currentLocalText: currentText(for: conflict),
                currentLocalData: currentData(for: conflict)
            ),
            activeNoteID: activeNoteID
        )
    }

    func acceptIncoming(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        resolve(conflict, choice: .acceptIncoming, activeNoteID: activeNoteID)
    }

    func saveMergedText(
        _ conflict: SyncConflictVersion,
        text: String,
        activeNoteID: UUID?
    ) -> SyncConflictRestoreResult? {
        resolve(
            conflict,
            choice: .merged(text: text, data: nil),
            activeNoteID: activeNoteID
        )
    }

    func keepLocalChecked(
        _ conflict: SyncConflictVersion,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)? = nil
    ) async throws -> SyncConflictRestoreResult {
        try await resolveChecked(
            conflict,
            choice: .keepLocal(
                currentLocalText: currentText(for: conflict),
                currentLocalData: currentData(for: conflict)
            ),
            activeNoteID: activeNoteID,
            publishResolution: publishResolution
        )
    }

    func acceptIncomingChecked(
        _ conflict: SyncConflictVersion,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)? = nil
    ) async throws -> SyncConflictRestoreResult {
        try await resolveChecked(
            conflict,
            choice: .acceptIncoming,
            activeNoteID: activeNoteID,
            publishResolution: publishResolution
        )
    }

    func saveMergedTextChecked(
        _ conflict: SyncConflictVersion,
        text: String,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)? = nil
    ) async throws -> SyncConflictRestoreResult {
        try await resolveChecked(
            conflict,
            choice: .merged(text: text, data: nil),
            activeNoteID: activeNoteID,
            publishResolution: publishResolution
        )
    }

    private func resolveChecked(
        _ conflict: SyncConflictVersion,
        choice: SyncTextConflictResolutionChoice,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)?
    ) async throws -> SyncConflictRestoreResult {
        guard resolvingConflictIDs.insert(conflict.id).inserted else {
            throw MyRAMSyncConflictResolutionError.duplicateResolution
        }
        defer { resolvingConflictIDs.remove(conflict.id) }
        guard store.activeConflict(id: conflict.id) == conflict else {
            throw MyRAMSyncConflictResolutionError.conflictUnavailable
        }

        let now = Date()
        let resolution = SyncTextConflictResolver.resolve(conflict.syncTextConflict, choice: choice)
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts(), resolution: resolution)
        do {
            switch conflict.field {
            case .noteTitle:
                guard let note = fetchNote(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                note.title = resolution.resolvedText
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id
            case .noteContent:
                guard let note = fetchNote(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                let previousContent = note.content
                let resolvedRichTextData: Data?
                if resolution.usesRemoteData {
                    resolvedRichTextData = sanitizedConflictRichTextData(
                        resolution.resolvedData,
                        plainText: resolution.resolvedText
                    )
                } else if previousContent != resolution.resolvedText {
                    resolvedRichTextData = resolution.resolvedData
                        ?? sanitizedConflictRichTextData(
                            note.richTextContentData,
                            plainText: resolution.resolvedText
                        )
                } else {
                    resolvedRichTextData = note.richTextContentData
                }
                _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
                    of: note,
                    with: resolution.resolvedText,
                    in: context
                )
                note.richTextContentData = resolvedRichTextData
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id
            case .folderTitle:
                guard let folder = fetchFolder(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                folder.name = resolution.resolvedText
                folder.modifiedAt = now
                result.folder = folder
            case .pinnedText:
                guard let thought = fetchPinnedThought(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                thought.text = resolution.resolvedText
                thought.modifiedAt = now
                thought.note?.modifiedAt = now
                result.pinnedThought = thought
                result.note = thought.note
                result.folder = thought.note?.folder
                result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
            }
            try saveOperation(context)
        } catch let error as MyRAMSyncConflictResolutionError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw MyRAMSyncConflictResolutionError.modelSaveFailed
        }

        do {
            if let baseline = checkedBaseline(
                for: conflict,
                resolvedText: resolution.resolvedText,
                result: result
            ) {
                try store.saveRemoteBaselineChecked(baseline)
            }
        } catch {
            throw MyRAMSyncConflictResolutionError.baselinePersistenceFailed
        }

        if let publishResolution {
            do {
                try await publishResolution(MyRAMSyncConflictPayload(
                    action: .resolved,
                    conflict: conflict,
                    resolvedText: resolution.resolvedText,
                    baseText: resolution.baseText
                ))
            } catch {
                throw MyRAMSyncConflictResolutionError.metadataPublicationFailed
            }
        }

        do {
            if conflict.id.isLifecycleConflictID {
                try store.markLifecycleResolvedChecked(id: conflict.id)
                try store.cleanupResolvedLifecycleConflictChecked(id: conflict.id)
                result.conflicts = store.activeConflicts()
            } else {
                result.conflicts = store.removeResolvedConflict(conflict)
            }
        } catch {
            throw MyRAMSyncConflictResolutionError.terminalPersistenceFailed
        }
        return result
    }

    private func checkedBaseline(
        for conflict: SyncConflictVersion,
        resolvedText: String,
        result: SyncConflictRestoreResult
    ) -> SyncRemoteTextBaseline? {
        switch conflict.field {
        case .noteTitle:
            guard let note = result.note else { return nil }
            return SyncRemoteTextBaseline(
                entityType: .note,
                entityID: conflict.entityID,
                field: .noteTitle,
                text: resolvedText,
                richTextContentData: nil,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )
        case .noteContent:
            guard let note = result.note else { return nil }
            return SyncRemoteTextBaseline(
                entityType: .note,
                entityID: conflict.entityID,
                field: .noteContent,
                text: resolvedText,
                richTextContentData: note.richTextContentData,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )
        case .pinnedText:
            guard let thought = result.pinnedThought else { return nil }
            return SyncRemoteTextBaseline(
                entityType: .pinnedThought,
                entityID: conflict.entityID,
                field: .pinnedText,
                text: resolvedText,
                richTextContentData: nil,
                modifiedAt: thought.modifiedAt,
                originDeviceID: nil
            )
        case .folderTitle:
            return nil
        }
    }

    private func resolve(
        _ conflict: SyncConflictVersion,
        choice: SyncTextConflictResolutionChoice,
        activeNoteID: UUID?
    ) -> SyncConflictRestoreResult? {
        let now = Date()
        let resolution = SyncTextConflictResolver.resolve(conflict.syncTextConflict, choice: choice)
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts(), resolution: resolution)

        do {
            switch conflict.field {
            case .noteTitle:
                guard let note = fetchNote(withID: conflict.entityID) else { return nil }
                note.title = resolution.resolvedText
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id

            case .noteContent:
                guard let note = fetchNote(withID: conflict.entityID) else { return nil }
                let previousContent = note.content
                let resolvedRichTextData: Data?
                if resolution.usesRemoteData {
                    resolvedRichTextData = sanitizedConflictRichTextData(
                        resolution.resolvedData,
                        plainText: resolution.resolvedText
                    )
                } else if previousContent != resolution.resolvedText {
                    // Plain-text merge resolutions can omit rich text data; preserve
                    // compatible formatting without publishing before persistence.
                    resolvedRichTextData = resolution.resolvedData
                        ?? sanitizedConflictRichTextData(
                            note.richTextContentData,
                            plainText: resolution.resolvedText
                        )
                } else {
                    resolvedRichTextData = note.richTextContentData
                }
                _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
                    of: note,
                    with: resolution.resolvedText,
                    in: context
                )
                note.richTextContentData = resolvedRichTextData
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id

            case .folderTitle:
                guard let folder = fetchFolder(withID: conflict.entityID) else { return nil }
                folder.name = resolution.resolvedText
                folder.modifiedAt = now
                result.folder = folder

            case .pinnedText:
                guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return nil }
                thought.text = resolution.resolvedText
                thought.modifiedAt = now
                thought.note?.modifiedAt = now
                result.pinnedThought = thought
                result.note = thought.note
                result.folder = thought.note?.folder
                result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
            }

            try saveOperation(context)
        } catch {
            context.rollback()
            return nil
        }
        result.conflicts = store.removeResolvedConflict(conflict)
        return result
    }

    func markReviewed(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        keepLocal(conflict, activeNoteID: activeNoteID)
    }

    func discard(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        keepLocal(conflict, activeNoteID: activeNoteID)
    }

    func restore(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        acceptIncoming(conflict, activeNoteID: activeNoteID)
    }

    private func currentText(for conflict: SyncConflictVersion) -> String {
        switch conflict.field {
        case .noteTitle:
            fetchNote(withID: conflict.entityID)?.title ?? conflict.localText
        case .noteContent:
            fetchNote(withID: conflict.entityID)?.content ?? conflict.localText
        case .folderTitle:
            fetchFolder(withID: conflict.entityID)?.name ?? conflict.localText
        case .pinnedText:
            fetchPinnedThought(withID: conflict.entityID)?.text ?? conflict.localText
        }
    }

    private func currentData(for conflict: SyncConflictVersion) -> Data? {
        switch conflict.field {
        case .noteContent:
            fetchNote(withID: conflict.entityID)?.richTextContentData
        case .noteTitle, .folderTitle, .pinnedText:
            nil
        }
    }

    private func sanitizedConflictRichTextData(_ data: Data?, plainText: String) -> Data? {
        #if os(iOS)
        return RichTextContentCodec.sanitizedConflictRichTextData(data, plainText: plainText)
        #else
        guard let data,
              let attributedText = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                  documentAttributes: nil
              ),
              let compatibleText = attributedText.myramCompatibleConflictText(matching: plainText) else {
            return nil
        }
        return RTFCoding.encode(NSMutableAttributedString(attributedString: compatibleText))
        #endif
    }

    private func fetchNote(withID noteID: UUID) -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == noteID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchFolder(withID folderID: UUID) -> Folder? {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == folderID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchPinnedThought(withID thoughtID: UUID) -> PinnedThought? {
        let descriptor = FetchDescriptor<PinnedThought>(
            predicate: #Predicate { thought in
                thought.id == thoughtID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }
}