import Foundation

enum MyRAMWidgetSnapshotReadResult: Equatable, Sendable {
    case snapshot(MyRAMWidgetSnapshotEnvelope)
    case missing
    case inaccessible
    case unsupportedVersion(Int)
    case malformed
}

enum WidgetSnapshotPublicationOutcome: Equatable, Sendable {
    case unchanged
    case published
    case failed
}

final class MyRAMWidgetSnapshotStore: @unchecked Sendable {
    typealias AtomicWriter = @Sendable (Data, URL) throws -> Void

    static let relativeSnapshotPath = "Library/Application Support/MyRAMWidget/widget-snapshot-v1.json"

    private let containerURLProvider: @Sendable () -> URL?
    private let fileManager: FileManager
    private let codec: MyRAMWidgetSnapshotCodec
    private let atomicWriter: AtomicWriter
    private let lock = NSLock()

    init(
        containerURLProvider: @escaping @Sendable () -> URL?,
        fileManager: FileManager = .default,
        codec: MyRAMWidgetSnapshotCodec = MyRAMWidgetSnapshotCodec(),
        atomicWriter: @escaping AtomicWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.containerURLProvider = containerURLProvider
        self.fileManager = fileManager
        self.codec = codec
        self.atomicWriter = atomicWriter
    }

    func read() -> MyRAMWidgetSnapshotReadResult {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked()
    }

    func publish(_ envelope: MyRAMWidgetSnapshotEnvelope) -> WidgetSnapshotPublicationOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard envelope.schemaVersion == MyRAMWidgetSnapshotEnvelope.currentSchemaVersion,
              MyRAMWidgetSnapshotBounds.validates(envelope),
              let snapshotURL = resolvedSnapshotURL(createDirectory: true) else {
            return .failed
        }

        if case .snapshot(let previous) = readUnlocked(), previous.note == envelope.note {
            return .unchanged
        }

        let data: Data
        do {
            data = try codec.encode(envelope)
            try atomicWriter(data, snapshotURL)
        } catch {
            return .failed
        }

        guard case .snapshot(let committed) = readUnlocked(), committed == envelope else {
            return .failed
        }
        return .published
    }

    private func readUnlocked() -> MyRAMWidgetSnapshotReadResult {
        guard let snapshotURL = resolvedSnapshotURL(createDirectory: false) else {
            return .inaccessible
        }
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return .missing
        }
        guard fileManager.isReadableFile(atPath: snapshotURL.path) else {
            return .inaccessible
        }

        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch {
            return .inaccessible
        }

        do {
            return .snapshot(try codec.decode(data))
        } catch MyRAMWidgetSnapshotCodecError.unsupportedVersion(let version) {
            return .unsupportedVersion(version)
        } catch {
            return .malformed
        }
    }

    private func resolvedSnapshotURL(createDirectory: Bool) -> URL? {
        guard let containerURL = containerURLProvider() else { return nil }
        let directoryURL = containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MyRAMWidget", isDirectory: true)

        if createDirectory {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                return nil
            }
        }

        var isDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        )
        if directoryExists {
            guard isDirectory.boolValue,
                  fileManager.isReadableFile(atPath: directoryURL.path) else {
                return nil
            }
        } else if createDirectory {
            return nil
        }

        return directoryURL.appendingPathComponent("widget-snapshot-v1.json", isDirectory: false)
    }
}
