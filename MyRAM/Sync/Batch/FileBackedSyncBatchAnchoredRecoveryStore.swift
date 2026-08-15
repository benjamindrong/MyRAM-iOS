import AnchoredSequenceCore
import Foundation

enum SyncBatchAnchoredRecoveryStoreHealth: Equatable, Sendable {
  case healthy
  case fileMissing
  case corrupt
  case unsupportedVersion(Int)
  case unsupportedRecordShape
  case readFailed(String)
  case writeFailed(String)

  var permitsOrdinaryMutation: Bool {
    switch self {
    case .healthy, .fileMissing:
      true
    case .corrupt, .unsupportedVersion, .unsupportedRecordShape,
      .readFailed, .writeFailed:
      false
    }
  }
}

struct SyncBatchAnchoredRecoveryStoreSnapshot: Equatable, Sendable {
  let records: [SyncBatchAnchoredRecoveryRecord]
  let health: SyncBatchAnchoredRecoveryStoreHealth

  init(
    records: [SyncBatchAnchoredRecoveryRecord],
    health: SyncBatchAnchoredRecoveryStoreHealth
  ) {
    self.records = records.sorted { $0.key < $1.key }
    self.health = health
  }

  func record(
    for key: SyncBatchAnchoredRecoveryRecordKey
  ) -> SyncBatchAnchoredRecoveryRecord? {
    records.first { $0.key == key }
  }

  func waitingIndex(
    noteID: SyncBatchNoteID? = nil
  ) -> [SyncOperationID: [SyncBatchAnchoredRecoveryRecordKey]] {
    var result: [SyncOperationID: [SyncBatchAnchoredRecoveryRecordKey]] = [:]
    for record in records {
      if let noteID, record.key.noteID != noteID {
        continue
      }
      guard case .waiting(let dependency) = record.lifecycle else {
        continue
      }
      result[dependency.operationID, default: []].append(record.key)
    }
    for operationID in Array(result.keys) {
      result[operationID]?.sort()
    }
    return result
  }
}

enum SyncBatchAnchoredRecoveryStoreError: Error, Equatable {
  case unhealthyPersistence
  case identityCollision(SyncBatchAnchoredRecoveryRecordKey)
  case staleExpectedRecord(SyncBatchAnchoredRecoveryRecordKey)
  case duplicateTransition(SyncBatchAnchoredRecoveryRecordKey)
  case invalidTransition(SyncBatchAnchoredRecoveryRecordKey)
  case persistenceFailed
}

enum SyncBatchAnchoredRecoveryStoreFileLocationError: Error, Equatable {
  case applicationSupportDirectoryUnavailable
}

enum SyncBatchAnchoredRecoveryStoreFileLocation {
  typealias ApplicationSupportDirectoryProvider = () -> URL?

  static func fileURL(
    for platform: SyncBatchPlatform,
    applicationSupportDirectory: ApplicationSupportDirectoryProvider = {
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    }
  ) throws -> URL {
    guard let supportDirectory = applicationSupportDirectory() else {
      throw SyncBatchAnchoredRecoveryStoreFileLocationError.applicationSupportDirectoryUnavailable
    }
    let filename: String
    switch platform {
    case .iPhone:
      filename = "ios-anchored-recovery-store.json"
    case .nativeMac:
      filename = "mac-anchored-recovery-store.json"
    }
    return
      supportDirectory
      .appendingPathComponent("MyRAM", isDirectory: true)
      .appendingPathComponent(filename)
  }
}

final class FileBackedSyncBatchAnchoredRecoveryStore {
  typealias AtomicWriter = (Data, URL) throws -> Void

  private let fileURL: URL
  private let fileManager: FileManager
  private let atomicWriter: AtomicWriter
  private var recordsByKey: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord] =
    [:]
  private var health: SyncBatchAnchoredRecoveryStoreHealth = .healthy

  init(
    fileURL: URL,
    fileManager: FileManager = .default,
    atomicWriter: @escaping AtomicWriter = { data, url in
      try data.write(to: url, options: .atomic)
    }
  ) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    self.atomicWriter = atomicWriter
    let loaded = Self.load(
      fileURL: fileURL,
      fileManager: fileManager
    )
    recordsByKey = Dictionary(
      uniqueKeysWithValues: loaded.records.map { ($0.key, $0) }
    )
    health = loaded.health
  }

  func snapshot() -> SyncBatchAnchoredRecoveryStoreSnapshot {
    SyncBatchAnchoredRecoveryStoreSnapshot(
      records: Array(recordsByKey.values),
      health: health
    )
  }

  @discardableResult
  func apply(
    _ transitions: [SyncBatchAnchoredRecoveryStoreTransition]
  ) throws -> Bool {
    guard health.permitsOrdinaryMutation else {
      throw SyncBatchAnchoredRecoveryStoreError.unhealthyPersistence
    }
    guard !transitions.isEmpty else { return false }

    var next = recordsByKey
    var seenKeys: Set<SyncBatchAnchoredRecoveryRecordKey> = []
    var didChange = false

    for transition in transitions {
      let key = transition.key
      guard seenKeys.insert(key).inserted else {
        throw SyncBatchAnchoredRecoveryStoreError.duplicateTransition(key)
      }

      switch transition {
      case .insertExpectedAbsent(let proposed):
        if let current = next[key] {
          if current == proposed {
            continue
          }
          if current.change == proposed.change,
            current.lifecycle.isTerminal,
            proposed.lifecycle.isWaiting
          {
            continue
          }
          throw SyncBatchAnchoredRecoveryStoreError.identityCollision(key)
        }
        next[key] = proposed
        didChange = true

      case .replace(let expected, let replacement):
        guard expected.key == replacement.key,
          expected.change == replacement.change
        else {
          throw SyncBatchAnchoredRecoveryStoreError.invalidTransition(key)
        }
        guard let current = next[key], current == expected else {
          throw SyncBatchAnchoredRecoveryStoreError.staleExpectedRecord(key)
        }
        guard !(expected.lifecycle.isTerminal && replacement.lifecycle.isWaiting) else {
          throw SyncBatchAnchoredRecoveryStoreError.invalidTransition(key)
        }
        guard current != replacement else { continue }
        next[key] = replacement
        didChange = true

      case .removeCommitted(let expected):
        guard let current = next[key], current == expected else {
          throw SyncBatchAnchoredRecoveryStoreError.staleExpectedRecord(key)
        }
        next.removeValue(forKey: key)
        didChange = true
      }
    }

    guard didChange else { return false }
    try persistReplacement(next)
    recordsByKey = next
    health = .healthy
    return true
  }

  func replaceAllForRecovery(
    _ replacement: [SyncBatchAnchoredRecoveryRecord]
  ) throws {
    var replacementByKey: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord] =
      [:]
    for record in replacement {
      guard replacementByKey[record.key] == nil else {
        throw SyncBatchAnchoredRecoveryStoreError.identityCollision(record.key)
      }
      replacementByKey[record.key] = record
    }
    try persistReplacement(replacementByKey)
    recordsByKey = replacementByKey
    health = .healthy
  }

  private func persistReplacement(
    _ replacement: [SyncBatchAnchoredRecoveryRecordKey: SyncBatchAnchoredRecoveryRecord]
  ) throws {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let envelope = PersistedSyncBatchAnchoredRecoveryStore(
        version: PersistedSyncBatchAnchoredRecoveryStore.currentVersion,
        records: replacement.values.sorted { $0.key < $1.key }
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(envelope)
      try atomicWriter(data, fileURL)
    } catch {
      health = .writeFailed(String(describing: error))
      throw SyncBatchAnchoredRecoveryStoreError.persistenceFailed
    }
  }

  private static func load(
    fileURL: URL,
    fileManager: FileManager
  ) -> SyncBatchAnchoredRecoveryStoreSnapshot {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [],
        health: .fileMissing
      )
    }

    do {
      let data = try Data(contentsOf: fileURL)
      let decoder = JSONDecoder()
      let version = try decoder.decode(
        PersistedSyncBatchAnchoredRecoveryStoreVersion.self,
        from: data
      ).version
      guard version == PersistedSyncBatchAnchoredRecoveryStore.currentVersion else {
        return SyncBatchAnchoredRecoveryStoreSnapshot(
          records: [],
          health: .unsupportedVersion(version)
        )
      }
      let envelope = try decoder.decode(
        PersistedSyncBatchAnchoredRecoveryStore.self,
        from: data
      )
      var keys: Set<SyncBatchAnchoredRecoveryRecordKey> = []
      for record in envelope.records {
        guard keys.insert(record.key).inserted else {
          throw SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape
        }
      }
      return SyncBatchAnchoredRecoveryStoreSnapshot(
        records: envelope.records,
        health: .healthy
      )
    } catch SyncBatchAnchoredRecoveryCodingError.unsupportedRecordShape {
      return SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [],
        health: .unsupportedRecordShape
      )
    } catch _ as DecodingError {
      return SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [],
        health: .corrupt
      )
    } catch {
      return SyncBatchAnchoredRecoveryStoreSnapshot(
        records: [],
        health: .readFailed(String(describing: error))
      )
    }
  }
}


extension FileBackedSyncBatchAnchoredRecoveryStore: SyncConvergenceAnchoredRecoveryAdapter {
  func applyAnchoredRecoveryTransitions(
    _ transitions: [SyncBatchAnchoredRecoveryStoreTransition]
  ) -> SyncConvergencePostCommitAdapterResult {
    guard !transitions.isEmpty else { return .verifiedComplete }

    do {
      let current = snapshot()
      guard current.health.permitsOrdinaryMutation else { return .failed }

      var unapplied: [SyncBatchAnchoredRecoveryStoreTransition] = []
      for transition in transitions {
        let record = current.record(for: transition.key)
        switch transition {
        case .insertExpectedAbsent(let proposed):
          if record == proposed { continue }
          guard record == nil else { return .failed }
          unapplied.append(transition)
        case .replace(let expected, let replacement):
          if record == replacement { continue }
          guard record == expected else { return .failed }
          unapplied.append(transition)
        case .removeCommitted(let expected):
          if record == nil { continue }
          guard record == expected else { return .failed }
          unapplied.append(transition)
        }
      }

      if !unapplied.isEmpty {
        _ = try apply(unapplied)
      }

      let verified = snapshot()
      guard verified.health.permitsOrdinaryMutation else { return .failed }
      for transition in transitions {
        let record = verified.record(for: transition.key)
        switch transition {
        case .insertExpectedAbsent(let proposed):
          guard record == proposed else { return .failed }
        case .replace(_, let replacement):
          guard record == replacement else { return .failed }
        case .removeCommitted:
          guard record == nil else { return .failed }
        }
      }
      return .verifiedComplete
    } catch {
      return .failed
    }
  }
}


private struct PersistedSyncBatchAnchoredRecoveryStore: Codable {
  static let currentVersion = 2

  let version: Int
  let records: [SyncBatchAnchoredRecoveryRecord]
}

private struct PersistedSyncBatchAnchoredRecoveryStoreVersion: Codable {
  let version: Int
}
