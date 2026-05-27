// NotesViewModel.swift
import SwiftUI
import SwiftData

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [Folder] = []
    @Published var currentNote: Note? = nil
    @Published var currentFolder: Folder? = nil
    
    private static let recentlyDeletedRetention: TimeInterval = 7 * 24 * 60 * 60
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        purgeExpiredDeletedNotes()
        refreshCurrentFolderContent()
        loadLastNote()
    }

    func refreshCurrentFolderContent() {
        let notesDescriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        let foldersDescriptor = FetchDescriptor<Folder>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )

        let allNotes = (try? context.fetch(notesDescriptor)) ?? []
        let allFolders = (try? context.fetch(foldersDescriptor)) ?? []

        if let currentFolder {
            notes = allNotes.filter { $0.folder?.id == currentFolder.id }
            folders = allFolders.filter { $0.parentFolder?.id == currentFolder.id }
        } else {
            notes = allNotes.filter { $0.folder == nil }
            folders = allFolders.filter { $0.parentFolder == nil }
        }
    }

    func fetchRecentlyDeletedNotes() -> [Note] {
        purgeExpiredDeletedNotes()
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func loadLastNote() {
        guard let idString = UserDefaults.standard.string(forKey: "lastNoteID"),
              let uuid = UUID(uuidString: idString) else {
            return
        }

        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == uuid && note.deletedAt == nil
            }
        )
        if let note = (try? context.fetch(descriptor))?.first {
            currentNote = note
            currentFolder = note.folder
            refreshCurrentFolderContent()
        }
    }

    @discardableResult
    func createNewNote() -> Note {
        let note = Note(folder: currentFolder)
        context.insert(note)
        currentFolder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
        selectNote(note)
        return note
    }

    func createFolder(named name: String = "New Folder") {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(
            name: trimmedName.isEmpty ? "New Folder" : trimmedName,
            parentFolder: currentFolder
        )
        currentFolder?.modifiedAt = .now
        context.insert(folder)
        try? context.save()
        refreshCurrentFolderContent()
    }

    func renameFolder(_ folder: Folder, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        folder.name = trimmedName
        folder.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    func fetchAllFolders() -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func openFolder(_ folder: Folder) {
        currentFolder = folder
        refreshCurrentFolderContent()
    }

    func navigateToParentFolder() {
        currentFolder = currentFolder?.parentFolder
        refreshCurrentFolderContent()
    }

    func deleteFolder(_ folder: Folder, preserveNotes: Bool = false) {
        let activeFolder = currentFolder
        let shouldNavigateToParent = activeFolder.map { isDescendantOrSame($0, of: folder) } ?? false
        let targetFolder = shouldNavigateToParent ? folder.parentFolder : currentFolder
        let subtreeFolderIDs = Set(allFoldersInSubtree(of: folder).map(\.id))

        if !preserveNotes,
           let selectedFolderID = currentNote?.folder?.id,
           subtreeFolderIDs.contains(selectedFolderID) {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }

        if preserveNotes {
            orphanNotes(inFoldersWithIDs: subtreeFolderIDs)
        }

        context.delete(folder)
        try? context.save()

        currentFolder = targetFolder
        refreshCurrentFolderContent()
    }

    func selectNote(_ note: Note?) {
        currentNote = note
        UserDefaults.standard.set(note?.id.uuidString, forKey: "lastNoteID")
    }

    func updateNote(_ note: Note, title: String, content: String) {
        guard note.deletedAt == nil else { return }
        note.title = title
        note.content = content
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    func addPhotoAttachment(to note: Note, imageData: Data) {
        guard note.deletedAt == nil else { return }
        let attachment = NotePhotoAttachment(imageData: imageData, note: note)
        context.insert(attachment)
        note.photoAttachments.append(attachment)
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    func removePhotoAttachment(_ attachment: NotePhotoAttachment, from note: Note) {
        guard note.deletedAt == nil else { return }
        note.photoAttachments.removeAll { $0.id == attachment.id }
        context.delete(attachment)
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    func deleteNote(_ note: Note) {
        note.deletedAt = .now
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    func moveNote(_ note: Note, to destinationFolder: Folder?) {
        guard note.deletedAt == nil else { return }
        if note.folder?.id == destinationFolder?.id { return }

        note.folder?.modifiedAt = .now
        destinationFolder?.modifiedAt = .now
        note.folder = destinationFolder
        note.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    func restoreNote(_ note: Note) {
        note.deletedAt = nil
        note.modifiedAt = .now
        note.folder?.modifiedAt = .now
        try? context.save()
        refreshCurrentFolderContent()
    }

    func permanentlyDeleteNote(_ note: Note) {
        context.delete(note)
        try? context.save()
        refreshCurrentFolderContent()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    private func isDescendantOrSame(_ folder: Folder, of ancestor: Folder) -> Bool {
        var cursor: Folder? = folder
        while let current = cursor {
            if current.id == ancestor.id {
                return true
            }
            cursor = current.parentFolder
        }
        return false
    }

    private func orphanNotes(inFoldersWithIDs folderIDs: Set<UUID>) {
        guard !folderIDs.isEmpty else { return }

        let allNotes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        for note in allNotes where note.folder.map({ folderIDs.contains($0.id) }) == true {
            note.folder = nil
            note.modifiedAt = .now
        }
    }

    private func allFoldersInSubtree(of rootFolder: Folder) -> [Folder] {
        var result: [Folder] = []
        var queue: [Folder] = [rootFolder]

        while let next = queue.first {
            queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: next.childFolders)
        }

        return result
    }

    private func purgeExpiredDeletedNotes() {
        let cutoff = Date().addingTimeInterval(-Self.recentlyDeletedRetention)
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil })
        let deletedNotes = (try? context.fetch(descriptor)) ?? []

        for note in deletedNotes {
            if let deletedAt = note.deletedAt, deletedAt < cutoff {
                context.delete(note)
            }
        }

        try? context.save()
    }

    func exportNotesForSharing(
        _ notesToExport: [Note],
        nowProvider: () -> Date = Date.init
    ) throws -> [URL] {
        let nonDeletedNotes = notesToExport.filter { $0.deletedAt == nil }
        guard !nonDeletedNotes.isEmpty else {
            throw NoteExportError.noNotesSelected
        }

        let exportTime = nowProvider()
        return try Self.writeStructuredExportJSON(notes: nonDeletedNotes, exportedAt: exportTime)
    }

    nonisolated static func buildNoteExportText(
        for note: Note,
        exportedAt: Date = Date(),
        dateFormatter: (Date) -> String = NotesViewModel.defaultDateFormatter
    ) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : note.title
        let body = note.content.isEmpty ? "(No content)" : note.content

        return [
            "MyRAM Notes Export",
            "Exported: \(dateFormatter(exportedAt))",
            "",
            "Title: \(title)",
            "Created: \(dateFormatter(note.createdAt))",
            "Modified: \(dateFormatter(note.modifiedAt))",
            "Body:",
            body,
            ""
        ].joined(separator: "\n")
    }

    nonisolated static func makeExportFilename(notes: [Note], now: Date) -> String {
        let timestamp = makeExportTimestamp(now)
        if notes.count == 1, let note = notes.first {
            let stem = makeSafeFileStem(from: note.title, fallback: "Note")
            return "MyRAM-\(stem)-\(timestamp).json"
        }
        return "MyRAM-Notes-\(timestamp).json"
    }

    nonisolated private static func writeStructuredExportJSON(
        notes: [Note],
        exportedAt: Date
    ) throws -> [URL] {
        let exportRoot = try makeExportDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        var manifestNotes: [ExportManifestNote] = []
        var attachmentURLs: [URL] = []
        var usedAttachmentFilenames: Set<String> = []

        for note in notes {
            let sortedAttachments = note.photoAttachments.sorted { $0.createdAt < $1.createdAt }
            var manifestAttachments: [ExportManifestAttachment] = []

            for attachment in sortedAttachments {
                let mimeType = inferredMimeType(for: attachment.imageData)
                let fileExtension = inferredImageFileExtension(for: attachment.imageData)
                let baseName = "\(note.id.uuidString)-\(attachment.id.uuidString)"
                let uniqueFileStem = uniqueFilename(baseName: baseName, used: &usedAttachmentFilenames)
                let filename = "\(uniqueFileStem).\(fileExtension)"
                let attachmentURL = exportRoot.appendingPathComponent(filename)
                try attachment.imageData.write(to: attachmentURL, options: .atomic)
                attachmentURLs.append(attachmentURL)

                manifestAttachments.append(
                    ExportManifestAttachment(
                        id: attachment.id.uuidString,
                        createdAt: iso8601Timestamp(from: attachment.createdAt),
                        mimeType: mimeType,
                        filename: filename
                    )
                )
            }

            manifestNotes.append(
                ExportManifestNote(
                    id: note.id.uuidString,
                    title: note.title,
                    content: note.content,
                    createdAt: iso8601Timestamp(from: note.createdAt),
                    modifiedAt: iso8601Timestamp(from: note.modifiedAt),
                    deletedAt: note.deletedAt.map(iso8601Timestamp(from:)),
                    folderPath: folderPathSegments(for: note.folder),
                    attachments: manifestAttachments
                )
            )
        }

        let manifest = ExportManifest(
            format: "myram-note-export",
            version: 1,
            exportedAt: iso8601Timestamp(from: exportedAt),
            notes: manifestNotes
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let manifestData = try? encoder.encode(manifest) else {
            throw NoteExportError.failedToEncodeManifest
        }

        let exportFilename = makeExportFilename(notes: notes, now: exportedAt)
        let exportURL = exportRoot.appendingPathComponent(exportFilename)
        if fileManager.fileExists(atPath: exportURL.path) {
            try fileManager.removeItem(at: exportURL)
        }
        try manifestData.write(to: exportURL, options: .atomic)
        return [exportURL] + attachmentURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func writeSingleNoteExport(note: Note, exportedAt: Date) throws -> URL {
        let exportText = buildNoteExportText(for: note, exportedAt: exportedAt)
        guard let utf8Data = exportText.data(using: .utf8) else {
            throw NoteExportError.failedToEncodeText
        }

        let exportDirectory = try makeExportDirectory()
        let filename = "\(makeSafeFileStem(from: note.title, fallback: "Note"))-\(makeExportTimestamp(exportedAt)).txt"
        let exportURL = exportDirectory.appendingPathComponent(filename)
        try utf8Data.write(to: exportURL, options: .atomic)
        return exportURL
    }

    nonisolated private static func writeMultipleNoteExportArchive(notes: [Note], exportedAt: Date) throws -> URL {
        let exportRoot = try makeExportDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = exportRoot.appendingPathComponent("Notes", isDirectory: true)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: notesDirectory, withIntermediateDirectories: true)

        var usedFilenames: Set<String> = []
        for (index, note) in notes.enumerated() {
            let baseName = makeSafeFileStem(from: note.title, fallback: "Note-\(index + 1)")
            let uniqueName = uniqueFilename(baseName: baseName, used: &usedFilenames)
            let noteText = buildNoteExportText(for: note, exportedAt: exportedAt)

            guard let utf8Data = noteText.data(using: .utf8) else {
                throw NoteExportError.failedToEncodeText
            }

            let fileURL = notesDirectory.appendingPathComponent("\(uniqueName).txt")
            try utf8Data.write(to: fileURL, options: .atomic)
        }

        let zipFilename = "MyRAM-Notes-\(makeExportTimestamp(exportedAt)).zip"
        let zipURL = exportRoot.appendingPathComponent(zipFilename)
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        let filesToArchive = try fileManager.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        let archiveEntries: [(name: String, data: Data)] = try filesToArchive.map { url in
            let fileData = try Data(contentsOf: url)
            return ("Notes/\(url.lastPathComponent)", fileData)
        }

        try writeZipArchive(entries: archiveEntries, to: zipURL)
        return zipURL
    }

    nonisolated private static func makeExportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyRAMExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    nonisolated private static func makeExportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    nonisolated private static func makeSafeFileStem(from rawTitle: String, fallback: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(40)
        let safe = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? fallback : safe
    }

    nonisolated private static func folderPathSegments(for folder: Folder?) -> [String] {
        var segments: [String] = []
        var cursor = folder
        while let current = cursor {
            segments.append(current.name)
            cursor = current.parentFolder
        }
        return segments.reversed()
    }

    nonisolated private static func inferredMimeType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3,
           bytes[0] == 0xFF,
           bytes[1] == 0xD8,
           bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 8,
           bytes[0] == 0x89,
           bytes[1] == 0x50,
           bytes[2] == 0x4E,
           bytes[3] == 0x47,
           bytes[4] == 0x0D,
           bytes[5] == 0x0A,
           bytes[6] == 0x1A,
           bytes[7] == 0x0A {
            return "image/png"
        }
        if bytes.count >= 6,
           bytes[0] == 0x47,
           bytes[1] == 0x49,
           bytes[2] == 0x46,
           bytes[3] == 0x38 {
            return "image/gif"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52,
           bytes[1] == 0x49,
           bytes[2] == 0x46,
           bytes[3] == 0x46,
           bytes[8] == 0x57,
           bytes[9] == 0x45,
           bytes[10] == 0x42,
           bytes[11] == 0x50 {
            return "image/webp"
        }
        if bytes.count >= 12,
           bytes[4] == 0x66,
           bytes[5] == 0x74,
           bytes[6] == 0x79,
           bytes[7] == 0x70 {
            return "image/heic"
        }
        return "application/octet-stream"
    }

    nonisolated private static func inferredImageFileExtension(for data: Data) -> String {
        let mimeType = inferredMimeType(for: data)
        switch mimeType {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/heic":
            return "heic"
        default:
            return "bin"
        }
    }

    nonisolated private static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func uniqueFilename(baseName: String, used: inout Set<String>) -> String {
        if !used.contains(baseName) {
            used.insert(baseName)
            return baseName
        }

        var index = 2
        while used.contains("\(baseName)-\(index)") {
            index += 1
        }
        let unique = "\(baseName)-\(index)"
        used.insert(unique)
        return unique
    }

    nonisolated private static func writeZipArchive(
        entries: [(name: String, data: Data)],
        to url: URL
    ) throws {
        var archiveData = Data()
        var centralDirectoryData = Data()

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            guard nameData.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archiveData.count <= Int(UInt32.max) else {
                throw NoteExportError.failedToCreateArchive
            }

            let crc32 = crc32(for: entry.data)
            let fileSize = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(archiveData.count)

            appendUInt32(0x04034B50, to: &archiveData)
            appendUInt16(20, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt16(0, to: &archiveData)
            appendUInt32(crc32, to: &archiveData)
            appendUInt32(fileSize, to: &archiveData)
            appendUInt32(fileSize, to: &archiveData)
            appendUInt16(UInt16(nameData.count), to: &archiveData)
            appendUInt16(0, to: &archiveData)
            archiveData.append(nameData)
            archiveData.append(entry.data)

            appendUInt32(0x02014B50, to: &centralDirectoryData)
            appendUInt16(20, to: &centralDirectoryData)
            appendUInt16(20, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt32(crc32, to: &centralDirectoryData)
            appendUInt32(fileSize, to: &centralDirectoryData)
            appendUInt32(fileSize, to: &centralDirectoryData)
            appendUInt16(UInt16(nameData.count), to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt16(0, to: &centralDirectoryData)
            appendUInt32(0, to: &centralDirectoryData)
            appendUInt32(localHeaderOffset, to: &centralDirectoryData)
            centralDirectoryData.append(nameData)
        }

        guard archiveData.count <= Int(UInt32.max),
              centralDirectoryData.count <= Int(UInt32.max),
              entries.count <= Int(UInt16.max) else {
            throw NoteExportError.failedToCreateArchive
        }

        let centralDirectoryOffset = UInt32(archiveData.count)
        let centralDirectorySize = UInt32(centralDirectoryData.count)
        let entryCount = UInt16(entries.count)
        archiveData.append(centralDirectoryData)

        appendUInt32(0x06054B50, to: &archiveData)
        appendUInt16(0, to: &archiveData)
        appendUInt16(0, to: &archiveData)
        appendUInt16(entryCount, to: &archiveData)
        appendUInt16(entryCount, to: &archiveData)
        appendUInt32(centralDirectorySize, to: &archiveData)
        appendUInt32(centralDirectoryOffset, to: &archiveData)
        appendUInt16(0, to: &archiveData)

        try archiveData.write(to: url, options: .atomic)
    }

    nonisolated private static func crc32(for data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crc32LookupTable[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    nonisolated private static let crc32LookupTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if (crc & 1) == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    nonisolated private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    nonisolated private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    nonisolated static func defaultDateFormatter(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ExportManifest: Codable {
    let format: String
    let version: Int
    let exportedAt: String
    let notes: [ExportManifestNote]
}

private struct ExportManifestNote: Codable {
    let id: String
    let title: String
    let content: String
    let createdAt: String
    let modifiedAt: String
    let deletedAt: String?
    let folderPath: [String]
    let attachments: [ExportManifestAttachment]
}

private struct ExportManifestAttachment: Codable {
    let id: String
    let createdAt: String
    let mimeType: String
    let filename: String
}

enum NoteExportError: LocalizedError {
    case noNotesSelected
    case failedToEncodeText
    case failedToEncodeManifest
    case failedToCreateArchive

    var errorDescription: String? {
        switch self {
        case .noNotesSelected:
            "No notes were selected to export."
        case .failedToEncodeText:
            "The note export could not be encoded as UTF-8."
        case .failedToEncodeManifest:
            "The note export manifest could not be encoded as JSON."
        case .failedToCreateArchive:
            "The selected notes could not be zipped for export."
        }
    }
}
