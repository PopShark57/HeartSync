import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("YCBT frame codec")
struct YCBTFrameCodecTests {
    private func framed(_ group: UInt8, _ command: UInt8, _ payload: [UInt8]) -> [UInt8] {
        Array(YCBTFrameCodec.encode(.init(group: group, command: command), payload: payload))
    }

    @Test("CRC-16/CCITT-FALSE matches its published check value")
    func crcCheckValue() {
        #expect(YCBTFrameCodec.crc16(Array("123456789".utf8)) == 0x29B1)
    }

    @Test("Commands carry group, command, total length, payload, and a little-endian CRC")
    func encodesCommands() {
        let start = Array(YCBTFrameCodec.measurementRequest(start: true, sensor: .heartRate))
        #expect(Array(start.prefix(6)) == [0x03, 0x2F, 0x08, 0x00, 0x01, 0x00])
        #expect(start.count == 8)
        let crc = YCBTFrameCodec.crc16(start.prefix(6))
        #expect(start[6] == UInt8(crc & 0xFF))
        #expect(start[7] == UInt8(crc >> 8))

        let stop = Array(YCBTFrameCodec.measurementRequest(start: false, sensor: .heartRate))
        #expect(Array(stop.prefix(6)) == [0x03, 0x2F, 0x08, 0x00, 0x00, 0x00])

        let identity = Array(YCBTFrameCodec.deviceInfoRequest())
        #expect(Array(identity.prefix(6)) == [0x02, 0x00, 0x08, 0x00, 0x47, 0x43])
    }

    @Test("A frame split across notifications is reassembled")
    func splitFrame() {
        let frame = framed(0x06, 0x01, [72])
        var assembler = YCBTFrameAssembler()
        #expect(assembler.append(Data(frame.prefix(3))).isEmpty)
        let outputs = assembler.append(Data(frame.dropFirst(3)))
        #expect(outputs == [.frame(.init(group: 0x06, command: 0x01, payload: [72]))])
        #expect(assembler.buffer.isEmpty)
    }

    @Test("Two frames in one notification both decode, in order")
    func coalescedFrames() {
        let bytes = framed(0x06, 0x01, [70]) + framed(0x04, 0x0E, [0x00, 0x01])
        var assembler = YCBTFrameAssembler()
        let outputs = assembler.append(Data(bytes))
        #expect(outputs.count == 2)
        guard case .frame(let second) = outputs.last else {
            Issue.record("Expected a frame")
            return
        }
        #expect(YCBTFrameCodec.message(for: second) == .measurementFinished(sensor: 0, result: 1))
    }

    @Test("A bad CRC produces no frame and the next valid frame still decodes")
    func badCRC() {
        var corrupt = framed(0x06, 0x01, [72])
        corrupt[4] = 99
        var assembler = YCBTFrameAssembler()
        #expect(assembler.append(Data(corrupt)) == [.rejected(.crcMismatch)])
        #expect(assembler.append(Data(framed(0x06, 0x01, [73]))) == [.frame(.init(group: 0x06, command: 0x01, payload: [73]))])
    }

    @Test("An impossible declared length clears the buffer instead of buffering without bound")
    func badLength() {
        var assembler = YCBTFrameAssembler()
        #expect(assembler.append(Data([0x06, 0x01, 0x02, 0x00, 0xAA])) == [.rejected(.invalidLength(2))])
        #expect(assembler.buffer.isEmpty)
        #expect(assembler.append(Data([0x06, 0x01, 0xFF, 0xFF])) == [.rejected(.invalidLength(0xFFFF))])
        #expect(assembler.buffer.isEmpty)
    }

    @Test("The identity reply carries the battery percent and charging state")
    func deviceInfoBattery() {
        // Device id 0xD3E0, firmware 1.07, charging, 76%, then bind and sync state.
        let charging = YCBTFrameCodec.Frame(group: 0x02, command: 0x00, payload: [0xE0, 0xD3, 0x07, 0x01, 0x01, 76, 0x00, 0x00])
        #expect(YCBTFrameCodec.message(for: charging) == .deviceInfo(.init(payloadLength: 8, batteryPercent: 76, isCharging: true)))
        let idle = YCBTFrameCodec.Frame(group: 0x02, command: 0x00, payload: [0xE0, 0xD3, 0x07, 0x01, 0x00, 100])
        #expect(YCBTFrameCodec.message(for: idle) == .deviceInfo(.init(payloadLength: 6, batteryPercent: 100, isCharging: false)))
        // Too short for the battery bytes, or an impossible percentage: identity only.
        let short = YCBTFrameCodec.Frame(group: 0x02, command: 0x00, payload: [0xE0, 0xD3, 0x07, 0x01, 0x00])
        #expect(YCBTFrameCodec.message(for: short) == .deviceInfo(.init(payloadLength: 5)))
        let impossible = YCBTFrameCodec.Frame(group: 0x02, command: 0x00, payload: [0xE0, 0xD3, 0x07, 0x01, 0x00, 101])
        #expect(YCBTFrameCodec.message(for: impossible) == .deviceInfo(.init(payloadLength: 6)))
    }

    @Test("Short payloads decode as truncated, never as values")
    func truncated() {
        let frame = YCBTFrameCodec.Frame(group: 0x06, command: 0x01, payload: [])
        #expect(YCBTFrameCodec.message(for: frame) == .truncated(.liveHeartRate))
        let finished = YCBTFrameCodec.Frame(group: 0x04, command: 0x0E, payload: [0x00])
        #expect(YCBTFrameCodec.message(for: finished) == .truncated(.measurementFinished))
    }
}

@Suite("R11M ring session")
struct R11MRingSessionTests {
    private let vendor = R11MRingSession.serviceUUID
    private let command = R11MRingSession.commandCharacteristicUUID
    private let events = R11MRingSession.eventCharacteristicUUID

    /// A session with both channels subscribed and the identity reply received.
    private func identifiedSession() -> R11MRingSession {
        var session = R11MRingSession(writeWithResponse: true)
        _ = session.subscriptionFinished(.command, error: nil)
        _ = session.subscriptionFinished(.events, error: nil)
        _ = session.received(.deviceInfo(.init(payloadLength: 24)), at: .now)
        return session
    }

    @Test("The adapter is chosen from topology; a matching name with other services is not enough")
    func topology() {
        #expect(R11MRingSession.match(services: ["180D": ["2A37": [.notify]]])
            == .notMatched(reason: "No YCBT vendor service"))
        #expect(R11MRingSession.match(services: [vendor: [command: [.write, .notify]]])
            == .notMatched(reason: "Vendor service without its event characteristic"))
        #expect(R11MRingSession.match(services: [vendor: [command: [.notify], events: [.notify]]])
            == .notMatched(reason: "Vendor command characteristic is not writable"))
        // Lower-case UUIDs and an indicate-only event channel are both accepted.
        #expect(R11MRingSession.match(services: [vendor.lowercased(): [
            command.lowercased(): [.writeWithoutResponse, .indicate],
            events.lowercased(): [.indicate],
        ]]) == .matched(writeWithResponse: false))
    }

    @Test("An identity reply reports the battery, and an idle ring can be asked again")
    func battery() {
        var session = R11MRingSession(writeWithResponse: true)
        _ = session.subscriptionFinished(.command, error: nil)
        #expect(session.refreshBattery().isEmpty)
        _ = session.subscriptionFinished(.events, error: nil)
        #expect(session.refreshBattery().isEmpty)

        let reply = YCBTFrameCodec.Message.deviceInfo(.init(payloadLength: 8, batteryPercent: 42, isCharging: false))
        #expect(session.received(reply, at: .now) == [.battery(percent: 42, isCharging: false)])
        #expect(session.isIdentified)
        #expect(session.refreshBattery() == [.write(YCBTFrameCodec.deviceInfoRequest(), purpose: .batteryQuery)])

        // A later reply updates the battery without disturbing the phase.
        let later = YCBTFrameCodec.Message.deviceInfo(.init(payloadLength: 8, batteryPercent: 41, isCharging: true))
        #expect(session.received(later, at: .now) == [.battery(percent: 41, isCharging: true)])
        #expect(session.phase == .ready(last: nil))
        // A failed battery query changes nothing.
        #expect(session.writeFinished(.batteryQuery, error: "Busy").isEmpty)
        #expect(session.phase == .ready(last: nil))

        // Never while a measurement owns the channel.
        _ = session.startHeartRate()
        #expect(session.refreshBattery().isEmpty)
    }

    @Test("A reply without battery bytes identifies the ring and reports nothing")
    func identityWithoutBattery() {
        var session = R11MRingSession(writeWithResponse: true)
        _ = session.subscriptionFinished(.command, error: nil)
        _ = session.subscriptionFinished(.events, error: nil)
        #expect(session.received(.deviceInfo(.init(payloadLength: 4)), at: .now).isEmpty)
        #expect(session.isIdentified)
    }

    @Test("No command is written until both vendor channels confirm")
    func waitsForBothChannels() {
        var session = R11MRingSession(writeWithResponse: true)
        #expect(session.subscriptionFinished(.events, error: nil).isEmpty)
        #expect(session.phase == .awaitingSubscriptions(pending: [.command]))
        #expect(session.startHeartRate().isEmpty)

        let actions = session.subscriptionFinished(.command, error: nil)
        #expect(session.phase == .identifying)
        #expect(actions.first == .write(YCBTFrameCodec.deviceInfoRequest(), purpose: .identify))
        // Identification alone never starts a measurement.
        #expect(!actions.contains { if case .write(_, .start) = $0 { true } else { false } })
    }

    @Test("A failed vendor subscription is named and sends nothing")
    func oneChannelFails() {
        var session = R11MRingSession(writeWithResponse: true)
        _ = session.subscriptionFinished(.command, error: nil)
        #expect(session.subscriptionFinished(.events, error: "Not permitted").isEmpty)
        #expect(session.phase == .subscriptionFailed(.events, "Not permitted"))
        #expect(session.startHeartRate().isEmpty)
        #expect(!session.suppressesStandardHeartRate)
        #expect(session.statusText.contains("event channel"))
    }

    @Test("No identity reply leaves the ring unidentified and the standard path in charge")
    func identityTimeout() {
        var session = R11MRingSession(writeWithResponse: true)
        _ = session.subscriptionFinished(.command, error: nil)
        let actions = session.subscriptionFinished(.events, error: nil)
        guard case .scheduleTimeout(.identification, _, let token) = actions.last else {
            Issue.record("Expected an identification timeout")
            return
        }
        #expect(session.timeoutElapsed(.identification, token: token).isEmpty)
        guard case .unidentified = session.phase else {
            Issue.record("Expected unidentified, got \(session.phase)")
            return
        }
        #expect(!session.isIdentified)
        #expect(!session.suppressesStandardHeartRate)
        #expect(session.startHeartRate().isEmpty)
    }

    @Test("Warm-up and zero values are provisional; the last value before completion is emitted")
    func warmupThenCompletion() {
        var session = identifiedSession()
        let start = session.startHeartRate()
        #expect(start.first == .write(YCBTFrameCodec.measurementRequest(start: true, sensor: .heartRate), purpose: .start(.heartRate)))
        #expect(session.received(.measurementAck(status: 0), at: .now).isEmpty)

        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(session.received(.liveHeartRate(bpm: 0), at: t0).isEmpty)
        #expect(session.phase == .measuring(.heartRate, provisional: nil))
        #expect(session.received(.liveHeartRate(bpm: 46), at: t0.addingTimeInterval(22)).isEmpty)
        #expect(session.received(.liveHeartRate(bpm: 46), at: t0.addingTimeInterval(23)).isEmpty)
        let final = t0.addingTimeInterval(34)
        #expect(session.received(.liveHeartRate(bpm: 81), at: final).isEmpty)
        #expect(session.phase == .measuring(.heartRate, provisional: .heartRate(bpm: 81)))

        let done = session.received(.measurementFinished(sensor: 0, result: 1), at: t0.addingTimeInterval(35))
        #expect(done == [.emit(.heartRate(bpm: 81), measuredAt: final)])
        #expect(session.phase == .ready(last: .measured(.heartRate(bpm: 81), measuredAt: final)))
    }

    @Test("No contact, a rejected request, and a completion without values never emit")
    func nonMeasurements() {
        var noContact = identifiedSession()
        _ = noContact.startHeartRate()
        _ = noContact.received(.liveHeartRate(bpm: 55), at: .now)
        #expect(noContact.received(.measurementFinished(sensor: 0, result: 2), at: .now).isEmpty)
        #expect(noContact.phase == .ready(last: .noContact))

        var rejected = identifiedSession()
        _ = rejected.startHeartRate()
        #expect(rejected.received(.measurementAck(status: 0xFE), at: .now).isEmpty)
        #expect(rejected.phase == .ready(last: .requestRejected(status: 0xFE)))
        #expect(rejected.statusText.contains("rejected the measurement request"))

        var empty = identifiedSession()
        _ = empty.startHeartRate()
        _ = empty.received(.liveHeartRate(bpm: 0), at: .now)
        #expect(empty.received(.measurementFinished(sensor: 0, result: 1), at: .now).isEmpty)
        #expect(empty.phase == .ready(last: .finishedWithoutValue))
    }

    @Test("Acquisition timeout stops the measurement; a stale timer is ignored")
    func acquisitionTimeout() {
        var session = identifiedSession()
        let first = session.startHeartRate()
        guard case .scheduleTimeout(.acquisition, _, let firstToken) = first.last else {
            Issue.record("Expected an acquisition timeout")
            return
        }
        _ = session.received(.liveHeartRate(bpm: 60), at: .now)
        let stop = session.timeoutElapsed(.acquisition, token: firstToken)
        #expect(stop == [.write(YCBTFrameCodec.measurementRequest(start: false, sensor: .heartRate), purpose: .stop(.heartRate))])
        #expect(session.phase == .ready(last: .timedOut(livePackets: 1)))

        // A second measurement is unaffected by the first one's late timer.
        _ = session.startHeartRate()
        #expect(session.timeoutElapsed(.acquisition, token: firstToken).isEmpty)
        #expect(session.isMeasuring)

        var silent = identifiedSession()
        let actions = silent.startHeartRate()
        guard case .scheduleTimeout(.acquisition, _, let token) = actions.last else { return }
        _ = silent.timeoutElapsed(.acquisition, token: token)
        #expect(silent.statusText == "No measurement packets received after starting measurement.")
    }

    @Test("Cancel sends one stop and a repeat measurement works afterwards")
    func cancelAndRepeat() {
        var session = identifiedSession()
        _ = session.startHeartRate()
        #expect(session.cancel().count == 1)
        #expect(session.cancel().isEmpty)
        #expect(session.phase == .ready(last: .cancelled))
        #expect(session.received(.measurementFinished(sensor: 0, result: 1), at: .now).isEmpty)

        _ = session.startHeartRate()
        _ = session.received(.liveHeartRate(bpm: 70), at: .now)
        #expect(session.received(.measurementFinished(sensor: 0, result: 1), at: .now).count == 1)
    }

    @Test("A failed start write ends the measurement with the transport error")
    func writeFailure() {
        var session = identifiedSession()
        _ = session.startHeartRate()
        _ = session.writeFinished(.start(.heartRate), error: "Disconnected")
        #expect(session.phase == .ready(last: .writeFailed("Disconnected")))
    }

    @Test("Frames and completions of another measurement never become readings")
    func otherMeasurementIgnored() {
        var session = identifiedSession()
        _ = session.startHeartRate()
        #expect(session.received(.liveSpO2(percent: 97), at: .now).isEmpty)
        #expect(session.received(.liveBloodPressure(systolic: 120, diastolic: 80), at: .now).isEmpty)
        #expect(session.livePackets == 0)
        #expect(session.received(.measurementFinished(sensor: 0x02, result: 1), at: .now).isEmpty)
        #expect(session.isMeasuring)
    }
}

@Suite("Bluetooth readiness and diagnostics")
struct BluetoothReadinessDiagnosticsTests {

    @Test("Standard HR frames keep unknown, off-body, and contact semantics")
    func contactVectors() throws {
        let unknown = try #require(HeartRateMeasurement(data: Data([0x00, 0x48])))
        #expect(unknown.beatsPerMinute == 72)
        #expect(unknown.isSensorContactDetected == nil)
        #expect(unknown.rrIntervalsMS.isEmpty)
        let offBody = try #require(HeartRateMeasurement(data: Data([0x04, 0x48])))
        #expect(offBody.isSensorContactDetected == false)
        let contact = try #require(HeartRateMeasurement(data: Data([0x06, 0x48])))
        #expect(contact.isSensorContactDetected == true)
    }

    @Test("Heart-rate readiness promises one metric, not three")
    func readinessCountsHeartRateOnly() {
        var state = BluetoothDiscoveryState(serviceIDs: ["180D"])
        state.finishService(id: "180D", candidates: [.init(id: "2A37", metrics: [.heartRate])])
        state.finishSubscription(id: "2A37")
        #expect(state.resolution == .ready(metrics: [.heartRate], warnings: []))
        let resolved = PeripheralConnectionState.resolving(state.resolution, current: .enablingNotifications([.heartRate]), observed: [])
        // The plural form ("metric") comes from the string catalog, so only the count is pinned.
        #expect(resolved.state.title.hasPrefix("Ready for 1 metric"))
        #expect(resolved.state.title.hasSuffix("; waiting for data\u{2026}"))
        #expect(resolved.armsWatchdog)
    }

    @Test("A vendor control channel makes a connection ready without advertising a metric")
    func controlChannelReadiness() {
        var state = BluetoothDiscoveryState(serviceIDs: ["BE940000"])
        state.finishService(id: "BE940000", candidates: [
            .init(id: "cmd", metrics: []),
            .init(id: "evt", metrics: []),
        ])
        #expect(state.resolution == .enabling([]))
        state.finishSubscription(id: "cmd")
        state.finishSubscription(id: "evt", errorDescription: "Declined")
        #expect(state.resolution == .ready(metrics: [], warnings: ["Subscription evt: Declined"]))

        let ring = PeripheralConnectionState.resolving(
            state.resolution,
            current: .enablingNotifications([]),
            observed: [],
            onDemandStatus: "Connected; waiting for ring measurement."
        )
        #expect(ring.state == .ready([], warning: "Connected; waiting for ring measurement."))
        #expect(!ring.armsWatchdog)
    }

    @Test("An early valid value survives a late discovery callback")
    func lateCallbackPreservesStreaming() {
        let streaming = PeripheralConnectionState.streaming([.heartRate])
        let enabling = PeripheralConnectionState.resolving(.enabling([.heartRate, .spo2]), current: streaming, observed: [.heartRate])
        #expect(enabling.state == streaming)
        let ready = PeripheralConnectionState.resolving(.ready(metrics: [.heartRate, .spo2], warnings: []), current: streaming, observed: [.heartRate])
        #expect(ready.state == streaming)
        #expect(!ready.armsWatchdog)
        let fromReady = PeripheralConnectionState.resolving(.ready(metrics: [.heartRate], warnings: []), current: .ready([.heartRate], warning: nil), observed: [.heartRate])
        #expect(fromReady.state == .streaming([.heartRate]))
    }

    @Test("Silence, rejection, and a stopped stream have distinct explanations")
    func stallDiagnosis() {
        let start = Date(timeIntervalSince1970: 10_000)
        var silent = BluetoothDiagnostics(startedAt: start, connectionSession: 1, fullDiscovery: false)
        silent.recordCharacteristic(key: "k", uuid: "2A37", serviceUUID: "180D", properties: ["notify"])
        #expect(silent.stallDiagnosis == .noPackets)

        var rejected = silent
        rejected.recordPacket(key: "k", data: Data([0x04, 0x48]), at: start.addingTimeInterval(1), isMeasurement: true)
        rejected.reject(.offBody)
        #expect(rejected.measurementPackets == 1)
        #expect(rejected.acceptedValues == 0)
        #expect(rejected.stallDiagnosis == .packetsRejected(.offBody))
        #expect(rejected.stallDiagnosis.message(seconds: 30) == "Receiving packets; readings rejected: sensor reports no contact.")

        var stopped = silent
        stopped.recordPacket(key: "k", data: Data([0x00, 0x48]), at: start.addingTimeInterval(1), isMeasurement: true)
        stopped.accept(.heartRate, value: 72, at: start.addingTimeInterval(1))
        #expect(stopped.stallDiagnosis == .streamStopped)
        stopped.recordPacket(key: "k", data: Data([0x04, 0x48]), at: start.addingTimeInterval(2), isMeasurement: true)
        stopped.reject(.offBody)
        #expect(stopped.stallDiagnosis == .packetsRejected(.offBody))

        // Battery and other non-measurement packets do not count as measurement attempts.
        var battery = silent
        battery.recordPacket(key: "k", data: Data([80]), at: start, isMeasurement: false)
        battery.reject(.unknownCharacteristic)
        #expect(battery.stallDiagnosis == .noPackets)
    }

    @Test("Raw packets are captured only during a diagnostic session, and bounded")
    func rawCaptureBounds() {
        let start = Date(timeIntervalSince1970: 20_000)
        var ordinary = BluetoothDiagnostics(startedAt: start, connectionSession: 1, fullDiscovery: false)
        ordinary.recordPacket(key: "k", data: Data([1, 2]), at: start, isMeasurement: true)
        #expect(ordinary.rawCapture.isEmpty)
        #expect(!ordinary.exportText(deviceName: "Ring").contains("Raw packets"))

        var diagnostic = BluetoothDiagnostics(startedAt: start, connectionSession: 2, fullDiscovery: true)
        for index in 0..<(BluetoothDiagnostics.maximumRawPackets + 20) {
            diagnostic.recordPacket(key: "k", data: Data([0xAB]), at: start.addingTimeInterval(Double(index) * 0.1), isMeasurement: true)
        }
        #expect(diagnostic.rawCapture.count == BluetoothDiagnostics.maximumRawPackets)
        diagnostic.recordPacket(key: "k", data: Data([0xCD]), at: start.addingTimeInterval(BluetoothDiagnostics.diagnosticCaptureDuration + 1), isMeasurement: true)
        #expect(!diagnostic.rawCapture.contains { $0.hex == "CD" })
        #expect(diagnostic.exportText(deviceName: "Ring").contains("AB"))
    }

    @Test("A written command is recorded separately from the ring's acceptance")
    func commandStages() {
        var diagnostics = BluetoothDiagnostics(startedAt: .now, connectionSession: 1, fullDiscovery: false)
        diagnostics.recordCommand(purpose: "Start heart-rate measurement", bytes: 8, at: .now)
        #expect(diagnostics.commands.last?.stage == .sent)
        diagnostics.recordWrite(purpose: "Start heart-rate measurement", error: nil)
        #expect(diagnostics.commands.last?.stage == .written)
        #expect(diagnostics.exportText(deviceName: "Ring").contains("transport only"))
    }

    @Test("The stall threshold follows the stream's cadence within bounds")
    func cadence() {
        var cadence = StreamCadence()
        #expect(cadence.stallThreshold == StreamCadence.initialAcquisitionBudget)
        let start = Date(timeIntervalSince1970: 0)
        for second in 0..<5 { cadence.record(start.addingTimeInterval(Double(second))) }
        #expect(cadence.stallThreshold == StreamCadence.initialAcquisitionBudget)

        var slow = StreamCadence()
        for minute in 0..<5 { slow.record(start.addingTimeInterval(Double(minute) * 60)) }
        #expect(slow.stallThreshold == 240)

        var sparse = StreamCadence()
        for hour in 0..<3 { sparse.record(start.addingTimeInterval(Double(hour) * 3_600)) }
        #expect(sparse.stallThreshold == StreamCadence.maximumThreshold)
    }
}
