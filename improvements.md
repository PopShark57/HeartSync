# HeartSync improvement audit

This is a fresh review of the current repository at commit
`3e46f364632261225337f840181130c947d50a53` (2026-09-02). It replaces the previous
resolved backlog rather than carrying old findings forward.

The review covered the application composition and lifecycle, canonical models, Bluetooth
parsers and connection flow, HealthKit authorization/sync/write-back, Oura OAuth/API/cache,
persistence and compaction, analysis/export, SwiftUI screens, `project.yml`, shipped
resources, and all test sources.

Priority means:

- **P0:** address before trusting or expanding the affected measurement path.
- **P1:** important reliability, data-integrity, or user-trust work.
- **P2:** product-quality and maintainability work after the correctness items.

## Recommended order

1. Correct PLX status handling, HRV window timing, derived-value replacement, and sensor
   technology claims.
2. Make persistence transactional and scalable, then preserve compaction provenance.
3. Make startup, HealthKit sync, deletion, and retention outcomes truthful and recoverable.
4. Reconcile cloud deletions and HealthKit source identity.
5. Finish the product-quality items and establish automated/device validation gates.

---

## P0 — Measurement and analysis correctness

### 1. Interpret both PLX status fields before accepting pulse-oximeter values

**Current behavior**

`PulseOximeterMeasurement.isDeviceReportedInvalid` only evaluates
`deviceAndSensorStatus`. It ignores `measurementStatus`, including the standard
“measurement unavailable,” “questionable measurement,” and “invalid measurement” bits.
Its device-status mask also omits bit 15, “sensor disconnected,” and the nearby bit labels
are shifted relative to the specification. `BluetoothManager.handlePulseOximeter` treats
the resulting Boolean as the complete quality decision and then admits both SpO2 and pulse.
The parser retains Pulse Amplitude Index, but the manager discards it.

The Bluetooth SIG defines the two status fields separately and assigns device/sensor status
bits 0 through 15, including bit 15 for a disconnected sensor. See the official
[Pulse Oximeter Service specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/PLXS_v1.0.1/out/en/index-en.html).

**Improve it**

- Replace the Boolean with an explicit quality result such as `accepted`, `provisional`,
  `questionable`, and `invalid`, derived from both status fields.
- Use named masks that match the specification. Reject unavailable/invalid/disconnected and
  device-fault states. Deliberately define how ongoing, early-estimate, calibration,
  questionable, and fully-qualified states affect continuous versus spot-check readings.
- Either retain quality metadata with the reading or show it as a live caveat. Surface Pulse
  Amplitude Index when present because it can explain low-perfusion disagreement.
- Parse PLX Features if the app needs to distinguish unsupported status bits from supported
  but clear bits.

**Done when**

Table-driven tests cover every meaningful bit in both fields, especially measurement-status
bits 13–15 and device-status bit 15, and manager-level tests prove rejected frames cannot
reach `HealthStore` or HealthKit write-back.

### 2. Give Bluetooth-derived HRV its real observation interval

**Current behavior**

`HRVAccumulator.emitIfReady` can emit after only 20 clean intervals and has no minimum
elapsed-duration requirement. `BluetoothManager` nevertheless stamps every emitted RMSSD
and SDNN reading as `now - 300 seconds ... now`. A packet containing 20 intervals can
therefore produce a value almost immediately whose midpoint is placed roughly 2.5 minutes
before the actual capture. That can create or remove overlap with another device in the
comparison engine. It also presents SDNN as a five-minute result even though the source
comment correctly says SDNN needs a longer window to stabilize.

All intervals in one notification are currently assigned the same receipt time, so even
`bufferedDuration` understates packet-internal elapsed time while the stored `Reading`
overstates it.

**Improve it**

- Track the real start and end of the accumulated interval sequence. Reconstruct interval
  times backward from receipt time when a notification contains multiple R–R values, or at
  minimum use the first notification time instead of a synthetic full-window start.
- Split readiness policy by metric. RMSSD may be emitted on a shorter validated capture;
  SDNN should require the intended duration or be explicitly named “short-term SDNN.”
- Store duration and quality facts needed to interpret an HRV result, rather than keeping
  them only in transient `BluetoothManager.hrvQuality` state.

**Done when**

Tests cover a first packet containing many R–R intervals, a 20-second capture, a complete
five-minute capture, reconnect/reset behavior, and comparison-window placement. No reading
claims time the accumulator did not observe.

### 3. Upsert revisable estimates and reconcile estimates that are no longer eligible

**Current behavior**

`AppModel.recomputeDerivedMetrics` sends generated values through
`HealthStore.append(contentsOf:)`. The VO2 max estimate has one stable ID per source/day and
the blood-pressure trend has one stable ID per five-minute slot. Append semantics keep the
first value and reject later values with the same ID, although the blood-pressure comment
says recomputation “updates one reading.” A new resting-heart-rate input or newer consensus
inside the same slot therefore cannot revise the displayed estimate.

Turning an estimator off, removing its input, or letting a cuff calibration expire also
stops future production without removing or clearly invalidating already stored estimates.

**Improve it**

- Route model-generated values through upsert semantics, separate from append-only measured
  sensor values.
- Add a reconciliation step that removes or marks current estimates stale when their feature
  is disabled, their measured input disappears, or their calibration expires.
- Keep estimated readings outside device-disagreement claims and HealthKit write-back.

**Done when**

Tests prove that a same-day VO2 estimate and same-slot blood-pressure estimate update, an
identical recomputation is a no-op, and disabling/expiry produces the documented UI and
storage behavior.

### 4. Stop inferring PPG versus ECG from Body Sensor Location

**Current behavior**

`BodySensorLocation.isOptical` defines every location except chest as optical and labels
chest as electrical. Devices and pairwise analysis then state that the sensors use PPG or
ECG and explain disagreement on that basis.

The Bluetooth characteristic reports the intended **location** of the heart-rate
measurement, not the sensing technology. The official
[Heart Rate Service specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/HRS_v1.0/out/en/index-en.html)
does not make a technology claim. Placement is useful evidence; treating it as proof of
PPG/ECG is not.

**Improve it**

- Display only reported placement by default: chest, wrist, finger, and so on.
- Remove `isOptical`, `sensingTechnology`, and the pairwise assertion that different physical
  signals are known from location alone.
- If technology is valuable, add a separate optional field populated by explicit device
  metadata, a verified model registry, or a user-confirmed setting. Unknown must stay
  unknown.
- Pairwise guidance may say that different placements can contribute to disagreement without
  deciding which technology or device is correct.

**Done when**

No UI or accessibility text claims PPG/ECG from characteristic `0x2A38`, and tests preserve
the distinction between location, known technology, and unknown technology.

---

## P1 — Data integrity, reliability, and user trust

### 5. Replace the whole-file store with one transactional, indexed persistence boundary

**Current behavior**

`HealthStore` retains all readings in one main-actor array. Every save encodes and atomically
rewrites all readings, then independently rewrites all sources. The 30-second maximum save
latency means a continuous stream repeatedly serializes the whole archive. Because
compaction cannot begin before 14 days, a single 1 Hz source can accumulate about 1.2 million
raw rows before the first eligible compaction pass.

Each file is individually crash-safe, but the pair is not transactional. A successful
`readings.json` write followed by a failed `sources.json` write leaves a mixed-generation
store. Time-bounded queries also still scan every reading of a metric—or the entire array
for `readings(in:)`—instead of seeking to the requested dates.

**Improve it**

- Move readings and sources behind the existing `HealthStore` API into a transactional local
  database with indexes for stable ID, metric, source, and time. SQLite or SwiftData can work;
  the choice matters less than measured behavior and a tested migration.
- Append/upsert/delete incrementally, query only requested ranges, and page large result sets.
- Commit source metadata and its readings in the same transaction.
- Preserve stable IDs, protection/backup requirements, rejection rules, Oura revision
  semantics, and HealthKit deletion behavior.
- If a database migration is deferred, use generation-stamped paired archives and chunk
  readings by bounded time periods as an interim measure.

**Done when**

A migration test opens an existing version-1 archive without loss, injected failures cannot
produce mixed generations, and performance tests exercise at least the 14-day 1 Hz case on a
representative iPhone without blocking UI work.

### 6. Make archive and settings failures visible and recoverable

**Current behavior**

If the readings archive is unreadable, `AppModel.start` correctly avoids overwriting it and
does not attach transports—but `RootView` still shows the normal tabs and empty states. A
user can reasonably interpret “no devices/readings” as an empty account rather than a
protected or temporarily unavailable archive. If settings cannot load, the app continues
with defaults while silently refusing to save later edits.

Corrupt files are preserved aside, which is good, but there is no recovery UI and repeated
corruptions reuse one `.corrupt` sibling.

**Improve it**

- Add an observable startup state: loading, ready, temporarily unavailable, and recovered
  from corrupt data.
- Put a blocking but non-destructive recovery view or persistent banner above the tabs with
  Retry, an explanation, and a support/export path where possible.
- Make Settings read-only or clearly warn that changes are not durable until its archive is
  available.
- Keep timestamped corrupt backups and expose enough diagnostic metadata to identify which
  collection failed without showing health values.

**Done when**

UI tests cover unreadable readings, unreadable sources, unreadable settings, corruption, a
successful retry after first unlock, and confirmation that no live transport starts early.

### 7. Report HealthKit sync as complete, partial, or failed

**Current behavior**

`HealthKitManager.syncAll` discards each mapping’s Boolean outcome and always sets
`lastSyncedAt` after the loop. A request can therefore fail for every type while Devices says
it synced just now. Reaching the per-run object budget also returns `true` even though a
backlog remains. Errors are logged but not summarized for the user.

**Improve it**

- Aggregate per-type results into complete, partial, failed, permission-unknown, and
  budget-deferred outcomes.
- Track “last successful complete sync” separately from “last attempt.”
- Surface a concise status in Devices, with per-type detail only when useful and without
  falsely claiming that HealthKit revealed read authorization.
- Schedule or invite continuation when the object budget is reached.

**Done when**

Pure aggregation tests cover all-success, mixed permission/failure, all-failed, and budget
exhaustion cases, and UI copy never equates completion of the authorization sheet with data
access.

### 8. Preserve compaction provenance instead of reporting aggregates as raw samples

**Current behavior**

Compaction deliberately discards raw count and within-window spread, then stores the median
as an ordinary `Reading`. On later analysis, `ComparisonEngine.aggregate` sees that one row
and reports `sampleCount = 1` and `standardDeviation = 0`. The pairwise UI and CSV therefore
describe an old compacted aggregate as one raw sample with zero spread, and summary totals
include it in “raw sample” counts. Unknown evidence has become false precision.

**Improve it**

- Add backward-compatible aggregation metadata such as `compacted`, original sample count,
  and optional sufficient statistics where they can be preserved honestly.
- When old archives cannot supply count/spread, represent those fields as unknown—not one
  and zero—and label UI/export rows as compacted window medians.
- Decide whether corrections and upstream deletions remain impossible after compaction, then
  state that limitation next to exported historical evidence.

**Done when**

Round-trip and export tests distinguish raw singleton readings from compacted medians and no
field named “raw samples” includes an unknown compacted count.

### 9. Make retention shortening and “delete all” semantics explicit

**Current behavior**

Choosing a shorter retention period immediately mutates the store and calls `prune()` with
no confirmation or preview, even though deletion/compaction is irreversible. “Delete all
readings” clears `HealthStore` but leaves the Oura dashboard cache and HealthKit anchors.
Later Oura sync can repopulate cached cloud values, while cleared HealthKit history may not
return because its anchors still advance. One action therefore has inconsistent behavior by
transport.

**Improve it**

- Stage retention changes. Before shortening, show the cutoff and number of readings that
  will be deleted or compacted, then require confirmation.
- Split destructive intent into clear actions, for example “Clear local cache; data may
  resync” and “Forget imported history,” with source-specific consequences.
- Coordinate Oura snapshot removal, HealthKit anchor reset/retention choice, derived-value
  cleanup, and the readings transaction. Do not imply Apple Health data is deleted.
- Report whether the deletion was durably saved; offer an export before irreversible work.

**Done when**

Tests cover each transport before/after relaunch and sync, cancellation leaves all state
unchanged, and confirmation text predicts exactly what returns.

### 10. Reconcile records deleted or withdrawn by Oura

**Current behavior**

Successful windowed Oura responses are always merged into the cached collection. Corrected
documents with the same ID replace prior copies, but a record absent from a later complete
response remains cached until it ages out. Its normalized `Reading` also remains in
`HealthStore`; there is no Oura deletion reconciliation path. This can retain withdrawn or
deleted upstream health data and continue using it in comparisons.

**Improve it**

- On a successful, non-truncated full-window response, reconcile IDs inside that endpoint’s
  fetched window and remove missing cached documents plus their normalized readings.
- Preserve merge-only behavior for incremental, partial, truncated, permission-failed, and
  transport-failed responses; absence there is not evidence of deletion.
- Define generated reading IDs per endpoint in one place so reconciliation cannot drift from
  mapping.
- Treat a failed Oura snapshot write as a durability warning rather than announcing an
  unqualified successful sync.

**Done when**

Tests cover upstream deletion, truncated full responses, failed endpoints, incremental
overlap, cache-write failure, and relaunch consistency.

### 11. Resolve HealthKit writer identity without silently merging physical devices

**Current behavior**

HealthKit readings use `hk.<source bundle identifier>` as source identity and keep device
model as mutable metadata. Multiple devices writing through the same app—or a replacement
device—can therefore be merged into one comparison source. The reverse problem also exists:
one physical Oura Ring can appear through both Oura Cloud and HealthKit and be compared as if
the two paths were independent instruments.

Changing IDs casually would split existing history, so this needs a migration rather than a
string tweak.

**Improve it**

- First relabel the current entity honestly as a HealthKit writer when physical device
  identity is unknown.
- Detect multiple device descriptors behind one writer and warn or split future data using a
  documented, stable composite identity only where HealthKit provides sufficient evidence.
- Add source relationships such as “same upstream device, different transport” so pairwise
  analysis can warn about non-independent comparisons.
- Design and test archive migration/aliasing before changing the shipped ID formula.

**Done when**

Fixtures cover two models from one writer, one model changing over time, one physical source
through two transports, missing device metadata, and migration of existing source IDs.

### 12. Stop requesting and storing biological sex unless a feature actually uses it

**Current behavior**

The app requests biological sex from HealthKit, imports it into `UserProfile`, and exposes a
profile picker. No estimator or analysis reads `profile.sex`; the VO2 max estimator uses age
only. The comment saying VO2 max needs both age and sex does not match the implementation.

**Improve it**

- Remove biological sex from HealthKit read types, settings, and new archives unless a
  reviewed feature has a concrete need for it.
- Keep backward decoding compatibility so existing settings archives still load.
- If a future model genuinely requires it, explain the purpose before collection and make
  the value optional without degrading unrelated functionality.

**Done when**

HealthKit authorization tests no longer expect that characteristic, old settings decode,
and no UI asks for unused sensitive data.

### 13. Complete Bluetooth discovery with an evidence-based connection result

**Current behavior**

Each successful `didDiscoverCharacteristicsFor` callback can mark the peripheral as
`.streaming([])` even if no supported measurement characteristic was found or subscribed.
Discovery errors and value-update errors return silently; notification-subscription errors
are logged but do not make the visible connection state actionable. “Connected” can thus
mean connected at the link layer but incapable of producing a reading.

**Improve it**

- Track outstanding service discovery and supported characteristic/subscription outcomes.
- Distinguish link connected, discovering, ready for specific metrics, unsupported service,
  subscription failed, and stream stalled.
- Put concise recovery steps in Devices and preserve error detail for diagnostics.

**Done when**

State-machine tests cover partial services, no usable characteristic, one service failing,
subscription failure, value errors, disconnect/reconnect, and a normal multi-service device.

### 2.8 The Oura heart-rate chart re-derived its whole sample set once per plotted point

**Status: Fixed.** `OuraHeartRateSeries` parses the cached collection once per update and
supplies the plotted points, the area baseline, the range label, and the thinning note as
stored properties. `OuraSnapshot.latestHeartRate` likewise parses each timestamp once
instead of inside a comparator.

**High.** `OuraHeartRateSection` derived its chart points in a computed property that
`compactMap`ped, parsed, and sorted the entire cached heart-rate collection, and read it
five times per body pass. One of those reads was the area mark's baseline, evaluated inside
the `Chart` content closure — which Swift Charts runs once per plotted sample.

A fortnight of five-minute samples is roughly 4,000 cached records and 288 inside the
24-hour window, so drawing the card cost about 1.2 million `ISO8601DateFormatter` parses,
288 sorts of a 4,000-element array, and 1.2 million string interpolations for the point ids
— all on the main thread, repeated on every body pass. The Oura tab froze on entry; a
denser cache (Oura can sample once a minute) froze it for minutes. Replacing the section's
`LazyVStack` with an eager `VStack` had only moved the freeze from mid-scroll to tab entry.

---

## P2 — Product quality and confidence

### 14. Add evidence grades and uncertainty to pairwise conclusions

The current five-window minimum is a good guardrail, but five windows can represent very
different evidence depending on time span, per-window samples, missingness, compaction, and
signal quality. Add an evidence grade based on paired-window count, analyzed span, overlap,
known versus unknown sample depth, and quality caveats. Add confidence intervals for mean
bias and limits of agreement when the sample size supports them. Keep the existing fixed
clinical/product tolerances and never let a confidence display imply that either device is a
reference standard.

Also warn when both sources likely represent the same physical device through different
transports, because agreement then is not independent corroboration.

### 15. Decide what Oura onboarding should be for a distributable app

The current setup asks every user to create an Oura developer application and paste a client
ID. That is workable for a personal/developer build but is a severe onboarding wall for a
consumer app. Choose explicitly between:

- a personal/developer tool, with setup presented clearly before the Oura tab;
- a distributable app with a registered first-party client identity and an OAuth design
  reviewed against Oura’s current production requirements; or
- making Oura an advanced optional integration while the core Bluetooth/HealthKit flow is
  immediately useful.

Do not embed a client secret in the app or weaken the existing state/callback validation.

### 16. Establish validation gates for behavior that compilation cannot prove

- Run the full hosted Swift Testing suite on an installed iOS simulator in CI for every PR.
- Add focused UI tests for startup recovery, empty/loading/error states, source pause/delete,
  retention confirmation, comparison evidence, Oura partial failure, and accessibility text.
- Add a physical-iPhone release checklist for real BLE devices, HealthKit read/write and
  deletion, background delivery, locked-screen collection, state restoration, OAuth return,
  file protection, and large-history responsiveness.
- Add a String Catalog and at least one pseudo-localization pass. Many strings use
  `String(localized:)`, but most view copy is still inline English and there is no shipped
  localization catalog.
- Run VoiceOver, Dynamic Type, Reduce Motion, high-contrast, and landscape/iPad checks on the
  five primary tabs. Preserve explicit unavailable/insufficient/estimated states while
  adapting layout.

---

## Validation performed for this audit

- `xcodebuild -list` confirmed one app target, one hosted unit-test target, and the shared
  `HeartSyncChecker` scheme.
- `xcodebuild -showdestinations` found a connected physical iPhone but no installed concrete
  iOS Simulator runtime.
- Unsigned Debug compilation for `generic/platform=iOS Simulator` succeeded.
- `build-for-testing` for the same generic destination succeeded, so the app and test bundle
  compile together.
- The current test sources contain 229 `@Test` declarations across 29 `@Suite` declarations.

No test suite was executed, no app UI was launched, and no Bluetooth, HealthKit, Oura,
background, locked-device, or physical-device behavior was validated. Build success is not
evidence that those runtime paths work.

## Existing strengths to preserve while implementing these changes

- One canonical `Reading`/`DataSource` model and one ingestion seam.
- Stable IDs, idempotent HealthKit/Bluetooth append, and revisable Oura upsert semantics.
- Explicit measured/derived/estimated provenance and exclusion of estimates from device
  disagreement and HealthKit write-back.
- Epoch-aligned median comparison windows, canonical A-minus-B ordering, and full-data
  statistics/export independent of chart thinning.
- Per-endpoint Oura failure isolation, credential handling in device-only Keychain, and
  token-free cache persistence.
- Refusal to overwrite an unreadable protected archive and preservation of corrupt bytes.
- XcodeGen as the target/build/capability source of truth.

These are architectural guardrails, not obstacles. The improvements above should extend
them rather than create parallel stores, alternate analysis logic, or transport parsing in
views.
