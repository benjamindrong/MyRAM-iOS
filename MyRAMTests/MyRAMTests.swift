import XCTest
import SwiftData
import UIKit
@testable import MyRAM

@MainActor
final class MyRAMTests: XCTestCase {
    private struct DecodedExportManifest: Decodable {
        struct NoteRecord: Decodable {
            struct AttachmentRecord: Decodable {
                let id: String
                let createdAt: String
                let mimeType: String
                let filename: String
            }

            let id: String
            let title: String
            let content: String
            let createdAt: String
            let modifiedAt: String
            let deletedAt: String?
            let folderPath: [String]
            let attachments: [AttachmentRecord]
        }

        let format: String
        let version: Int
        let exportedAt: String
        let notes: [NoteRecord]
    }

    func testCreateFolderSupportsRootAndNestedHierarchy() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Projects")
        let rootFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Projects" }))
        XCTAssertNil(rootFolder.parentFolder)

        vm.openFolder(rootFolder)
        vm.createFolder(named: "Client A")
        let nestedFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Client A" }))

        XCTAssertEqual(nestedFolder.parentFolder?.id, rootFolder.id)
    }

    func testCreateNewNoteUsesCurrentFolderContext() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        vm.openFolder(workFolder)
        let nestedNote = vm.createNewNote()

        XCTAssertEqual(nestedNote.folder?.id, workFolder.id)

        vm.navigateToParentFolder()
        let rootNote = vm.createNewNote()
        XCTAssertNil(rootNote.folder)
    }

    func testActiveNoteCountInFolderExcludesDeletedNotesAndOtherFolders() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "A")
        let folderA = try XCTUnwrap(vm.folders.first(where: { $0.name == "A" }))
        vm.createFolder(named: "B")
        let folderB = try XCTUnwrap(vm.folders.first(where: { $0.name == "B" }))

        vm.openFolder(folderA)
        _ = vm.createNewNote()
        let deletedNote = vm.createNewNote()
        vm.deleteNote(deletedNote)

        vm.openFolder(folderB)
        _ = vm.createNewNote()

        XCTAssertEqual(vm.activeNoteCount(in: folderA), 1)
        XCTAssertEqual(vm.activeNoteCount(in: folderB), 1)
    }

    func testActiveNoteCountInFolderIncludesNestedFolders() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Parent")
        let parentFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Parent" }))
        vm.openFolder(parentFolder)
        vm.createFolder(named: "Child")
        let childFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Child" }))

        vm.openFolder(childFolder)
        _ = vm.createNewNote()
        _ = vm.createNewNote()
        let deletedNestedNote = vm.createNewNote()
        vm.deleteNote(deletedNestedNote)

        XCTAssertEqual(vm.activeNoteCount(in: childFolder), 2)
        XCTAssertEqual(vm.activeNoteCount(in: parentFolder), 2)
    }

    func testFetchRecentlyDeletedNotesLoadsPreexistingDeletedNotesOnInit() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext
        let preexistingDeletedNote = Note(title: "Deleted Earlier", content: "Body")
        preexistingDeletedNote.deletedAt = Date()
        context.insert(preexistingDeletedNote)
        try context.save()

        let vm = NotesViewModel(context: context)
        let deletedNotes = vm.fetchRecentlyDeletedNotes()

        XCTAssertTrue(deletedNotes.contains(where: { $0.id == preexistingDeletedNote.id }))
    }

    func testRefreshRecentlyDeletedNotesPurgesExpiredDeletedNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let context = container.mainContext

        let staleDeletedNote = Note(title: "Old Deleted", content: "Expired")
        staleDeletedNote.deletedAt = Date().addingTimeInterval(-(8 * 24 * 60 * 60))
        context.insert(staleDeletedNote)

        let recentDeletedNote = Note(title: "New Deleted", content: "Active")
        recentDeletedNote.deletedAt = Date()
        context.insert(recentDeletedNote)

        try context.save()

        let vm = NotesViewModel(context: context)
        vm.refreshRecentlyDeletedNotes()
        let deletedNotes = vm.fetchRecentlyDeletedNotes()

        XCTAssertFalse(deletedNotes.contains(where: { $0.id == staleDeletedNote.id }))
        XCTAssertTrue(deletedNotes.contains(where: { $0.id == recentDeletedNote.id }))
    }

    func testDeleteFolderPreservingNotesMovesNotesToTopLevel() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Projects")
        let parent = try XCTUnwrap(vm.folders.first(where: { $0.name == "Projects" }))
        vm.openFolder(parent)
        let parentNote = vm.createNewNote()
        vm.createFolder(named: "Client")
        let child = try XCTUnwrap(vm.folders.first(where: { $0.name == "Client" }))
        vm.openFolder(child)
        let childNote = vm.createNewNote()

        vm.deleteFolder(parent, preserveNotes: true)

        let remainingFolders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertTrue(remainingFolders.isEmpty)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let preservedParentNote = try XCTUnwrap(notes.first(where: { $0.id == parentNote.id }))
        let preservedChildNote = try XCTUnwrap(notes.first(where: { $0.id == childNote.id }))
        XCTAssertNil(preservedParentNote.folder)
        XCTAssertNil(preservedChildNote.folder)
    }

    func testDeleteFolderWithoutPreservingNotesSoftDeletesContainedNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Temp")
        let folder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Temp" }))
        vm.openFolder(folder)
        let note = vm.createNewNote()

        vm.deleteFolder(folder, preserveNotes: false)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let deletedNote = try XCTUnwrap(notes.first(where: { $0.id == note.id }))
        XCTAssertNotNil(deletedNote.deletedAt)
        XCTAssertNil(deletedNote.folder)
    }

    func testRenameFolderUpdatesNameWhenProvidedNonEmptyValue() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Old Name")
        let folder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Old Name" }))

        vm.renameFolder(folder, to: "  New Name  ")

        XCTAssertEqual(folder.name, "New Name")
    }

    func testMoveNoteSupportsTopLevelAndFolderDestinations() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let rootNote = vm.createNewNote()
        XCTAssertNil(rootNote.folder)

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        vm.moveNote(rootNote, to: workFolder)
        XCTAssertEqual(rootNote.folder?.id, workFolder.id)

        vm.moveNote(rootNote, to: nil)
        XCTAssertNil(rootNote.folder)
    }

    func testMoveNoteBetweenFoldersChangesParentFolder() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "A")
        let folderA = try XCTUnwrap(vm.folders.first(where: { $0.name == "A" }))
        vm.createFolder(named: "B")
        let folderB = try XCTUnwrap(vm.folders.first(where: { $0.name == "B" }))

        vm.openFolder(folderA)
        let note = vm.createNewNote()
        XCTAssertEqual(note.folder?.id, folderA.id)

        vm.moveNote(note, to: folderB)
        XCTAssertEqual(note.folder?.id, folderB.id)
    }

    func testAddPhotoAttachmentStoresImageOnNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        let imageData = try makeJPEGData()

        vm.addPhotoAttachment(to: note, imageData: imageData)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let fetched = try XCTUnwrap(notes.first { $0.id == note.id })
        XCTAssertEqual(fetched.photoAttachments.count, 1)
        XCTAssertFalse(fetched.photoAttachments[0].imageData.isEmpty)
    }

    func testRemovePhotoAttachmentDeletesAttachment() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        let imageData = try makeJPEGData()

        vm.addPhotoAttachment(to: note, imageData: imageData)
        vm.addPhotoAttachment(to: note, imageData: imageData)

        let attachmentToRemove = try XCTUnwrap(note.photoAttachments.first)
        vm.removePhotoAttachment(attachmentToRemove, from: note)

        XCTAssertEqual(note.photoAttachments.count, 1)
        XCTAssertFalse(note.photoAttachments.contains { $0.id == attachmentToRemove.id })
    }

    func testAttachmentsPersistAcrossContainerReinit() throws {
        let storeName = "MyRAMTests-\(UUID().uuidString)"
        let noteID: UUID

        do {
            let container = try makeContainer(
                isStoredInMemoryOnly: false,
                configurationName: storeName
            )
            let vm = NotesViewModel(context: container.mainContext)
            let note = vm.createNewNote()
            let imageData = try makeJPEGData()

            vm.addPhotoAttachment(to: note, imageData: imageData)
            noteID = note.id
        }

        let reopenedContainer = try makeContainer(
            isStoredInMemoryOnly: false,
            configurationName: storeName
        )
        let reopenedContext = reopenedContainer.mainContext
        let reopenedNotes = try reopenedContext.fetch(FetchDescriptor<Note>())
        let reopenedNote = try XCTUnwrap(reopenedNotes.first { $0.id == noteID })

        XCTAssertEqual(reopenedNote.photoAttachments.count, 1)
    }

    func testUpdateNoteKeepsExistingNotesWithoutAttachmentsCompatible() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        vm.updateNote(note, title: "Title", content: "Content")

        XCTAssertEqual(note.title, "Title")
        XCTAssertEqual(note.content, "Content")
        XCTAssertTrue(note.photoAttachments.isEmpty)
    }

    func testBuildNoteExportTextIncludesReadableFieldsForSingleNote() throws {
        let note = Note(title: "Trip Plan", content: "Book flights")
        note.createdAt = Date(timeIntervalSince1970: 1000)
        note.modifiedAt = Date(timeIntervalSince1970: 2000)
        let dateFormatter: (Date) -> String = { date in
            let seconds = Int(date.timeIntervalSince1970)
            return "TS-\(seconds)"
        }

        let exported = NotesViewModel.buildNoteExportText(
            for: note,
            exportedAt: Date(timeIntervalSince1970: 3000),
            dateFormatter: dateFormatter
        )

        XCTAssertTrue(exported.contains("MyRAM Notes Export"))
        XCTAssertTrue(exported.contains("Exported: TS-3000"))
        XCTAssertTrue(exported.contains("Title: Trip Plan"))
        XCTAssertTrue(exported.contains("Created: TS-1000"))
        XCTAssertTrue(exported.contains("Modified: TS-2000"))
        XCTAssertTrue(exported.contains("Body:\nBook flights"))
    }

    func testExportNotesForSharingSingleNoteCreatesStructuredJSONFileAndImageFiles() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        vm.updateNote(note, title: "Daily Log", content: "UTF-8 test ✅")
        note.createdAt = Date(timeIntervalSince1970: 1000)
        note.modifiedAt = Date(timeIntervalSince1970: 2000)
        let imageData = try makeJPEGData()
        vm.addPhotoAttachment(to: note, imageData: imageData)
        note.photoAttachments[0].createdAt = Date(timeIntervalSince1970: 3000)

        let exportedAt = Date(timeIntervalSince1970: 4000)
        let exportURLs = try vm.exportNotesForSharing([note], nowProvider: { exportedAt })
        let exportURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "json" }))
        let imageURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "jpg" }))
        let exportData = try Data(contentsOf: exportURL)
        let manifest = try JSONDecoder().decode(DecodedExportManifest.self, from: exportData)
        let noteRecord = try XCTUnwrap(manifest.notes.first)
        let attachmentRecord = try XCTUnwrap(noteRecord.attachments.first)

        XCTAssertEqual(manifest.format, "myram-note-export")
        XCTAssertEqual(manifest.exportedAt, iso8601String(exportedAt))
        XCTAssertEqual(noteRecord.title, "Daily Log")
        XCTAssertEqual(noteRecord.content, "UTF-8 test ✅")
        XCTAssertEqual(noteRecord.createdAt, iso8601String(note.createdAt))
        XCTAssertEqual(noteRecord.modifiedAt, iso8601String(note.modifiedAt))
        XCTAssertEqual(attachmentRecord.mimeType, "image/jpeg")
        XCTAssertEqual(attachmentRecord.filename, imageURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: imageURL), imageData)
    }

    func testExportNotesForSharingMultipleNotesIncludesFolderPathsAndPhotos() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note1 = vm.createNewNote()
        vm.updateNote(note1, title: "First Note", content: "Body A")

        vm.createFolder(named: "Work")
        let workFolder = try XCTUnwrap(vm.folders.first(where: { $0.name == "Work" }))
        let note2 = vm.createNewNote()
        vm.updateNote(note2, title: "Second Note", content: "Body B")
        vm.moveNote(note2, to: workFolder)
        let imageData = try makeJPEGData()
        vm.addPhotoAttachment(to: note2, imageData: imageData)

        let exportURLs = try vm.exportNotesForSharing([note1, note2])
        let exportURL = try XCTUnwrap(exportURLs.first(where: { $0.pathExtension.lowercased() == "json" }))
        let jpgURLs = exportURLs.filter { $0.pathExtension.lowercased() == "jpg" }
        XCTAssertEqual(jpgURLs.count, 1)
        let exportData = try Data(contentsOf: exportURL)
        let manifest = try JSONDecoder().decode(DecodedExportManifest.self, from: exportData)
        XCTAssertEqual(manifest.notes.count, 2)

        let noteByTitle = Dictionary(uniqueKeysWithValues: manifest.notes.map { ($0.title, $0) })
        XCTAssertEqual(noteByTitle["First Note"]?.content, "Body A")
        XCTAssertEqual(noteByTitle["Second Note"]?.content, "Body B")
        XCTAssertEqual(noteByTitle["Second Note"]?.folderPath, ["Work"])
        XCTAssertEqual(noteByTitle["Second Note"]?.attachments.first?.mimeType, "image/jpeg")
        XCTAssertEqual(noteByTitle["Second Note"]?.attachments.first?.filename, jpgURLs[0].lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: jpgURLs[0]), imageData)
    }

    func testSetNotePinnedMovesNoteAheadOfUnpinnedNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let older = vm.createNewNote()
        vm.updateNote(older, title: "Older", content: "")
        let newer = vm.createNewNote()
        vm.updateNote(newer, title: "Newer", content: "")

        vm.setNotePinned(older, isPinned: true)

        XCTAssertEqual(vm.notes.first?.id, older.id)
        XCTAssertTrue(vm.notes.contains { $0.id == newer.id })
    }

    func testUndoLastActionRestoresSoftDeletedNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        vm.deleteNote(note)
        XCTAssertNotNil(note.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)

        vm.undoLastAction()

        XCTAssertNil(note.deletedAt)
        XCTAssertFalse(vm.hasUndoableAction)
    }

    func testUndoLastActionRestoresDeletedFolderHierarchyAndNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Parent")
        let parent = try XCTUnwrap(vm.folders.first(where: { $0.name == "Parent" }))
        vm.openFolder(parent)
        vm.createFolder(named: "Child")
        let child = try XCTUnwrap(vm.folders.first(where: { $0.name == "Child" }))
        vm.openFolder(child)
        let nestedNote = vm.createNewNote()

        vm.deleteFolder(parent, preserveNotes: false)
        XCTAssertNotNil(nestedNote.deletedAt)
        XCTAssertNil(nestedNote.folder)

        vm.undoLastAction()

        let restoredFolders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        let restoredParent = try XCTUnwrap(restoredFolders.first(where: { $0.id == parent.id }))
        let restoredChild = try XCTUnwrap(restoredFolders.first(where: { $0.id == child.id }))
        XCTAssertEqual(restoredChild.parentFolder?.id, restoredParent.id)
        XCTAssertEqual(nestedNote.folder?.id, restoredChild.id)
        XCTAssertNil(nestedNote.deletedAt)
    }

    private func makeContainer(
        isStoredInMemoryOnly: Bool,
        configurationName: String = "MyRAMTests"
    ) throws -> ModelContainer {
        let schema = Schema([Folder.self, Note.self, NotePhotoAttachment.self])
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )

        return try ModelContainer(
            for: Folder.self, Note.self, NotePhotoAttachment.self,
            configurations: configuration
        )
    }

    private func makeJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
