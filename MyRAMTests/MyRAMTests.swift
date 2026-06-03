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

            struct PinnedThoughtRecord: Decodable {
                let id: String
                let text: String
                let order: Int
                let isCollapsed: Bool
                let createdAt: String
                let modifiedAt: String
            }

            let id: String
            let title: String
            let content: String
            let pinnedThoughts: [PinnedThoughtRecord]
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

    private struct NoteIntelligenceRuleSpec: Decodable {
        struct Rule: Decodable {
            let id: String
            let label: String
            let priority: Int
            let conditions: [String: [String]]
            let rationale: String
        }

        let specVersion: Int
        let specName: String
        let labels: [String]
        let rules: [Rule]
    }

    private struct NoteIntelligenceFixture: Decodable {
        struct Input: Decodable {
            struct Features: Decodable {
                let lemmas: [String]
                let tokens: [String]
                let openCount30d: Int
                let editCount7d: Int
                let firstPersonRatio: Double

                enum CodingKeys: String, CodingKey {
                    case lemmas
                    case tokens
                    case openCount30d = "open_count_30d"
                    case editCount7d = "edit_count_7d"
                    case firstPersonRatio = "first_person_ratio"
                }
            }

            struct Entities: Decodable {
                let datetimes: [String]
                let emails: [String]
                let phones: [String]
                let urls: [String]
                let addresses: [String]
            }

            let noteId: String
            let text: String
            let language: String
            let createdAt: String
            let modifiedAt: String
            let features: Features
            let entities: Entities
            let similarNoteIds: [String]

            enum CodingKeys: String, CodingKey {
                case noteId = "note_id"
                case text
                case language
                case createdAt = "created_at"
                case modifiedAt = "modified_at"
                case features
                case entities
                case similarNoteIds = "similar_note_ids"
            }
        }

        let fixtureId: String
        let input: Input
        let expectedLabels: [String]

        enum CodingKeys: String, CodingKey {
            case fixtureId = "fixture_id"
            case input
            case expectedLabels = "expected_labels"
        }
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

    func testDebugBuildUsesDevelopmentBundleIdentifier() {
#if DEBUG
        let identifiers = Set(Bundle.allBundles.compactMap(\.bundleIdentifier))
        XCTAssertTrue(
            identifiers.contains("com.apexcoretechs.MyRAM.dev"),
            "Debug runs should include the development app bundle identifier."
        )
#endif
    }

    func testNoteIntelligenceRuleSpecV1HasExpectedVersionAndUniqueRuleIds() throws {
        let spec: NoteIntelligenceRuleSpec = try decodeNoteIntelligenceArtifact(
            relativePath: "note_intelligence_rules.v1.json"
        )

        XCTAssertEqual(spec.specVersion, 1)
        XCTAssertEqual(spec.specName, "note_intelligence_rules")
        XCTAssertEqual(Set(spec.labels).count, spec.labels.count, "Labels should be unique.")
        XCTAssertFalse(spec.rules.isEmpty)

        let ruleIDs = spec.rules.map(\.id)
        XCTAssertEqual(Set(ruleIDs).count, ruleIDs.count, "Rule IDs should be unique.")
        XCTAssertTrue(spec.rules.allSatisfy { spec.labels.contains($0.label) })
        XCTAssertTrue(spec.rules.allSatisfy { $0.priority >= 0 && $0.priority <= 100 })
    }

    func testNoteIntelligenceFixturesOnlyUseKnownLabels() throws {
        let spec: NoteIntelligenceRuleSpec = try decodeNoteIntelligenceArtifact(
            relativePath: "note_intelligence_rules.v1.json"
        )
        let knownLabels = Set(spec.labels)
        let fixtures = try loadNoteIntelligenceFixtures()
        XCTAssertEqual(fixtures.count, 8)

        for fixture in fixtures {
            XCTAssertFalse(fixture.expectedLabels.isEmpty, "Fixture must include expected labels: \(fixture.fixtureId)")
            XCTAssertEqual(
                Set(fixture.expectedLabels).count,
                fixture.expectedLabels.count,
                "Fixture labels should be unique: \(fixture.fixtureId)"
            )
            XCTAssertTrue(
                fixture.expectedLabels.allSatisfy { knownLabels.contains($0) },
                "Fixture contains unknown label: \(fixture.fixtureId)"
            )
        }
    }

    func testNoteIntelligenceFixturesHaveBaselineCanonicalInputShape() throws {
        let fixtures = try loadNoteIntelligenceFixtures()

        for fixture in fixtures {
            XCTAssertFalse(fixture.fixtureId.isEmpty)
            XCTAssertFalse(fixture.input.noteId.isEmpty)
            XCTAssertFalse(fixture.input.text.isEmpty)
            XCTAssertGreaterThanOrEqual(fixture.input.language.count, 2)
            XCTAssertGreaterThanOrEqual(fixture.input.features.openCount30d, 0)
            XCTAssertGreaterThanOrEqual(fixture.input.features.editCount7d, 0)
            XCTAssertGreaterThanOrEqual(fixture.input.features.firstPersonRatio, 0)
            XCTAssertLessThanOrEqual(fixture.input.features.firstPersonRatio, 1)
            XCTAssertNotNil(ISO8601DateFormatter().date(from: fixture.input.createdAt))
            XCTAssertNotNil(ISO8601DateFormatter().date(from: fixture.input.modifiedAt))
        }
    }

    func testNoteIntelligenceRuleSpecUsesSupportedConditionKeysAndNames() throws {
        let spec: NoteIntelligenceRuleSpec = try decodeNoteIntelligenceArtifact(
            relativePath: "note_intelligence_rules.v1.json"
        )
        let supportedConditionNames: Set<String> = [
            "contains_action_verb",
            "has_datetime_entity",
            "contains_event_phrase",
            "contains_followup_phrase",
            "has_datetime_or_contact_entity",
            "contains_idea_phrase",
            "not_contains_action_verb",
            "contains_reflective_phrase",
            "first_person_ratio_high",
            "open_count_above_threshold",
            "edited_recently_multiple_times",
            "text_similarity_above_threshold",
            "shares_topic_keywords"
        ]

        for rule in spec.rules {
            for (conditionKey, conditionNames) in rule.conditions {
                XCTAssertTrue(
                    conditionKey == "all" || conditionKey == "any",
                    "Unexpected condition key in rule \(rule.id): \(conditionKey)"
                )
                XCTAssertTrue(
                    conditionNames.allSatisfy { supportedConditionNames.contains($0) },
                    "Rule uses unsupported condition name: \(rule.id)"
                )
            }
        }
    }

    func testNoteIntelligenceRuntimeEvaluatorMatchesFixtureExpectedLabels() throws {
        let fixtures = try loadNoteIntelligenceFixtures()
        let service = NoteIntelligenceService()

        for fixture in fixtures {
            let labels = Set(service.evaluateCanonicalInput(canonicalInput(from: fixture)))
            XCTAssertEqual(
                labels,
                Set(fixture.expectedLabels),
                "Runtime evaluator mismatch for fixture: \(fixture.fixtureId)"
            )
        }
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

#if DEBUG
    func testDebugDemoDataGeneratorCreatesExpectedNotesAndPinnedThoughts() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)

        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let demoNotes = notes.filter { DebugDemoDataGenerator.demoNoteIDs.contains($0.id) }
        XCTAssertEqual(demoNotes.count, 8)

        let todayNote = try XCTUnwrap(demoNotes.first { $0.title == "TODAY - Jun 3, 2026" })
        XCTAssertFalse(todayNote.content.contains("Ask landlord about garage opener"))
        XCTAssertEqual(todayNote.pinnedThoughts.map(\.text), ["Ask landlord about garage opener"])
        XCTAssertTrue(todayNote.content.contains("Need to remember to move the laundry before bed."))

        let noPinnedThoughtsNote = try XCTUnwrap(demoNotes.first { $0.title == "Stuff To Figure Out" })
        XCTAssertTrue(noPinnedThoughtsNote.pinnedThoughts.isEmpty)
    }

    func testDebugDemoDataGeneratorIsSafeToRunRepeatedly() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)

        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)
        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        let demoNotes = notes.filter { DebugDemoDataGenerator.demoNoteIDs.contains($0.id) }
        XCTAssertEqual(demoNotes.count, 8)
        XCTAssertEqual(Set(demoNotes.map(\.id)).count, 8)
    }

    func testDebugDemoDataGeneratorClearPreservesUserNotes() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let userNote = Note(title: "User Note", content: "Keep this")
        container.mainContext.insert(userNote)

        DebugDemoDataGenerator.generateDemoNotes(in: container.mainContext)
        DebugDemoDataGenerator.clearDemoNotes(in: container.mainContext)

        let notes = try container.mainContext.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.map(\.id), [userNote.id])
        XCTAssertEqual(notes.first?.title, "User Note")
    }
#endif

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

    func testUndoRedoLastActionMovesNoteBetweenFolders() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "A")
        let folderA = try XCTUnwrap(vm.folders.first(where: { $0.name == "A" }))
        vm.createFolder(named: "B")
        let folderB = try XCTUnwrap(vm.folders.first(where: { $0.name == "B" }))
        vm.openFolder(folderA)
        let note = vm.createNewNote()

        vm.moveNote(note, to: folderB)
        XCTAssertEqual(note.folder?.id, folderB.id)

        vm.undoLastAction()
        XCTAssertEqual(note.folder?.id, folderA.id)
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()
        XCTAssertEqual(note.folder?.id, folderB.id)
    }

    func testUndoRedoLastActionTogglesCreatedNoteVisibility() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        let note = vm.createNewNote()
        XCTAssertNil(note.deletedAt)

        vm.undoLastAction()
        XCTAssertNotNil(note.deletedAt)
        XCTAssertFalse(vm.notes.contains { $0.id == note.id })
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()
        XCTAssertNil(note.deletedAt)
        XCTAssertTrue(vm.notes.contains { $0.id == note.id })
    }

    func testUndoRedoLastActionTogglesCreatedFolderVisibility() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)

        vm.createFolder(named: "Projects")
        let folderID = try XCTUnwrap(vm.folders.first(where: { $0.name == "Projects" })?.id)

        vm.undoLastAction()
        var folders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertFalse(folders.contains { $0.id == folderID })
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()
        folders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertTrue(folders.contains { $0.id == folderID })
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

    func testPinnedThoughtsCanBeAddedEditedDraggedAndUnpinnedWithoutChangingBody() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()
        note.content = "Body text"
        note.richTextContentData = Data("rich body".utf8)

        let first = try XCTUnwrap(vm.addPinnedThought(to: note, text: "First thought"))
        let second = try XCTUnwrap(vm.addPinnedThought(to: note, text: "Second thought"))

        XCTAssertEqual(vm.sortedPinnedThoughts(for: note).map(\.text), ["First thought", "Second thought"])

        vm.updatePinnedThought(first, text: "  Updated first  ")
        vm.setPinnedThoughtCollapsed(first, isCollapsed: true)
        vm.movePinnedThought(second, before: first)

        let reordered = vm.sortedPinnedThoughts(for: note)
        XCTAssertEqual(reordered.map(\.text), ["Second thought", "Updated first"])
        XCTAssertTrue(first.isCollapsed)
        XCTAssertEqual(reordered.map(\.order), [0, 1])

        vm.movePinnedThought(second, toIndex: 2)
        XCTAssertEqual(vm.sortedPinnedThoughts(for: note).map(\.text), ["Updated first", "Second thought"])

        vm.unpinThought(first)

        XCTAssertEqual(vm.sortedPinnedThoughts(for: note).map(\.text), ["Second thought"])
        XCTAssertEqual(note.content, "Body text")
        XCTAssertEqual(note.richTextContentData, Data("rich body".utf8))
    }

    func testChecklistPinCandidateExtractsThoughtAndSourceLineForMove() throws {
        let sourceText = "Before\n☐ Follow up on pinned thought\nAfter" as NSString
        let selection = NSRange(location: sourceText.range(of: "Follow up").location, length: 6)

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: selection
        ))

        XCTAssertEqual(candidate.text, "Follow up on pinned thought")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "☐ Follow up on pinned thought\n")
    }

    func testPinCandidateIgnoresSelectionAndUsesEntireCursorLine() throws {
        let sourceText = "Before\nPin this entire line please\nAfter" as NSString
        let selectedWordRange = sourceText.range(of: "entire")

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: selectedWordRange
        ))

        XCTAssertEqual(candidate.text, "Pin this entire line please")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "Pin this entire line please\n")
    }

    func testPinCandidateUsesCursorLineWhenSelectionIsCollapsed() throws {
        let sourceText = "Before\nPin this line from cursor\nAfter" as NSString
        let cursorLocation = sourceText.range(of: "from").location

        let candidate = try XCTUnwrap(ChecklistItemEditor.pinCandidate(
            in: sourceText,
            selection: NSRange(location: cursorLocation, length: 0)
        ))

        XCTAssertEqual(candidate.text, "Pin this line from cursor")
        XCTAssertEqual(sourceText.substring(with: candidate.sourceRange), "Pin this line from cursor\n")
    }

    func testPinnedThoughtsPersistAcrossContainerReinit() throws {
        let storeName = "MyRAMPinnedThoughtTests-\(UUID().uuidString)"
        let noteID: UUID

        do {
            let container = try makeContainer(
                isStoredInMemoryOnly: false,
                configurationName: storeName
            )
            let vm = NotesViewModel(context: container.mainContext)
            let note = vm.createNewNote()
            noteID = note.id

            _ = vm.addPinnedThought(to: note, text: "Remember this")
        }

        let reopenedContainer = try makeContainer(
            isStoredInMemoryOnly: false,
            configurationName: storeName
        )
        let reopenedContext = reopenedContainer.mainContext
        let reopenedNotes = try reopenedContext.fetch(FetchDescriptor<Note>())
        let reopenedNote = try XCTUnwrap(reopenedNotes.first { $0.id == noteID })

        XCTAssertEqual(reopenedNote.pinnedThoughts.map(\.text), ["Remember this"])
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

    func testUpdateNotePersistsRichTextDataAlongsidePlainText() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        let attributedText = NSAttributedString(
            string: "Styled note",
            attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        )
        let richTextData = try XCTUnwrap(RichTextContentCodec.encode(attributedText))

        vm.updateNote(
            note,
            title: "Styled",
            content: attributedText.string,
            richTextContentData: richTextData
        )

        XCTAssertEqual(note.title, "Styled")
        XCTAssertEqual(note.content, "Styled note")
        XCTAssertEqual(note.richTextContentData, richTextData)
    }

    func testRichTextCodecFallsBackToPlainTextWhenRichDataMissing() {
        let decoded = RichTextContentCodec.decode(
            richTextData: nil,
            plainText: "Plain body",
            baseFont: .preferredFont(forTextStyle: .body)
        )

        XCTAssertEqual(decoded.string, "Plain body")
    }

    func testRichTextCodecRoundTripPreservesAttributedContent() throws {
        let mutable = NSMutableAttributedString(string: "Bold Italic")
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: fullRange)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        let encoded = try XCTUnwrap(RichTextContentCodec.encode(mutable))

        let decoded = RichTextContentCodec.decode(
            richTextData: encoded,
            plainText: "",
            baseFont: .preferredFont(forTextStyle: .body)
        )

        XCTAssertEqual(decoded.string, "Bold Italic")
        let underlineValue = decoded.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(underlineValue, NSUnderlineStyle.single.rawValue)
    }

    func testRichTextCodecRoundTripPreservesForegroundColor() throws {
        let expectedColor = UIColor(red: 0.85, green: 0.18, blue: 0.12, alpha: 1)
        let mutable = NSMutableAttributedString(string: "Color")
        mutable.addAttribute(
            .foregroundColor,
            value: expectedColor,
            range: NSRange(location: 0, length: mutable.length)
        )

        let encoded = try XCTUnwrap(RichTextContentCodec.encode(mutable))
        let decoded = RichTextContentCodec.decode(
            richTextData: encoded,
            plainText: "",
            baseFont: .preferredFont(forTextStyle: .body)
        )

        let decodedColor = try XCTUnwrap(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(decodedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 0.85, accuracy: 0.01)
        XCTAssertEqual(green, 0.18, accuracy: 0.01)
        XCTAssertEqual(blue, 0.12, accuracy: 0.01)
        XCTAssertEqual(alpha, 1, accuracy: 0.01)
    }

    func testRichTextDisplayNormalizationRemovesNearBlackColorInDarkMode() {
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: 1))
        mutable.addAttribute(.foregroundColor, value: UIColor.systemRed, range: NSRange(location: 1, length: 1))

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            UIColor.label
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.systemRed
        )
    }

    func testRichTextDisplayNormalizationRemovesNearWhiteColorInLightMode() {
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(.foregroundColor, value: UIColor.white, range: NSRange(location: 0, length: 1))
        mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: NSRange(location: 1, length: 1))

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .light)
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            UIColor.label
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.systemBlue
        )
    }

    func testRichTextDisplayNormalizationRemovesDarkGrayInDarkMode() {
        let mutable = NSMutableAttributedString(string: "AB")
        mutable.addAttribute(
            .foregroundColor,
            value: UIColor(white: 0.2, alpha: 1),
            range: NSRange(location: 0, length: 1)
        )
        mutable.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: NSRange(location: 1, length: 1))

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )

        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
            UIColor.label
        )
        XCTAssertEqual(
            normalized.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor,
            UIColor.systemGreen
        )
    }

    func testNoteEditorOverflowActionPriorityMatchesEditorSpec() {
        XCTAssertEqual(
            NoteEditorOverflowAction.priorityOrder,
            [
                .newNote,
                .newFolder,
                .exportNote,
                .attachments,
                .deleteNote
            ]
        )
    }

    func testNoteEditorOverflowActionPriorityIncludesEachActionOnce() {
        XCTAssertEqual(
            Set(NoteEditorOverflowAction.priorityOrder),
            Set(NoteEditorOverflowAction.allCases)
        )
        XCTAssertEqual(
            NoteEditorOverflowAction.priorityOrder.count,
            NoteEditorOverflowAction.allCases.count
        )
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
        XCTAssertTrue(exported.contains("Pinned:\n(None)"))
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
        XCTAssertTrue(vm.hasUndoableAction)
        XCTAssertTrue(vm.hasRedoableAction)
    }

    func testRedoLastActionReappliesSoftDeletedNote() throws {
        let container = try makeContainer(isStoredInMemoryOnly: true)
        let vm = NotesViewModel(context: container.mainContext)
        let note = vm.createNewNote()

        vm.deleteNote(note)
        vm.undoLastAction()
        XCTAssertTrue(vm.hasRedoableAction)

        vm.redoLastAction()

        XCTAssertNotNil(note.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)
        XCTAssertFalse(vm.hasRedoableAction)
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

    func testRedoLastActionReappliesDeletedFolderHierarchyAndNotes() throws {
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
        vm.undoLastAction()
        XCTAssertNil(nestedNote.deletedAt)

        vm.redoLastAction()

        let remainingFolders = try container.mainContext.fetch(FetchDescriptor<Folder>())
        XCTAssertFalse(remainingFolders.contains { $0.id == parent.id })
        XCTAssertFalse(remainingFolders.contains { $0.id == child.id })
        XCTAssertNil(nestedNote.folder)
        XCTAssertNotNil(nestedNote.deletedAt)
        XCTAssertTrue(vm.hasUndoableAction)
        XCTAssertFalse(vm.hasRedoableAction)
    }

    func testRichTextContentCodecRoundTripPreservesFormattingAttributes() throws {
        let baseFont = UIFont.systemFont(ofSize: 17)
        let mutable = NSMutableAttributedString(
            string: "MyRAM",
            attributes: [.font: baseFont]
        )

        let boldFont = UIFont.boldSystemFont(ofSize: 17)
        let italicFont = UIFont.italicSystemFont(ofSize: 17)
        mutable.addAttribute(.font, value: boldFont, range: NSRange(location: 0, length: 2))
        mutable.addAttribute(.font, value: italicFont, range: NSRange(location: 2, length: 2))
        mutable.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 4, length: 1)
        )
        mutable.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 3, length: 2)
        )

        let data = try XCTUnwrap(RichTextContentCodec.encode(mutable))
        let decoded = RichTextContentCodec.decode(
            richTextData: data,
            plainText: mutable.string,
            baseFont: baseFont
        )

        let boldDecoded = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldDecoded.fontDescriptor.symbolicTraits.contains(.traitBold))

        let italicDecoded = try XCTUnwrap(decoded.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(italicDecoded.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let underline = decoded.attribute(.underlineStyle, at: 4, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)

        let strikethrough = decoded.attribute(.strikethroughStyle, at: 3, effectiveRange: nil) as? Int
        XCTAssertEqual(strikethrough, NSUnderlineStyle.single.rawValue)
    }

    func testRichTextDisplayNormalizationKeepsFormattingWhileNormalizingLegacyTextColor() {
        let baseFont = UIFont.systemFont(ofSize: 17)
        let mutable = NSMutableAttributedString(
            string: "Task",
            attributes: [.font: baseFont]
        )
        mutable.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: 4))
        mutable.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 4)
        )

        let normalized = RichTextContentCodec.normalizedForDisplay(
            mutable,
            traitCollection: UITraitCollection(userInterfaceStyle: .dark)
        )

        let color = normalized.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertNotNil(color)

        let underline = normalized.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
    }

    func testChecklistActionCreatesUncheckedItemAtCurrentLine() {
        let mutable = NSMutableAttributedString(string: "Buy milk")

        let updatedSelection = ChecklistItemEditor.applyChecklistAction(
            in: mutable,
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(mutable.string, "☐ Buy milk")
        XCTAssertEqual(updatedSelection.location, ChecklistItemEditor.uncheckedPrefix.utf16.count)
        XCTAssertEqual(updatedSelection.length, 0)
    }

    func testChecklistActionTogglesUncheckedAndCheckedState() {
        let mutable = NSMutableAttributedString(string: "☐ Buy milk")

        _ = ChecklistItemEditor.applyChecklistAction(
            in: mutable,
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(mutable.string, "☑︎ Buy milk")

        _ = ChecklistItemEditor.applyChecklistAction(
            in: mutable,
            selection: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(mutable.string, "☐ Buy milk")
    }

    func testChecklistRenderingAppliesStrikethroughOnlyToCheckedItemText() {
        let mutable = NSMutableAttributedString(string: "☑︎ Done\n☐ Pending")

        XCTAssertTrue(ChecklistItemEditor.applyCheckedItemRendering(in: mutable))

        let checkedTextStart = ChecklistItemEditor.checkedPrefix.utf16.count
        let checkedStyle = mutable.attribute(.strikethroughStyle, at: checkedTextStart, effectiveRange: nil) as? Int
        XCTAssertEqual(checkedStyle, NSUnderlineStyle.single.rawValue)

        let prefixStyle = mutable.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertNil(prefixStyle)

        let nsText = mutable.string as NSString
        let uncheckedLineLocation = nsText.range(of: "☐ Pending").location
        let uncheckedTextStart = uncheckedLineLocation + ChecklistItemEditor.uncheckedPrefix.utf16.count
        let uncheckedStyle = mutable.attribute(.strikethroughStyle, at: uncheckedTextStart, effectiveRange: nil) as? Int
        XCTAssertNil(uncheckedStyle)
    }

    func testChecklistCheckedItemRemainsEditableAfterRendering() {
        let mutable = NSMutableAttributedString(string: "☑︎ Done")
        _ = ChecklistItemEditor.applyCheckedItemRendering(in: mutable)

        mutable.replaceCharacters(in: NSRange(location: mutable.length, length: 0), with: " now")
        _ = ChecklistItemEditor.applyCheckedItemRendering(in: mutable)

        XCTAssertEqual(mutable.string, "☑︎ Done now")
        let lastCharacterIndex = max(mutable.length - 1, 0)
        let style = mutable.attribute(.strikethroughStyle, at: lastCharacterIndex, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)
    }

    func testChecklistRenderingMigratesLegacyMarkersToIcons() {
        let mutable = NSMutableAttributedString(string: "- [x] Done\n- [ ] Pending")

        _ = ChecklistItemEditor.applyCheckedItemRendering(in: mutable)

        XCTAssertEqual(mutable.string, "☑︎ Done\n☐ Pending")
    }

    func testChecklistIconDetectionMatchesIconPrefixRange() {
        let text = "☐ Buy milk" as NSString

        XCTAssertTrue(ChecklistItemEditor.isChecklistIcon(at: 0, in: text))
        XCTAssertTrue(ChecklistItemEditor.isChecklistIcon(at: 1, in: text))
        XCTAssertFalse(ChecklistItemEditor.isChecklistIcon(at: 2, in: text))
    }

    private func makeContainer(
        isStoredInMemoryOnly: Bool,
        configurationName: String = "MyRAMTests"
    ) throws -> ModelContainer {
        let schema = Schema([Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self])
        let configuration = ModelConfiguration(
            configurationName,
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )

        return try ModelContainer(
            for: Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self,
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

    private func loadNoteIntelligenceFixtures() throws -> [NoteIntelligenceFixture] {
        let fixturesDirectory = try noteIntelligenceBaseURL()
            .appendingPathComponent("fixtures/v1", isDirectory: true)
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: fixturesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try fixtureURLs.map { url in
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(NoteIntelligenceFixture.self, from: data)
        }
    }

    private func canonicalInput(from fixture: NoteIntelligenceFixture) -> NoteIntelligenceCanonicalInput {
        .init(
            noteID: fixture.input.noteId,
            text: fixture.input.text,
            language: fixture.input.language,
            createdAt: fixture.input.createdAt,
            modifiedAt: fixture.input.modifiedAt,
            features: .init(
                lemmas: fixture.input.features.lemmas,
                tokens: fixture.input.features.tokens,
                posTags: [],
                openCount30d: fixture.input.features.openCount30d,
                editCount7d: fixture.input.features.editCount7d,
                firstPersonRatio: fixture.input.features.firstPersonRatio
            ),
            entities: .init(
                datetimes: fixture.input.entities.datetimes,
                emails: fixture.input.entities.emails,
                phones: fixture.input.entities.phones,
                urls: fixture.input.entities.urls,
                addresses: fixture.input.entities.addresses
            ),
            similarNoteIDs: fixture.input.similarNoteIds
        )
    }

    private func decodeNoteIntelligenceArtifact<T: Decodable>(relativePath: String) throws -> T {
        let artifactURL = try noteIntelligenceBaseURL().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: artifactURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func noteIntelligenceBaseURL() throws -> URL {
        let testBundle = Bundle(for: Self.self)
        if let bundledURL = testBundle.url(forResource: "note-intelligence", withExtension: nil) {
            return bundledURL
        }

        let repositoryPathURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/note-intelligence", isDirectory: true)
        if FileManager.default.fileExists(atPath: repositoryPathURL.path) {
            return repositoryPathURL
        }

        throw NSError(
            domain: "MyRAMTests",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not locate note-intelligence test artifacts in bundle or repository path."
            ]
        )
    }
}
