import AnchoredSequenceCore
import Foundation
import XCTest

@testable import MyRAM

enum SyncBatchAnchoredRecoveryTestFactory {
  static let noteID = UUID(
    uuidString: "17710000-0000-0000-0000-000000000001"
  )!
  static let deviceID = UUID(
    uuidString: "17710000-0000-0000-0000-000000000002"
  )!
  static let modifiedAt = Date(timeIntervalSince1970: 1_771)

  static func operation(_ counter: UInt64) -> SyncOperationID {
    SyncOperationID(deviceID: deviceID, localCounter: counter)
  }

  static func insertionChange(
    state: SyncTextSequenceState,
    offset: Int,
    text: String,
    operationID: SyncOperationID,
    baseContentHash: String? = nil
  ) throws -> SyncBatchAnchoredRecoveryChange {
    let batchChange = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
      noteID: noteID,
      utf16Offset: offset,
      text: text,
      modifiedAt: modifiedAt,
      baseContentHash: baseContentHash,
      operationID: operationID,
      state: state
    )
    guard case .noteBodyTextInsertedAnchored(let change) = batchChange else {
      throw FactoryError.unexpectedChange
    }
    return .insertion(change)
  }

  static func deletionChange(
    state: SyncTextSequenceState,
    offset: Int,
    length: Int,
    operationID: SyncOperationID,
    expectedText: String? = nil,
    baseContentHash: String? = nil
  ) throws -> SyncBatchAnchoredRecoveryChange {
    let batchChange = try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
      noteID: noteID,
      utf16Offset: offset,
      utf16Length: length,
      expectedText: expectedText,
      modifiedAt: modifiedAt,
      baseContentHash: baseContentHash,
      operationID: operationID,
      state: state
    )
    guard case .noteBodyTextDeletedAnchored(let change) = batchChange else {
      throw FactoryError.unexpectedChange
    }
    return .deletion(change)
  }

  static func element(
    _ operationID: SyncOperationID,
    offset: Int
  ) throws -> SyncTextElementID {
    try SyncTextElementID(
      operationID: operationID,
      elementOffset: offset
    )
  }

  static func insertionChange(
    replacingAnchorIn change: SyncBatchAnchoredRecoveryChange,
    kind: String,
    leftElementID: SyncTextElementID?,
    rightElementID: SyncTextElementID?
  ) throws -> SyncBatchAnchoredRecoveryChange {
    guard case .insertion(let anchoredChange) = change else {
      throw FactoryError.unexpectedChange
    }
    let encoder = JSONEncoder()
    let encoded = try encoder.encode(anchoredChange)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
      var payload = object["payload"] as? [String: Any],
      var anchor = payload["anchor"] as? [String: Any]
    else {
      throw FactoryError.invalidEncoding
    }
    anchor["kind"] = kind
    anchor.removeValue(forKey: "leftElementID")
    anchor.removeValue(forKey: "rightElementID")
    if let leftElementID {
      anchor["leftElementID"] = try JSONSerialization.jsonObject(
        with: encoder.encode(leftElementID)
      )
    }
    if let rightElementID {
      anchor["rightElementID"] = try JSONSerialization.jsonObject(
        with: encoder.encode(rightElementID)
      )
    }
    payload["anchor"] = anchor
    object["payload"] = payload
    let replacement = try JSONSerialization.data(withJSONObject: object)
    return .insertion(
      try JSONDecoder().decode(
        SyncBatchNoteBodyTextInsertedAnchoredChange.self,
        from: replacement
      )
    )
  }

  static func deletionChange(
    replacingFirstSpanLengthIn change: SyncBatchAnchoredRecoveryChange,
    utf16Length: Int
  ) throws -> SyncBatchAnchoredRecoveryChange {
    guard case .deletion(let anchoredChange) = change else {
      throw FactoryError.unexpectedChange
    }
    let encoded = try JSONEncoder().encode(anchoredChange)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
      var payload = object["payload"] as? [String: Any],
      var spans = payload["deletedElementIDSpans"] as? [[String: Any]],
      !spans.isEmpty
    else {
      throw FactoryError.invalidEncoding
    }
    spans[0]["utf16Length"] = utf16Length
    payload["deletedElementIDSpans"] = spans
    object["payload"] = payload
    let replacement = try JSONSerialization.data(withJSONObject: object)
    return .deletion(
      try JSONDecoder().decode(
        SyncBatchNoteBodyTextDeletedAnchoredChange.self,
        from: replacement
      )
    )
  }

  static func applying(
    _ change: SyncBatchAnchoredRecoveryChange,
    to state: SyncTextSequenceState
  ) throws -> SyncTextSequenceState {
    try SyncBatchAnchoredRecoveryReplay.apply(change, to: state)
  }

  static func state(
    text: String,
    operationID: SyncOperationID
  ) throws -> SyncTextSequenceState {
    let change = try insertionChange(
      state: .empty,
      offset: 0,
      text: text,
      operationID: operationID
    )
    return try applying(change, to: .empty)
  }

  static func waitingRecord(
    change: SyncBatchAnchoredRecoveryChange,
    dependency: SyncBatchAnchoredMissingDependency
  ) throws -> SyncBatchAnchoredRecoveryRecord {
    try SyncBatchAnchoredRecoveryRecord(
      change: change,
      lifecycle: .waiting(dependency)
    )
  }

  enum FactoryError: Error {
    case unexpectedChange
    case invalidEncoding
  }
}

final class SyncBatchAnchoredRecoveryStoreTests: XCTestCase {
  func testFileLocationResolvesExpectedHostPaths() throws {
    let supportDirectory = URL(fileURLWithPath: "/tmp/myram-application-support", isDirectory: true)

    XCTAssertEqual(
      try SyncBatchAnchoredRecoveryStoreFileLocation.fileURL(
        for: .iPhone,
        applicationSupportDirectory: { supportDirectory }
      ),
      supportDirectory
        .appendingPathComponent("MyRAM", isDirectory: true)
        .appendingPathComponent("ios-anchored-recovery-store.json")
    )
    XCTAssertEqual(
      try SyncBatchAnchoredRecoveryStoreFileLocation.fileURL(
        for: .nativeMac,
        applicationSupportDirectory: { supportDirectory }
      ),
      supportDirectory
        .appendingPathComponent("MyRAM", isDirectory: true)
        .appendingPathComponent("mac-anchored-recovery-store.json")
    )
  }

  func testFileLocationThrowsWhenApplicationSupportIsUnavailable() {
    XCTAssertThrowsError(
      try SyncBatchAnchoredRecoveryStoreFileLocation.fileURL(
        for: .iPhone,
        applicationSupportDirectory: { nil }
      )
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreFileLocationError,
        .applicationSupportDirectoryUnavailable
      )
    }
  }

  func testStoreRoundTripsRecordsInDeterministicOrder() throws {
    let fileURL = temporaryFileURL()
    let firstChange = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let secondChange = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "B",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let dependency = try SyncBatchAnchoredRecoveryTestFactory.element(
      SyncBatchAnchoredRecoveryTestFactory.operation(1),
      offset: 0
    )
    let first = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: firstChange,
      dependency: .insertionAnchor(dependency)
    )
    let second = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: secondChange,
      dependency: .insertionAnchor(dependency)
    )
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)

    try store.apply([
      .insertExpectedAbsent(first),
      .insertExpectedAbsent(second),
    ])

    let expected = [second, first]
    XCTAssertEqual(store.snapshot().records, expected)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      expected
    )
  }

  func testEquivalentAdmissionIsIdempotentAndDoesNotRewrite() throws {
    let fileURL = temporaryFileURL()
    var writes = 0
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { data, url in
        writes += 1
        try data.write(to: url, options: .atomic)
      }
    )
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let record = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(1),
          offset: 0
        )
      )
    )

    XCTAssertTrue(try store.apply([.insertExpectedAbsent(record)]))
    XCTAssertFalse(try store.apply([.insertExpectedAbsent(record)]))
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(store.snapshot().records, [record])
  }

  func testInitialAdmissionFailurePreservesEmptyMemoryAndDisk() throws {
    let fileURL = temporaryFileURL()
    let record = try makeWaitingRecord(counter: 2, dependencyCounter: 1)
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { _, _ in throw InjectedError.failure }
    )

    XCTAssertThrowsError(
      try store.apply([.insertExpectedAbsent(record)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .persistenceFailed
      )
    }
    XCTAssertTrue(store.snapshot().records.isEmpty)
    assertWriteFailed(store.snapshot().health)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertThrowsError(
      try store.apply([.insertExpectedAbsent(record)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .unhealthyPersistence
      )
    }
  }

  func testSameKeyDifferentContentIsRejectedWithoutOverwrite() throws {
    let fileURL = temporaryFileURL()
    let operationID = SyncBatchAnchoredRecoveryTestFactory.operation(2)
    let firstChange = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: operationID
    )
    let conflictingChange = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "B",
      operationID: operationID
    )
    let dependency = try SyncBatchAnchoredRecoveryTestFactory.element(
      SyncBatchAnchoredRecoveryTestFactory.operation(1),
      offset: 0
    )
    let first = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: firstChange,
      dependency: .insertionAnchor(dependency)
    )
    let conflict = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: conflictingChange,
      dependency: .insertionAnchor(dependency)
    )
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    try store.apply([.insertExpectedAbsent(first)])

    XCTAssertThrowsError(
      try store.apply([.insertExpectedAbsent(conflict)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .identityCollision(first.key)
      )
    }
    XCTAssertEqual(store.snapshot().records, [first])
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [first]
    )
  }

  func testWriteFailureRollsBackMemoryAndDiskAndMarksWriteFailure() throws {
    let fileURL = temporaryFileURL()
    var shouldFail = false
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { data, url in
        if shouldFail { throw InjectedError.failure }
        try data.write(to: url, options: .atomic)
      }
    )
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let first = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(1),
          offset: 0
        )
      )
    )
    let replacement = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(2),
          offset: 0
        )
      )
    )
    try store.apply([.insertExpectedAbsent(first)])
    shouldFail = true

    XCTAssertThrowsError(
      try store.apply([.replace(expected: first, replacement: replacement)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .persistenceFailed
      )
    }
    XCTAssertEqual(store.snapshot().records, [first])
    assertWriteFailed(store.snapshot().health)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [first]
    )
    XCTAssertThrowsError(
      try store.apply([.replace(expected: first, replacement: replacement)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .unhealthyPersistence
      )
    }
  }

  func testRemovalFailurePreservesPriorMemoryAndDisk() throws {
    let fileURL = temporaryFileURL()
    var shouldFail = false
    let record = try makeWaitingRecord(counter: 2, dependencyCounter: 1)
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { data, url in
        if shouldFail { throw InjectedError.failure }
        try data.write(to: url, options: .atomic)
      }
    )
    try store.apply([.insertExpectedAbsent(record)])
    let originalData = try Data(contentsOf: fileURL)
    shouldFail = true

    XCTAssertThrowsError(
      try store.apply([.removeCommitted(expected: record)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .persistenceFailed
      )
    }
    XCTAssertEqual(store.snapshot().records, [record])
    assertWriteFailed(store.snapshot().health)
    XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [record]
    )
  }

  func testFullRecoveryReplacementFailurePreservesPriorSnapshotThenRecovers() throws {
    let fileURL = temporaryFileURL()
    var shouldFail = false
    let record = try makeWaitingRecord(counter: 2, dependencyCounter: 1)
    let store = FileBackedSyncBatchAnchoredRecoveryStore(
      fileURL: fileURL,
      atomicWriter: { data, url in
        if shouldFail { throw InjectedError.failure }
        try data.write(to: url, options: .atomic)
      }
    )
    try store.apply([.insertExpectedAbsent(record)])
    let originalData = try Data(contentsOf: fileURL)
    shouldFail = true

    XCTAssertThrowsError(
      try store.replaceAllForRecovery([])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .persistenceFailed
      )
    }
    XCTAssertEqual(store.snapshot().records, [record])
    assertWriteFailed(store.snapshot().health)
    XCTAssertEqual(try Data(contentsOf: fileURL), originalData)

    shouldFail = false
    try store.replaceAllForRecovery([])

    XCTAssertEqual(store.snapshot().health, .healthy)
    XCTAssertTrue(store.snapshot().records.isEmpty)
    let reopened = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertEqual(reopened.snapshot().health, .healthy)
    XCTAssertTrue(reopened.snapshot().records.isEmpty)
  }

  func testCorruptAndUnsupportedVersionRemainDistinct() throws {
    let corruptURL = temporaryFileURL()
    try Data("not-json".utf8).write(to: corruptURL, options: .atomic)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: corruptURL)
        .snapshot().health,
      .corrupt
    )

    let unsupportedURL = temporaryFileURL()
    try Data(#"{"version":99,"records":[]}"#.utf8)
      .write(to: unsupportedURL, options: .atomic)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: unsupportedURL)
        .snapshot().health,
      .unsupportedVersion(99)
    )
  }

  func testMissingFileAndWaitingKindValidation() throws {
    let missingURL = temporaryFileURL()
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: missingURL)
        .snapshot().health,
      .fileMissing
    )

    let insertion = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    XCTAssertThrowsError(
      try SyncBatchAnchoredRecoveryRecord(
        change: insertion,
        lifecycle: .waiting(
          .deletionTarget(
            SyncBatchAnchoredRecoveryTestFactory.operation(99)
          )
        )
      )
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryCodingError,
        .unsupportedRecordShape
      )
    }
  }

  func testStoreRoundTripsDeletionAndCompatibilityMetadataExactly() throws {
    let fileURL = temporaryFileURL()
    let base = try SyncBatchAnchoredRecoveryTestFactory.state(
      text: "AB",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(1)
    )
    let change = try SyncBatchAnchoredRecoveryTestFactory.deletionChange(
      state: base,
      offset: 0,
      length: 1,
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2),
      expectedText: "A",
      baseContentHash: SyncBatchContentHash.sha256Hex(for: "AB")
    )
    let record = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .deletionTarget(
        SyncBatchAnchoredRecoveryTestFactory.operation(99)
      )
    )
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)

    try store.apply([.insertExpectedAbsent(record)])

    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [record]
    )
  }

  func testEquivalentRecordSetsProduceIdenticalPersistedData() throws {
    let firstURL = temporaryFileURL()
    let secondURL = temporaryFileURL()
    let dependency = try SyncBatchAnchoredRecoveryTestFactory.element(
      SyncBatchAnchoredRecoveryTestFactory.operation(1),
      offset: 0
    )
    let records = try [UInt64(2), UInt64(3)].map { counter in
      try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
        change: SyncBatchAnchoredRecoveryTestFactory.insertionChange(
          state: .empty,
          offset: 0,
          text: String(counter),
          operationID: SyncBatchAnchoredRecoveryTestFactory.operation(counter)
        ),
        dependency: .insertionAnchor(dependency)
      )
    }
    let first = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: firstURL)
    try first.apply(records.map(SyncBatchAnchoredRecoveryStoreTransition.insertExpectedAbsent))
    let second = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: secondURL)
    try second.apply(
      records.reversed().map(SyncBatchAnchoredRecoveryStoreTransition.insertExpectedAbsent)
    )

    XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
  }

  func testDuplicateAndStaleTransitionBatchesLeaveStoreUnchanged() throws {
    let fileURL = temporaryFileURL()
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(3)
    )
    let first = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(1),
          offset: 0
        )
      )
    )
    let replacement = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(2),
          offset: 0
        )
      )
    )
    let stale = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(99),
          offset: 0
        )
      )
    )
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    try store.apply([.insertExpectedAbsent(first)])
    let originalData = try Data(contentsOf: fileURL)

    XCTAssertThrowsError(
      try store.apply([
        .replace(expected: first, replacement: replacement),
        .removeCommitted(expected: first),
      ])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .duplicateTransition(first.key)
      )
    }
    XCTAssertThrowsError(
      try store.apply([.replace(expected: stale, replacement: replacement)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .staleExpectedRecord(first.key)
      )
    }
    XCTAssertEqual(store.snapshot().records, [first])
    XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
  }

  func testExactRemovalPersistsAndStaleRemovalIsRejected() throws {
    let fileURL = temporaryFileURL()
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let record = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(1),
          offset: 0
        )
      )
    )
    let stale = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(99),
          offset: 0
        )
      )
    )
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    try store.apply([.insertExpectedAbsent(record)])

    XCTAssertThrowsError(try store.apply([.removeCommitted(expected: stale)]))
    XCTAssertEqual(store.snapshot().records, [record])
    XCTAssertTrue(try store.apply([.removeCommitted(expected: record)]))
    XCTAssertTrue(store.snapshot().records.isEmpty)
    XCTAssertTrue(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records.isEmpty
    )
  }

  func testUnsupportedRecordShapeAndReadFailureRemainDistinct() throws {
    let validURL = temporaryFileURL()
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let record = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(1),
          offset: 0
        )
      )
    )
    let encodedRecord = try JSONEncoder().encode(record)
    guard var object = try JSONSerialization.jsonObject(with: encodedRecord) as? [String: Any],
      var lifecycle = object["lifecycle"] as? [String: Any]
    else {
      return XCTFail("Unable to inspect encoded recovery record")
    }
    lifecycle["kind"] = "futureLifecycle"
    object["lifecycle"] = lifecycle
    let envelope: [String: Any] = ["version": 2, "records": [object]]
    try JSONSerialization.data(withJSONObject: envelope)
      .write(to: validURL, options: .atomic)
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: validURL)
        .snapshot().health,
      .unsupportedRecordShape
    )

    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    guard
      case .readFailed = FileBackedSyncBatchAnchoredRecoveryStore(
        fileURL: directoryURL
      ).snapshot().health
    else {
      return XCTFail("Expected readFailed health")
    }
  }

  func testFullReplacementRecoversUnsupportedStore() throws {
    let fileURL = temporaryFileURL()
    try Data(#"{"version":99,"records":[]}"#.utf8)
      .write(to: fileURL, options: .atomic)
    let store = FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
    XCTAssertEqual(store.snapshot().health, .unsupportedVersion(99))

    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(2)
    )
    let record = try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(1),
          offset: 0
        )
      )
    )
    XCTAssertThrowsError(
      try store.apply([.insertExpectedAbsent(record)])
    ) { error in
      XCTAssertEqual(
        error as? SyncBatchAnchoredRecoveryStoreError,
        .unhealthyPersistence
      )
    }

    try store.replaceAllForRecovery([record])

    XCTAssertEqual(store.snapshot().health, .healthy)
    XCTAssertEqual(store.snapshot().records, [record])
    XCTAssertEqual(
      FileBackedSyncBatchAnchoredRecoveryStore(fileURL: fileURL)
        .snapshot().records,
      [record]
    )
  }

  private func makeWaitingRecord(
    counter: UInt64,
    dependencyCounter: UInt64
  ) throws -> SyncBatchAnchoredRecoveryRecord {
    let change = try SyncBatchAnchoredRecoveryTestFactory.insertionChange(
      state: .empty,
      offset: 0,
      text: "A",
      operationID: SyncBatchAnchoredRecoveryTestFactory.operation(counter)
    )
    return try SyncBatchAnchoredRecoveryTestFactory.waitingRecord(
      change: change,
      dependency: .insertionAnchor(
        try SyncBatchAnchoredRecoveryTestFactory.element(
          SyncBatchAnchoredRecoveryTestFactory.operation(dependencyCounter),
          offset: 0
        )
      )
    )
  }

  private func assertWriteFailed(
    _ health: SyncBatchAnchoredRecoveryStoreHealth,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .writeFailed = health else {
      return XCTFail("Expected writeFailed health", file: file, line: line)
    }
  }

  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("myr177-\(UUID().uuidString)-recovery.json")
  }

  private enum InjectedError: Error {
    case failure
  }
}
