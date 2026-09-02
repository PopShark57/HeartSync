@preconcurrency import CoreBluetooth
import Foundation
import OSLog

extension BluetoothManager {

    // MARK: Ingest

    func emit(_ reading: Reading) {
        onReading?(reading)
    }

    func note(metric: MetricKind, for peripheralID: UUID) {
        if case .streaming(var kinds) = connectionStates[peripheralID] ?? .disconnected {
            guard !kinds.contains(metric) else { return }
            kinds.insert(metric)
            connectionStates[peripheralID] = .streaming(kinds)
        } else {
            connectionStates[peripheralID] = .streaming([metric])
        }
    }

    func handleHeartRate(_ data: Data, from peripheral: CBPeripheral) {
        guard let measurement = HeartRateMeasurement(data: data) else {
            logger.debug("Unparseable HR frame, \(data.count) bytes")
            return
        }
        let id = peripheral.identifier
        let sourceID = id.uuidString
        let now = Date.now

        // A sensor that supports contact detection and says it is off-body is reporting
        // noise. Storing it would generate a large, meaningless discrepancy.
        if measurement.isSensorContactDetected == false { return }

        emit(Reading(
            sourceID: sourceID,
            kind: .heartRate,
            value: Double(measurement.beatsPerMinute),
            start: now,
            provenance: .measured
        ))
        note(metric: .heartRate, for: id)

        guard !measurement.rrIntervalsMS.isEmpty else { return }
        var accumulator = hrvAccumulators[id] ?? HRVAccumulator()
        accumulator.add(intervals: measurement.rrIntervalsMS, at: now)
        hrvProgress[id] = (accumulator.bufferedBeats, accumulator.bufferedDuration)

        if let metrics = accumulator.emitIfReady(at: now) {
            let windowStart = now.addingTimeInterval(-accumulator.window)
            emit(Reading(sourceID: sourceID, kind: .hrvRMSSD, value: metrics.rmssd,
                         start: windowStart, end: now, provenance: .derived))
            emit(Reading(sourceID: sourceID, kind: .hrvSDNN, value: metrics.sdnn,
                         start: windowStart, end: now, provenance: .derived))
            note(metric: .hrvRMSSD, for: id)
            note(metric: .hrvSDNN, for: id)
            // Published alongside, not stored: it qualifies the window that was just
            // emitted rather than being a measurement of its own.
            hrvQuality[id] = HRVQuality(metrics: metrics, measuredAt: now)
        }
        hrvAccumulators[id] = accumulator
    }

    func handlePulseOximeter(_ data: Data, from peripheral: CBPeripheral, isSpotCheck: Bool) {
        let parsed = isSpotCheck
            ? PulseOximeterMeasurement.spotCheck(data: data)
            : PulseOximeterMeasurement.continuous(data: data)
        guard let measurement = parsed else { return }
        // The device's own status bits are more reliable than any heuristic here.
        guard !measurement.isDeviceReportedInvalid else {
            logger.debug("Pulse oximeter reported an invalid measurement; skipping")
            return
        }

        let id = peripheral.identifier
        let sourceID = id.uuidString
        let timestamp = measurement.timestamp ?? .now

        if let spo2 = measurement.spo2Percent {
            emit(Reading(sourceID: sourceID, kind: .spo2, value: spo2,
                         start: timestamp, provenance: .measured))
            note(metric: .spo2, for: id)
        }
        if let pulse = measurement.pulseRateBPM {
            emit(Reading(sourceID: sourceID, kind: .heartRate, value: pulse,
                         start: timestamp, provenance: .measured))
            note(metric: .heartRate, for: id)
        }
    }

    func handleTemperature(_ data: Data, from peripheral: CBPeripheral) {
        guard let measurement = TemperatureMeasurement(data: data) else { return }
        emit(Reading(
            sourceID: peripheral.identifier.uuidString,
            kind: .bodyTemperature,
            value: measurement.celsius,
            start: measurement.timestamp ?? .now,
            provenance: .measured
        ))
        note(metric: .bodyTemperature, for: peripheral.identifier)
    }

    func handleBattery(_ data: Data, from peripheral: CBPeripheral) {
        var reader = BinaryReader(data)
        guard let percent = reader.uint8(), percent <= 100 else { return }
        store?.updateBattery(Int(percent), forSource: peripheral.identifier.uuidString)
    }

    /// Records where on the body the sensor sits (Body Sensor Location, 0x2A38).
    ///
    /// A single uint8 from the SIG enumeration. Unknown values are dropped rather than
    /// coerced to `.other`: the interpretation text keys off optical-versus-electrical
    /// sensing, and inventing a location would let the UI explain away a real
    /// disagreement with a technology difference that may not exist.
    func handleBodySensorLocation(_ data: Data, from peripheral: CBPeripheral) {
        var reader = BinaryReader(data)
        guard let raw = reader.uint8(), let location = BodySensorLocation(rawValue: raw) else {
            logger.debug("Unrecognised body sensor location value")
            return
        }
        store?.setBodyLocation(location, forSource: peripheral.identifier.uuidString)
    }

    func handleDeviceInfo(_ characteristic: CBCharacteristic, from peripheral: CBPeripheral) {
        guard let data = characteristic.value,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }

        let id = peripheral.identifier
        var info = pendingModelInfo[id] ?? DeviceInformation()
        switch characteristic.uuid {
        case GATT.manufacturerNameString:   info.manufacturer = text
        case GATT.modelNumberString:        info.model = text
        // Firmware matters here because two units of the same model on different firmware
        // are genuinely different measuring instruments, and this app exists to explain
        // why two devices disagree.
        case GATT.firmwareRevisionString:   info.firmware = text
        default: return
        }
        pendingModelInfo[id] = info

        let combined = info.displayString
        guard !combined.isEmpty, let store, var source = store.source(id: id.uuidString) else { return }
        source.model = combined
        store.upsert(source)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        MainActor.assumeIsolated {
            self.state = newState
            if newState == .poweredOn {
                self.reconnectKnownDevices()
            } else {
                // Ends the scan properly rather than only flipping the flag: the timeout
                // and coalescing tasks have to stop too, and the last packets published.
                self.stopScan()
                // Pending reconnects cannot succeed without a radio, and would otherwise
                // spend their attempt ceiling while Bluetooth is off.
                for task in self.reconnectTasks.values { task.cancel() }
                self.reconnectTasks.removeAll()
                // Mark everything disconnected so the UI does not keep showing stale
                // "streaming" badges after the radio goes away.
                for key in self.connectionStates.keys {
                    self.connectionStates[key] = .disconnected
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Unnamed device"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { GATT.title(for: $0) }
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let rssi = RSSI.intValue

        MainActor.assumeIsolated {
            self.peripherals[id] = peripheral

            // RSSI of 127 is CoreBluetooth's "not available" sentinel, not a strong signal.
            let entry = DiscoveredPeripheral(
                id: id,
                name: name,
                rssi: rssi == 127 ? -100 : rssi,
                advertisedServices: services,
                isConnectable: connectable,
                lastSeen: .now
            )
            // Coalesced rather than published here: with duplicates allowed this runs for
            // every advertisement packet from every device in range.
            self.discoveredByID[id] = entry
            self.hasUnpublishedDiscoveries = true
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.logger.info("Connected to \(peripheral.identifier.uuidString, privacy: .public)")
            // A connection that actually succeeded resets the backoff, so a device that
            // drops once an hour never accumulates its way to the attempt ceiling.
            self.cancelPendingReconnect(for: peripheral.identifier)
            self.reconnectAttempts[peripheral.identifier] = nil
            self.store?.markSeen(sourceID: peripheral.identifier.uuidString)
            self.discoverServices(on: peripheral)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let reason = error?.localizedDescription ?? "Could not connect"
        MainActor.assumeIsolated {
            self.logger.info(
                "Failed to connect to \(peripheral.identifier.uuidString, privacy: .public): \(reason, privacy: .public)"
            )
            // Transient first-connect failures (device out of range, brief radio glitch)
            // used to stay in `.failed` forever. Share the disconnect backoff so they
            // recover automatically, and only surface a permanent failure after the ceiling.
            guard let source = self.store?.source(id: peripheral.identifier.uuidString),
                  source.isEnabled
            else {
                self.connectionStates[peripheral.identifier] = .failed(reason)
                return
            }
            self.connectionStates[peripheral.identifier] = .disconnected
            self.scheduleReconnect(
                peripheral,
                gaveUpReason: "Could not connect. Use Reconnect to try again."
            )
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            self.connectionStates[peripheral.identifier] = .disconnected
            // The HRV window is only meaningful over a continuous recording, so a
            // disconnection invalidates it rather than pausing it.
            self.hrvAccumulators[peripheral.identifier]?.reset()
            self.hrvProgress[peripheral.identifier] = nil
            self.hrvQuality[peripheral.identifier] = nil

            // Rings drop out constantly. Reconnect automatically as long as the source is
            // still enabled, but with a backoff: an immediate retry against a device that
            // is dropping every second is a tight loop with no end state.
            guard let source = self.store?.source(id: peripheral.identifier.uuidString),
                  source.isEnabled
            else { return }
            self.scheduleReconnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // `[CBPeripheral]` is not Sendable, so handing the array to the main actor trips
        // region isolation. It is sound here for the same reason the `assumeIsolated`
        // hops are: the central was created with a nil queue, so this callback is already
        // running on the main queue and no second thread can observe these objects.
        nonisolated(unsafe) let restored =
            dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated {
            // iOS relaunched the app to hand back live connections. Re-adopt them and
            // re-attach the delegate, otherwise notifications arrive nowhere.
            for peripheral in restored {
                self.peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
                if peripheral.state == .connected {
                    self.discoverServices(on: peripheral)
                }
            }
            self.logger.info("Restored \(restored.count) peripheral(s) from background")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        MainActor.assumeIsolated {
            if let error {
                self.connectionStates[peripheral.identifier] = .failed(error.localizedDescription)
                return
            }
            let services = peripheral.services ?? []
            guard !services.isEmpty else {
                self.connectionStates[peripheral.identifier] =
                    .failed("This device exposes no readable health services.")
                return
            }
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            guard error == nil, let characteristics = service.characteristics else { return }
            for characteristic in characteristics {
                if GATT.notifyCharacteristics.contains(characteristic.uuid),
                   characteristic.properties.contains(.notify)
                       || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if GATT.readOnceCharacteristics.contains(characteristic.uuid),
                   characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
            if case .streaming = self.connectionStates[peripheral.identifier] {} else {
                self.connectionStates[peripheral.identifier] = .streaming([])
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            guard error == nil, let data = characteristic.value else { return }
            switch characteristic.uuid {
            case GATT.heartRateMeasurement:
                self.handleHeartRate(data, from: peripheral)
            case GATT.plxContinuousMeasurement:
                self.handlePulseOximeter(data, from: peripheral, isSpotCheck: false)
            case GATT.plxSpotCheckMeasurement:
                self.handlePulseOximeter(data, from: peripheral, isSpotCheck: true)
            case GATT.temperatureMeasurement, GATT.intermediateTemperature:
                self.handleTemperature(data, from: peripheral)
            case GATT.batteryLevel:
                self.handleBattery(data, from: peripheral)
            case GATT.bodySensorLocation:
                self.handleBodySensorLocation(data, from: peripheral)
            case GATT.manufacturerNameString, GATT.modelNumberString, GATT.firmwareRevisionString:
                self.handleDeviceInfo(characteristic, from: peripheral)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let error else { return }
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            self.logger.error(
                "Failed to subscribe to \(uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
