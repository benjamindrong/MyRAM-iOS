import Foundation
import UniformTypeIdentifiers

enum MyRAMImportFileKind: Equatable {
    case markdown
    case myram
    case unsupported
}

enum MarkdownFileIOError: Error, Equatable, LocalizedError {
    case unsupportedFileType
    case fileUnavailable
    case invalidUTF8
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "The selected file is not a supported MyRAM import format."
        case .fileUnavailable:
            return "The selected Markdown file could not be read."
        case .invalidUTF8:
            return "The selected Markdown file is not valid UTF-8."
        case .writeFailed:
            return "The Markdown file could not be written."
        }
    }
}

struct MarkdownFileClassifier {
    static let myRAMExportTypeIdentifier = "com.northsignalstudio.myram.export"
    static let markdownContentType = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )

    private let contentTypeProvider: (URL) -> UTType?

    init(contentTypeProvider: @escaping (URL) -> UTType? = { url in
        try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    }) {
        self.contentTypeProvider = contentTypeProvider
    }

    func kind(for url: URL) -> MyRAMImportFileKind {
        if let contentType = contentTypeProvider(url) {
            if contentType.conforms(to: Self.markdownContentType) {
                return .markdown
            }
            if contentType.identifier == Self.myRAMExportTypeIdentifier {
                return .myram
            }
        }

        switch url.pathExtension.lowercased() {
        case "md":
            return .markdown
        case "myram":
            return .myram
        default:
            return .unsupported
        }
    }
}

struct ImportedMarkdownDocument: Equatable {
    let source: String
    let suggestedTitle: String
}

struct MarkdownFileReader {
    private let dataLoader: (URL) throws -> Data

    init(dataLoader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.dataLoader = dataLoader
    }

    func read(from url: URL) throws -> ImportedMarkdownDocument {
        let data: Data
        do {
            data = try dataLoader(url)
        } catch {
            throw MarkdownFileIOError.fileUnavailable
        }

        guard let source = String(data: data, encoding: .utf8) else {
            throw MarkdownFileIOError.invalidUTF8
        }

        return ImportedMarkdownDocument(
            source: source,
            suggestedTitle: MarkdownFilenamePolicy.importedTitle(for: url)
        )
    }
}

enum MarkdownFilenamePolicy {
    static let maximumStemLength = 120

    static func importedTitle(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : stem
    }

    static func exportFilename(for title: String) -> String {
        var stem = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".md") {
            stem.removeLast(3)
        }

        let invalidCharacters = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/\\:?%*|\"<>"))
        stem = String(stem.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? Character("-") : Character(String(scalar))
        })
        stem = String(stem.prefix(maximumStemLength))
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if stem.isEmpty {
            stem = "Untitled"
        }
        return "\(stem).md"
    }
}

struct MarkdownFileWriter {
    private let writeOperation: (Data, URL) throws -> Void

    init(writeOperation: @escaping (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) {
        self.writeOperation = writeOperation
    }

    static func encodedData(for source: String) -> Data {
        Data(source.utf8)
    }

    func write(source: String, to url: URL) throws {
        do {
            try writeOperation(Self.encodedData(for: source), url)
        } catch {
            throw MarkdownFileIOError.writeFailed
        }
    }
}
