import Foundation
import Testing
@testable import HeartSyncChecker

/// `BluetoothManager`'s per-peripheral state as two values (improvement 66), exercised
/// without CoreBluetooth: the characteristic type is a stand-in.
@Suite("Per-peripheral link and record")
struct PeripheralStateTests {

    private struct FakeCharacteristic: Equatable { var name: String }

    @Test("A new link starts empty: no metrics, no beats, no ring bookkeeping")
    func newLinkIsEmpty() {
        var link = PeripheralLink<FakeCharacteristic>(session: 7)
        #expect(link.session == 7)
        #expect(link.discovery == nil)
        #expect(link.observedMetrics.isEmpty)
        #expect(link.hrv.bufferedBeats == 0)
        #expect(link.ring.pendingWrites.isEmpty)
        #expect(link.cadence.stallThreshold == StreamCadence.initialAcquisitionBudget)
        link.hrv.add(intervals: [800, 810, 790], at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(link.hrv.bufferedBeats == 3)
        // Ending a session replaces the value: the beats cannot survive into the next one.
        link = PeripheralLink(session: 8)
        #expect(link.hrv.bufferedBeats == 0)
    }

    @Test("Ending a link cancels the work it scheduled")
    func cancelScheduledWork() async {
        var link = PeripheralLink<FakeCharacteristic>(session: 1)
        link.stallTask = Task { try? await Task.sleep(for: .seconds(60)) }
        link.ring.timeoutTask = Task { try? await Task.sleep(for: .seconds(60)) }
        link.cancelScheduledWork()
        #expect(link.stallTask?.isCancelled == true)
        #expect(link.ring.timeoutTask?.isCancelled == true)
    }

    @Test("Write results are matched to the oldest write awaiting one")
    func pendingWritesAreFIFO() {
        var ring = RingLink<FakeCharacteristic>()
        #expect(ring.takeWriteResult() == nil)
        ring.noteWriteSent(.identify)
        ring.noteWriteSent(.start(.heartRate))
        #expect(ring.takeWriteResult() == .identify)
        #expect(ring.takeWriteResult() == .start(.heartRate))
        #expect(ring.takeWriteResult() == nil)
    }

    @Test("A frame split across notifications reassembles per channel, and channels stay apart")
    func assemblyPerChannel() {
        var ring = RingLink<FakeCharacteristic>()
        let frame = YCBTFrameCodec.deviceInfoRequest()
        let head = Data(frame.prefix(3))
        let tail = Data(frame.dropFirst(3))
        #expect(ring.assemble(head, on: .events).isEmpty)
        // The other channel's assembler has not seen the head.
        let other = ring.assemble(tail, on: .command)
        #expect(!other.contains { if case .frame = $0 { true } else { false } })
        let outputs = ring.assemble(tail, on: .events)
        #expect(outputs.count == 1)
        if case .frame(let assembled) = outputs.first {
            #expect(assembled.payload == [0x47, 0x43])
        } else {
            Issue.record("Expected one reassembled frame")
        }
    }

    @Test("A device record's reconnect bookkeeping cancels cleanly")
    func recordCancellation() async {
        var record = PeripheralRecord()
        record.reconnectAttempts = 3
        record.reconnectTask = Task { try? await Task.sleep(for: .seconds(60)) }
        record.awaitingFreshReconnect = true
        record.freshReconnectFallback = Task { try? await Task.sleep(for: .seconds(60)) }
        let reconnect = record.reconnectTask
        let fallback = record.freshReconnectFallback

        record.cancelFreshReconnect()
        #expect(!record.awaitingFreshReconnect)
        #expect(record.freshReconnectFallback == nil)
        #expect(fallback?.isCancelled == true)

        record.cancelPendingReconnect()
        #expect(record.reconnectTask == nil)
        #expect(reconnect?.isCancelled == true)
        // Attempts are the backoff's memory; only a successful connection clears them.
        #expect(record.reconnectAttempts == 3)
    }

    @Test("Device information reads as identity then firmware, omitting what is missing")
    func deviceInformation() {
        #expect(DeviceInformation(manufacturer: "Polar", model: "H10", firmware: "3.1.1").displayString == "Polar H10 (firmware 3.1.1)")
        #expect(DeviceInformation(manufacturer: nil, model: nil, firmware: "2.0").displayString == "Firmware 2.0")
        #expect(DeviceInformation(manufacturer: "Acme", model: nil, firmware: nil).displayString == "Acme")
        #expect(DeviceInformation().displayString.isEmpty)
    }
}
