import Foundation

enum MyRAMWidgetSnapshotCodecError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case malformed
}

struct MyRAMWidgetSnapshotCodec: Sendable {
    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    func encode(_ envelope: MyRAMWidgetSnapshotEnvelope) throws -> Data {
        guard MyRAMWidgetSnapshotBounds.validates(envelope) else {
            throw MyRAMWidgetSnapshotCodecError.malformed
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(envelope)
        } catch {
            throw MyRAMWidgetSnapshotCodecError.malformed
        }
    }

    func decode(_ data: Data) throws -> MyRAMWidgetSnapshotEnvelope {
        let probeDecoder = JSONDecoder()
        let version: Int
        do {
            version = try probeDecoder.decode(VersionProbe.self, from: data).schemaVersion
        } catch {
            throw MyRAMWidgetSnapshotCodecError.malformed
        }

        guard version == MyRAMWidgetSnapshotEnvelope.currentSchemaVersion else {
            throw MyRAMWidgetSnapshotCodecError.unsupportedVersion(version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: MyRAMWidgetSnapshotEnvelope
        do {
            envelope = try decoder.decode(MyRAMWidgetSnapshotEnvelope.self, from: data)
        } catch {
            throw MyRAMWidgetSnapshotCodecError.malformed
        }

        guard MyRAMWidgetSnapshotBounds.validates(envelope) else {
            throw MyRAMWidgetSnapshotCodecError.malformed
        }
        return envelope
    }
}
