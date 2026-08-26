import Foundation
import Dispatch

enum MyRAMSyncPayloadKind: String, Codable {
    case note
    case folder
    case pinnedThought
    case photoAttachment
    case syncConflict
}

struct MyRAMNoteSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let title: String
    let content: String
    let richTextContentData: Data?
    let isPinned: Bool
    let createdAt: Date
    let modifiedAt: Date
    let deletedAt: Date?
    let folderID: UUID?
    let baseTitle: String?
    let baseContent: String?
    let baseRichTextContentData: Data?

    init(
        note: Note,
        baseTitle: String? = nil,
        baseContent: String? = nil,
        baseRichTextContentData: Data? = nil
    ) {
        kind = .note
        id = note.id
        title = note.title
        content = note.content
        richTextContentData = note.richTextContentData
        isPinned = note.isPinned ?? false
        createdAt = note.createdAt
        modifiedAt = note.modifiedAt
        deletedAt = note.deletedAt
        folderID = note.folder?.id
        self.baseTitle = baseTitle
        self.baseContent = baseContent
        self.baseRichTextContentData = baseRichTextContentData
    }
}

struct MyRAMFolderSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let parentFolderID: UUID?
    let isDeleted: Bool

    init(folder: Folder, isDeleted: Bool = false) {
        kind = .folder
        id = folder.id
        name = folder.name
        createdAt = folder.createdAt
        modifiedAt = folder.modifiedAt
        parentFolderID = folder.parentFolder?.id
        self.isDeleted = isDeleted
    }
}

struct MyRAMPinnedThoughtSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let noteID: UUID?
    let text: String
    let order: Int
    let isCollapsed: Bool
    let createdAt: Date
    let modifiedAt: Date
    let isDeleted: Bool
    let baseText: String?

    init(thought: PinnedThought, isDeleted: Bool = false, baseText: String? = nil) {
        kind = .pinnedThought
        id = thought.id
        noteID = thought.note?.id
        text = thought.text
        order = thought.order
        isCollapsed = thought.isCollapsed
        createdAt = thought.createdAt
        modifiedAt = thought.modifiedAt
        self.isDeleted = isDeleted
        self.baseText = baseText
    }
}

struct MyRAMPhotoAttachmentSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let noteID: UUID?
    let imageData: Data
    let createdAt: Date
    let isDeleted: Bool

    init(attachment: NotePhotoAttachment, isDeleted: Bool = false) {
        kind = .photoAttachment
        id = attachment.id
        noteID = attachment.note?.id
        imageData = attachment.imageData
        createdAt = attachment.createdAt
        self.isDeleted = isDeleted
    }
}

enum MyRAMSyncConflictAction: String, Codable {
    case preserved
    case resolved
}

struct MyRAMSyncConflictPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let action: MyRAMSyncConflictAction
    let conflict: SyncConflictVersion?
    let conflictID: UUID
    let resolvedText: String?
    let baseText: String?
    let updatedAt: Date

    init(
        action: MyRAMSyncConflictAction,
        conflict: SyncConflictVersion,
        resolvedText: String? = nil,
        baseText: String? = nil,
        updatedAt: Date = Date()
    ) {
        kind = .syncConflict
        self.action = action
        self.conflict = conflict
        conflictID = conflict.id
        self.resolvedText = resolvedText
        self.baseText = baseText
        self.updatedAt = updatedAt
    }
}

enum MyRAMSyncPayloadCoding {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ payload: MyRAMNoteSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMFolderSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMPinnedThoughtSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMPhotoAttachmentSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMSyncConflictPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func decodeNote(from data: Data) throws -> MyRAMNoteSyncPayload {
        try decoder.decode(MyRAMNoteSyncPayload.self, from: data)
    }

    static func decodeFolder(from data: Data) throws -> MyRAMFolderSyncPayload {
        try decoder.decode(MyRAMFolderSyncPayload.self, from: data)
    }

    static func decodePinnedThought(from data: Data) throws -> MyRAMPinnedThoughtSyncPayload {
        try decoder.decode(MyRAMPinnedThoughtSyncPayload.self, from: data)
    }

    static func decodePhotoAttachment(from data: Data) throws -> MyRAMPhotoAttachmentSyncPayload {
        try decoder.decode(MyRAMPhotoAttachmentSyncPayload.self, from: data)
    }

    static func decodeSyncConflict(from data: Data) throws -> MyRAMSyncConflictPayload {
        try decoder.decode(MyRAMSyncConflictPayload.self, from: data)
    }
}

// MARK: - Opt-in local sync benchmark telemetry

/// Launch configuration used by development/verification builds. The mode is intentionally
/// non-persistent: nothing in the app writes a preference that could accidentally leave
/// benchmark capture enabled for later launches.
enum MyRAMSyncBenchmarkConfiguration {
    static let loggingEnvironmentKey = "MYRAM_SYNC_BENCHMARK_LOGGING"
    static let runIDEnvironmentKey = "MYRAM_SYNC_BENCHMARK_RUN_ID"

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let rawValue = environment[loggingEnvironmentKey] else { return false }
        return ["1", "true", "yes", "on"].contains(rawValue.lowercased())
    }

    static func runID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment[runIDEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum MyRAMSyncBenchmarkPlatform: String, Codable, Sendable {
    case iOS
    case macOS
}

enum MyRAMSyncBenchmarkEventType: String, Codable, Sendable {
    case sessionStarted
    case queueLoaded
    case batchQueued
    case batchQueueDuplicate
    case batchDequeued
    case queueReplaced
    case queueWriteFailed
    case peerObserved
    case peerConnectionState
    case messageEncoded
    case messageDecoded
    case batchSendStarted
    case batchSendSucceeded
    case batchSendFailed
    case batchSendDeferred
    case batchReceived
    case batchCaptureCompleted
    case batchConvergenceCompleted
    case batchAcknowledgementSent
    case batchAcknowledgementSendFailed
    case batchAcknowledgementReceived
}

struct MyRAMSyncBenchmarkEvent: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let sessionID: UUID
    let runID: String?
    let timestamp: Date
    /// Explicit sub-second wall-clock value for combining separately recorded device artifacts.
    let unixEpochMilliseconds: Int64
    /// Process-local monotonic time for precise duration calculations that must ignore wall-clock changes.
    let monotonicNanoseconds: UInt64
    let platform: MyRAMSyncBenchmarkPlatform
    let deviceID: String
    let eventType: MyRAMSyncBenchmarkEventType
    let batchID: String?
    let peerDeviceID: String?
    let queueName: String?
    let queueDepth: Int?
    let itemCount: Int?
    let outcome: String?
    let detail: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: UUID,
        runID: String?,
        timestamp: Date = Date(),
        unixEpochMilliseconds: Int64? = nil,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        platform: MyRAMSyncBenchmarkPlatform,
        deviceID: String,
        eventType: MyRAMSyncBenchmarkEventType,
        batchID: String? = nil,
        peerDeviceID: String? = nil,
        queueName: String? = nil,
        queueDepth: Int? = nil,
        itemCount: Int? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.runID = runID
        self.timestamp = timestamp
        self.unixEpochMilliseconds = unixEpochMilliseconds
            ?? Int64(timestamp.timeIntervalSince1970 * 1_000)
        self.monotonicNanoseconds = monotonicNanoseconds
        self.platform = platform
        self.deviceID = deviceID
        self.eventType = eventType
        self.batchID = batchID
        self.peerDeviceID = peerDeviceID
        self.queueName = queueName
        self.queueDepth = queueDepth
        self.itemCount = itemCount
        self.outcome = outcome
        self.detail = detail
    }
}

/// Append-only JSON Lines recorder. Recording is deliberately best-effort and happens on a
/// private queue so telemetry can never become a prerequisite for synchronization progress.
final class MyRAMSyncBenchmarkRecorder: @unchecked Sendable {
    let sessionID: UUID
    let runID: String?
    let platform: MyRAMSyncBenchmarkPlatform
    let deviceID: String
    let artifactURL: URL?

    private let enabled: Bool
    private let writerQueue = DispatchQueue(label: "com.myram.sync-benchmark-writer", qos: .utility)

    init(
        enabled: Bool,
        platform: MyRAMSyncBenchmarkPlatform,
        deviceID: String,
        runID: String? = nil,
        sessionID: UUID = UUID(),
        outputDirectoryURL: URL? = nil
    ) {
        self.enabled = enabled
        self.platform = platform
        self.deviceID = deviceID
        self.runID = runID
        self.sessionID = sessionID

        if enabled {
            let directory = outputDirectoryURL ?? Self.defaultOutputDirectoryURL()
            artifactURL = directory.appendingPathComponent(
                "sync-benchmark-\(platform.rawValue)-\(sessionID.uuidString).jsonl"
            )
        } else {
            artifactURL = nil
        }
    }

    func record(
        _ eventType: MyRAMSyncBenchmarkEventType,
        batchID: String? = nil,
        peerDeviceID: String? = nil,
        queueName: String? = nil,
        queueDepth: Int? = nil,
        itemCount: Int? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) {
        guard enabled, let artifactURL else { return }

        let event = MyRAMSyncBenchmarkEvent(
            sessionID: sessionID,
            runID: runID,
            platform: platform,
            deviceID: deviceID,
            eventType: eventType,
            batchID: batchID,
            peerDeviceID: peerDeviceID,
            queueName: queueName,
            queueDepth: queueDepth,
            itemCount: itemCount,
            outcome: outcome,
            detail: detail
        )

        writerQueue.async {
            Self.append(event, to: artifactURL)
        }
    }

    /// Test-only synchronization seam; production sync never waits for telemetry I/O.
    func flushForTesting() {
        writerQueue.sync {}
    }

    private static func append(_ event: MyRAMSyncBenchmarkEvent, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)

            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Observability is never allowed to affect synchronization behavior.
        }
    }

    private static func defaultOutputDirectoryURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("SyncBenchmarks", isDirectory: true)
    }
}

/// Process-scoped facade configured once the platform's stable sync device identity is known.
/// A single recorder means every event produced during one app launch shares one session ID.
final class MyRAMSyncBenchmarkTelemetry: @unchecked Sendable {
    static let shared = MyRAMSyncBenchmarkTelemetry()

    private let lock = NSLock()
    private var recorder: MyRAMSyncBenchmarkRecorder?

    private init() {}

    func configure(
        platform: MyRAMSyncBenchmarkPlatform,
        deviceID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard MyRAMSyncBenchmarkConfiguration.isEnabled(environment: environment) else { return }

        let createdRecorder: MyRAMSyncBenchmarkRecorder? = lock.withLock {
            guard recorder == nil else { return nil }
            let recorder = MyRAMSyncBenchmarkRecorder(
                enabled: true,
                platform: platform,
                deviceID: deviceID,
                runID: MyRAMSyncBenchmarkConfiguration.runID(environment: environment)
            )
            self.recorder = recorder
            return recorder
        }

        guard let createdRecorder else { return }
        createdRecorder.record(.sessionStarted)
        if let artifactURL = createdRecorder.artifactURL {
            print("[MyRAM Sync Benchmark] \(artifactURL.path)")
        }
    }

    func record(
        _ eventType: MyRAMSyncBenchmarkEventType,
        batchID: String? = nil,
        peerDeviceID: String? = nil,
        queueName: String? = nil,
        queueDepth: Int? = nil,
        itemCount: Int? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) {
        let currentRecorder = lock.withLock { recorder }
        currentRecorder?.record(
            eventType,
            batchID: batchID,
            peerDeviceID: peerDeviceID,
            queueName: queueName,
            queueDepth: queueDepth,
            itemCount: itemCount,
            outcome: outcome,
            detail: detail
        )
    }

    /// Narrow test seam for exercising real sync call paths with an isolated artifact.
    func replaceRecorderForTesting(_ recorder: MyRAMSyncBenchmarkRecorder?) {
        lock.withLock {
            self.recorder = recorder
        }
    }

    func flushForTesting() {
        let currentRecorder = lock.withLock { recorder }
        currentRecorder?.flushForTesting()
    }
}
