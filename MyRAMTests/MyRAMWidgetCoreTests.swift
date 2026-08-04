import XCTest
@testable import MyRAM

final class MyRAMWidgetCoreTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testTitleTrimFallbackThenBound() {
        XCTAssertEqual(MyRAMWidgetSnapshotBounds.boundedDisplayTitle("  \n "), "Untitled")
        XCTAssertEqual(MyRAMWidgetSnapshotBounds.boundedDisplayTitle("  Title  "), "Title")

        let composed = String(repeating: "é", count: 300)
        let bounded = MyRAMWidgetSnapshotBounds.boundedDisplayTitle(composed)
        XCTAssertLessThanOrEqual(bounded.unicodeScalars.count, 256)
    }

    func testPublicationBoundsPreserveOrderAndDropEmptyPins() {
        let snapshot = MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
            id: UUID(),
            title: "  ",
            orderedPinnedTexts: [" first ", "\n", "second"],
            bodyPreviewSource: " body "
        )
        XCTAssertEqual(snapshot.title, "Untitled")
        XCTAssertEqual(snapshot.orderedPinnedTexts, ["first", "second"])
        XCTAssertEqual(snapshot.bodyPreviewSource, "body")
    }

    func testCodecRoundTripAndDeterministicEncoding() throws {
        let envelope = MyRAMWidgetSnapshotEnvelope(
            generatedAt: fixedDate,
            note: MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
                id: UUID(uuidString: "8F59F206-8C0B-42D2-A52C-151F6D5EFB2B")!,
                title: "Title",
                orderedPinnedTexts: ["First", "Second"],
                bodyPreviewSource: "Body"
            )
        )
        let codec = MyRAMWidgetSnapshotCodec()
        let first = try codec.encode(envelope)
        let second = try codec.encode(envelope)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try codec.decode(first), envelope)
    }

    func testFractionalSecondDateSurvivesExactCodecAndStoreRoundTrip() throws {
        let envelope = MyRAMWidgetSnapshotEnvelope(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000.123456),
            note: MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
                id: UUID(uuidString: "8F59F206-8C0B-42D2-A52C-151F6D5EFB2B")!,
                title: "Title",
                orderedPinnedTexts: ["Pin"],
                bodyPreviewSource: "Body"
            )
        )
        let codec = MyRAMWidgetSnapshotCodec()
        let encoded = try codec.encode(envelope)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(
            decoded.generatedAt.timeIntervalSinceReferenceDate.bitPattern,
            envelope.generatedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(decoded, envelope)

        let root = temporaryDirectory()
        let store = MyRAMWidgetSnapshotStore(containerURLProvider: { root })
        XCTAssertEqual(store.publish(envelope), .published)
        XCTAssertEqual(store.read(), .snapshot(envelope))
    }

    func testCodecRejectsUnsupportedVersionBeforeFullDecode() {
        for version in [0, -1, 2, 99] {
            let data = Data("{\"schemaVersion\":\(version),\"garbage\":true}".utf8)
            XCTAssertThrowsError(try MyRAMWidgetSnapshotCodec().decode(data)) { error in
                XCTAssertEqual(
                    error as? MyRAMWidgetSnapshotCodecError,
                    .unsupportedVersion(version)
                )
            }
        }
    }

    func testMalformedCurrentVersionFailsClosed() {
        let data = Data("{\"schemaVersion\":1,\"garbage\":true}".utf8)
        XCTAssertThrowsError(try MyRAMWidgetSnapshotCodec().decode(data)) { error in
            XCTAssertEqual(error as? MyRAMWidgetSnapshotCodecError, .malformed)
        }
    }

    func testDeepLinkRequiresExactPlatformShape() {
        let id = UUID(uuidString: "8F59F206-8C0B-42D2-A52C-151F6D5EFB2B")!
        let iOSURL = MyRAMWidgetDeepLink.url(noteID: id, platform: .iOS)!
        let macURL = MyRAMWidgetDeepLink.url(noteID: id, platform: .macOS)!
        XCTAssertEqual(MyRAMWidgetDeepLink.noteID(from: iOSURL, platform: .iOS), id)
        XCTAssertEqual(MyRAMWidgetDeepLink.noteID(from: macURL, platform: .macOS), id)
        XCTAssertNil(MyRAMWidgetDeepLink.noteID(from: macURL, platform: .iOS))
        XCTAssertNil(MyRAMWidgetDeepLink.noteID(
            from: URL(string: "myram://note/\(id)?x=1")!,
            platform: .iOS
        ))
        XCTAssertNil(MyRAMWidgetDeepLink.noteID(
            from: URL(string: "myram://note/\(id)#x")!,
            platform: .iOS
        ))
        XCTAssertNil(MyRAMWidgetDeepLink.noteID(
            from: URL(string: "myram://note/\(id)/extra")!,
            platform: .iOS
        ))
    }

    func testLayoutPolicyUsesSystemMarginsAndExpandedCapacityAcrossFamiliesAndPlatforms() {
        for platform in [MyRAMWidgetPlatform.iOS, .macOS] {
            let small = MyRAMWidgetLayoutPolicy(family: .small, platform: platform)
            XCTAssertEqual(small.contentLineBudget, 6)
            XCTAssertEqual(small.contentMarginMode, .systemOnly)
            XCTAssertEqual(small.rootSpacing, 4)
            XCTAssertEqual(small.pinSpacing, 4)

            let medium = MyRAMWidgetLayoutPolicy(family: .medium, platform: platform)
            XCTAssertEqual(medium.contentLineBudget, 10)
            XCTAssertEqual(medium.contentMarginMode, .systemOnly)
            XCTAssertEqual(medium.rootSpacing, 4)
            XCTAssertEqual(medium.pinSpacing, 4)
        }
    }

    func testContentPolicyUsesPinPriorityAndExactBudgets() {
        let zeroPins = render(pins: [], body: "Body", family: .small)
        XCTAssertTrue(zeroPins.pinnedTexts.isEmpty)
        XCTAssertEqual(zeroPins.bodyText, "Body")
        XCTAssertEqual(zeroPins.bodyLineLimit, 6)

        let onePin = render(pins: ["Pin"], body: "Body", family: .medium)
        XCTAssertEqual(onePin.pinnedTexts, ["Pin"])
        XCTAssertEqual(onePin.bodyText, "Body")
        XCTAssertEqual(onePin.bodyLineLimit, 9)

        let exhausted = render(
            pins: ["1", "2", "3", "4", "5", "6", "7"],
            body: "Body",
            family: .small
        )
        XCTAssertEqual(exhausted.pinnedTexts, ["1", "2", "3", "4", "5", "6"])
        XCTAssertNil(exhausted.bodyText)
        XCTAssertEqual(exhausted.bodyLineLimit, 0)
    }

    func testStableStatesRemainDistinct() {
        let empty = render(pins: ["  "], body: "\n", family: .small)
        XCTAssertEqual(empty.state, .emptyNote)
        XCTAssertEqual(empty.bodyText, MyRAMWidgetRenderModel.emptyNoteMessage)
        XCTAssertNotNil(empty.noteURL)

        let policy = MyRAMWidgetContentSelectionPolicy()
        let noSelection = policy.renderModel(
            from: .snapshot(MyRAMWidgetSnapshotEnvelope(generatedAt: fixedDate, note: nil)),
            family: .small,
            platform: .iOS
        )
        let failed = policy.renderModel(from: .malformed, family: .small, platform: .iOS)
        XCTAssertEqual(noSelection.state, .noSelection)
        XCTAssertEqual(failed.state, .updateRequired)
    }

    func testStorePublishesThenSuppressesSemanticNoOp() {
        let root = temporaryDirectory()
        let store = MyRAMWidgetSnapshotStore(containerURLProvider: { root })
        let note = MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
            id: UUID(),
            title: "Title",
            orderedPinnedTexts: ["Pin"],
            bodyPreviewSource: "Body"
        )
        let first = MyRAMWidgetSnapshotEnvelope(generatedAt: fixedDate, note: note)
        let second = MyRAMWidgetSnapshotEnvelope(
            generatedAt: fixedDate.addingTimeInterval(60),
            note: note
        )

        XCTAssertEqual(store.read(), .missing)
        XCTAssertEqual(store.publish(first), .published)
        XCTAssertEqual(store.publish(second), .unchanged)
        XCTAssertEqual(store.read(), .snapshot(first))
    }

    func testFailedReplacementPreservesPriorSnapshot() {
        let root = temporaryDirectory()
        let baselineStore = MyRAMWidgetSnapshotStore(containerURLProvider: { root })
        let first = MyRAMWidgetSnapshotEnvelope(
            generatedAt: fixedDate,
            note: MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
                id: UUID(),
                title: "First",
                orderedPinnedTexts: [],
                bodyPreviewSource: "Body"
            )
        )
        XCTAssertEqual(baselineStore.publish(first), .published)

        let failingStore = MyRAMWidgetSnapshotStore(
            containerURLProvider: { root },
            atomicWriter: { _, _ in throw CocoaError(.fileWriteUnknown) }
        )
        let replacement = MyRAMWidgetSnapshotEnvelope(
            generatedAt: fixedDate.addingTimeInterval(60),
            note: MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
                id: UUID(),
                title: "Second",
                orderedPinnedTexts: [],
                bodyPreviewSource: "Body"
            )
        )
        XCTAssertEqual(failingStore.publish(replacement), .failed)
        XCTAssertEqual(baselineStore.read(), .snapshot(first))
    }

    private func render(
        pins: [String],
        body: String,
        family: MyRAMWidgetFamily
    ) -> MyRAMWidgetRenderModel {
        let note = MyRAMWidgetSnapshotBounds.makeNoteSnapshot(
            id: UUID(),
            title: "Title",
            orderedPinnedTexts: pins,
            bodyPreviewSource: body
        )
        return MyRAMWidgetContentSelectionPolicy().renderModel(
            from: MyRAMWidgetSnapshotEnvelope(generatedAt: fixedDate, note: note),
            family: family,
            platform: .iOS
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
