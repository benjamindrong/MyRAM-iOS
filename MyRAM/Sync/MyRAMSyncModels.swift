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

// MARK: - BEN-36 isolated endurance harness

struct MyRAMSyncBenchmarkEnduranceLaunch: Equatable, Sendable {
    let runID: String
    let durationSeconds: Int
}

enum MyRAMSyncBenchmarkEnduranceLaunchValidation: Equatable, Sendable {
    case notRequested
    case invalid(String)
    case valid(MyRAMSyncBenchmarkEnduranceLaunch)
}

extension MyRAMSyncBenchmarkConfiguration {
    static var enduranceEnvironmentKey: String { "MYRAM_SYNC_BENCHMARK_ENDURANCE" }
    static var enduranceDurationEnvironmentKey: String { "MYRAM_SYNC_BENCHMARK_ENDURANCE_SECONDS" }
    static var enduranceDefaultDurationSeconds: Int { 720 }
    static var enduranceMinimumDurationSeconds: Int { 300 }
    static var enduranceMaximumDurationSeconds: Int { 900 }

    static func isEnduranceRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let rawValue = environment[enduranceEnvironmentKey] else { return false }
        return ["1", "true", "yes", "on"].contains(rawValue.lowercased())
    }

    static func enduranceLaunchValidation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> MyRAMSyncBenchmarkEnduranceLaunchValidation {
        guard isEnduranceRequested(environment: environment) else { return .notRequested }
        guard isEnabled(environment: environment) else {
            return .invalid("MYRAM_SYNC_BENCHMARK_LOGGING must be enabled")
        }
        guard let runID = runID(environment: environment) else {
            return .invalid("MYRAM_SYNC_BENCHMARK_RUN_ID is required")
        }
        guard arguments.contains("UITEST_MODE") else {
            return .invalid("UITEST_MODE is required so benchmark notes never use the normal SwiftData store")
        }

        let durationSeconds: Int
        if let rawDuration = environment[enduranceDurationEnvironmentKey] {
            guard let parsedDuration = Int(rawDuration),
                  (enduranceMinimumDurationSeconds...enduranceMaximumDurationSeconds).contains(parsedDuration) else {
                return .invalid(
                    "MYRAM_SYNC_BENCHMARK_ENDURANCE_SECONDS must be between \(enduranceMinimumDurationSeconds) and \(enduranceMaximumDurationSeconds)"
                )
            }
            durationSeconds = parsedDuration
        } else {
            durationSeconds = enduranceDefaultDurationSeconds
        }

        return .valid(MyRAMSyncBenchmarkEnduranceLaunch(
            runID: runID,
            durationSeconds: durationSeconds
        ))
    }

    static func enduranceLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> MyRAMSyncBenchmarkEnduranceLaunch? {
        guard case .valid(let launch) = enduranceLaunchValidation(
            environment: environment,
            arguments: arguments
        ) else {
            return nil
        }
        return launch
    }

    /// Every persistent sync artifact used by an endurance launch must resolve beneath this
    /// run-scoped directory. Even an invalid endurance request is redirected away from normal
    /// MyRAM state so a missing safety flag cannot contaminate the next regular launch.
    static func enduranceStateDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard isEnduranceRequested(environment: environment) else { return nil }
        let runComponent = runID(environment: environment).map(safePathComponent) ?? "rejected-launch"
        return benchmarkRootDirectoryURL()
            .appendingPathComponent("Endurance", isDirectory: true)
            .appendingPathComponent(runComponent, isDirectory: true)
            .appendingPathComponent("State", isDirectory: true)
    }

    static func enduranceStateFileURL(
        _ filename: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        enduranceStateDirectoryURL(environment: environment)?
            .appendingPathComponent(filename)
    }

    static func enduranceStateSubdirectoryURL(
        _ directoryName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        enduranceStateDirectoryURL(environment: environment)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func enduranceOutputDirectoryURL(
        runID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        benchmarkRootDirectoryURL()
            .appendingPathComponent("Endurance", isDirectory: true)
            .appendingPathComponent(safePathComponent(runID), isDirectory: true)
    }

    static func enduranceUserDefaultsKey(
        _ productionKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard isEnduranceRequested(environment: environment) else { return productionKey }
        let runComponent = runID(environment: environment).map(safePathComponent) ?? "rejected-launch"
        return "\(productionKey).endurance.\(runComponent)"
    }

    private static func benchmarkRootDirectoryURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("SyncBenchmarks", isDirectory: true)
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "unnamed-run" : result
    }
}

enum MyRAMSyncBenchmarkEnduranceControlKind: String, Codable, Sendable {
    case launch
    case phase
    case checkpoint
    case network
    case localMutationFailure
    case verification
    case completed
    case failed
}

struct MyRAMSyncBenchmarkEnduranceControlEvent: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runID: String
    let platform: MyRAMSyncBenchmarkPlatform
    let timestamp: Date
    let unixEpochMilliseconds: Int64
    let monotonicNanoseconds: UInt64
    let kind: MyRAMSyncBenchmarkEnduranceControlKind
    let phase: String?
    let operationCount: Int?
    let queueDepth: Int?
    let outcome: String?
    let detail: String?

    init(
        runID: String,
        platform: MyRAMSyncBenchmarkPlatform,
        kind: MyRAMSyncBenchmarkEnduranceControlKind,
        phase: String? = nil,
        operationCount: Int? = nil,
        queueDepth: Int? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) {
        let now = Date()
        schemaVersion = Self.currentSchemaVersion
        self.runID = runID
        self.platform = platform
        timestamp = now
        unixEpochMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        monotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.kind = kind
        self.phase = phase
        self.operationCount = operationCount
        self.queueDepth = queueDepth
        self.outcome = outcome
        self.detail = detail
    }
}

struct MyRAMSyncBenchmarkEnduranceNoteDigest: Codable, Equatable, Sendable {
    let title: String
    let bodySHA256: String
}

struct MyRAMSyncBenchmarkEnduranceResult: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let runID: String
    let platform: MyRAMSyncBenchmarkPlatform
    let startedAt: Date
    let finishedAt: Date
    let outcome: String
    let attemptedOperations: Int
    let committedOperations: Int
    let failedOperations: Int
    let finalUnsentBatchCount: Int
    let connectedAtFinish: Bool
    let expectedBenchmarkNoteCount: Int
    let observedBenchmarkNotes: [MyRAMSyncBenchmarkEnduranceNoteDigest]
    let detail: String?
}

final class MyRAMSyncBenchmarkEnduranceRecorder: @unchecked Sendable {
    private let runID: String
    private let platform: MyRAMSyncBenchmarkPlatform
    private let controlURL: URL
    private let resultURL: URL
    private let writerQueue = DispatchQueue(label: "com.myram.sync-benchmark-endurance-writer", qos: .utility)

    init(runID: String, platform: MyRAMSyncBenchmarkPlatform) {
        self.runID = runID
        self.platform = platform
        let directory = MyRAMSyncBenchmarkConfiguration.enduranceOutputDirectoryURL(runID: runID)
        controlURL = directory.appendingPathComponent("endurance-control-\(platform.rawValue).jsonl")
        resultURL = directory.appendingPathComponent("endurance-result-\(platform.rawValue).json")
    }

    func record(
        _ kind: MyRAMSyncBenchmarkEnduranceControlKind,
        phase: String? = nil,
        operationCount: Int? = nil,
        queueDepth: Int? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) {
        let event = MyRAMSyncBenchmarkEnduranceControlEvent(
            runID: runID,
            platform: platform,
            kind: kind,
            phase: phase,
            operationCount: operationCount,
            queueDepth: queueDepth,
            outcome: outcome,
            detail: detail
        )
        writerQueue.async {
            Self.append(event, to: self.controlURL)
        }
    }

    func writeResult(_ result: MyRAMSyncBenchmarkEnduranceResult) {
        writerQueue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(to: resultURL, options: .atomic)
            } catch {
                // Endurance evidence must never become a new sync failure mode.
            }
        }
    }

    private static func append(_ event: MyRAMSyncBenchmarkEnduranceControlEvent, to url: URL) {
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
            // Evidence capture is deliberately best-effort.
        }
    }
}

enum MyRAMSyncBenchmarkEnduranceWorkload {
    static let notesPerPlatform = 4
    static let finalDrainSeconds = 90
    static let mutationIntervalNanoseconds: UInt64 = 600_000_000

    struct OutageWindow: Equatable, Sendable {
        let startSecond: Int
        let endSecond: Int

        func contains(_ elapsedSeconds: Int) -> Bool {
            elapsedSeconds >= startSecond && elapsedSeconds < endSecond
        }
    }

    static func expectedTitles(runID: String) -> [String] {
        [MyRAMSyncBenchmarkPlatform.iOS, .macOS].flatMap { platform in
            (1...notesPerPlatform).map { index in
                noteTitle(runID: runID, platform: platform, index: index)
            }
        }
    }

    static func noteTitle(
        runID: String,
        platform: MyRAMSyncBenchmarkPlatform,
        index: Int
    ) -> String {
        "BEN36-\(runID)-\(platform.rawValue)-\(index)"
    }

    static func initialBody(
        runID: String,
        platform: MyRAMSyncBenchmarkPlatform,
        index: Int
    ) -> String {
        "BEN-36 synthetic endurance note | run=\(runID) | platform=\(platform.rawValue) | note=\(index)"
    }

    static func mutationToken(
        platform: MyRAMSyncBenchmarkPlatform,
        operation: Int
    ) -> String {
        "\n\(platform.rawValue)-op-\(operation)"
    }

    static func outageWindows(totalDurationSeconds: Int) -> [OutageWindow] {
        let workloadSeconds = max(180, totalDurationSeconds - finalDrainSeconds)
        let starts = [0.20, 0.40, 0.60, 0.78]
        let durations = [25, 35, 25, 35]
        return zip(starts, durations).map { fraction, duration in
            let start = Int(Double(workloadSeconds) * fraction)
            return OutageWindow(startSecond: start, endSecond: min(workloadSeconds, start + duration))
        }
    }
}

private enum MyRAMSyncBenchmarkEnduranceDriverSupport {
    static func benchmarkDigests(
        notes: [Note],
        runID: String
    ) -> [MyRAMSyncBenchmarkEnduranceNoteDigest] {
        let prefix = "BEN36-\(runID)-"
        return notes
            .filter { $0.deletedAt == nil && $0.title.hasPrefix(prefix) }
            .map {
                MyRAMSyncBenchmarkEnduranceNoteDigest(
                    title: $0.title,
                    bodySHA256: SyncBatchContentHash.sha256Hex(for: $0.content)
                )
            }
            .sorted { $0.title < $1.title }
    }

    static func expectedTitlesObserved(
        _ digests: [MyRAMSyncBenchmarkEnduranceNoteDigest],
        runID: String
    ) -> Bool {
        let observed = Set(digests.map(\.title))
        return Set(MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: runID)).isSubset(of: observed)
    }
}

#if DEBUG && os(iOS)
@MainActor
final class MyRAMSyncBenchmarkEnduranceIOSDriver {
    static let shared = MyRAMSyncBenchmarkEnduranceIOSDriver()
    private var task: Task<Void, Never>?

    private init() {}

    func startIfNeeded(state: NotesListState) {
        guard task == nil,
              MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() else { return }
        task = Task { @MainActor in
            await run(state: state)
        }
    }

    private func run(state: NotesListState) async {
        switch MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation() {
        case .notRequested:
            return
        case .invalid(let message):
            print("[MyRAM Sync Endurance] rejected iOS launch: \(message)")
            return
        case .valid(let launch):
            await run(state: state, launch: launch)
        }
    }

    private func run(
        state: NotesListState,
        launch: MyRAMSyncBenchmarkEnduranceLaunch
    ) async {
        let recorder = MyRAMSyncBenchmarkEnduranceRecorder(runID: launch.runID, platform: .iOS)
        let startedAt = Date()
        recorder.record(.launch, outcome: "accepted", detail: "durationSeconds=\(launch.durationSeconds)")

        guard await waitForBootstrapAndConnection(state: state, timeoutSeconds: 60) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: 0,
                committed: 0,
                failed: 0,
                state: state,
                detail: "initial peer connection was not established"
            )
            return
        }

        recorder.record(.phase, phase: "seed", outcome: "started")
        var noteIDs: [UUID] = []
        var attempted = 0
        var committed = 0
        var failed = 0

        for index in 1...MyRAMSyncBenchmarkEnduranceWorkload.notesPerPlatform {
            guard let note = state.vm.createNewNote() else {
                failed += 1
                continue
            }
            attempted += 1
            let title = MyRAMSyncBenchmarkEnduranceWorkload.noteTitle(
                runID: launch.runID,
                platform: .iOS,
                index: index
            )
            let body = MyRAMSyncBenchmarkEnduranceWorkload.initialBody(
                runID: launch.runID,
                platform: .iOS,
                index: index
            )
            if await state.vm.commitNoteEditForProduction(note, title: title, content: body) {
                committed += 1
                noteIDs.append(note.id)
            } else {
                failed += 1
            }
        }
        recorder.record(.phase, phase: "seed", operationCount: attempted, outcome: "completed")

        guard noteIDs.count == MyRAMSyncBenchmarkEnduranceWorkload.notesPerPlatform else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: attempted,
                committed: committed,
                failed: failed,
                state: state,
                detail: "unable to create the complete synthetic iOS note set"
            )
            return
        }

        let workloadEnd = startedAt.addingTimeInterval(
            TimeInterval(max(1, launch.durationSeconds - MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds))
        )
        recorder.record(.phase, phase: "workload", outcome: "started")
        var operation = 0

        while Date() < workloadEnd, !Task.isCancelled {
            if !state.syncController.hasConnectedPeers,
               let peer = state.syncController.availablePeers.first {
                state.syncController.invite(peer)
            }

            let noteID = noteIDs[operation % noteIDs.count]
            attempted += 1
            if let note = state.vm.refreshedNote(withID: noteID) {
                let nextBody = note.content + MyRAMSyncBenchmarkEnduranceWorkload.mutationToken(
                    platform: .iOS,
                    operation: operation
                )
                if await state.vm.commitNoteEditForProduction(
                    note,
                    title: note.title,
                    content: nextBody
                ) {
                    committed += 1
                } else {
                    failed += 1
                    recorder.record(
                        .localMutationFailure,
                        phase: "workload",
                        operationCount: operation,
                        outcome: "commitRejected"
                    )
                }
            } else {
                failed += 1
                recorder.record(
                    .localMutationFailure,
                    phase: "workload",
                    operationCount: operation,
                    outcome: "noteMissing"
                )
            }

            operation += 1
            if operation % 50 == 0 {
                recorder.record(
                    .checkpoint,
                    phase: "workload",
                    operationCount: operation,
                    queueDepth: state.syncController.unsentBatchQueueSnapshot().pendingBatches.count,
                    outcome: state.syncController.hasConnectedPeers ? "connected" : "disconnected"
                )
            }
            try? await Task.sleep(nanoseconds: MyRAMSyncBenchmarkEnduranceWorkload.mutationIntervalNanoseconds)
        }

        recorder.record(.phase, phase: "finalDrain", operationCount: operation, outcome: "started")
        let finalQueueDepth = await waitForIOSDrain(state: state, timeoutSeconds: MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds)
        let notes = state.vm.fetchSearchableNotes()
        let digests = MyRAMSyncBenchmarkEnduranceDriverSupport.benchmarkDigests(notes: notes, runID: launch.runID)
        let hasExpectedNotes = MyRAMSyncBenchmarkEnduranceDriverSupport.expectedTitlesObserved(digests, runID: launch.runID)
        let locallyComplete = failed == 0
            && finalQueueDepth == 0
            && state.syncController.hasConnectedPeers
            && hasExpectedNotes

        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .iOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: locallyComplete ? "locallyComplete" : "incomplete",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: finalQueueDepth,
            connectedAtFinish: state.syncController.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: hasExpectedNotes ? nil : "one or more cross-device synthetic notes were absent at final verification"
        )
        recorder.record(
            .verification,
            phase: "finalDrain",
            operationCount: operation,
            queueDepth: finalQueueDepth,
            outcome: result.outcome,
            detail: "observedBenchmarkNotes=\(digests.count)"
        )
        recorder.writeResult(result)
        recorder.record(.completed, outcome: result.outcome)
    }

    private func waitForBootstrapAndConnection(
        state: NotesListState,
        timeoutSeconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline, !Task.isCancelled {
            if state.bootstrapState == .ready && state.syncController.hasConnectedPeers {
                return true
            }
            if state.bootstrapState == .ready,
               let peer = state.syncController.availablePeers.first {
                state.syncController.invite(peer)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func waitForIOSDrain(
        state: NotesListState,
        timeoutSeconds: Int
    ) async -> Int {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var stableZeroSamples = 0
        var lastDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
        while Date() < deadline, !Task.isCancelled {
            if !state.syncController.hasConnectedPeers,
               let peer = state.syncController.availablePeers.first {
                state.syncController.invite(peer)
            }
            lastDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
            if lastDepth == 0 && state.syncController.hasConnectedPeers {
                stableZeroSamples += 1
                if stableZeroSamples >= 5 { return 0 }
            } else {
                stableZeroSamples = 0
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return lastDepth
    }

    private func finishFailure(
        recorder: MyRAMSyncBenchmarkEnduranceRecorder,
        launch: MyRAMSyncBenchmarkEnduranceLaunch,
        startedAt: Date,
        attempted: Int,
        committed: Int,
        failed: Int,
        state: NotesListState,
        detail: String
    ) {
        let digests = MyRAMSyncBenchmarkEnduranceDriverSupport.benchmarkDigests(
            notes: state.vm.fetchSearchableNotes(),
            runID: launch.runID
        )
        let queueDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .iOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: "failed",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: queueDepth,
            connectedAtFinish: state.syncController.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: detail
        )
        recorder.writeResult(result)
        recorder.record(.failed, queueDepth: queueDepth, outcome: "failed", detail: detail)
    }
}
#endif

#if DEBUG && os(macOS)
@MainActor
final class MyRAMSyncBenchmarkEnduranceMacDriver {
    static let shared = MyRAMSyncBenchmarkEnduranceMacDriver()
    private static let invitationRetryInterval: TimeInterval = 12
    private var task: Task<Void, Never>?
    private var convergenceCoordinator: MacSyncConvergenceCoordinator?
    private var lastInvitationAt: Date?

    private init() {}

    func startIfNeeded() {
        guard task == nil,
              MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() else { return }
        task = Task { @MainActor in
            await run()
        }
    }

    private func run() async {
        switch MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation() {
        case .notRequested:
            return
        case .invalid(let message):
            print("[MyRAM Sync Endurance] rejected macOS launch: \(message)")
            return
        case .valid(let launch):
            await run(launch: launch)
        }
    }

    private func run(launch: MyRAMSyncBenchmarkEnduranceLaunch) async {
        let controller = MyRAMMacProcessSyncCompositionRoot.syncController
        configureConvergenceIfNeeded(controller: controller)
        controller.startNetworkingIfNeeded()
        let recorder = MyRAMSyncBenchmarkEnduranceRecorder(runID: launch.runID, platform: .macOS)
        let adapter = MacNotePersistenceAdapter()
        let startedAt = Date()
        recorder.record(.launch, outcome: "accepted", detail: "durationSeconds=\(launch.durationSeconds)")

        guard await waitForMacConnection(controller: controller, timeoutSeconds: 60) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: 0,
                committed: 0,
                failed: 0,
                controller: controller,
                adapter: adapter,
                detail: "initial peer connection was not established"
            )
            return
        }

        recorder.record(.phase, phase: "seed", outcome: "started")
        var noteIDs: [UUID] = []
        var attempted = 0
        var committed = 0
        var failed = 0

        for index in 1...MyRAMSyncBenchmarkEnduranceWorkload.notesPerPlatform {
            attempted += 1
            do {
                let note = try adapter.createNote(
                    title: MyRAMSyncBenchmarkEnduranceWorkload.noteTitle(
                        runID: launch.runID,
                        platform: .macOS,
                        index: index
                    ),
                    body: MyRAMSyncBenchmarkEnduranceWorkload.initialBody(
                        runID: launch.runID,
                        platform: .macOS,
                        index: index
                    )
                )
                let capturedCreate = SyncConvergenceCapturedLocalChange(
                    change: SyncBatchNoteChangeCapture.noteCreated(
                        noteID: note.id,
                        title: note.title,
                        body: note.content,
                        folderID: note.folder?.id,
                        createdAt: note.createdAt,
                        modifiedAt: note.modifiedAt
                    ),
                    evidence: nil
                )
                await controller.record(capturedCreate, at: note.modifiedAt)
                noteIDs.append(note.id)
                committed += 1
            } catch {
                failed += 1
                recorder.record(.localMutationFailure, phase: "seed", outcome: "createFailed", detail: error.localizedDescription)
            }
        }
        recorder.record(.phase, phase: "seed", operationCount: attempted, outcome: "completed")

        guard noteIDs.count == MyRAMSyncBenchmarkEnduranceWorkload.notesPerPlatform else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: attempted,
                committed: committed,
                failed: failed,
                controller: controller,
                adapter: adapter,
                detail: "unable to create the complete synthetic macOS note set"
            )
            return
        }

        let workloadSeconds = max(1, launch.durationSeconds - MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds)
        let workloadEnd = startedAt.addingTimeInterval(TimeInterval(workloadSeconds))
        let outageWindows = MyRAMSyncBenchmarkEnduranceWorkload.outageWindows(totalDurationSeconds: launch.durationSeconds)
        var networkEnabled = true
        var operation = 0
        recorder.record(.phase, phase: "workload", outcome: "started")

        while Date() < workloadEnd, !Task.isCancelled {
            let elapsedSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
            let shouldNetworkBeEnabled = !outageWindows.contains { $0.contains(elapsedSeconds) }
            if shouldNetworkBeEnabled != networkEnabled {
                networkEnabled = shouldNetworkBeEnabled
                controller.setBenchmarkEnduranceNetworkingEnabled(networkEnabled)
                recorder.record(
                    .network,
                    phase: "workload",
                    operationCount: operation,
                    queueDepth: controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count,
                    outcome: networkEnabled ? "resumed" : "suspended",
                    detail: "elapsedSeconds=\(elapsedSeconds)"
                )
            }

            if networkEnabled, !controller.hasConnectedPeers {
                inviteMacPeerIfDue(controller: controller)
            }

            let noteID = noteIDs[operation % noteIDs.count]
            attempted += 1
            do {
                guard let note = try adapter.loadNote(id: noteID) else {
                    throw MyRAMSyncBenchmarkEnduranceMacError.noteMissing
                }
                let nextBody = note.content + MyRAMSyncBenchmarkEnduranceWorkload.mutationToken(
                    platform: .macOS,
                    operation: operation
                )
                let prepared = try await adapter.prepareProductionLocalNoteEdit(
                    noteID: noteID,
                    proposedAttributedContent: NSAttributedString(string: nextBody)
                )
                try adapter.persistPreparedLocalNoteEdit(prepared)
                await controller.record(prepared.capturedChanges, at: prepared.modifiedAt)
                committed += 1
            } catch {
                failed += 1
                recorder.record(
                    .localMutationFailure,
                    phase: "workload",
                    operationCount: operation,
                    outcome: "commitFailed",
                    detail: error.localizedDescription
                )
            }

            operation += 1
            if operation % 50 == 0 {
                recorder.record(
                    .checkpoint,
                    phase: "workload",
                    operationCount: operation,
                    queueDepth: controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count,
                    outcome: controller.hasConnectedPeers ? "connected" : "disconnected"
                )
            }
            try? await Task.sleep(nanoseconds: MyRAMSyncBenchmarkEnduranceWorkload.mutationIntervalNanoseconds)
        }

        if !networkEnabled {
            controller.setBenchmarkEnduranceNetworkingEnabled(true)
            recorder.record(.network, phase: "finalDrain", operationCount: operation, outcome: "resumed")
        }
        recorder.record(.phase, phase: "finalDrain", operationCount: operation, outcome: "started")
        let finalQueueDepth = await waitForMacDrain(
            controller: controller,
            timeoutSeconds: MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds
        )
        let notes = (try? adapter.loadNotes()) ?? []
        let digests = MyRAMSyncBenchmarkEnduranceDriverSupport.benchmarkDigests(notes: notes, runID: launch.runID)
        let hasExpectedNotes = MyRAMSyncBenchmarkEnduranceDriverSupport.expectedTitlesObserved(digests, runID: launch.runID)
        let locallyComplete = failed == 0
            && finalQueueDepth == 0
            && controller.hasConnectedPeers
            && hasExpectedNotes

        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .macOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: locallyComplete ? "locallyComplete" : "incomplete",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: finalQueueDepth,
            connectedAtFinish: controller.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: hasExpectedNotes ? nil : "one or more cross-device synthetic notes were absent at final verification"
        )
        recorder.record(
            .verification,
            phase: "finalDrain",
            operationCount: operation,
            queueDepth: finalQueueDepth,
            outcome: result.outcome,
            detail: "observedBenchmarkNotes=\(digests.count)"
        )
        recorder.writeResult(result)
        recorder.record(.completed, outcome: result.outcome)
    }

    private func configureConvergenceIfNeeded(controller: MacSyncBatchController) {
        guard convergenceCoordinator == nil else { return }

        let presentationSurface = MacSyncConvergencePresentationSurface(
            selectedNoteID: { nil },
            hasUnsavedChanges: { false },
            refreshNotesList: {},
            closeRemovedSelectedEditor: { _ in },
            applyIncremental: { _, _, _ in
                EditorRemoteBatchApplyResult(
                    appliedCount: 0,
                    disposition: .noApplicableMutations
                )
            },
            reloadSelectedEditor: { _, _ in true },
            currentEditorBody: { nil }
        )
        let boundarySurface = MacSyncIncomingLocalBoundarySurface(
            prepareForIncomingBodyMutation: { noteIDs in
                for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    if let obligation = await controller.takePendingLocalObligationIfAffecting(
                        noteID: noteID
                    ) {
                        return .localObligation(obligation)
                    }
                }
                return .ready
            }
        )
        convergenceCoordinator = MacSyncConvergenceCoordinator(
            context: PersistenceManager.shared.context,
            syncController: controller,
            conflictStore: controller.conflictStore,
            presentationSurface: presentationSurface,
            incomingBoundarySurface: boundarySurface
        )
    }

    private func waitForMacConnection(
        controller: MacSyncBatchController,
        timeoutSeconds: Int
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline, !Task.isCancelled {
            if controller.hasConnectedPeers { return true }
            inviteMacPeerIfDue(controller: controller)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func waitForMacDrain(
        controller: MacSyncBatchController,
        timeoutSeconds: Int
    ) async -> Int {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var stableZeroSamples = 0
        var lastDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count
        while Date() < deadline, !Task.isCancelled {
            if !controller.hasConnectedPeers {
                inviteMacPeerIfDue(controller: controller)
            }
            lastDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count
            if lastDepth == 0 && controller.hasConnectedPeers {
                stableZeroSamples += 1
                if stableZeroSamples >= 5 { return 0 }
            } else {
                stableZeroSamples = 0
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return lastDepth
    }

    private func inviteMacPeerIfDue(controller: MacSyncBatchController) {
        let now = Date()
        if let lastInvitationAt,
           now.timeIntervalSince(lastInvitationAt) < Self.invitationRetryInterval {
            return
        }
        guard let peer = controller.availablePeers.first else { return }
        lastInvitationAt = now
        controller.invite(peer)
    }

    private func finishFailure(
        recorder: MyRAMSyncBenchmarkEnduranceRecorder,
        launch: MyRAMSyncBenchmarkEnduranceLaunch,
        startedAt: Date,
        attempted: Int,
        committed: Int,
        failed: Int,
        controller: MacSyncBatchController,
        adapter: MacNotePersistenceAdapter,
        detail: String
    ) {
        let digests = MyRAMSyncBenchmarkEnduranceDriverSupport.benchmarkDigests(
            notes: (try? adapter.loadNotes()) ?? [],
            runID: launch.runID
        )
        let queueDepth = controller.unsentBatchQueueSnapshotForTesting().pendingBatches.count
        let result = MyRAMSyncBenchmarkEnduranceResult(
            schemaVersion: MyRAMSyncBenchmarkEnduranceResult.currentSchemaVersion,
            runID: launch.runID,
            platform: .macOS,
            startedAt: startedAt,
            finishedAt: Date(),
            outcome: "failed",
            attemptedOperations: attempted,
            committedOperations: committed,
            failedOperations: failed,
            finalUnsentBatchCount: queueDepth,
            connectedAtFinish: controller.hasConnectedPeers,
            expectedBenchmarkNoteCount: MyRAMSyncBenchmarkEnduranceWorkload.expectedTitles(runID: launch.runID).count,
            observedBenchmarkNotes: digests,
            detail: detail
        )
        recorder.writeResult(result)
        recorder.record(.failed, queueDepth: queueDepth, outcome: "failed", detail: detail)
    }
}

private enum MyRAMSyncBenchmarkEnduranceMacError: LocalizedError {
    case noteMissing

    var errorDescription: String? {
        "Synthetic benchmark note disappeared before the next mutation."
    }
}
#endif
