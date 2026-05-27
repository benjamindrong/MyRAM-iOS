// NotesViewModel.swift
import SwiftUI
import SwiftData

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var currentNote: Note? = nil
    
    private static let recentlyDeletedRetention: TimeInterval = 7 * 24 * 60 * 60
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        purgeExpiredDeletedNotes()
        fetchNotes()
        loadLastNote()
    }

    func fetchNotes() {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        notes = (try? context.fetch(descriptor)) ?? []
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
        if let idString = UserDefaults.standard.string(forKey: "lastNoteID"),
           let uuid = UUID(uuidString: idString),
           let note = notes.first(where: { $0.id == uuid }) {
            currentNote = note
        }
    }

    @discardableResult
    func createNewNote() -> Note {
        let note = Note()
        context.insert(note)
        try? context.save()
        fetchNotes()
        selectNote(note)
        return note
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
        try? context.save()
        fetchNotes()
    }

    func addPhotoAttachment(to note: Note, imageData: Data) {
        guard note.deletedAt == nil else { return }
        let attachment = NotePhotoAttachment(imageData: imageData, note: note)
        context.insert(attachment)
        note.photoAttachments.append(attachment)
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func removePhotoAttachment(_ attachment: NotePhotoAttachment, from note: Note) {
        guard note.deletedAt == nil else { return }
        note.photoAttachments.removeAll { $0.id == attachment.id }
        context.delete(attachment)
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func deleteNote(_ note: Note) {
        note.deletedAt = .now
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
    }

    func restoreNote(_ note: Note) {
        note.deletedAt = nil
        note.modifiedAt = .now
        try? context.save()
        fetchNotes()
    }

    func permanentlyDeleteNote(_ note: Note) {
        context.delete(note)
        try? context.save()
        fetchNotes()
        if currentNote?.id == note.id {
            currentNote = nil
            UserDefaults.standard.removeObject(forKey: "lastNoteID")
        }
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
    ) throws -> URL {
        let nonDeletedNotes = notesToExport.filter { $0.deletedAt == nil }
        guard !nonDeletedNotes.isEmpty else {
            throw NoteExportError.noNotesSelected
        }

        let exportTime = nowProvider()
        if nonDeletedNotes.count == 1, let note = nonDeletedNotes.first {
            return try Self.writeSingleNoteExport(note: note, exportedAt: exportTime)
        }

        return try Self.writeMultipleNoteExportArchive(notes: nonDeletedNotes, exportedAt: exportTime)
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
            return "\(makeSafeFileStem(from: note.title, fallback: "Note"))-\(timestamp).txt"
        }
        return "MyRAM-Notes-\(timestamp).zip"
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

enum NoteExportError: LocalizedError {
    case noNotesSelected
    case failedToEncodeText
    case failedToCreateArchive

    var errorDescription: String? {
        switch self {
        case .noNotesSelected:
            "No notes were selected to export."
        case .failedToEncodeText:
            "The note export could not be encoded as UTF-8."
        case .failedToCreateArchive:
            "The selected notes could not be zipped for export."
        }
    }
}
