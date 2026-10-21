import Foundation

/// One step of the mirror: what the Mac applies in one transaction.
struct MacMirrorBatch: Equatable, Sendable {
    /// The phone's change log this batch belongs to (`HealthDatabase.ChangeLogPosition`).
    var epoch: String
    /// The log position the Mac has reached once this batch is applied.
    var cursor: Int64
    /// Set while a snapshot is being sent; nil for an ordinary batch of changes.
    var snapshot: HealthDatabase.MirrorSnapshotStep?
    /// For a snapshot's first batch: how many rows the snapshot will send, for progress.
    var snapshotTotal: Int?
    /// The phone's whole source list, when it changed or the connection is new.
    var sources: [DataSource]?
    /// Rows exactly as the phone stores them now.
    var readings: [Reading]
    /// Rows the phone no longer has.
    var removedIDs: [UUID]
}

/// The binary body of a `.batch` frame.
///
/// A month of 1 Hz heart rate is over a million rows, so rows are not JSON: each is its id,
/// indexes into a string table for source, metric, and provenance, the two times and the
/// value as raw doubles, and its metadata as JSON only when it has any. The whole body is
/// then LZFSE-compressed. Times travel as the exact doubles the phone stores, so a window
/// boundary cannot move in transit.
///
/// Layout before compression: a big-endian `UInt32` header length, the JSON `Header`, the
/// rows, then the removed ids as raw 16-byte UUIDs.
enum MacMirrorBatchCodec {
    private struct Header: Codable {
        var epoch: String
        var cursor: Int64
        var snapshot: String?
        var snapshotTotal: Int?
        var sources: [DataSource]?
        var strings: [String]
        var readingCount: Int
        var removedCount: Int
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(HealthDatabase.PayloadDates.encode)
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(HealthDatabase.PayloadDates.decode)
        return decoder
    }()

    static func encode(_ batch: MacMirrorBatch) throws -> Data {
        var strings: [String] = []
        var index: [String: Int] = [:]
        func slot(_ text: String) -> Int {
            if let existing = index[text] { return existing }
            index[text] = strings.count
            strings.append(text)
            return strings.count - 1
        }

        var rows = Data()
        rows.reserveCapacity(batch.readings.count * 48)
        for reading in batch.readings {
            rows.appendUUID(reading.id)
            rows.appendVarint(slot(reading.sourceID))
            rows.appendVarint(slot(reading.kind.rawValue))
            rows.appendVarint(slot(reading.provenance.rawValue))
            rows.appendDouble(reading.start.timeIntervalSince1970)
            rows.appendDouble(reading.end.timeIntervalSince1970)
            rows.appendDouble(reading.value)
            if let metadata = reading.metadata {
                let json = try payloadEncoder.encode(metadata)
                rows.appendVarint(json.count)
                rows.append(json)
            } else {
                rows.appendVarint(0)
            }
        }
        for id in batch.removedIDs { rows.appendUUID(id) }

        let header = try payloadEncoder.encode(Header(
            epoch: batch.epoch,
            cursor: batch.cursor,
            snapshot: batch.snapshot.map(stepName),
            snapshotTotal: batch.snapshotTotal,
            sources: batch.sources,
            strings: strings,
            readingCount: batch.readings.count,
            removedCount: batch.removedIDs.count
        ))
        var plain = Data(capacity: 4 + header.count + rows.count)
        withUnsafeBytes(of: UInt32(header.count).bigEndian) { plain.append(contentsOf: $0) }
        plain.append(header)
        plain.append(rows)
        return try (plain as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ body: Data) throws -> MacMirrorBatch {
        let plain: Data
        do { plain = try (body as NSData).decompressed(using: .lzfse) as Data }
        catch { throw MacMirrorError.malformed("batch is not LZFSE data") }
        var reader = ByteReader(plain)
        let headerLength = Int(try reader.uint32())
        let header: Header
        do { header = try payloadDecoder.decode(Header.self, from: try reader.bytes(headerLength)) }
        catch let error as MacMirrorError { throw error }
        catch { throw MacMirrorError.malformed("batch header: \(error.localizedDescription)") }

        func string(_ position: Int) throws -> String {
            guard header.strings.indices.contains(position) else {
                throw MacMirrorError.malformed("string index \(position)")
            }
            return header.strings[position]
        }
        // A count is checked against the bytes left before anything is reserved, so a
        // hostile header cannot ask for a huge allocation.
        guard header.readingCount >= 0, header.removedCount >= 0,
              header.readingCount <= reader.remaining / 41,
              header.removedCount <= reader.remaining / 16
        else { throw MacMirrorError.malformed("batch counts") }

        var readings: [Reading] = []
        readings.reserveCapacity(header.readingCount)
        for _ in 0..<header.readingCount {
            let id = try reader.uuid()
            let sourceID = try string(reader.varint())
            let kindName = try string(reader.varint())
            let provenanceName = try string(reader.varint())
            guard let kind = MetricKind(rawValue: kindName) else {
                throw MacMirrorError.malformed("unknown metric \(kindName); update HeartSync on this Mac")
            }
            guard let provenance = Provenance(rawValue: provenanceName) else {
                throw MacMirrorError.malformed("unknown provenance \(provenanceName); update HeartSync on this Mac")
            }
            let start = try reader.double()
            let end = try reader.double()
            let value = try reader.double()
            let metadataLength = try reader.varint()
            var metadata: ReadingMetadata?
            if metadataLength > 0 {
                do { metadata = try payloadDecoder.decode(ReadingMetadata.self, from: try reader.bytes(metadataLength)) }
                catch let error as MacMirrorError { throw error }
                catch { throw MacMirrorError.malformed("reading metadata: \(error.localizedDescription)") }
            }
            readings.append(Reading(
                id: id,
                sourceID: sourceID,
                kind: kind,
                value: value,
                start: Date(timeIntervalSince1970: start),
                end: Date(timeIntervalSince1970: end),
                provenance: provenance,
                metadata: metadata
            ))
        }
        var removed: [UUID] = []
        removed.reserveCapacity(header.removedCount)
        for _ in 0..<header.removedCount { removed.append(try reader.uuid()) }
        guard reader.remaining == 0 else { throw MacMirrorError.malformed("trailing batch bytes") }

        var snapshot: HealthDatabase.MirrorSnapshotStep?
        if let name = header.snapshot {
            guard let step = step(named: name) else { throw MacMirrorError.malformed("snapshot step \(name)") }
            snapshot = step
        }
        return MacMirrorBatch(
            epoch: header.epoch,
            cursor: header.cursor,
            snapshot: snapshot,
            snapshotTotal: header.snapshotTotal,
            sources: header.sources,
            readings: readings,
            removedIDs: removed
        )
    }

    private static func stepName(_ step: HealthDatabase.MirrorSnapshotStep) -> String {
        switch step {
        case .begin: "begin"
        case .page: "page"
        case .end: "end"
        }
    }

    private static func step(named name: String) -> HealthDatabase.MirrorSnapshotStep? {
        switch name {
        case "begin": .begin
        case "page": .page
        case "end": .end
        default: nil
        }
    }
}

// MARK: - Byte helpers

private extension Data {
    mutating func appendUUID(_ id: UUID) {
        Swift.withUnsafeBytes(of: id.uuid) { append(contentsOf: $0) }
    }

    mutating func appendDouble(_ value: Double) {
        Swift.withUnsafeBytes(of: value.bitPattern.bigEndian) { append(contentsOf: $0) }
    }

    /// LEB128: seven bits a byte, low bits first.
    mutating func appendVarint(_ value: Int) {
        var remaining = UInt64(Swift.max(0, value))
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            append(byte)
        } while remaining != 0
    }
}

/// Reads the batch layout, throwing `MacMirrorError.malformed` instead of trapping on a
/// short or corrupt body.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        let at = try take(count)
        return Data(bytes[at..<at + count])
    }

    /// Advances past `count` bytes and returns where they started.
    private mutating func take(_ count: Int) throws -> Int {
        guard count >= 0, count <= remaining else { throw MacMirrorError.malformed("truncated batch") }
        defer { offset += count }
        return offset
    }

    mutating func byte() throws -> UInt8 {
        bytes[try take(1)]
    }

    mutating func uint32() throws -> UInt32 {
        let at = try take(4)
        return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func double() throws -> Double {
        let at = try take(8)
        return Double(bitPattern: bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) })
    }

    mutating func uuid() throws -> UUID {
        let at = try take(16)
        let raw = bytes
        return UUID(uuid: (
            raw[at], raw[at + 1], raw[at + 2], raw[at + 3], raw[at + 4], raw[at + 5], raw[at + 6], raw[at + 7],
            raw[at + 8], raw[at + 9], raw[at + 10], raw[at + 11], raw[at + 12], raw[at + 13], raw[at + 14], raw[at + 15]
        ))
    }

    mutating func varint() throws -> Int {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard shift < 63 else { throw MacMirrorError.malformed("varint too long") }
            let byte = try byte()
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        guard result <= UInt64(Int.max) else { throw MacMirrorError.malformed("varint overflow") }
        return Int(result)
    }
}
