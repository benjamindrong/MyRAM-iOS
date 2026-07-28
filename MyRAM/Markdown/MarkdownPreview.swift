// MarkdownPreview.swift
// Shared across the iOS application target and the native Mac application target.
// Owns: mode enum, reminder copy, parser result, parser, optional block projection, and SwiftUI preview surface.
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

    // Characterization note (Step 2 of implementation sequence):
    // On the deployment SDK (iOS 26 / macOS 26, Foundation), Text(AttributedString) does NOT
    // render paragraph-level presentation intents such as header(level:), blockQuote, or
    // codeBlock when the entire string is passed to a single Text view. Those intents require
    // per-block rendering via MarkdownPreviewDocument. The projection is therefore activated.
    // See MarkdownPreviewParserTests for characterization evidence.

    /// Returns the inline-attributed parse result. Used by parser contract tests.
    func parse(_ source: String) -> MarkdownPreviewContent {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .throwError,
            languageCode: nil
        )
        do {
            let attributed = try AttributedString(markdown: source, options: options)
            return .rendered(attributed)
        } catch {
            // Contract: exact plain-text fallback on any Foundation parse failure.
            // Do not trim, normalize, or modify source.
            return .plainText(source)
        }
    }

    /// Returns the immutable block projection used by MarkdownPreviewView.
    func parseDocument(_ source: String) -> MarkdownPreviewResult {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .throwError,
            languageCode: nil
        )
        do {
            let attributed = try AttributedString(markdown: source, options: options)
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
        var currentKind: MarkdownBlockKind = .paragraph

        func flushPending() {
            guard !pendingRuns.isEmpty else { return }
            var merged = AttributedString()
            for run in pendingRuns { merged += run }
            blocks.append(MarkdownPreviewBlock(kind: currentKind, content: merged))
            pendingRuns = []
        }

        for run in attributed.runs {
            let kind = MarkdownBlockKind(from: run.presentationIntent)
            if kind != currentKind {
                flushPending()
                currentKind = kind
            }
            pendingRuns.append(AttributedString(attributed[run.range]))
        }
        flushPending()

        return blocks
    }
}

struct MarkdownPreviewBlock: Equatable {
    let kind: MarkdownBlockKind
    let content: AttributedString
}

/// The six permitted block classifications from §6.4.
/// Unknown or future Foundation presentation intents map to .paragraph.
enum MarkdownBlockKind: Equatable {
    case paragraph
    case heading(level: Int)
    case orderedListItem
    case unorderedListItem
    case blockQuote
    case codeBlock
}

extension MarkdownBlockKind {
    init(from intent: PresentationIntent?) {
        guard let intent else {
            self = .paragraph
            return
        }
        // Walk intent components from most to least specific.
        // Unknown components fall through to .paragraph without triggering plain-text fallback.
        for component in intent.components {
            switch component.kind {
            case .header(level: let level):
                self = .heading(level: level)
                return
            case .orderedList:
                self = .orderedListItem
                return
            case .unorderedList:
                self = .unorderedListItem
                return
            case .blockQuote:
                self = .blockQuote
                return
            case .codeBlock:
                self = .codeBlock
                return
            case .paragraph, .listItem:
                // Ordinary content; continue to check for enclosing context.
                continue
            @unknown default:
                // Unknown/future Foundation intent: render as ordinary attributed content.
                continue
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
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
        case .orderedListItem:
            Text(block.content)
                .font(.body)
        case .unorderedListItem:
            Text(block.content)
                .font(.body)
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
