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
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
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
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bitPattern = try container.decode(UInt64.self)
            return Date(
                timeIntervalSinceReferenceDate: Double(bitPattern: bitPattern)
            )
        }
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
