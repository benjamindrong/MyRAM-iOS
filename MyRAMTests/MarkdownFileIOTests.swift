import Foundation
import UniformTypeIdentifiers
import XCTest
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class MarkdownFileIOTests: XCTestCase {
    func testClassifierUsesMarkdownContentTypeAndExtensionFallbacks() {
        let contentTypeClassifier = MarkdownFileClassifier(contentTypeProvider: { _ in
            MarkdownFileClassifier.markdownContentType
        })

        XCTAssertEqual(contentTypeClassifier.kind(for: URL(fileURLWithPath: "/tmp/note.data")), .markdown)
        XCTAssertEqual(MarkdownFileClassifier().kind(for: URL(fileURLWithPath: "/tmp/note.md")), .markdown)
        XCTAssertEqual(MarkdownFileClassifier().kind(for: URL(fileURLWithPath: "/tmp/note.MD")), .markdown)
    }

    func testClassifierKeepsMyRAMDistinctAndRejectsUnsupportedFiles() {
        let classifier = MarkdownFileClassifier(contentTypeProvider: { _ in nil })

        XCTAssertEqual(classifier.kind(for: URL(fileURLWithPath: "/tmp/note.myram")), .myram)
        XCTAssertNotEqual(classifier.kind(for: URL(fileURLWithPath: "/tmp/note.md")), .myram)
        XCTAssertEqual(classifier.kind(for: URL(fileURLWithPath: "/tmp/note.txt")), .unsupported)
    }

    func testReaderStrictlyPreservesValidUTF8Source() throws {
        let source = "\r\n\t  # Heading  \rBare\r\nEmoji 🚀\ne\u{301}\n"
        let reader = MarkdownFileReader(dataLoader: { _ in Data(source.utf8) })

        let document = try reader.read(from: URL(fileURLWithPath: "/tmp/Project.Plan.MD"))

        XCTAssertEqual(Array(document.source.utf8), Array(source.utf8))
        XCTAssertEqual(document.suggestedTitle, "Project.Plan")
    }

    func testReaderPreservesEmptySource() throws {
        let document = try MarkdownFileReader(dataLoader: { _ in Data() })
            .read(from: URL(fileURLWithPath: "/tmp/Empty.md"))

        XCTAssertEqual(document.source, "")
        XCTAssertEqual(document.suggestedTitle, "Empty")
    }

    func testReaderRejectsInvalidUTF8() {
        let reader = MarkdownFileReader(dataLoader: { _ in Data([0xC3, 0x28]) })

        XCTAssertThrowsError(try reader.read(from: URL(fileURLWithPath: "/tmp/Bad.md"))) {
            XCTAssertEqual($0 as? MarkdownFileIOError, .invalidUTF8)
        }
    }

    func testReaderMapsFileFailureWithoutConstructingDocument() {
        let reader = MarkdownFileReader(dataLoader: { _ in throw InjectedError.failure })

        XCTAssertThrowsError(try reader.read(from: URL(fileURLWithPath: "/tmp/Missing.md"))) {
            XCTAssertEqual($0 as? MarkdownFileIOError, .fileUnavailable)
        }
    }

    func testImportedTitleUsesVisibleStemAndUntitledFallback() {
        XCTAssertEqual(
            MarkdownFilenamePolicy.importedTitle(for: URL(fileURLWithPath: "/tmp/Example.md")),
            "Example"
        )
        XCTAssertEqual(
            MarkdownFilenamePolicy.importedTitle(for: URL(fileURLWithPath: "/tmp/ .md")),
            "Untitled"
        )
    }

    func testExportEncodingAddsNoBOMNewlineOrNormalization() {
        let source = "Line\r\ne\u{301}"
        let data = MarkdownFileWriter.encodedData(for: source)

        XCTAssertEqual(data, Data(source.utf8))
        XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertEqual(MarkdownFileWriter.encodedData(for: ""), Data())
    }

    func testExportFilenameSanitizesAndAvoidsDuplicateExtension() {
        XCTAssertEqual(MarkdownFilenamePolicy.exportFilename(for: "Roadmap"), "Roadmap.md")
        XCTAssertEqual(MarkdownFilenamePolicy.exportFilename(for: "Roadmap.md"), "Roadmap.md")
        XCTAssertEqual(MarkdownFilenamePolicy.exportFilename(for: "ROADMAP.MD"), "ROADMAP.md")
        XCTAssertEqual(MarkdownFilenamePolicy.exportFilename(for: "  "), "Untitled.md")
        XCTAssertEqual(
            MarkdownFilenamePolicy.exportFilename(for: "Q3/Launch: Notes"),
            "Q3-Launch- Notes.md"
        )
    }

    func testExportFilenameCapDoesNotSplitCharacter() {
        let title = String(repeating: "a", count: MarkdownFilenamePolicy.maximumStemLength - 1) + "🚀tail"
        let filename = MarkdownFilenamePolicy.exportFilename(for: title)
        let stem = String(filename.dropLast(3))

        XCTAssertEqual(stem.count, MarkdownFilenamePolicy.maximumStemLength)
        XCTAssertTrue(stem.hasSuffix("🚀"))
    }

    func testExportFilenameRetrimsSeparatorsIntroducedAtCapBoundary() {
        for separator in ["/", ":", ".", " ", "-"] {
            let title = String(
                repeating: "a",
                count: MarkdownFilenamePolicy.maximumStemLength - 1
            ) + separator + "tail"
            let filename = MarkdownFilenamePolicy.exportFilename(for: title)
            let stem = String(filename.dropLast(3))

            XCTAssertFalse(stem.hasSuffix(" "), separator)
            XCTAssertFalse(stem.hasSuffix("."), separator)
            XCTAssertFalse(stem.hasSuffix("-"), separator)
            XCTAssertEqual(stem.count, MarkdownFilenamePolicy.maximumStemLength - 1, separator)
        }
    }

    func testExportFilenameFallsBackWhenPostCapTrimEmptiesStem() {
        let title = String(
            repeating: "/",
            count: MarkdownFilenamePolicy.maximumStemLength
        ) + "VisibleOnlyAfterCap"

        XCTAssertEqual(
            MarkdownFilenamePolicy.exportFilename(for: title),
            "Untitled.md"
        )
    }

    func testWriterPassesExactBytesToAtomicWriteSeam() throws {
        var observedData: Data?
        let writer = MarkdownFileWriter(writeOperation: { data, _ in observedData = data })

        try writer.write(source: "Exact\r\n🚀", to: URL(fileURLWithPath: "/tmp/output.md"))

        XCTAssertEqual(observedData, Data("Exact\r\n🚀".utf8))
    }

    func testInjectedWriteFailureLeavesExistingDestinationUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownFileIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Existing.md")
        try Data("previous".utf8).write(to: destination)
        let writer = MarkdownFileWriter(writeOperation: { _, _ in throw InjectedError.failure })

        XCTAssertThrowsError(try writer.write(source: "replacement", to: destination)) {
            XCTAssertEqual($0 as? MarkdownFileIOError, .writeFailed)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Existing.md"])
    }

    func testAtomicWriterCreatesExactDestinationWithoutTemporaryArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownFileIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Output.md")

        try MarkdownFileWriter().write(source: "complete", to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Output.md"])
    }
}

private enum InjectedError: Error {
    case failure
}
