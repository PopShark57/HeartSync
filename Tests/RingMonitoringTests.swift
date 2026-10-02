import Foundation
import Testing
@testable import HeartSyncChecker

/// The YCBT ring's automatic-measuring schedule (`01 0C` heart rate, `01 26` blood oxygen,
/// payload `{enable, minutes}`), the setting the vendor app shows as Health monitoring and
/// Interval. Both commands were accepted by a ring reporting R11M firmware in the published
/// vitals capture; this ring's own answer is unverified on hardware.
@Suite("YCBT ring automatic measuring")
struct RingMonitoringTests {
    /// 2026-10-02T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_790_942_400)

    private func identifiedSession() -> R11MRingSession {
        var session = R11MRingSession(writeWithResponse: true)
        _ = session.subscriptionFinished(.command, error: nil)
        _ = session.subscriptionFinished(.events, error: nil)
        _ = session.received(.deviceInfo(.init(payloadLength: 24)), at: Self.now)
        return session
    }

    private func decoded(_ bytes: [UInt8]) -> YCBTFrameCodec.Message? {
        var assembler = YCBTFrameAssembler()
        guard case .frame(let frame) = assembler.append(Data(bytes)).first else { return nil }
        return YCBTFrameCodec.message(for: frame)
    }

    @Test("Requests are framed as the references build them, CRC included")
    func requestBytes() {
        #expect(Array(YCBTFrameCodec.monitorRequest(.heartRate, enabled: true, intervalMinutes: 30))
            == [0x01, 0x0C, 0x08, 0x00, 0x01, 0x1E, 0x96, 0x85])
        #expect(Array(YCBTFrameCodec.monitorRequest(.heartRate, enabled: false, intervalMinutes: 60))
            == [0x01, 0x0C, 0x08, 0x00, 0x00, 0x3C, 0x87, 0xB2])
        #expect(Array(YCBTFrameCodec.monitorRequest(.bloodOxygen, enabled: true, intervalMinutes: 30))
            == [0x01, 0x26, 0x08, 0x00, 0x01, 0x1E, 0x8C, 0xCB])
    }

    @Test("Replies decode to a status; the captured blood-pressure refusal is a monitor HeartSync never sets")
    func replies() {
        let accepted = Array(YCBTFrameCodec.encode(.heartRateMonitor, payload: [0x00]))
        #expect(decoded(accepted) == .monitorAck(.heartRate, status: 0))
        let refused = Array(YCBTFrameCodec.encode(.bloodOxygenMonitor, payload: [0xFC]))
        #expect(decoded(refused) == .monitorAck(.bloodOxygen, status: 0xFC))
        let empty = Array(YCBTFrameCodec.encode(.heartRateMonitor))
        #expect(decoded(empty) == .truncated(.heartRateMonitor))
        // Byte for byte from the vitals capture: `01 1C` answered `FC` on R11M firmware.
        #expect(decoded([0x01, 0x1C, 0x07, 0x00, 0xFC, 0xCB, 0x44]) == .other(.init(group: 0x01, command: 0x1C)))
    }

    @Test("The interval never goes under the vendor floor of 30 minutes or past one byte")
    func intervalBounds() {
        #expect(R11MRingSession.MonitoringSchedule.every(5).intervalByte == 30)
        #expect(R11MRingSession.MonitoringSchedule.every(45).intervalByte == 45)
        #expect(R11MRingSession.MonitoringSchedule.every(600).intervalByte == 255)
        #expect(R11MRingSession.MonitoringSchedule.off.intervalByte == 60)
        #expect(R11MRingSession.MonitoringSchedule.intervalChoices.allSatisfy { (30...255).contains($0) })
    }

    @Test("Nothing is written before the ring identifies itself, or while it is busy")
    func gating() {
        var unidentified = R11MRingSession(writeWithResponse: true)
        #expect(unidentified.setMonitoring(.every(30)).isEmpty)
        _ = unidentified.subscriptionFinished(.command, error: nil)
        _ = unidentified.subscriptionFinished(.events, error: nil)
        #expect(unidentified.setMonitoring(.every(30)).isEmpty)

        var measuring = identifiedSession()
        _ = measuring.start(.heartRate)
        #expect(measuring.setMonitoring(.every(30)).isEmpty)
        #expect(measuring.activeMeasurement == .heartRate)
    }

    @Test("Heart rate is set first; blood oxygen follows its reply; both accepted is reported as in effect")
    func bothAccepted() {
        var session = identifiedSession()
        let first = session.setMonitoring(.every(40))
        #expect(first.first == .write(
            YCBTFrameCodec.monitorRequest(.heartRate, enabled: true, intervalMinutes: 40),
            purpose: .setMonitor(.heartRate, .every(40))
        ))
        #expect(session.isConfiguringMonitors)
        #expect(!session.canStartMeasurement)
        #expect(session.isIdentified)
        #expect(session.refreshBattery().isEmpty)

        let second = session.received(.monitorAck(.heartRate, status: 0), at: Self.now)
        #expect(second.first == .write(
            YCBTFrameCodec.monitorRequest(.bloodOxygen, enabled: true, intervalMinutes: 40),
            purpose: .setMonitor(.bloodOxygen, .every(40))
        ))
        #expect(session.received(.monitorAck(.bloodOxygen, status: 0), at: Self.now).isEmpty)
        #expect(session.phase == .ready(last: .monitoringSet(.every(40), results: [.heartRate: .accepted, .bloodOxygen: .accepted])))
        #expect(session.canStartMeasurement)
        #expect(session.statusText.contains("accepted automatic heart rate and blood oxygen measuring every 40 min"))
        #expect(session.statusText.contains("Import stored"))
    }

    @Test("A refusal is named and never described as in effect")
    func refusal() {
        var session = identifiedSession()
        _ = session.setMonitoring(.every(30))
        _ = session.received(.monitorAck(.heartRate, status: 0), at: Self.now)
        _ = session.received(.monitorAck(.bloodOxygen, status: 0xFC), at: Self.now)
        let text = session.statusText
        #expect(text.contains("accepted automatic heart rate measuring every 30 min"))
        #expect(!text.contains("heart rate and blood oxygen"))
        #expect(text.contains("Automatic blood oxygen: not supported by this ring."))

        var refusedAll = identifiedSession()
        _ = refusedAll.setMonitoring(.every(30))
        _ = refusedAll.received(.monitorAck(.heartRate, status: 0x07), at: Self.now)
        _ = refusedAll.received(.monitorAck(.bloodOxygen, status: 0xFC), at: Self.now)
        #expect(refusedAll.statusText.hasPrefix("The ring did not accept"))
        #expect(refusedAll.statusText.contains("refused (status 07)"))
    }

    @Test("Turning it off sends enable 00 and says so")
    func off() {
        var session = identifiedSession()
        let actions = session.setMonitoring(.off)
        #expect(actions.first == .write(
            YCBTFrameCodec.monitorRequest(.heartRate, enabled: false, intervalMinutes: 60),
            purpose: .setMonitor(.heartRate, .off)
        ))
        _ = session.received(.monitorAck(.heartRate, status: 0), at: Self.now)
        _ = session.received(.monitorAck(.bloodOxygen, status: 0), at: Self.now)
        #expect(session.statusText == "Automatic heart rate and blood oxygen measuring is off on the ring.")
    }

    @Test("Silence and a failed write each end that monitor's step; a stale timer does nothing")
    func silenceAndWriteFailure() {
        var session = identifiedSession()
        let first = session.setMonitoring(.every(30))
        guard case .scheduleTimeout(.monitorSetting, _, let token) = first.last else {
            Issue.record("Expected a reply timeout")
            return
        }
        let next = session.timeoutElapsed(.monitorSetting, token: token)
        #expect(next.first == .write(
            YCBTFrameCodec.monitorRequest(.bloodOxygen, enabled: true, intervalMinutes: 30),
            purpose: .setMonitor(.bloodOxygen, .every(30))
        ))
        // The first step's timer is stale now.
        #expect(session.timeoutElapsed(.monitorSetting, token: token).isEmpty)
        // A late reply for the step that timed out is ignored.
        #expect(session.received(.monitorAck(.heartRate, status: 0), at: Self.now).isEmpty)
        #expect(session.isConfiguringMonitors)

        _ = session.writeFinished(.setMonitor(.bloodOxygen, .every(30)), error: "Not connected")
        #expect(session.phase == .ready(last: .monitoringSet(.every(30), results: [
            .heartRate: .noAnswer,
            .bloodOxygen: .writeFailed("Not connected"),
        ])))
        #expect(session.statusText.contains("Automatic heart rate: no answer."))
        #expect(session.statusText.contains("Automatic blood oxygen: not sent (Not connected)."))
    }

    @Test("A setting reply outside a schedule change changes nothing")
    func strayReply() {
        var session = identifiedSession()
        #expect(session.received(.monitorAck(.heartRate, status: 0), at: Self.now).isEmpty)
        #expect(session.phase == .ready(last: nil))
    }
}
