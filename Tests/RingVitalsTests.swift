import Foundation
import Testing
@testable import HeartSyncChecker

/// On-demand blood oxygen and blood pressure, and the stored-history import, for the YCBT
/// ring candidate. Vectors follow the public references in `RingFix.md`; the history request
/// frame is byte-identical to a published capture.
@Suite("YCBT ring vitals and stored history")
struct RingVitalsTests {
    private static let utc = TimeZone(secondsFromGMT: 0)!
    /// 2026-09-29T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_790_683_200)

    private func identifiedSession(timeZone: TimeZone = Self.utc) -> R11MRingSession {
        var session = R11MRingSession(writeWithResponse: true, historyTimeZone: timeZone)
        _ = session.subscriptionFinished(.command, error: nil)
        _ = session.subscriptionFinished(.events, error: nil)
        _ = session.received(.deviceInfo(payloadLength: 24), at: Self.now)
        return session
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    /// Ring seconds since 2000 for an instant, as a UTC wall clock would show it.
    private func ringSeconds(_ date: Date) -> UInt32 {
        UInt32(date.timeIntervalSince1970 - 946_684_800)
    }

    private func blockEnd(for buffer: [UInt8]) -> YCBTHistory.BlockEnd {
        YCBTHistory.BlockEnd(packets: 1, bytes: buffer.count, crc: YCBTFrameCodec.crc16(buffer))
    }

    private func frame(_ group: UInt8, _ command: UInt8, _ payload: [UInt8]) -> YCBTFrameCodec.Frame {
        YCBTFrameCodec.Frame(group: group, command: command, payload: payload)
    }

    // MARK: Codec

    @Test("Measurement requests use the sensor codes both references agree on")
    func sensorCodes() {
        #expect(Array(YCBTFrameCodec.measurementRequest(start: true, sensor: .bloodOxygen)) == [0x03, 0x2F, 0x08, 0x00, 0x01, 0x02, 0x0D, 0x3B])
        #expect(Array(YCBTFrameCodec.measurementRequest(start: true, sensor: .bloodPressure).prefix(6)) == [0x03, 0x2F, 0x08, 0x00, 0x01, 0x01])
        #expect(Array(YCBTFrameCodec.measurementRequest(start: false, sensor: .bloodPressure).prefix(6)) == [0x03, 0x2F, 0x08, 0x00, 0x00, 0x01])
    }

    @Test("The history request matches a published capture byte for byte")
    func historyRequestVector() {
        #expect(Array(YCBTHistory.request(.heartRate)) == [0x05, 0x06, 0x06, 0x00, 0x83, 0x20])
        #expect(Array(YCBTHistory.blockAcknowledgement(accepted: true)) == [0x05, 0x80, 0x07, 0x00, 0x00, 0xF3, 0x6A])
        #expect(Array(YCBTHistory.blockAcknowledgement(accepted: false).prefix(5)) == [0x05, 0x80, 0x07, 0x00, 0x04])
    }

    @Test("Live SpO2, live blood pressure, and history frames decode")
    func decodesMessages() {
        #expect(YCBTFrameCodec.message(for: frame(0x06, 0x02, [97])) == .liveSpO2(percent: 97))
        #expect(YCBTFrameCodec.message(for: frame(0x06, 0x03, [118, 76, 75, 0, 0])) == .liveBloodPressure(systolic: 118, diastolic: 76))
        #expect(YCBTFrameCodec.message(for: frame(0x06, 0x03, [118])) == .truncated(.liveBloodPressure))

        let header: [UInt8] = [0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 12, 0, 0, 0]
        #expect(YCBTFrameCodec.message(for: frame(0x05, 0x06, header)) == .historyHeader(.heartRate, announcedBytes: 12))
        // A short header, or a zero record count, means the ring holds nothing of that type.
        #expect(YCBTFrameCodec.message(for: frame(0x05, 0x06, [0x00, 0x00])) == .historyHeader(.heartRate, announcedBytes: nil))
        #expect(YCBTFrameCodec.message(for: frame(0x05, 0x18, [1, 2, 3])) == .historyData(.combined, payload: [1, 2, 3]))
        // The published terminal block: one packet, six bytes, CRC E803.
        #expect(YCBTFrameCodec.message(for: frame(0x05, 0x80, [0x01, 0x00, 0x06, 0x00, 0x03, 0xE8]))
            == .historyBlockEnd(.init(packets: 1, bytes: 6, crc: 0xE803)))
        #expect(YCBTFrameCodec.message(for: frame(0x05, 0x80, [0x01])) == .truncated(.historyBlockEnd))
        #expect(YCBTFrameCodec.message(for: frame(0x05, 0x40, [])) == .other(.init(group: 0x05, command: 0x40)))
    }

    // MARK: On-demand measurements

    @Test("Blood oxygen: warm-up zeros are ignored and the last value is emitted as measured")
    func bloodOxygen() {
        var session = identifiedSession()
        let start = session.start(.bloodOxygen)
        #expect(start.first == .write(YCBTFrameCodec.measurementRequest(start: true, sensor: .bloodOxygen), purpose: .start(.bloodOxygen)))
        _ = session.received(.measurementAck(status: 0), at: Self.now)
        _ = session.received(.liveSpO2(percent: 0), at: Self.now)
        let last = Self.now.addingTimeInterval(30)
        _ = session.received(.liveSpO2(percent: 96), at: Self.now.addingTimeInterval(20))
        _ = session.received(.liveSpO2(percent: 97), at: last)
        // Heart rate's completion does not finish a blood-oxygen measurement.
        #expect(session.received(.measurementFinished(sensor: 0x00, result: 1), at: last).isEmpty)
        let done = session.received(.measurementFinished(sensor: 0x02, result: 1), at: last.addingTimeInterval(1))
        #expect(done == [.emit(.bloodOxygen(percent: 97), measuredAt: last)])
        #expect(R11MRingSession.provenance(for: .spo2) == .measured)
    }

    @Test("Blood pressure is emitted as a pair and labelled an estimate")
    func bloodPressure() {
        var session = identifiedSession()
        _ = session.start(.bloodPressure)
        let at = Self.now.addingTimeInterval(40)
        _ = session.received(.liveBloodPressure(systolic: 0, diastolic: 0), at: Self.now)
        // An inverted pair is never plausible.
        _ = session.received(.liveBloodPressure(systolic: 70, diastolic: 90), at: Self.now)
        #expect(session.phase == .measuring(.bloodPressure, provisional: nil))
        _ = session.received(.liveBloodPressure(systolic: 114, diastolic: 79), at: at)
        let done = session.received(.measurementFinished(sensor: 0x01, result: 1), at: at)
        #expect(done == [.emit(.bloodPressure(systolic: 114, diastolic: 79), measuredAt: at)])
        let value = R11MRingSession.RingValue.bloodPressure(systolic: 114, diastolic: 79)
        #expect(value.metrics.map { $0.kind } == [.bloodPressureSystolic, .bloodPressureDiastolic])
        #expect(value.metrics.map { $0.value } == [114, 79])
        #expect(R11MRingSession.provenance(for: .bloodPressureSystolic) == .estimated)
        #expect(R11MRingSession.provenance(for: .bloodPressureDiastolic) == .estimated)
        #expect(R11MRingSession.provenance(for: .bodyTemperature) == .estimated)
        #expect(session.statusText.contains("estimate"))
    }

    @Test("A cancelled blood-pressure measurement sends that sensor's stop")
    func cancelStopsSameSensor() {
        var session = identifiedSession()
        _ = session.start(.bloodPressure)
        #expect(session.cancel() == [.write(YCBTFrameCodec.measurementRequest(start: false, sensor: .bloodPressure), purpose: .stop(.bloodPressure))])
    }

    // MARK: History transfer

    @Test("A checked transfer is acknowledged, decoded, emitted, and followed by the next type")
    func historyTransfer() throws {
        var session = identifiedSession()
        let first = session.importHistory()
        #expect(first.first == .write(YCBTHistory.request(.heartRate), purpose: .historyRequest(.heartRate)))
        #expect(session.isImportingHistory)
        #expect(session.startHeartRate().isEmpty)

        let t1 = Self.now.addingTimeInterval(-3_600)
        let t2 = Self.now.addingTimeInterval(-3_300)
        let records: [UInt8] = le32(ringSeconds(t1)) + [0, 72] + le32(ringSeconds(t2)) + [0, 75]
        _ = session.received(.historyHeader(.heartRate, announcedBytes: records.count), at: Self.now)
        // Records straddle frames.
        _ = session.received(.historyData(.heartRate, payload: Array(records.prefix(7))), at: Self.now)
        _ = session.received(.historyData(.heartRate, payload: Array(records.dropFirst(7))), at: Self.now)
        let actions = session.received(.historyBlockEnd(blockEnd(for: records)), at: Self.now)

        #expect(actions.first == .write(YCBTHistory.blockAcknowledgement(accepted: true), purpose: .historyAcknowledgement))
        #expect(actions.contains(.emitHistory([
            .init(kind: .heartRate, value: 72, recordedAt: t1),
            .init(kind: .heartRate, value: 75, recordedAt: t2),
        ])))
        #expect(actions.contains(.write(YCBTHistory.request(.bloodPressure), purpose: .historyRequest(.bloodPressure))))
        guard case .importingHistory(let progress) = session.phase else {
            Issue.record("Expected the import to continue")
            return
        }
        #expect(progress.current == .bloodPressure)
        #expect(progress.buffer.isEmpty)
        #expect(progress.summary.imported == 2)
    }

    @Test("Empty types advance, a bad CRC is refused, silence fails one type, and the import ends")
    func historyFailures() throws {
        var session = identifiedSession()
        _ = session.importHistory()
        // Heart rate: nothing stored.
        _ = session.received(.historyHeader(.heartRate, announcedBytes: nil), at: Self.now)
        // Blood pressure: corrupted transfer.
        let records: [UInt8] = le32(ringSeconds(Self.now.addingTimeInterval(-60))) + [0, 120, 80, 70]
        _ = session.received(.historyHeader(.bloodPressure, announcedBytes: records.count), at: Self.now)
        _ = session.received(.historyData(.bloodPressure, payload: records), at: Self.now)
        var end = blockEnd(for: records)
        end.crc ^= 0x0101
        let refused = session.received(.historyBlockEnd(end), at: Self.now)
        #expect(refused.first == .write(YCBTHistory.blockAcknowledgement(accepted: false), purpose: .historyAcknowledgement))
        #expect(!refused.contains { if case .emitHistory = $0 { true } else { false } })

        // Combined: the ring never answers; the inactivity timer fails only that type.
        let token = session.token
        let next = session.timeoutElapsed(.history, token: token)
        #expect(next.first == .write(YCBTHistory.request(.bloodOxygen), purpose: .historyRequest(.bloodOxygen)))
        // A stale timer from before the advance is ignored.
        #expect(session.timeoutElapsed(.history, token: token).isEmpty)

        _ = session.received(.historyHeader(.bloodOxygen, announcedBytes: nil), at: Self.now)
        _ = session.received(.historyHeader(.temperature, announcedBytes: nil), at: Self.now)
        #expect(session.phase == .ready(last: .historyImported(.init(imported: 0, skipped: 0, failed: [.bloodPressure, .combined]))))
        #expect(session.statusText.contains("blood pressure, combined vitals"))
        #expect(session.canStartMeasurement)
    }

    @Test("Cancelling an import writes nothing and returns to ready")
    func cancelImport() {
        var session = identifiedSession()
        _ = session.importHistory()
        #expect(session.isBusy)
        #expect(session.cancel().isEmpty)
        #expect(session.phase == .ready(last: .cancelled))
        #expect(session.received(.historyHeader(.heartRate, announcedBytes: nil), at: Self.now).isEmpty)
    }

    @Test("An oversized transfer is not decoded")
    func oversizedTransfer() {
        var session = identifiedSession()
        _ = session.importHistory()
        let chunk = [UInt8](repeating: 0, count: 500)
        var sent: [UInt8] = []
        while sent.count <= YCBTHistory.maximumTransferBytes {
            _ = session.received(.historyData(.heartRate, payload: chunk), at: Self.now)
            sent += chunk
        }
        let actions = session.received(.historyBlockEnd(blockEnd(for: sent)), at: Self.now)
        #expect(actions.first == .write(YCBTHistory.blockAcknowledgement(accepted: false), purpose: .historyAcknowledgement))
    }

    // MARK: Records

    @Test("The combined record yields each present vital; HRV and zero fields are not imported")
    func combinedRecord() {
        let at = Self.now.addingTimeInterval(-600)
        var record = le32(ringSeconds(at))
        record += [0x10, 0x00]           // steps
        record += [68, 114, 79, 95, 16]  // hr, sys, dia, spo2, resp
        record += [19, 0]                // vendor HRV, cvrr
        record += [36, 5]                // 36.5 °C
        record += [0, 0, 0, 0, 0]
        let decoded = YCBTHistory.decode(.combined, records: record, timeZone: Self.utc, now: Self.now)
        #expect(decoded.skipped == 0)
        #expect(decoded.samples.map(\.kind) == [.heartRate, .bloodPressureSystolic, .bloodPressureDiastolic, .spo2, .respiratoryRate, .bodyTemperature])
        #expect(decoded.samples.map(\.value) == [68, 114, 79, 95, 16, 36.5])
        #expect(!decoded.samples.contains { $0.kind == .hrvRMSSD || $0.kind == .hrvSDNN })
        #expect(decoded.samples.allSatisfy { $0.recordedAt == at })

        var empty = le32(ringSeconds(at))
        empty += [UInt8](repeating: 0, count: 16)
        #expect(YCBTHistory.decode(.combined, records: empty, timeZone: Self.utc, now: Self.now) == .init(samples: [], skipped: 1))
    }

    @Test("Temperature bytes are an integer and its decimal digits")
    func temperatureComposite() {
        #expect(YCBTHistory.temperature(integer: 36, fraction: 5) == 36.5)
        #expect(YCBTHistory.temperature(integer: 36, fraction: 12) == 36.12)
        #expect(YCBTHistory.temperature(integer: 0, fraction: 5) == nil)
        #expect(YCBTHistory.temperature(integer: 36, fraction: 200) == nil)
    }

    @Test("Old, future, and repeated timestamps are skipped instead of guessed")
    func clockGuards() {
        let good: [UInt8] = le32(ringSeconds(Self.now.addingTimeInterval(-120))) + [0, 70]
        let repeated: [UInt8] = Array(good.prefix(4)) + [0, 90]
        let old: [UInt8] = le32(ringSeconds(Self.now.addingTimeInterval(-40 * 86_400))) + [0, 71]
        let future: [UInt8] = le32(ringSeconds(Self.now.addingTimeInterval(3_600))) + [0, 72]
        let unset: [UInt8] = le32(60) + [0, 73]
        let partial: [UInt8] = [1, 2, 3]
        var buffer: [UInt8] = good
        buffer += repeated
        buffer += old
        buffer += future
        buffer += unset
        buffer += partial
        let decoded = YCBTHistory.decode(.heartRate, records: buffer, timeZone: Self.utc, now: Self.now)
        #expect(decoded.samples == [.init(kind: .heartRate, value: 70, recordedAt: Self.now.addingTimeInterval(-120))])
        #expect(decoded.skipped == 5)
    }

    @Test("The ring's wall clock is read in the given time zone")
    func wallClock() throws {
        #expect(YCBTHistory.date(deviceSeconds: 0, timeZone: Self.utc) == Date(timeIntervalSince1970: 946_684_800))
        let plusThree = try #require(TimeZone(secondsFromGMT: 3 * 3_600))
        #expect(YCBTHistory.date(deviceSeconds: 0, timeZone: plusThree) == Date(timeIntervalSince1970: 946_684_800 - 3 * 3_600))
    }

    @Test("Reading IDs are stable across imports and distinct per metric and time")
    func stableIDs() {
        let sample = YCBTHistory.Sample(kind: .heartRate, value: 70, recordedAt: Self.now)
        let id = YCBTHistory.readingID(sourceID: "ring", sample: sample)
        #expect(id == YCBTHistory.readingID(sourceID: "ring", sample: sample))
        #expect(id != YCBTHistory.readingID(sourceID: "other", sample: sample))
        #expect(id != YCBTHistory.readingID(sourceID: "ring", sample: .init(kind: .spo2, value: 70, recordedAt: Self.now)))
        #expect(id != YCBTHistory.readingID(sourceID: "ring", sample: .init(kind: .heartRate, value: 70, recordedAt: Self.now.addingTimeInterval(60))))
        #expect(sample.provenance == .measured)
        #expect(YCBTHistory.Sample(kind: .bloodPressureSystolic, value: 120, recordedAt: Self.now).provenance == .estimated)
    }
}
