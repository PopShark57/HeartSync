import Foundation
import Testing
@testable import HeartSyncChecker

/// On-demand temperature for the YCBT ring candidate. The ring sends no live temperature
/// frame, so a completed measurement is read back from its temperature and combined records.
/// Unverified on an R11M, whose published capability bitmap has no temperature sensor: such
/// a ring is expected to refuse the start, which must store nothing.
@Suite("YCBT ring temperature")
struct RingTemperatureTests {
    private static let utc = TimeZone(secondsFromGMT: 0)!
    /// 2026-09-29T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_790_683_200)

    private func identifiedSession() -> R11MRingSession {
        var session = R11MRingSession(writeWithResponse: true, historyTimeZone: Self.utc)
        _ = session.subscriptionFinished(.command, error: nil)
        _ = session.subscriptionFinished(.events, error: nil)
        _ = session.received(.deviceInfo(.init(payloadLength: 24)), at: Self.now)
        return session
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    private func ringSeconds(_ date: Date) -> UInt32 {
        UInt32(date.timeIntervalSince1970 - 946_684_800)
    }

    private func blockEnd(for buffer: [UInt8]) -> YCBTHistory.BlockEnd {
        YCBTHistory.BlockEnd(packets: 1, bytes: buffer.count, crc: YCBTFrameCodec.crc16(buffer))
    }

    /// One temperature record: ts:4 | type:1 | integer:1 | fraction:1.
    private func temperatureRecord(at date: Date, integer: UInt8, fraction: UInt8) -> [UInt8] {
        le32(ringSeconds(date)) + [0, integer, fraction]
    }

    @Test("The start request uses mode 04 from the reference's measurement table")
    func startRequest() {
        #expect(Array(YCBTFrameCodec.measurementRequest(start: true, sensor: .temperature).prefix(6)) == [0x03, 0x2F, 0x08, 0x00, 0x01, 0x04])
        var session = identifiedSession()
        let actions = session.start(.temperature)
        #expect(actions.first == .write(YCBTFrameCodec.measurementRequest(start: true, sensor: .temperature), purpose: .start(.temperature)))
        #expect(session.activeMeasurement == .temperature)
    }

    @Test("A ring without the sensor refuses; nothing is read or stored")
    func refusalStoresNothing() {
        var session = identifiedSession()
        _ = session.start(.temperature)
        #expect(session.received(.measurementAck(status: 0xFC), at: Self.now).isEmpty)
        #expect(session.phase == .ready(last: .requestRejected(status: 0xFC)))
        #expect(session.statusText.contains("may not support"))
    }

    @Test("Completion reads the temperature and combined records, and reports the new value")
    func completionReadsMemory() {
        var session = identifiedSession()
        _ = session.start(.temperature)
        _ = session.received(.measurementAck(status: 0), at: Self.now)
        // Another sensor's live frame is not this measurement.
        _ = session.received(.liveHeartRate(bpm: 70), at: Self.now)

        let finished = Self.now.addingTimeInterval(40)
        let request = session.received(.measurementFinished(sensor: 0x04, result: 1), at: finished)
        #expect(request.first == .write(YCBTHistory.request(.temperature), purpose: .historyRequest(.temperature)))
        #expect(session.isImportingHistory)

        // An old record and the one just taken.
        let old = temperatureRecord(at: Self.now.addingTimeInterval(-86_400), integer: 36, fraction: 2)
        let fresh = temperatureRecord(at: Self.now.addingTimeInterval(30), integer: 36, fraction: 7)
        let records = old + fresh
        _ = session.received(.historyHeader(.temperature, announcedBytes: records.count), at: finished)
        _ = session.received(.historyData(.temperature, payload: records), at: finished)
        let stored = session.received(.historyBlockEnd(blockEnd(for: records)), at: finished)
        #expect(stored.contains(.emitHistory([
            .init(kind: .bodyTemperature, value: 36.2, recordedAt: Self.now.addingTimeInterval(-86_400)),
            .init(kind: .bodyTemperature, value: 36.7, recordedAt: Self.now.addingTimeInterval(30)),
        ])))
        #expect(stored.contains(.write(YCBTHistory.request(.combined), purpose: .historyRequest(.combined))))

        _ = session.received(.historyHeader(.combined, announcedBytes: nil), at: finished)
        guard case .ready(last: .readFromMemory(.temperature, let sample, let summary)) = session.phase else {
            Issue.record("Expected the stored temperature to be reported, got \(session.phase)")
            return
        }
        #expect(sample?.value == 36.7)
        #expect(summary.imported == 2)
        #expect(session.statusText.contains("Temperature (estimate) read from the ring"))
        #expect(R11MRingSession.provenance(for: .bodyTemperature) == .estimated)
    }

    @Test("Only an old record comes back: the measurement stored no new value")
    func onlyOldRecord() {
        var session = identifiedSession()
        _ = session.start(.temperature)
        _ = session.received(.measurementAck(status: 0), at: Self.now)
        let finished = Self.now.addingTimeInterval(40)
        _ = session.received(.measurementFinished(sensor: 0x04, result: 1), at: finished)
        let records = temperatureRecord(at: Self.now.addingTimeInterval(-6 * 3_600), integer: 36, fraction: 4)
        _ = session.received(.historyHeader(.temperature, announcedBytes: records.count), at: finished)
        _ = session.received(.historyData(.temperature, payload: records), at: finished)
        _ = session.received(.historyBlockEnd(blockEnd(for: records)), at: finished)
        _ = session.received(.historyHeader(.combined, announcedBytes: nil), at: finished)

        #expect(session.phase == .ready(last: .readFromMemory(
            .temperature,
            sample: nil,
            summary: .init(
                imported: 1,
                skipped: 0,
                failed: [],
                newest: [.bodyTemperature: .init(kind: .bodyTemperature, value: 36.4, recordedAt: Self.now.addingTimeInterval(-6 * 3_600))]
            )
        )))
        #expect(session.statusText.contains("stored no new value"))
    }

    @Test("No contact on a temperature measurement reads nothing")
    func noContact() {
        var session = identifiedSession()
        _ = session.start(.temperature)
        _ = session.received(.measurementAck(status: 0), at: Self.now)
        #expect(session.received(.measurementFinished(sensor: 0x04, result: 2), at: Self.now).isEmpty)
        #expect(session.phase == .ready(last: .noContact))
    }

    @Test("Live-value measurements are unchanged: they read no memory")
    func liveMeasurementsReadNoMemory() {
        for measurement in [R11MRingSession.Measurement.heartRate, .bloodOxygen, .bloodPressure] {
            #expect(measurement.storedIn.isEmpty)
        }
        var session = identifiedSession()
        _ = session.start(.heartRate)
        _ = session.received(.liveHeartRate(bpm: 64), at: Self.now)
        let done = session.received(.measurementFinished(sensor: 0x00, result: 1), at: Self.now)
        #expect(done == [.emit(.heartRate(bpm: 64), measuredAt: Self.now)])
    }
}
