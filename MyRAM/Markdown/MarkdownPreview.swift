// MarkdownPreview.swift
// Shared across the iOS application target and the native Mac application target.
// Owns: mode enum, reminder copy, parser result, parser, block projection, and SwiftUI preview surface.
// Does NOT own: note content, persistence, sync, file I/O, or editor state.

import Foundation
import SwiftUI

// MARK: - Mode

/// Presentation-only mode for the note editor. Must not be persisted, encoded, or added to Note.
enum MarkdownEditorMode: String, CaseIterable, Identifiable {
    case edit
    case preview

    var id: Self { self }
}

// MARK: - Reminder copy

/// Centralizes the exact Jira-approved reminder string. Both platforms must display this verbatim.
enum MarkdownPreviewCopy {
    static let reminder =
        "Markdown Preview only renders formatting written as Markdown syntax. " +
        "Formatting applied with MyRAM's rich-text controls will not appear here " +
        "or in exported .md files."
}

// MARK: - Parser result

/// Explicit success/fallback value. Parser errors never leak into the editor surface.
enum MarkdownPreviewContent: Equatable {
    /// Foundation successfully parsed the source. Rendered as attributed text.
    case rendered(AttributedString)
    /// Foundation threw a parse error. The exact unmodified source is shown as selectable plain text.
    case plainText(String)
}

// MARK: - Parser

/// Pure, deterministic, Foundation-based Markdown parser.
/// No persistence, view-model, sync, platform, or file-I/O dependencies.
/// Never inspects richTextContentData.
struct MarkdownPreviewParser {
    typealias ParseOperation = (String) throws -> AttributedString

    private let parseOperation: ParseOperation

    init(parseOperation: @escaping ParseOperation = Self.defaultFoundationParse) {
        self.parseOperation = parseOperation
    }

    private static func defaultFoundationParse(_ source: String) throws -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .throwError,
            languageCode: nil
        )
        return try AttributedString(markdown: source, options: options)
    }

    /// Returns the inline-attributed parse result. Used by parser contract tests.
    func parse(_ source: String) -> MarkdownPreviewContent {
        do {
            let attributed = try parseOperation(source)
            return .rendered(attributed)
        } catch {
            // Contract: exact plain-text fallback on any Foundation parse failure.
            // Do not trim, normalize, or modify source.
            return .plainText(source)
        }
    }

    /// Returns the immutable block projection used by MarkdownPreviewView.
    func parseDocument(_ source: String) -> MarkdownPreviewResult {
        do {
            let attributed = try parseOperation(source)
            let document = MarkdownPreviewDocument(from: attributed)
            return .rendered(document)
        } catch {
            return .plainTextFallback(source)
        }
    }
}

// MARK: - Block projection result

/// The result type used by MarkdownPreviewView. Separates Foundation-failure fallback from
/// projection success, so an unrecognized presentation intent never triggers plain-text fallback.
enum MarkdownPreviewResult: Equatable {
    case rendered(MarkdownPreviewDocument)
    case plainTextFallback(String)
}

// MARK: - Counter Key

struct MarkdownOrderedListCounterKey: Hashable {
    let containerIdentity: Int
    let depth: Int
}

// MARK: - Block projection

/// Immutable, shared block model derived solely from Foundation AttributedString + presentation intents.
/// Permitted block types (§6.4): paragraph, heading, orderedListItem, unorderedListItem,
/// blockQuote, codeBlock.
/// Inline semantics (emphasis, strong, links, inline code) remain AttributedString attributes
/// inside each block. They are never separate block cases.
/// Unknown/future Foundation intents render as .paragraph — never trigger plain-text fallback.
/// Never inspects or tokenizes the raw Markdown source string.
struct MarkdownPreviewDocument: Equatable {
    let blocks: [MarkdownPreviewBlock]

    init(from attributed: AttributedString) {
        self.blocks = Self.extractBlocks(from: attributed)
    }

    private init(blocks: [MarkdownPreviewBlock]) {
        self.blocks = blocks
    }

    static let empty = MarkdownPreviewDocument(blocks: [])

    private static func extractBlocks(from attributed: AttributedString) -> [MarkdownPreviewBlock] {
        guard !attributed.characters.isEmpty else { return [] }

        var blocks: [MarkdownPreviewBlock] = []
        var pendingRuns: [AttributedString] = []
        var currentIntent: PresentationIntent? = nil
        var currentKind: MarkdownBlockKind = .paragraph

        func flushPending() {
            guard !pendingRuns.isEmpty else { return }
            var merged = AttributedString()
            for run in pendingRuns { merged += run }
            blocks.append(MarkdownPreviewBlock(kind: currentKind, content: merged))
            pendingRuns = []
        }

        // Fallback counters keyed by container identity + depth, so separate lists at the same depth restart at 1
        var orderedListCounters: [MarkdownOrderedListCounterKey: Int] = [:]

        for run in attributed.runs {
            let intent = run.presentationIntent
            let kind = MarkdownBlockKind(from: intent, listCounters: &orderedListCounters)

            // Group runs ONLY when their presentation intent identity and block kind match.
            // Distinct list items or separate paragraphs have different intents and will NOT be merged.
            if intent != currentIntent || kind != currentKind {
                flushPending()
                currentIntent = intent
                currentKind = kind
            }
            pendingRuns.append(AttributedString(attributed[run.range]))
        }
        flushPending()

        return blocks
    }
}

struct MarkdownPreviewBlock: Equatable, Identifiable {
    let id = UUID()
    let kind: MarkdownBlockKind
    let content: AttributedString

    static func == (lhs: MarkdownPreviewBlock, rhs: MarkdownPreviewBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.content == rhs.content
    }
}

struct MarkdownListMetadata: Equatable {
    enum Style: Equatable {
        case ordered(ordinal: Int)
        case unordered
    }

    let style: Style
    let depth: Int
}

/// The six permitted block classifications from §6.4.
/// Unknown or future Foundation presentation intents map to .paragraph.
enum MarkdownBlockKind: Equatable {
    case paragraph
    case heading(level: Int)
    case orderedListItem(MarkdownListMetadata)
    case unorderedListItem(MarkdownListMetadata)
    case blockQuote
    case codeBlock
}

extension MarkdownBlockKind {
    init(from intent: PresentationIntent?, listCounters: inout [MarkdownOrderedListCounterKey: Int]) {
        guard let intent else {
            self = .paragraph
            return
        }

        var headingLevel: Int? = nil
        var isQuote = false
        var isCode = false
        
        // Track list containers in path order to select innermost list style
        enum ListContainerType {
            case ordered
            case unordered
        }
        var listContainers: [ListContainerType] = []
        var depth = 0
        var foundOrdinal: Int? = nil

        for component in intent.components {
            switch component.kind {
            case .header(let level):
                headingLevel = level
            case .orderedList:
                listContainers.append(.ordered)
                depth += 1
            case .unorderedList:
                listContainers.append(.unordered)
                depth += 1
            case .listItem(let ordinal):
                if ordinal > 0 {
                    foundOrdinal = ordinal
                }
            case .blockQuote:
                isQuote = true
            case .codeBlock:
                isCode = true
            case .paragraph:
                break
            @unknown default:
                break
            }
        }

        if let level = headingLevel {
            self = .heading(level: level)
            return
        }
        if isCode {
            self = .codeBlock
            return
        }
        if isQuote {
            self = .blockQuote
            return
        }

        // Innermost list container takes precedence for marker style (Foundation lists components innermost-first)
        if let innermost = listContainers.first {
            let containerIdentity = intent.hashValue
            let effectiveDepth = max(1, depth)
            
            switch innermost {
            case .ordered:
                let ordinal: Int
                if let found = foundOrdinal {
                    ordinal = found
                } else {
                    let key = MarkdownOrderedListCounterKey(containerIdentity: containerIdentity, depth: effectiveDepth)
                    let current = (listCounters[key] ?? 0) + 1
                    listCounters[key] = current
                    ordinal = current
                }
                self = .orderedListItem(MarkdownListMetadata(style: .ordered(ordinal: ordinal), depth: effectiveDepth))
                return

            case .unordered:
                self = .unorderedListItem(MarkdownListMetadata(style: .unordered, depth: effectiveDepth))
                return
            }
        }

        self = .paragraph
    }
}

// MARK: - Shared Preview surface

/// Read-only, selectable SwiftUI Markdown preview surface. Shared across iOS and macOS targets.
/// Renders only from `source`. Never writes, normalizes, or persists. No remote content.
struct MarkdownPreviewView: View {
    let source: String

    var body: some View {
        VStack(spacing: 0) {
            MarkdownPreviewReminder()
                .accessibilityIdentifier("markdown-preview-reminder")

            Divider()

            ScrollView {
                previewBody
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("markdown-preview-body")
            }
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        let result = MarkdownPreviewParser().parseDocument(source)
        switch result {
        case .rendered(let document):
            if document.blocks.isEmpty {
                EmptyView()
            } else {
                MarkdownDocumentView(document: document)
            }
        case .plainTextFallback(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .accessibilityIdentifier("markdown-preview-fallback")
        }
    }
}

// MARK: - Document renderer

private struct MarkdownDocumentView: View {
    let document: MarkdownPreviewDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownPreviewBlock

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(block.content)
                .font(.body)
        case .heading(let level):
            Text(block.content)
                .font(headingFont(level: level))
                .fontWeight(.bold)
        case .orderedListItem(let metadata):
            HStack(alignment: .top, spacing: 6) {
                if case .ordered(let ordinal) = metadata.style {
                    Text("\(ordinal).")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                }
                Text(block.content)
                    .font(.body)
            }
            .padding(.leading, CGFloat(max(0, metadata.depth - 1)) * 16)
        case .unorderedListItem(let metadata):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .center)
                Text(block.content)
                    .font(.body)
            }
            .padding(.leading, CGFloat(max(0, metadata.depth - 1)) * 16)
        case .blockQuote:
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(block.content)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .codeBlock:
            Text(block.content)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }
}

// MARK: - Reminder

/// Persistent, non-scrolling reminder displayed above the preview body.
/// Never intercepts selection or link interaction in the body.
private struct MarkdownPreviewReminder: View {
    var body: some View {
        Text(MarkdownPreviewCopy.reminder)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(reminderBackgroundColor)
            .accessibilityLabel(MarkdownPreviewCopy.reminder)
    }

    private var reminderBackgroundColor: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .secondarySystemBackground)
#endif
    }
}
