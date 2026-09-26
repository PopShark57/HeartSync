# RingFix — R11M direct Bluetooth diagnosis and proposed fix

**Reviewed:** 26 September 2026  
**Repository:** [PopShark57/HeartSync](https://github.com/PopShark57/HeartSync)  
**Reviewed revision:** [`ae872d8af778f74049e7806727ffe40f97057956`](https://github.com/PopShark57/HeartSync/commit/ae872d8af778f74049e7806727ffe40f97057956)  
**Scope:** The ring itself, through direct BLE. No SmartHealth or Apple Health data source, bridge, or fallback.  
**Change made by this review:** This document only. All implementation changes below are proposals.

## Implementation status (2026-09-26)

Steps 1–4 below are implemented. The protocol path is **still unverified on hardware**:
nothing here connected to a ring, so the completion criterion in section 8 is not yet met.

| Step | Where | State |
| --- | --- | --- |
| 1. Diagnostics | `Sources/Bluetooth/BluetoothDiagnostics.swift`, Devices › device menu › Run Bluetooth diagnostics / Export diagnostics | Done. Full `discoverServices(nil)` only in a diagnostic session. Packets counted before parsing, per characteristic. Named rejections. Commands tracked as sent, written, and failed, apart from the ring's acceptance. Forwarded is distinct from saved. Raw packets only for 60 seconds of a diagnostic session, at most 200, export only. |
| 2. Ring adapter | `Sources/Bluetooth/YCBTFrameCodec.swift`, `Sources/Bluetooth/R11MRingSession.swift` | Done as a candidate. Chosen from topology, not name. Waits for both channel subscriptions, then sends one read-only identity query (`02 00`, `"GC"`). Measurement is offered only after a CRC-valid identity reply, and starts only on Measure heart rate (`03 2F`, `01 00`). Fragmented frames reassemble within 512 bytes; bad length or CRC produces nothing. Live `06 01` values are provisional; the `04 0E` completion event emits the last one through `emit` → `AppModel.ingest` → `HealthStore`. No contact (`02`), rejection, and timeout (90 s, then stop) store nothing. SpO₂ is recognized but not requested or stored. Standard `2A37` from an identified ring is not ingested. |
| 3. Readiness | `BluetoothDiscoveryState`, `PeripheralConnectionState.resolving`, `StreamCadence` | Done. Heart rate counts as one metric; HRV appears only from real R–R intervals. Vendor channels make a link ready without adding metrics. Observed metrics survive late callbacks. The watchdog follows cadence (30 s to 10 min) and says whether it saw silence, rejected packets, or a stopped stream. A ring's spot reading ages normally; no watchdog runs for it. |
| 4. Reconnect | `BluetoothManager.reconnect`, `beginFreshSession` | Done. A connected link is cancelled, and one new connection starts from its disconnect callback, bypassing the backoff (10 s fallback if the callback never comes). Pause, forget, and radio-off cancel it. Delayed work checks a per-link session number. A foreground refresh no longer rediscovers a live link. |

Where the framing came from: the frame layout (`group | command | length LE | payload | CRC
LE`, CRC-16/CCITT-FALSE, total length including header and CRC) and the `04 0E` completion
event are from independent public write-ups of R11M-reporting and YCBT rings
([vitals-smart-ring-app PROTOCOL.md](https://github.com/narey83/vitals-smart-ring-app/blob/main/PROTOCOL.md),
[PulseLoopAndroid issue 59](https://github.com/foureight84/PulseLoopAndroid/issues/59)). The
same write-up reports that this firmware's `2A37` contact bit says "not detected" while
readings are genuine. That may explain the observed silence, because HeartSync correctly
discards off-body frames. The contact check was not weakened. The vendor completion result
is used for that ring instead.

Tests: `Tests/RingSessionTests.swift` (codec vectors, reassembly, topology selection,
subscription gating, warm-up, completion, no contact, rejection, timeouts, cancel and
repeat, readiness, late callbacks, stall diagnosis, capture bounds, cadence). Hardware
acceptance steps are in `RELEASE_CHECKLIST.md` under "Vendor ring".

## 1. Diagnosis

HeartSync can connect to the R11M and subscribe to a recognized measurement characteristic, but that does not establish that the ring is actively measuring or delivering usable measurements.

**The leading explanation is incomplete direct-ring protocol support:** HeartSync only discovers a short list of Bluetooth SIG services and passively subscribes to their measurements. It never discovers a vendor control service or sends a vendor measurement-start command. A ring that needs that initialization can therefore remain connected and subscribed indefinitely without providing usable values.

This is a well-supported hypothesis, not a confirmed packet-level diagnosis of this particular ring. The screenshots contain no characteristic inventory, raw packets, or firmware identity. They cannot distinguish a silent characteristic from received packets rejected for contact, format, quality, or value. A Yucheng/YCBT adapter is a concrete candidate, but it must be selected from the actual ring's GATT fingerprint and responses.

Several related application defects are confirmed independently: the inflated readiness count, an undifferentiated timeout, and a Reconnect action that does not establish a fresh link when already connected.

**Recommended fix:** Add direct-ring diagnostics and a narrowly scoped, fingerprint-gated ring adapter; initialize and start measurements through the verified ring protocol; retain the existing standard-profile path for other devices. Correct readiness and reconnect behavior alongside that work.

Changing the timeout or displaying three metric badges will not make the ring produce measurements.

## 2. What the screenshots actually establish

| Screenshot detail | Meaning in the reviewed code |
| --- | --- |
| “Ready for 3 metrics; waiting for data…” | Subscription readiness, not three received values. One `2A37` characteristic is assigned `.heartRate`, `.hrvRMSSD`, and `.hrvSDNN` before any RR intervals are observed. |
| “Connected and subscribed, but no valid measurement arrived…” | HeartSync's own 30-second watchdog reached a `.ready` state without a subsequent accepted emission resetting it. This is not an error returned by the ring. |
| Large green dot beside the ring | A persistent source-identification color. The smaller orange/red dot beside the status text carries connection status. |
| “Finger” | Body-location metadata. It can be retained from an earlier read; it does not prove that an optical measurement is underway. |
| No measurement badges under the Bluetooth ring | Consistent with no observed measurement metrics for that source. The readiness count is generated separately. |

The “3” most directly matches the heart-rate mapping, but the count alone does not prove which characteristics were discovered; another combination of profiles can also total three.

Evidence: [readiness and state text](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L27-L110), [watchdog and capability mapping](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L547-L581), [source row rendering](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Views/DevicesView.swift#L535-L602).

## 3. Confirmed gaps and their implications

### A. Discovery cannot reach a vendor measurement channel

`discoverServices(on:)` calls:

```swift
peripheral.discoverServices(GATT.discoverServices)
```

That list contains only `180D`, `1822`, `1809`, `180F`, and `180A`. Characteristic discovery is exhaustive only inside those returned services. The value callback dispatches known standard characteristics and ignores everything else.

There is no `writeValue` command path in the reviewed Bluetooth implementation. Consequently, successful `setNotifyValue(true, for:)` is the end of setup. If the ring needs a separate measurement command or protocol handshake, HeartSync cannot perform it.

This is an implementation limitation, not proof that every R11M firmware needs the same command.

Evidence: [GATT service list](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/GATT.swift#L13-L38), [service discovery](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L472-L482), [discovery/subscription/value callbacks](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L918-L1033).

### B. HRV is counted before the ring demonstrates RR support

The current heart-rate candidate is:

```swift
case GATT.heartRateMeasurement:
    metrics = [.heartRate, .hrvRMSSD, .hrvSDNN]
```

The handler correctly requires RR intervals and the existing accumulator's evidence thresholds before deriving HRV. The discovery label bypasses that distinction.

Proposed immediate correction, inside the document only:

```swift
case GATT.heartRateMeasurement:
    metrics = [.heartRate]
```

Present RR availability separately after observing valid intervals. Show “collecting beats” as appropriate, and expose each derived HRV metric only when its existing calculation requirements are satisfied. Never calculate HRV from successive BPM values.

Evidence: [candidate mapping and HR handler](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L567-L635).

### C. Silence and rejection are conflated

The HR path can return because parsing failed, the contact flag says off-body, notification admission throttled the packet, or the value failed `MetricKind.plausibleRange`. PLX and temperature add quality and timestamp checks. None of those outcomes is equivalent to receiving no packet.

The watchdog uses a fixed 30-second wait for both initial readiness and later streams. It does not track the measurement procedure or a verified sampling interval. It changes display state; it does not unsubscribe or prevent a later valid value from recovering the stream.

Also, `applyDiscoveryResolution` can overwrite `.streaming` with discovery/readiness state if a measurement arrives before another service or subscription callback finishes. Therefore, the timeout text alone cannot prove that no earlier measurement ever arrived.

Evidence: [emit, state resolution, watchdog](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L486-L564), [measurement handlers](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L584-L700).

### D. Reconnect repeats discovery on an existing connection

`reconnect(sourceID:)` calls `connect(peripheral)`. When `peripheral.state == .connected`, `connect` simply calls `discoverServices` and returns. This never tears down a stuck peripheral session or repeats any missing vendor handshake.

It explains why repeatedly choosing Reconnect may reproduce the same status. It does not establish the original cause of silence.

Evidence: [connect and reconnect](https://github.com/PopShark57/HeartSync/blob/ae872d8af778f74049e7806727ffe40f97057956/Sources/Bluetooth/BluetoothManager.swift#L361-L392).

### E. Indications are already supported

The subscription code checks both `.notify` and `.indicate`, then uses `setNotifyValue`. Do not propose “add indication support” as the missing fix. Apple documents that this API enables either notification type.

Similarly, do not remove the existing contact, quality, timestamp, or plausibility checks merely to make numbers appear.

## 4. Direct-ring protocol candidate: Yucheng/YCBT

Yucheng lists an R11M product and provides a native Bluetooth SDK. Independent YCBT implementations expose this topology:

| Role | Candidate UUID |
| --- | --- |
| Vendor service | `be940000-7333-be46-b7ae-689e71722bd5` |
| Command writes and command responses | `be940001-7333-be46-b7ae-689e71722bd5` |
| Measurement/history events | `be940003-7333-be46-b7ae-689e71722bd5` |

**These UUIDs have not been observed on the user's ring in this review.** A product name is insufficient to choose a driver. Discover the service, verify both characteristics and their properties, read available manufacturer/model/firmware metadata, and obtain a valid protocol response before considering the adapter identified.

The referenced YCBT encoder describes these logical operations:

| Operation | Group / command | Logical payload |
| --- | --- | --- |
| Query name | `02 / 03` | `47 50` |
| Query device information | `02 / 00` | `47 43` |
| Query supported functions | `02 / 01` | `47 46` |
| Start heart-rate measurement | `03 / 2F` | `01 00` |
| Stop heart-rate measurement | `03 / 2F` | `00 00` |
| Start SpO2 measurement | `03 / 2F` | `01 02` |
| Stop SpO2 measurement | `03 / 2F` | `00 02` |

**This is a research-backed candidate command map, not a verified R11M write recipe.** These are logical fields, not complete BLE packets. The reference adds a total-length field and CRC16/CCITT-FALSE, sends commands through the command characteristic, and handles responses on both channels. Revalidate command semantics, framing, responses, and firmware compatibility before enabling writes on this model. Do not send bare bytes from this table to arbitrary devices.

The direct adapter should subscribe to both channels and await subscription success before querying identity or starting a measurement. A successful CoreBluetooth write only confirms the transport operation; a protocol acknowledgement confirms command acceptance; a decoded measurement confirms data delivery. Track those separately.

Do not transplant an entire other ring's startup sequence. Model-specific initialization, authentication requirements, clock handling, and status/keepalive commands may differ. In particular, do not copy periodic `03 2F` writes as a generic keepalive: the referenced implementation uses that opcode to start/stop measurements.

The minimum proposed adapter reads live HR first, then adds independently validated SpO2. History download, changing all-day schedules, clock writes, firmware update, profile writes, and ring-history deletion are outside this fix.

Reference quality matters:

- [Yucheng product page](https://www.ycinnovate.com/products.html) and [SDK entry point](https://www.ycinnovate.com/sdk.html): manufacturer sources establishing a relevant product/SDK family, not this unit's fingerprint.
- [PulseLoop YCBT protocol](https://github.com/saksham2001/PulseLoopiOS/blob/e16c05c1a32cb1c1b804180c2b0e8ed987292132/PulseLoop/RingProtocol/YCBTProtocol.swift), [encoder](https://github.com/saksham2001/PulseLoopiOS/blob/e16c05c1a32cb1c1b804180c2b0e8ed987292132/PulseLoop/RingProtocol/YCBTEncoder.swift), and [driver](https://github.com/saksham2001/PulseLoopiOS/blob/e16c05c1a32cb1c1b804180c2b0e8ed987292132/PulseLoop/RingProtocol/YCBTDriver.swift): primary implementation references for the candidate topology, framing, and commands. Hardware experience with related models is not validation of this R11M.
- [OpenStrap's R11M adapter](https://github.com/OpenStrap/edge/blob/74ed35962d1bc22d346087c53aa881fd3e45e8a8/lib/ble/adapters/ring11m.dart) explicitly declares itself experimental, not hardware-tested, and does not decode physiological values. Its existence is not proof of a working fix.

## 5. Proposed implementation, in order

### Step 1 — Make direct BLE behavior inspectable

Add an on-demand diagnostic session to `BluetoothManager`, preferably backed by a small value-type `BluetoothDiagnostics.swift`.

During that bounded session, call `discoverServices(nil)` and enumerate characteristics. Outside diagnostics, keep ordinary discovery targeted; add a verified vendor service only when implementing its adapter.

Record per connection and per service/characteristic:

- UUIDs, properties, selected adapter, subscription attempts/results, and available firmware identity.
- Received callback count, byte count, first/last receipt times, and callback errors.
- Parse successes and explicit rejection reasons: malformed, off-body, invalid quality, invalid timestamp, out of range, throttled, or unknown characteristic.
- Command sent, transport completion, protocol reply/status, and measurement completion.
- First/last accepted value per metric. Distinguish values forwarded to ingestion from values confirmed saved; the current `onReading` callback returns `Void`, so `emit == true` is not a database-commit acknowledgement.

Count incoming measurement packets **before** parser/admission guards. Maintain separate last-packet and last-valid-measurement timestamps. Battery updates and command ACKs must not count as measurements.

Provide an explicit diagnostic export with a small, bounded raw-packet capture for debugging. Keep raw health packets out of ordinary public logs and repository commits.

This establishes which fix branch actually applies:

| Observation from the ring | Action |
| --- | --- |
| No supported standard measurements, matching vendor topology | Use the identified direct-ring adapter. |
| Standard subscription succeeds but no packets arrive | Investigate activation/session requirements and sampling mode. |
| Packets arrive but fail parsing or admission | Use captured fixtures to fix the specific decoder or device quirk; retain standard validity checks. |
| Valid standard values arrive | Keep standard ingestion; repair state display and verify storage independently. |
| Different vendor topology or unknown protocol | Report the exact unsupported service/firmware and retain diagnostics. Do not pretend a YCBT driver matched. |

### Step 2 — Add a small direct-ring adapter

Keep `BluetoothManager` as the connection owner. Add focused files such as:

- `Sources/Bluetooth/R11MRingSession.swift`: fingerprint selection, session setup, start/stop, replies, and timeouts.
- `Sources/Bluetooth/YCBTFrameCodec.swift`: bounded frame assembly, length/CRC checking, typed commands, and validated value decoding.

These names are proposed, not existing files. Avoid introducing a general plugin framework for this one integration.

Required behavior:

1. Select the adapter from service/characteristic identity and compatible responses, not the advertised name alone.
2. Register required subscriptions before sending commands; wait for both channel confirmations.
3. Query identity/capabilities and complete only initialization verified for that firmware.
4. Offer an explicit “Measure heart rate” action. Send one start request, await its protocol outcome, then wait for the measurement with a bounded, configurable acquisition timeout.
5. Assemble fragmented frames in bounded buffers scoped to the characteristic/session; reject malformed lengths and CRC failures.
6. Decode recognized measurement messages only. ACKs, battery, status, warmup zeros, and rejected commands must never produce physiological readings.
7. Route accepted values through the existing `emit` / `AppModel.ingest` / `HealthStore` path, using the existing peripheral UUID and `SourceTransport.bluetooth`. Here `HealthStore` means HeartSync's local store, not an external data source.
8. Stop the specific measurement mode on cancellation/pause when the link allows it, and discard pending writes/timers on disconnect. Do not run a ring sensor continuously by default.
9. Add SpO2 only after validating its start/stop procedure and payloads. Keep unsupported metrics unavailable.

Keep Swift 6 actor isolation and the current nil-queue CoreBluetooth delegate assumption. Preserve stable source IDs and existing history.

If both the standard and vendor channels report HR, select the verified measurement stream for this adapter and prevent duplicate ingestion. Do not assume standard `2A37` values are fresh solely because they arrive recently; validate behavior against on-finger/off-finger operation.

### Step 3 — Correct readiness and timeout semantics

Separate:

- connection established;
- subscriptions enabled;
- protocol initialization complete;
- measuring;
- valid measurement received;
- measurement rejected or timed out.

For standard HR, readiness should initially count HR only. Preserve observed metrics when late discovery callbacks arrive. Track discovered/subscribed capability separately from observed measurement evidence.

Use messages tied to evidence, for example:

- “Connected; waiting for ring measurement.”
- “Starting heart-rate measurement…”
- “Ring rejected the measurement request.”
- “Receiving packets; readings rejected: sensor reports no contact.”
- “No measurement packets received after starting measurement.”

Only show a ring-specific diagnosis after the adapter has established it. Before that, use neutral wording rather than asserting poor contact.

Apply a measurement-specific acquisition budget and a separate cadence-based freshness policy for continuous streams. A completed spot reading should retain its timestamp and become stale normally; it should not be treated as a broken continuous stream after 30 seconds.

### Step 4 — Make explicit Reconnect start a fresh session

Implement a deliberate reconnect path rather than changing every call to `connect`:

1. Mark a pending explicit reconnect for this peripheral and cancel its backoff, measurement requests, and watchdogs.
2. If connected/connecting, cancel the connection and wait for its terminal disconnect/failure callback.
3. Clear that peripheral's session, frame buffers, and discovery/subscription bookkeeping.
4. Reconnect once, rediscover, resubscribe, and rerun the verified initialization.
5. Prevent the normal automatic-backoff path from scheduling a duplicate connection.
6. Cancel the pending request if the source is paused, forgotten, or the radio becomes unavailable.

Use a connection-session identifier to invalidate delayed work. Scope cleanup to the target peripheral. A foreground refresh should not tear down a healthy measurement session or overwrite its observed streaming state.

## 6. Files to change during later implementation

| File | Proposed change |
| --- | --- |
| `Sources/Bluetooth/BluetoothManager.swift` | Diagnostic discovery, adapter routing, explicit reconnect, preserved observed state, accurate packet/value outcomes. |
| `Sources/Bluetooth/GATT.swift` | Verified vendor UUID constants while retaining existing standard-profile constants. |
| `Sources/Bluetooth/BluetoothDiscoveryState.swift` | Separate standard capability readiness from vendor channel readiness and initialized measurement state. Vendor control channels must not advertise measurements simply because they subscribed. |
| Proposed `BluetoothDiagnostics.swift` | Bounded session evidence and explicit export. |
| Proposed `R11MRingSession.swift` / `YCBTFrameCodec.swift` | Identified ring protocol and tested framing/decoding. |
| `Sources/Views/DevicesView.swift` | Direct measurement controls, diagnostic action, accurate status, readable recovery detail. |
| `Resources/Localizable.xcstrings` | Strings for the added states and controls. |
| `Tests/ImprovementTests.swift`, `Tests/ParsingTests.swift`, focused new tests | Readiness/reconnect regressions and verified protocol fixtures. |
| `README.md` | State verified model/firmware support; qualify claims that generic rings work through standard profiles. |

Do not alter HealthKit import, Oura integration, comparison algorithms, stable identities, or retention as part of this fix. No new Apple capability is indicated by the observed problem.

## 7. Acceptance tests

These are tests to implement/run later, not tests performed by this review.

| Case | Required result |
| --- | --- |
| Standard HR, no RR field | HR appears; HRV remains unavailable; readiness does not promise three metrics. |
| Synthetic standard frames `00 48`, `04 48`, `06 48` | Decode 72 BPM; preserve unknown-contact / off-body / contact-detected semantics respectively. Off-body does not enter history. |
| Notification received but invalid | Packet counter advances; no accepted value; specific rejection is visible. |
| No measurement notification | Distinct from parser rejection and command rejection. |
| Indicate-only vendor channel | Subscribes successfully; initialization waits for all required channels. |
| Only one vendor subscription succeeds | No measurement command sent prematurely; failed channel is identified. |
| Split frame / bad length / bad CRC | Reassembly works within bounds; malformed data produces no reading. |
| Matching name, different service topology | Vendor driver is not selected from the name. |
| Early valid frame followed by late discovery callback | Streaming evidence is preserved. |
| Reconnect on already-connected ring | Fresh app connection session and initialization occur exactly once. |
| Pause/disconnect during queued write or timeout | No stale write, timeout, or automatic reconnection restarts the paused session. |
| Direct R11M measurement | Trace shows identified ring, subscriptions, request, accepted response, valid measurement, and stored reading from the same Bluetooth source. |
| Off-finger / warmup / repeated measurement | No fabricated zero/stale values; repeat acquisition works after stopping and reconnecting. |
| Standard chest strap / standard pulse oximeter | Existing standards-based behavior remains functional. |

For the real-device test, keep other ring clients disconnected so the result is attributable to HeartSync's own direct BLE session. Verify HR first, then each additional metric separately. Confirm values are stored and displayed with their actual measurement timing.

Run the hosted Swift Testing suite on an installed iOS simulator for logic/regressions, then validate BLE on a physical iPhone with this R11M and its recorded firmware. A simulator build cannot validate the ring protocol.

## 8. Review limits and completion criterion

This review traced the current repository and exact screenshot messages, checked relevant parser/state tests, and researched direct BLE protocol references. It did not connect to the ring, execute an iOS build, run hardware tests, or modify application/test code. The installed app's exact build is not shown in the screenshots.

The missing evidence is the ring's full GATT inventory and a short direct-session trace. Until that identifies the protocol and shows a successful measurement exchange, the YCBT path remains a proposed compatibility fix, not a verified cure.

**The fix is complete when HeartSync itself starts or receives a valid measurement from this ring, saves it under the ring's Bluetooth source, recovers after reconnect, and accurately explains no-data/rejected-data states without relying on another health app.**

Additional platform references: [Apple — notifications/indications](https://developer.apple.com/documentation/CoreBluetooth/CBPeripheral/setNotifyValue(_:for:)), [Bluetooth SIG — Heart Rate Service](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/HRS_v1.0/out/en/index-en.html).

