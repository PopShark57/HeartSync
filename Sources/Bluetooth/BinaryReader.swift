import Foundation

/// Little-endian cursor over a GATT payload.
///
/// Normalises to a `[UInt8]` on init because `Data` slices do not start at index 0, which is
/// a classic source of off-by-one bugs when parsing characteristic values handed back by
/// CoreBluetooth.
struct BinaryReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { remaining <= 0 }

    mutating func uint8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /// 24-bit unsigned, used by the PLX device-and-sensor-status field.
    mutating func uint24() -> UInt32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
    }

    mutating func uint32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    mutating func skip(_ count: Int) {
        offset = min(offset + count, bytes.count)
    }

    /// IEEE-11073 16-bit SFLOAT: signed 4-bit exponent in the top nibble, signed 12-bit
    /// mantissa below. Used by every value in the Pulse Oximeter Service.
    ///
    /// Returns `nil` for the reserved special values (NaN / NRes / \u{00B1}INFINITY / Reserved),
    /// which devices legitimately send when a reading is unavailable \u{2014} treating those as
    /// numbers would inject garbage like 2047 into the record.
    mutating func sfloat() -> Double? {
        guard let raw = uint16() else { return nil }
        return Self.decodeSFloat(raw)
    }

    static func decodeSFloat(_ raw: UInt16) -> Double? {
        switch raw {
        case 0x07FF, 0x0800, 0x07FE, 0x0802, 0x0801: return nil  // NaN, NRes, +INF, -INF, Reserved
        default: break
        }
        var mantissa = Int(raw & 0x0FFF)
        if mantissa >= 0x0800 { mantissa -= 0x1000 }        // sign-extend 12-bit
        var exponent = Int(raw >> 12)
        if exponent >= 0x0008 { exponent -= 0x0010 }        // sign-extend 4-bit
        return Double(mantissa) * pow(10.0, Double(exponent))
    }

    /// IEEE-11073 32-bit FLOAT: signed 8-bit exponent in the top byte, signed 24-bit
    /// mantissa below. Used by the Health Thermometer Service.
    mutating func medfloat32() -> Double? {
        guard let raw = uint32() else { return nil }
        return Self.decodeMedFloat32(raw)
    }

    static func decodeMedFloat32(_ raw: UInt32) -> Double? {
        let mantissaBits = raw & 0x00FF_FFFF
        switch mantissaBits {
        case 0x007F_FFFF, 0x0080_0000, 0x007F_FFFE, 0x0080_0002, 0x0080_0001: return nil
        default: break
        }
        var mantissa = Int(mantissaBits)
        if mantissa >= 0x0080_0000 { mantissa -= 0x0100_0000 }   // sign-extend 24-bit
        let exponent = Int(Int8(bitPattern: UInt8(truncatingIfNeeded: raw >> 24)))
        return Double(mantissa) * pow(10.0, Double(exponent))
    }

    /// GATT "Date Time" (0x2A08): 7 bytes \u{2014} uint16 year, then uint8 month, day, hour,
    /// minute, second. A year of 0 means "unknown", in which case this returns nil and the
    /// caller falls back to the arrival time.
    mutating func dateTime() -> Date? {
        guard let year = uint16(),
              let month = uint8(), let day = uint8(),
              let hour = uint8(), let minute = uint8(), let second = uint8()
        else { return nil }
        guard year != 0, month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        var components = DateComponents()
        components.year = Int(year)
        components.month = Int(month)
        components.day = Int(day)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(second)
        return Calendar.current.date(from: components)
    }
}
