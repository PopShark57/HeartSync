import Foundation

/// Framing and message decoding for the Yucheng YCBT vendor protocol that some rings sold as
/// "R11M" expose beside (or instead of) the standard Heart Rate Service.
///
/// **Candidate protocol, not a verified R11M recipe.** The layout below comes from public,
/// independently reverse-engineered YCBT references (see `RingFix.md`). HeartSync therefore
/// never writes a measurement command to a device merely because its name matches: the vendor
/// session is selected from the GATT topology, and a measurement command is sent only after
/// the ring has answered an identity query with a frame that passes this codec's length and
/// CRC checks. A device that speaks a different protocol simply never gets past that step.
///
/// Frame layout, every field little-endian:
///
/// ```text
/// group:1 | command:1 | totalLength:2 | payload:n | crc16:2
/// ```
///
/// `totalLength` counts the whole frame, header and CRC included, so an empty payload makes a
/// six-byte frame. The CRC is CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xFFFF, no
/// reflection, no final XOR) over every byte before it.
enum YCBTFrameCodec {

    /// Header (group, command, length) plus trailing CRC.
    static let overheadLength = 6
    /// The largest frame the assembler will hold. Live measurement and identity replies are a
    /// few dozen bytes; anything longer is either history HeartSync does not request or noise,
    /// and a peripheral must not be able to make the app buffer without bound.
    static let maximumFrameLength = 512

    /// One complete, CRC-checked frame.
    struct Frame: Equatable, Sendable {
        var group: UInt8
        var command: UInt8
        var payload: [UInt8]

        var opcode: Opcode { Opcode(group: group, command: command) }
    }

    /// A group/command pair. The ring echoes both in its reply, which is how requests and
    /// responses pair up without sequence numbers.
    struct Opcode: Hashable, Sendable, CustomStringConvertible {
        var group: UInt8
        var command: UInt8

        var description: String { String(format: "%02X %02X", group, command) }

        /// Get Device Info (`02 00`, payload `"GC"`). Read-only identity/battery query.
        static let deviceInfo = Opcode(group: 0x02, command: 0x00)
        /// Start or stop an on-demand measurement (`03 2F`).
        static let measurementControl = Opcode(group: 0x03, command: 0x2F)
        /// Measurement-finished event (`04 0E`): sensor type, then result.
        static let measurementFinished = Opcode(group: 0x04, command: 0x0E)
        /// Live heart rate (`06 01`): one byte, beats per minute.
        static let liveHeartRate = Opcode(group: 0x06, command: 0x01)
        /// Live blood oxygen (`06 02`): one byte, percent. Recognized but not ingested; see
        /// `R11MRingSession`.
        static let liveSpO2 = Opcode(group: 0x06, command: 0x02)
    }

    /// The measurement sensors the start/stop command addresses.
    enum Sensor: UInt8, Sendable {
        case heartRate = 0x00
    }

    // MARK: Encoding

    /// Encodes one complete frame for the command characteristic.
    static func encode(_ opcode: Opcode, payload: [UInt8] = []) -> Data {
        let total = overheadLength + payload.count
        precondition(total <= maximumFrameLength, "YCBT frame exceeds the codec bound")
        var bytes: [UInt8] = [
            opcode.group,
            opcode.command,
            UInt8(total & 0xFF),
            UInt8((total >> 8) & 0xFF),
        ]
        bytes += payload
        let crc = crc16(bytes)
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8(crc >> 8))
        return Data(bytes)
    }

    /// The identity query sent once both vendor channels are subscribed. It changes nothing on
    /// the ring.
    static func deviceInfoRequest() -> Data {
        encode(.deviceInfo, payload: [0x47, 0x43])
    }

    /// Starts (`01`) or stops (`00`) one on-demand measurement of `sensor`.
    static func measurementRequest(start: Bool, sensor: Sensor) -> Data {
        encode(.measurementControl, payload: [start ? 0x01 : 0x00, sensor.rawValue])
    }

    // MARK: Checking

    /// CRC-16/CCITT-FALSE. The check value for ASCII "123456789" is 0x29B1.
    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var register: UInt16 = 0xFFFF
        for byte in bytes {
            register ^= UInt16(byte) << 8
            for _ in 0..<8 {
                register = register & 0x8000 != 0
                    ? (register << 1) ^ 0x1021
                    : register << 1
            }
        }
        return register
    }

    // MARK: Messages

    /// What a decoded frame means. Only `.liveHeartRate` can ever become a reading, and only
    /// after `R11MRingSession` sees the ring declare the measurement complete.
    enum Message: Equatable, Sendable {
        case deviceInfo(payloadLength: Int)
        /// A reply to start/stop. `status == 0` is acceptance.
        case measurementAck(status: UInt8)
        case measurementFinished(sensor: UInt8, result: UInt8)
        /// Zero is a warm-up or no-contact placeholder, never a heart rate, and is kept here
        /// only so diagnostics can count it.
        case liveHeartRate(bpm: Int)
        case liveSpO2(percent: Int)
        /// A CRC-valid frame HeartSync does not interpret (battery, status, history\u{2026}).
        case other(Opcode)
        /// A CRC-valid frame whose payload is too short for its opcode.
        case truncated(Opcode)
    }

    static func message(for frame: Frame) -> Message {
        let payload = frame.payload
        switch frame.opcode {
        case .deviceInfo:
            return .deviceInfo(payloadLength: payload.count)
        case .measurementControl:
            guard let status = payload.first else { return .truncated(frame.opcode) }
            return .measurementAck(status: status)
        case .measurementFinished:
            guard payload.count >= 2 else { return .truncated(frame.opcode) }
            return .measurementFinished(sensor: payload[0], result: payload[1])
        case .liveHeartRate:
            guard let bpm = payload.first else { return .truncated(frame.opcode) }
            return .liveHeartRate(bpm: Int(bpm))
        case .liveSpO2:
            guard let percent = payload.first else { return .truncated(frame.opcode) }
            return .liveSpO2(percent: Int(percent))
        default:
            return .other(frame.opcode)
        }
    }
}

/// Reassembles YCBT frames from notification fragments on one characteristic.
///
/// ATT notifications without a negotiated MTU carry at most 20 bytes, so a frame can arrive in
/// pieces. Each characteristic of each connection owns one assembler; it is discarded on
/// disconnect so a half frame from an old link can never prefix a new one.
struct YCBTFrameAssembler: Sendable {

    enum Failure: Equatable, Sendable {
        /// The declared length is shorter than a header or longer than the bound.
        case invalidLength(Int)
        case crcMismatch
    }

    enum Output: Equatable, Sendable {
        case frame(YCBTFrameCodec.Frame)
        case rejected(Failure)
    }

    private(set) var buffer: [UInt8] = []

    /// Appends one notification and returns every frame it completes, in order. A malformed
    /// header clears the buffer: with no delimiter to resynchronise on, keeping bytes after a
    /// bad length would only misframe everything that follows.
    mutating func append(_ data: Data) -> [Output] {
        buffer.append(contentsOf: data)
        var outputs: [Output] = []
        while buffer.count >= 4 {
            let declared = Int(buffer[2]) | Int(buffer[3]) << 8
            guard declared >= YCBTFrameCodec.overheadLength,
                  declared <= YCBTFrameCodec.maximumFrameLength
            else {
                buffer.removeAll()
                outputs.append(.rejected(.invalidLength(declared)))
                break
            }
            guard buffer.count >= declared else { break }
            let frameBytes = Array(buffer[0..<declared])
            buffer.removeFirst(declared)

            let body = frameBytes[0..<(declared - 2)]
            let received = UInt16(frameBytes[declared - 2]) | UInt16(frameBytes[declared - 1]) << 8
            guard YCBTFrameCodec.crc16(body) == received else {
                outputs.append(.rejected(.crcMismatch))
                continue
            }
            outputs.append(.frame(YCBTFrameCodec.Frame(
                group: frameBytes[0],
                command: frameBytes[1],
                payload: Array(frameBytes[4..<(declared - 2)])
            )))
        }
        if buffer.count > YCBTFrameCodec.maximumFrameLength {
            buffer.removeAll()
        }
        return outputs
    }

    mutating func reset() {
        buffer.removeAll()
    }
}
