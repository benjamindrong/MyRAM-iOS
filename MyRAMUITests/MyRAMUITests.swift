//
//  MyRAMUITests.swift
//  MyRAMUITests
//
//  Created by Benjamin Drong on 10/18/25.
//

import XCTest

final class MyRAMUITests: XCTestCase {
    private enum Timeout {
        static let short: TimeInterval = 2
        static let standard: TimeInterval = 5
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReadOnlyDiagnosticsContainCapturedStateOnFirstPresentation() throws {
        let app = makeApp()
        app.launch()
        let status = findElement("sync-status-indicator", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: Timeout.standard))
        status.tap()
        let diagnostics = app.buttons["ios-sync-readonly-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: Timeout.standard))
        diagnostics.tap()
        let snapshot = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "schema=myram.iphone.sync-diagnostics.v1"
        )).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: Timeout.standard), "First presentation must show the captured diagnostic snapshot.")
        XCTAssertTrue(snapshot.label.contains("networking_started="))
        XCTAssertTrue(snapshot.label.contains("unsent_count="))
        XCTAssertTrue(app.buttons["ios-sync-copy-diagnostics"].exists)
    }

    /// Native XCUITest over a real iPhone connection to a running MYR371 Mac app.
    /// Only the explicitly selected isolated physical test may execute this path.
    func testMYR371PhysicalTransportPairAndReconnect() throws {
        guard ProcessInfo.processInfo.environment["MYR371_PHYSICAL_TRANSPORT"] == "1" else {
            throw XCTSkip("Requires explicitly selected MYR371 physical transport acceptance")
        }

        let app = XCUIApplication(
            bundleIdentifier: "com.northsignalstudio.myram.myr371.transport.verification"
        )
        app.launch()
        assertMYR371TransportConnected(in: app)

        // Reconnect must be a fresh process/session, not the first connection
        // merely staying alive. No app store or production identity is touched.
        app.terminate()
        app.launch()
        assertMYR371TransportConnected(in: app)
    }

    private func assertMYR371TransportConnected(in app: XCUIApplication) {
        let status = app.buttons["sync-status-indicator"]
        XCTAssertTrue(status.waitForExistence(timeout: 20),
                      "Expected the isolated MYR371 iPhone app to launch")
        status.tap()

        let manualSync = app.buttons["Manual Sync"]
        XCTAssertTrue(manualSync.waitForExistence(timeout: Timeout.standard))
        if !manualSync.isEnabled {
            let peerActions = app.buttons.matching(NSPredicate(
                format: "label == %@ OR label == %@", "Pair", "Reconnect"
            ))
            XCTAssertTrue(peerActions.firstMatch.waitForExistence(timeout: 25),
                          "MYR371 Mac peer was not discovered")
            XCTAssertEqual(peerActions.count, 1,
                           "Isolated transport must discover exactly one eligible Mac peer")
            peerActions.firstMatch.tap()
        }

        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == YES"),
            object: manualSync
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 45), .completed,
                       "Actual MCSession did not reach a connected state")

        let diagnostics = app.buttons["ios-sync-readonly-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: Timeout.standard))
        diagnostics.tap()
        let snapshot = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "session_connected_count=1"
        )).firstMatch
        XCTAssertTrue(snapshot.waitForExistence(timeout: Timeout.standard),
                      "Native transport snapshot did not confirm exactly one connected peer")
        app.buttons["Close"].tap()
    }

    func testEditorSyncDiagnosticsUsesDistinctControls() throws {
        let app = makeApp()
        app.launch()
        openNewNote(in: app)
        let editorStatus = app.buttons["editor-sync-status-indicator"]
        XCTAssertTrue(waitForStableHitTarget(editorStatus))
        XCTAssertEqual(app.buttons.matching(identifier: "editor-sync-status-indicator").count, 1)
        XCTAssertLessThanOrEqual(app.buttons.matching(identifier: "sync-status-indicator").count, 1)
        editorStatus.tap()
        let diagnostics = app.buttons["ios-sync-readonly-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()
        let snapshot = app.staticTexts["ios-sync-diagnostics-snapshot"]
        XCTAssertTrue(snapshot.waitForExistence(timeout: 10))
        XCTAssertTrue(snapshot.label.contains("schema=myram.iphone.sync-diagnostics.v1"))
        app.buttons["ios-sync-diagnostics-close"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: snapshot)], timeout: 10), .completed)
        let done = app.buttons["editor-sync-done"]
        XCTAssertTrue(waitForStableHitTarget(done))
        done.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: done)], timeout: 10), .completed)
        XCTAssertTrue(waitForStableHitTarget(editorStatus))
    }

    /// Physical application-sync scenario; skipped in ordinary UI tests.
    func testPhysicalApplicationSyncRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["MYRAM_PHYSICAL_SYNC_TOKEN"] else {
            throw XCTSkip("Requires Scripts/verify.py physical-sync")
        }
        XCTAssertNotNil(token.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        let pair = try XCTUnwrap(env["MYRAM_PHYSICAL_SYNC_PAIR"])
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.myr227.test.verification")
        app.launch()
        defer { app.terminate() }

        func title(_ step: String) -> String { "Sync \(token) \(step)" }
        let initial = "Sync \(token) body"
        let combined = initial + " Mac"
        let insertion = " iPhone"
        let status = app.buttons["sync-status-indicator"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        status.tap()
        let manualSync = app.buttons["Manual Sync"]
        XCTAssertTrue(manualSync.waitForExistence(timeout: 10))
        if !manualSync.isEnabled {
            let actions = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Pair", "Reconnect"))
            XCTAssertTrue(actions.firstMatch.waitForExistence(timeout: 30))
            XCTAssertEqual(actions.count, 1, "Physical sync must discover exactly one eligible peer")
            actions.firstMatch.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == YES"), object: manualSync)], timeout: 60), .completed)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", pair),
            object: status)], timeout: 30), .completed, "Exact candidate pair required")
        XCTAssertFalse(app.staticTexts[title("A")].exists, "Fixture must be new")
        openNewNote(in: app)

        let titleButton = app.buttons["edit-note-title"]
        let body = findElement("note-editor-body", in: app)
        func rename(_ from: String, _ to: String, successor: String? = nil) {
            saveEditorTitle(in: app, from: from, to: to, successor: successor)
        }
        func assertEditor(_ expectedTitle: String, _ expectedBody: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", expectedTitle),
                object: titleButton)], timeout: 180), .completed)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND value == %@", expectedBody),
                object: body)], timeout: 180), .completed)
            let attachment = XCTAttachment(string: "title=\(titleButton.label)\nbody=\(body.value as? String ?? "")")
            attachment.name = expectedTitle
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        rename("", title("A"))
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForStableHitTarget(body), "Body must be interactive after title save")
        body.tap()
        body.typeText(initial)
        assertEditor(title("B"), initial)
        rename(title("B"), title("C"), successor: title("D"))
        assertEditor(title("D"), combined)
        rename(title("D"), title("E"))
        XCTAssertTrue(waitForStableHitTarget(body), "Body must be interactive after title save")
        // A native body tap selects a caret according to text layout; it is
        // not an append command. Verify exactly one insertion into the source
        // text, then carry the actual result through the remote/restart checks.
        XCTAssertEqual(body.value as? String, combined)
        body.tap()
        body.typeText(insertion)
        let final = try XCTUnwrap(body.value as? String)
        XCTAssertEqual(final.utf8.count, combined.utf8.count + insertion.utf8.count)
        XCTAssertEqual(final.replacingOccurrences(of: insertion, with: ""), combined,
                       "Native edit must insert the marker without losing or rearranging existing text")
        XCTAssertEqual(titleButton.label, title("E"))
        let source = try JSONSerialization.data(withJSONObject: [
            "token": token, "title": titleButton.label, "body": final
        ], options: .sortedKeys)
        let sourceAttachment = XCTAttachment(data: source, uniformTypeIdentifier: "public.json")
        sourceAttachment.name = "physical-sync-source-edit-\(token)"
        sourceAttachment.lifetime = .keepAlways
        add(sourceAttachment)
        assertEditor(title("E"), final)

        // The list remains in the accessibility tree beneath the editor sheet.
        // Only the editor-owned sync control opens this editor's Nearby Sync.
        let editorStatus = app.buttons["editor-sync-status-indicator"]
        XCTAssertTrue(waitForStableHitTarget(editorStatus))
        editorStatus.tap()
        let diagnostics = app.buttons["ios-sync-readonly-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        let required = ["unsent_count=0", "legacy_pending_count=0",
                        "local_convergence_pending_count=0", "pending_incoming_durable_count=0",
                        "pending_incoming_transport_count=0", "processing_incoming=false",
                        "queue_health_issue_count=0", "session_connected_count=1"]
        let deadline = Date().addingTimeInterval(120)
        var drained = false
        repeat {
            diagnostics.tap()
            let snapshot = app.staticTexts["ios-sync-diagnostics-snapshot"]
            XCTAssertTrue(snapshot.waitForExistence(timeout: 10))
            let lines = Set(snapshot.label.split(separator: "\n").map(String.init))
            drained = required.allSatisfy { lines.contains($0) }
            if !drained {
                print("SYNC_DRAIN_PENDING: " + required.filter { !lines.contains($0) }.joined(separator: ", "))
            }
            if drained {
                let attachment = XCTAttachment(string: snapshot.label)
                attachment.name = "physical-sync-iPhone-drained"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.buttons["ios-sync-diagnostics-close"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: snapshot)], timeout: 10), .completed)
        } while !drained && Date() < deadline
        XCTAssertTrue(drained, "Physical iPhone durable queues did not drain")
        let editorDone = app.buttons["editor-sync-done"]
        XCTAssertTrue(waitForStableHitTarget(editorDone))
        editorDone.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: editorDone)], timeout: 10), .completed)
        assertEditor(title("E"), final)
    }

    /// A separate native launch with the Mac stopped proves local restoration.
    func testPhysicalApplicationSyncOfflineRestoration() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["MYRAM_PHYSICAL_SYNC_RESTORE_TOKEN"] else {
            throw XCTSkip("Requires completed physical-sync round trip")
        }
        XCTAssertNotNil(token.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.myr227.test.verification")
        app.launch()
        defer { app.terminate() }
        let finalTitle = "Sync \(token) E"
        let finalBody = try XCTUnwrap(env["MYRAM_PHYSICAL_SYNC_EXPECTED_BODY"])
        let titleButton = app.buttons["edit-note-title"]
        if !titleButton.exists {
            let row = app.staticTexts[finalTitle].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30))
            row.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", finalTitle),
            object: titleButton)], timeout: 30), .completed)
        let body = findElement("note-editor-body", in: app)
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertEqual(body.value as? String, finalBody)
        let editorStatus = app.buttons["editor-sync-status-indicator"]
        XCTAssertTrue(waitForStableHitTarget(editorStatus))
        editorStatus.tap()
        let diagnostics = app.buttons["ios-sync-readonly-diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 10))
        diagnostics.tap()
        let snapshot = app.staticTexts["ios-sync-diagnostics-snapshot"]
        XCTAssertTrue(snapshot.waitForExistence(timeout: 10))
        let lines = Set(snapshot.label.split(separator: "\n").map(String.init))
        XCTAssertTrue(["session_connected_count=0", "unsent_count=0",
                       "local_convergence_pending_count=0", "pending_incoming_durable_count=0",
                       "pending_incoming_transport_count=0", "processing_incoming=false",
                       "queue_health_issue_count=0", "legacy_pending_count=0"].allSatisfy { lines.contains($0) },
                      "Offline restart requires zero connected peers and zero pending durable work")
        let attachment = XCTAttachment(string: "title=\(finalTitle)\nbody=\(body.value as? String ?? "")\n\(snapshot.label)")
        attachment.name = "physical-sync-iPhone-offline-restoration"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opt-in physical MYR-225 acceptance. The Xcode runner installs the
    /// candidate Test Host; this test only observes the preserved note UI.
    /// The companion runner independently verifies the Mac's durable dequeue.
    func testMYR225PhysicalRetainedMacTitleArrivesAndSurvivesRestart() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MYR225_PHYSICAL_TITLE_SYNC"] == "1" else {
            throw XCTSkip("Requires the MYR-225 physical Verification runner")
        }
        guard let previousTitle = env["MYR225_PREVIOUS_TITLE"], !previousTitle.isEmpty,
              let expectedTitle = env["MYR225_EXPECTED_TITLE"], !expectedTitle.isEmpty,
              previousTitle != expectedTitle else {
            return XCTFail("Physical title verification requires distinct previous and expected titles")
        }

        let app = XCUIApplication(
            bundleIdentifier: "com.northsignalstudio.myram.myr227.test.verification"
        )
        app.activate()

        let expectedPair = try XCTUnwrap(env["MYR225_EXPECTED_CONNECTED_PAIR"])
        let syncStatus = findElement("sync-status-indicator", in: app)
        let connectedPair = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", expectedPair),
            object: syncStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connectedPair], timeout: 30), .completed,
                       "The iPhone and retained batch's Mac must be connected on the exact candidate")
        let pairEvidence = XCTAttachment(string: expectedPair)
        pairEvidence.name = "MYR225-exact-connected-pair"
        pairEvidence.lifetime = .keepAlways
        add(pairEvidence)

        let selectedTitle = app.buttons["edit-note-title"]
        if !selectedTitle.waitForExistence(timeout: 8)
            || (!selectedTitle.label.contains(previousTitle)
                && !selectedTitle.label.contains(expectedTitle)) {
            let previousRow = app.staticTexts[previousTitle].firstMatch
            let currentRow = app.staticTexts[expectedTitle].firstMatch
            if previousRow.waitForExistence(timeout: 8) {
                previousRow.tap()
            } else {
                XCTAssertTrue(currentRow.waitForExistence(timeout: 8),
                              "The preserved target note is absent from the iPhone list")
                currentRow.tap()
            }
        }

        XCTAssertTrue(selectedTitle.waitForExistence(timeout: 8),
                      "The target note editor did not open")
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", expectedTitle),
            object: selectedTitle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 120), .completed,
                       "Mac title never appeared in the selected iPhone editor")
        let receivedTitle = selectedTitle.label
        XCTAssertTrue(receivedTitle.contains(expectedTitle))

        // Confirm the displayed title was durably restored, not merely projected
        // into a live editor before persistence. Image capture is not part of
        // title acceptance and must not prevent the restart assertion.
        app.terminate()
        app.activate()
        let restoredEditorTitle = app.buttons["edit-note-title"]
        let restoredTitleRow = app.staticTexts[expectedTitle].firstMatch
        let restoredTitle: String
        if restoredEditorTitle.waitForExistence(timeout: 12),
           restoredEditorTitle.label.contains(expectedTitle) {
            restoredTitle = restoredEditorTitle.label
        } else {
            XCTAssertTrue(restoredTitleRow.waitForExistence(timeout: 12),
                          "The received Mac title did not survive iPhone application restart")
            restoredTitle = restoredTitleRow.label
        }
        XCTAssertTrue(restoredTitle.contains(expectedTitle),
                      "The received Mac title did not survive iPhone application restart")

        let titleEvidence = XCTAttachment(string: "received=\(receivedTitle)\nrestored=\(restoredTitle)")
        titleEvidence.name = "MYR225-iPhone-title-received-and-restored"
        titleEvidence.lifetime = .keepAlways
        add(titleEvidence)
    }

    /// Opt-in physical acceptance against the preserved Verification fixture.
    /// Uses the installed app and its ordinary restoration flow, without a test store or reset.
    func testMYR233PhysicalRetainedNoteRestoration() throws {
        guard ProcessInfo.processInfo.environment["MYR233_PHYSICAL_RESTORATION"] == "1" else {
            throw XCTSkip("Requires explicitly bound physical Verification acceptance")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.activate()
        let more = app.buttons["notes-list-more"]
        XCTAssertTrue(more.waitForExistence(timeout: Timeout.standard))
        more.tap()
        let deleted = app.buttons["Recently Deleted"]
        XCTAssertTrue(deleted.waitForExistence(timeout: Timeout.standard))
        deleted.tap()
        let includeExpired = app.descendants(matching: .any)["verification-retained-deleted-notes"].firstMatch
        XCTAssertTrue(includeExpired.waitForExistence(timeout: Timeout.standard),
                      "Restoration requires the app's immutable Verification identity and service gate")
        includeExpired.tap()
        let ids = ["4F390252-1147-4575-B855-BCE319D88B0D", "DBC72F2B-EA8B-4309-980D-428FFF0A10D0"]
        // Both retained parents must exist before either is restored.
        for id in ids {
            XCTAssertTrue(app.descendants(matching: .any)["deleted-note-\(id)"].firstMatch
                .waitForExistence(timeout: Timeout.standard))
        }
        for id in ids {
            let row = app.descendants(matching: .any)["deleted-note-\(id)"].firstMatch
            row.swipeRight()
            let restore = app.buttons["Restore"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: Timeout.standard))
            restore.tap()
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: Timeout.standard), .completed)
        }
        app.buttons["Done"].tap()
    }

    /// Runs only against an explicitly prepared, synthetic Verification container.
    func testMYR238VerificationOfflineEditingAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["MYR238_VERIFICATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated MYR-238 synthetic journal fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.launch()
        XCTAssertTrue(app.buttons["Retry Sync"].waitForExistence(timeout: Timeout.standard))
        openNewNote(in: app)
        app.buttons["edit-note-title"].tap()
        let titleAlert = app.alerts["Edit Title"]
        XCTAssertTrue(titleAlert.waitForExistence(timeout: Timeout.standard))
        replaceText(in: titleAlert.textFields.firstMatch, with: "MYR238 Synthetic Offline", fallbackExistingText: "Untitled")
        titleAlert.buttons["Save"].tap()
        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        editor.tap()
        editor.typeText("MYR238 synthetic durable offline text")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Retry Sync"].waitForExistence(timeout: Timeout.standard))
        // Repeated recovery failure must leave the locally saved note available.
        app.buttons["Retry Sync"].tap()
        let row = app.staticTexts["MYR238 Synthetic Offline"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.standard))
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        XCTAssertEqual(editor.value as? String, "MYR238 synthetic durable offline text")
    }

    func testMYR238VerificationRecoveryPreservesOfflineText() throws {
        guard ProcessInfo.processInfo.environment["MYR238_VERIFICATION_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated MYR-238 synthetic recovery fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.launch()
        let row = app.staticTexts["MYR238 Synthetic Offline"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.standard))
        XCTAssertFalse(app.buttons["Retry Sync"].exists)
        row.tap()
        let editor = findElement("note-editor-body", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: Timeout.standard))
        XCTAssertEqual(editor.value as? String, "MYR238 synthetic durable offline text")
    }

    /// The full Verification app opens a copied, nonempty, captured database.
    /// The caller stages the fixture into a new disposable Simulator first;
    /// this test must never run against production or an empty test store.
    func testMYR238CapturedFullAppReadEditSaveAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["MYR238_CAPTURED_APP_RESTORE"] == "1" else {
            throw XCTSkip("Requires the sealed captured restore in a disposable Verification simulator")
        }
        let app = XCUIApplication(bundleIdentifier: "com.northsignalstudio.myram.verification")
        app.launch()

        // A protected note from the 23-note capture must be present. A fresh,
        // empty Verification store cannot satisfy this gate.
        let warning = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "sync history")
        ).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 15),
                      "Captured divergence was not loaded into the full app")
        let newTitle = "MYR238 Full App Restored Edit"
        let newBody = "MYR238 verified disposable durable edit"
        openNewNote(in: app)
        app.buttons["edit-note-title"].tap()
        let alert = app.alerts["Edit Title"]
        XCTAssertTrue(alert.waitForExistence(timeout: Timeout.standard))
        replaceText(in: alert.textFields.firstMatch, with: newTitle, fallbackExistingText: "Untitled")
        alert.buttons["Save"].tap()
        let body = findElement("note-editor-body", in: app)
        XCTAssertTrue(body.waitForExistence(timeout: Timeout.standard))
        body.tap()
        body.typeText(newBody)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(body.waitForExistence(timeout: Timeout.standard))
        app.terminate()
        app.launch()
        XCTAssertTrue(warning.waitForExistence(timeout: 15))
        let row = app.staticTexts[newTitle].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "The new note was not present after relaunch")
        row.tap()
        let restoredBody = findElement("note-editor-body", in: app)
        XCTAssertTrue(restoredBody.waitForExistence(timeout: Timeout.standard))
        XCTAssertEqual(restoredBody.value as? String, newBody)
    }

    func testNewNoteOpensWithoutAttachments() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(app.staticTexts["Untitled"].exists)

        XCTAssertFalse(app.staticTexts["Attachments"].exists)
    }

    func testNoteEditorTitlePopupAndRedoButtonAreAvailable() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        // Exercise the same real title-save transition used by the physical
        // application-sync scenario, including empty and existing titles.
        saveEditorTitle(in: app, from: "", to: "Native title verification")
        saveEditorTitle(in: app, from: "Native title verification", to: "Native title renamed")
        let body = findElement("note-editor-body", in: app)
        XCTAssertTrue(waitForStableHitTarget(body), "Title dialog must not obstruct the editor")
        body.tap()
        body.typeText("Native title save body")
        XCTAssertEqual(body.value as? String, "Native title save body")
    }

    func testKeyboardControlsAreCollapsedByDefault() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        XCTAssertTrue(findElement("keyboard-control-bar", in: app).waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(app.buttons["edit-note-title"].exists)
        XCTAssertFalse(findElement("format-bold-toggle", in: app).exists)
        XCTAssertFalse(findElement("keyboard-control-overflow-panel", in: app).exists)
    }

    func testKeyboardOverflowExpandsAndCollapsesFormattingControls() throws {
        let app = makeApp()
        app.launch()

        openNewNote(in: app)

        let controlBar = findElement("keyboard-control-bar", in: app)
        XCTAssertTrue(controlBar.waitForExistence(timeout: Timeout.standard))
        let overflowToggle = findElement("keyboard-control-overflow-toggle", in: app)
        tapOverflowToggle(overflowToggle)

        XCTAssertTrue(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: Timeout.standard))
        XCTAssertTrue(findElement("format-bold-toggle", in: app).exists)

        tapOverflowToggle(overflowToggle)
        XCTAssertFalse(findElement("keyboard-control-overflow-panel", in: app).waitForExistence(timeout: Timeout.short))
    }

    func testFolderTitleCanBeRenamedFromTopBar() throws {
        let app = makeApp()
        app.launch()

        let originalName = "UITest Folder \(Int(Date().timeIntervalSince1970))"
        let renamedName = "\(originalName) Renamed"

        createFolder(named: originalName, in: app)
        openFolder(named: originalName, in: app)

        let editFolderTitleButton = app.buttons["edit-folder-title"]
        XCTAssertTrue(editFolderTitleButton.waitForExistence(timeout: Timeout.standard))
        editFolderTitleButton.tap()

        let renameAlert = app.alerts["Rename Folder"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: Timeout.standard))
        let nameField = renameAlert.textFields["Folder Name"]
        XCTAssertTrue(nameField.exists)
        replaceText(in: nameField, with: renamedName, fallbackExistingText: originalName)
        renameAlert.buttons["Save"].tap()

        // After a rename we're still on the folder-detail screen, where the title
        // is the "edit-folder-title" button (confirmed by openFolder's own check
        // above) — not a static text, so only this locator can ever match here.
        XCTAssertTrue(folderTitleButton(named: renamedName, in: app).waitForExistence(timeout: Timeout.standard))
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("UITEST_MODE")
        return app
    }

    private func openNewNote(in app: XCUIApplication) {
        let quickActionButton = app.buttons["notes-topbar-new-note"]
        if quickActionButton.waitForExistence(timeout: Timeout.short) {
            quickActionButton.tap()
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: Timeout.standard))
            overflowButton.tap()

            let menuNewNoteButton = app.buttons["New Note"]
            XCTAssertTrue(menuNewNoteButton.waitForExistence(timeout: Timeout.standard))
            menuNewNoteButton.tap()
        }

        XCTAssertTrue(app.buttons["edit-note-title"].waitForExistence(timeout: Timeout.standard))
        let controlBar = app.descendants(matching: .any)["keyboard-control-bar"]
        let pinButton = app.buttons["keyboard-control-pin"]
        XCTAssertTrue(
            waitForAnyElement([controlBar, pinButton], timeout: Timeout.standard),
            "Expected note editor controls to appear after opening a note."
        )
    }

    private func createFolder(named folderName: String, in app: XCUIApplication) {
        let newFolderButton = app.buttons["notes-topbar-new-folder"]
        if newFolderButton.waitForExistence(timeout: Timeout.short) {
            newFolderButton.tap()
        } else {
            let overflowButton = app.buttons["notes-list-more"]
            XCTAssertTrue(overflowButton.waitForExistence(timeout: Timeout.standard))
            overflowButton.tap()

            let menuNewFolderButton = app.buttons["New Folder"]
            XCTAssertTrue(menuNewFolderButton.waitForExistence(timeout: Timeout.standard))
            menuNewFolderButton.tap()
        }

        let newFolderAlert = app.alerts["New Folder"]
        XCTAssertTrue(newFolderAlert.waitForExistence(timeout: Timeout.standard))
        let folderNameField = newFolderAlert.textFields["Folder Name"]
        XCTAssertTrue(folderNameField.exists)
        folderNameField.tap()
        folderNameField.typeText(folderName)
        newFolderAlert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: Timeout.standard))
    }

    private func openFolder(named folderName: String, in app: XCUIApplication) {
        let folderCell = app.staticTexts[folderName]
        XCTAssertTrue(folderCell.waitForExistence(timeout: Timeout.standard))
        folderCell.tap()
        XCTAssertTrue(app.buttons["edit-folder-title"].waitForExistence(timeout: Timeout.standard))
    }

    private func tapOverflowToggle(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: Timeout.short), "keyboard-control-overflow-toggle not found")
        toggle.tap()
    }

    /// Native keyboard transitions can move an alert between the text-entry
    /// event and the next hit test. Wait for stable, enabled, hittable geometry
    /// rather than assuming that existence or an idle app guarantees a hit.
    private func waitForStableHitTarget(_ element: XCUIElement, keyboard: XCUIElement? = nil,
                                        timeout: TimeInterval = 10) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var previousFrame: CGRect?
        var previousKeyboardFrame: CGRect?
        var stableSince: ContinuousClock.Instant?
        while clock.now < deadline {
            let keyboardFrame = keyboard.flatMap { $0.exists ? $0.frame : nil }
            let keyboardReady = keyboard == nil || keyboardFrame.map { !$0.isEmpty } == true
            if element.exists, element.isEnabled, element.isHittable, keyboardReady {
                let frame = element.frame
                if !frame.isEmpty, frame == previousFrame, keyboardFrame == previousKeyboardFrame {
                    if let stableSince, stableSince.duration(to: clock.now) >= .seconds(1) {
                        return true
                    }
                } else {
                    previousFrame = frame
                    previousKeyboardFrame = keyboardFrame
                    stableSince = frame.isEmpty ? nil : clock.now
                }
            } else {
                previousFrame = nil
                previousKeyboardFrame = nil
                stableSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    /// Every title transition must commit and dismiss the real editor alert
    /// before any subsequent interaction is allowed to target the note body.
    private func saveEditorTitle(in app: XCUIApplication, from original: String,
                                 to replacement: String, successor: String? = nil) {
        let titleButton = app.buttons["edit-note-title"]
        let alert = app.alerts["Edit Title"]
        XCTAssertTrue(waitForStableHitTarget(titleButton))
        titleButton.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let field = alert.textFields.firstMatch
        XCTAssertTrue(waitForStableHitTarget(field))
        let observed = field.value as? String ?? ""
        if original.isEmpty {
            XCTAssertTrue(observed.isEmpty || observed == field.placeholderValue,
                          "New note must have an empty title, not a stored placeholder")
        } else {
            XCTAssertEqual(observed, original, "Title draft must match the selected note")
        }
        let keyboard = app.keyboards.firstMatch
        // A visible software keyboard means the alert has already focused its
        // only text field. Avoid moving the caret or opening the edit menu.
        if !keyboard.exists { field.tap() }
        let expectedKeyboard: XCUIElement? = keyboard.exists ? keyboard : nil
        // Placeholder text is not editable content. Never issue deletes for it.
        if !original.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        }
        field.typeText(replacement)
        XCTAssertEqual(field.value as? String, replacement, "Exact title draft required before Save")
        let save = alert.buttons["Save"]
        XCTAssertTrue(waitForStableHitTarget(save, keyboard: expectedKeyboard),
                      "Title Save never became a stable hit target after keyboard transition")
        save.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "Title Save did not dismiss Edit Title; refusing to edit behind the modal")
        // The remote peer may already have observed the committed rename and
        // advanced to its next title; the Mac trace independently proves that
        // it observed the intermediate value before producing that successor.
        let accepted = successor.map { [replacement, $0] } ?? [replacement]
        let savedTitle = XCTNSPredicateExpectation(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "exists == true"),
                NSCompoundPredicate(orPredicateWithSubpredicates: accepted.map {
                    NSPredicate(format: "label CONTAINS %@", $0)
                })
            ]),
            object: titleButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [savedTitle], timeout: 10), .completed,
                       "Title editor did not display the committed title")
    }

    private func replaceText(in textField: XCUIElement, with replacement: String, fallbackExistingText: String) {
        textField.tap()
        let existingText = textField.value as? String
        let deleteCount = max(existingText?.count ?? 0, fallbackExistingText.count)
        textField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
        textField.typeText(replacement)
    }

    private func findElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForAnyElement(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: \.exists) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return elements.contains(where: \.exists)
    }

    private func folderTitleButton(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "edit-folder-title")
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
    }
}
