import Foundation

/// The YCBT ring's stored-history records: the periodic values the ring measures on its own
/// schedule and keeps in memory, which its vendor app shows as the day's heart rate, blood
/// pressure, blood oxygen, and temperature. The ring stores these; it never pushes them.
///
/// **Candidate protocol, not verified on this ring.** Record layouts come from two independent
/// public references (see `RingFix.md`): PulseLoop's YCBT decoder and the vitals-smart-ring-app
/// capture notes, which agree on the heart, blood-pressure, and combined layouts and on the
/// transfer sequence. Reading history does not delete it from the ring; HeartSync never sends
/// a delete command.
///
/// Transfer, for one record type:
///
/// ```text
/// app  -> 05 <query>                      (empty payload)
/// ring -> 05 <query>  count:u16 packets:u16 _:u16 bytes:u32   (payload < 10 bytes: no data)
/// ring -> 05 <data>   ...                 (payloads concatenate; records straddle frames)
/// ring -> 05 80       packets:u16 bytes:u16 crc16:u16          (CRC over the concatenation)
/// app  -> 05 80       00 accepted | 04 CRC failure
/// ```
enum YCBTHistory {

    /// History types HeartSync imports, in request order. Sleep, sport, and the vendor's
    /// body-composition and blood-sugar records are deliberately absent: HeartSync has no
    /// metric for them.
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case heartRate
        case bloodPressure
        /// The ring's periodic combined record: heart rate, blood pressure, SpO2,
        /// respiratory rate, and temperature in one 20-byte row.
        case combined
        case bloodOxygen
        case temperature

        /// The request command, echoed in the header reply.
        var queryCommand: UInt8 {
            switch self {
            case .heartRate:     0x06
            case .bloodPressure: 0x08
            case .combined:      0x09
            case .bloodOxygen:   0x1A
            case .temperature:   0x1E
            }
        }

        /// The command of the frames carrying record bytes.
        var dataCommand: UInt8 {
            switch self {
            case .heartRate:     0x15
            case .bloodPressure: 0x17
            case .combined:      0x18
            case .bloodOxygen:   0x22
            case .temperature:   0x26
            }
        }

        /// Bytes per record.
        var stride: Int {
            switch self {
            case .heartRate:     6
            case .bloodPressure: 8
            case .combined:      20
            case .bloodOxygen:   6
            case .temperature:   7
            }
        }

        var title: String {
            switch self {
            case .heartRate:     "heart rate"
            case .bloodPressure: "blood pressure"
            case .combined:      "combined vitals"
            case .bloodOxygen:   "blood oxygen"
            case .temperature:   "temperature"
            }
        }

        init?(queryCommand: UInt8) {
            guard let kind = Self.allCases.first(where: { $0.queryCommand == queryCommand }) else { return nil }
            self = kind
        }

        init?(dataCommand: UInt8) {
            guard let kind = Self.allCases.first(where: { $0.dataCommand == dataCommand }) else { return nil }
            self = kind
        }
    }

    static let group: UInt8 = 0x05
    static let blockEndCommand: UInt8 = 0x80
    /// A header payload shorter than this means the ring holds no records of that type.
    static let headerPayloadLength = 10
    /// The most record bytes kept for one type. A week of five-minute combined records is
    /// about 40 KB; the bound stops a peripheral from making the app buffer without limit.
    static let maximumTransferBytes = 262_144
    /// Records older than this are not imported: HealthKit reads the same 30-day span, and a
    /// much older timestamp usually means the ring's clock was never set.
    static let maximumRecordAge: TimeInterval = 30 * 86_400
    /// A record from the future beyond this tolerance means the ring's clock is ahead.
    static let futureTolerance: TimeInterval = 5 * 60

    /// Seconds from 2000-01-01T00:00:00Z to the Unix epoch.
    private static let epoch2000: TimeInterval = 946_684_800

    // MARK: Frames

    static func request(_ kind: Kind) -> Data {
        YCBTFrameCodec.encode(YCBTFrameCodec.Opcode(group: group, command: kind.queryCommand))
    }

    static func blockAcknowledgement(accepted: Bool) -> Data {
        YCBTFrameCodec.encode(
            YCBTFrameCodec.Opcode(group: group, command: blockEndCommand),
            payload: [accepted ? 0x00 : 0x04]
        )
    }

    /// `totalBytes` from a header payload, or nil when the ring reports no records.
    static func announcedBytes(inHeader payload: [UInt8]) -> Int? {
        guard payload.count >= headerPayloadLength else { return nil }
        let count = Int(payload[0]) | Int(payload[1]) << 8
        guard count > 0 else { return nil }
        let bytes = Int(payload[6]) | Int(payload[7]) << 8 | Int(payload[8]) << 16 | Int(payload[9]) << 24
        return bytes
    }

    struct BlockEnd: Equatable, Sendable {
        var packets: Int
        var bytes: Int
        var crc: UInt16
    }

    static func blockEnd(from payload: [UInt8]) -> BlockEnd? {
        guard payload.count >= 6 else { return nil }
        return BlockEnd(
            packets: Int(payload[0]) | Int(payload[1]) << 8,
            bytes: Int(payload[2]) | Int(payload[3]) << 8,
            crc: UInt16(payload[4]) | UInt16(payload[5]) << 8
        )
    }

    /// Whether the concatenated record bytes are exactly what the terminal block describes.
    /// The terminal length field is 16 bits wide, so it is compared modulo 65 536.
    static func verify(_ buffer: [UInt8], against end: BlockEnd) -> Bool {
        buffer.count & 0xFFFF == end.bytes && YCBTFrameCodec.crc16(buffer) == end.crc
    }

    // MARK: Records

    /// One value read from the ring's memory, already converted to HeartSync's units.
    struct Sample: Equatable, Hashable, Sendable {
        var kind: MetricKind
        var value: Double
        var recordedAt: Date

        var provenance: Provenance { R11MRingSession.provenance(for: kind) }
    }

    struct Decoded: Equatable, Sendable {
        var samples: [Sample] = []
        /// Records outside the accepted time span, with a repeated timestamp, or without any
        /// usable value.
        var skipped = 0
    }

    /// Decodes whole records. A trailing partial record is ignored and counted as skipped.
    ///
    /// Timestamps are seconds since 2000 in the ring's own clock, which its vendor app sets to
    /// the phone's local wall time; `timeZone` converts that to an instant. A record outside
    /// `now - maximumRecordAge ... now + futureTolerance` is skipped rather than guessed at.
    /// Two records of one type with the same timestamp mean the clock was not running, so only
    /// the first is kept.
    static func decode(_ kind: Kind, records buffer: [UInt8], timeZone: TimeZone, now: Date) -> Decoded {
        var decoded = Decoded()
        var seenTimestamps = Set<UInt32>()
        let whole = buffer.count / kind.stride
        if buffer.count % kind.stride != 0 { decoded.skipped += 1 }
        for index in 0..<whole {
            let record = Array(buffer[(index * kind.stride)..<((index + 1) * kind.stride)])
            let seconds = UInt32(record[0]) | UInt32(record[1]) << 8 | UInt32(record[2]) << 16 | UInt32(record[3]) << 24
            guard seenTimestamps.insert(seconds).inserted,
                  let date = date(deviceSeconds: seconds, timeZone: timeZone),
                  date >= now.addingTimeInterval(-maximumRecordAge),
                  date <= now.addingTimeInterval(futureTolerance)
            else {
                decoded.skipped += 1
                continue
            }
            let values = Self.values(kind, record: record)
            guard !values.isEmpty else {
                decoded.skipped += 1
                continue
            }
            decoded.samples += values.map { Sample(kind: $0.0, value: $0.1, recordedAt: date) }
        }
        return decoded
    }

    /// The usable values in one record. Zero and 0xFF mean "not measured" in every field.
    private static func values(_ kind: Kind, record r: [UInt8]) -> [(MetricKind, Double)] {
        func present(_ byte: UInt8) -> Double? {
            byte == 0 || byte == 0xFF ? nil : Double(byte)
        }
        var found: [(MetricKind, Double)] = []
        func add(_ metric: MetricKind, _ value: Double?) {
            guard let value, metric.plausibleRange.contains(value) else { return }
            found.append((metric, value))
        }
        func addPressure(systolic: UInt8, diastolic: UInt8) {
            guard let sys = present(systolic), let dia = present(diastolic), sys > dia,
                  MetricKind.bloodPressureSystolic.plausibleRange.contains(sys),
                  MetricKind.bloodPressureDiastolic.plausibleRange.contains(dia)
            else { return }
            found.append((.bloodPressureSystolic, sys))
            found.append((.bloodPressureDiastolic, dia))
        }

        switch kind {
        case .heartRate:
            // ts:4 | mode:1 | bpm:1
            add(.heartRate, present(r[5]))
        case .bloodPressure:
            // ts:4 | inflated:1 | systolic:1 | diastolic:1 | pulse:1
            addPressure(systolic: r[5], diastolic: r[6])
        case .combined:
            // ts:4 | steps:2 | hr@6 | sys@7 | dia@8 | spo2@9 | resp@10 | hrv@11 | cvrr@12
            // | tempInt@13 | tempFrac@14 | ...
            // The vendor's HRV byte is not imported: the references do not say whether it is
            // RMSSD, SDNN, or a proprietary score, and HeartSync never guesses which.
            add(.heartRate, present(r[6]))
            addPressure(systolic: r[7], diastolic: r[8])
            add(.spo2, present(r[9]))
            add(.respiratoryRate, present(r[10]))
            add(.bodyTemperature, temperature(integer: r[13], fraction: r[14]))
        case .bloodOxygen:
            // ts:4 | type:1 | percent:1
            add(.spo2, present(r[5]))
        case .temperature:
            // ts:4 | type:1 | integer:1 | fraction:1
            add(.bodyTemperature, temperature(integer: r[5], fraction: r[6]))
        }
        return found
    }

    /// The ring writes a temperature as an integer byte and a decimal-digits byte, so 36 and 5
    /// is 36.5 °C and 36 and 12 is 36.12 °C.
    static func temperature(integer: UInt8, fraction: UInt8) -> Double? {
        guard integer != 0, integer != 0xFF else { return nil }
        switch fraction {
        case 0..<10:   return Double(integer) + Double(fraction) / 10
        case 10..<100: return Double(integer) + Double(fraction) / 100
        default:       return nil
        }
    }

    /// Converts the ring's wall-clock seconds since 2000 to an instant in `timeZone`.
    static func date(deviceSeconds: UInt32, timeZone: TimeZone) -> Date? {
        let wall = Date(timeIntervalSince1970: epoch2000 + TimeInterval(deviceSeconds))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? timeZone
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
        return local.date(from: parts)
    }

    /// A deterministic reading ID, so importing the same history again de-duplicates instead
    /// of adding copies. Keyed by source, metric, and the ring's timestamp.
    static func readingID(sourceID: String, sample: Sample) -> UUID {
        UUID(stableFrom: "ycbt-history|\(sourceID)|\(sample.kind.rawValue)|\(Int(sample.recordedAt.timeIntervalSince1970))")
    }
}
