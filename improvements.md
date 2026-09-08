# HeartSync improvement roadmap

## Current follow-up review (2026-09-08)

Reviewed `main` at commit
[`ca8f07a7993572722a0d09967f8a8c416acb4389`](https://github.com/PopShark57/HeartSync/commit/ca8f07a7993572722a0d09967f8a8c416acb4389),
including the native watchOS companion and complications.

**Implementation status (2026-09-08): items 17–25 have since been implemented.** Items
17–20, 24 and 25 are complete against their “Done when” paragraphs. Items 21, 22 and 23
are partially complete; each section below records exactly what was deferred and why. The
“Observed behavior” paragraphs describe the code as reviewed, before those changes.

The older audit and its implementation notes are retained below as history. Its original
“Current behavior” paragraphs describe the earlier checkout, not the app reviewed here.
Existing SQLite storage, pairwise evidence grades, source-relationship warnings, recovery
screens, CI, and watch features were extended rather than rebuilt.

**Validation limits for that implementation work.** It was verified by
`xcodebuild build-for-testing` for the iOS scheme and a watchOS Simulator build of the
watch app, plus 118 tests executed against the real source files through a scratch SwiftPM
harness (no iOS simulator runtime is installed on the machine used). The tests have **not**
been executed in the real hosted bundle; CI is the first place that happens. No physical
device run, no profiling, and no on-device latency or memory measurement was performed, so
every remaining performance and device claim in item 21 and item 25 is still unvalidated.

This is a source review, not an on-device bug reproduction or a completed release audit.
Each item distinguishes observed code behavior from a product proposal or performance risk.

### Priorities and suggested sequence

| Item | Priority | Next improvement | Basis | Status |
| --- | --- | --- | --- | --- |
| 17 | P1 | Distinguish database query failures from empty results | Observed error handling | Done |
| 18 | P1 | Key chart series by stable source ID | Observed chart identity issue | Done |
| 19 | P1 | Carry compaction semantics into metric summaries and full-history exports | Remaining presentation/export gap | Done |
| 20 | P1 | Qualify pairs by actual measurement timing and show gaps honestly | Analysis refinement | Done |
| 21 | P1 | Keep large queries, analysis, and exports responsive | Code-supported performance risk; measure on device | Partial — snapshots and export moved off the render path; database work still on the main actor and no device budgets measured |
| 22 | P2 | Add saved comparison sessions and custom date ranges | Product proposal | Partial — exact periods, saved sessions and revisit disclosure done; no guided capture screen |
| 23 | P2 | Add comparison-only source selection and editable source relationships | Product proposal | Partial — comparison-only selection and same-device disclosure done; relationships remain read-only |
| 24 | P2 | Keep range controls available in the empty Compare screen | Observed navigation dead end | Done |
| 25 | P1 | Exercise the watch workout lifecycle with deterministic tests | Validation gap | Done (deterministic suite); physical-device recovery and save still unvalidated |

**P1** addresses correctness, reliability, or release confidence. **P2** improves product
usability after those foundations.

Start with 17–19 and the small fix in 24. Define timing semantics in 20 before adding
sessions in 22. Profile 21 while extending source selection in 23. Complete 25 before
making a release claim about workout recovery or save reliability.

### 17. Surface query failures after startup instead of displaying empty history

**Observed behavior**

[HealthStore.swift](Sources/Store/HealthStore.swift) uses `try?` and empty/zero/nil fallbacks
in `readings`, range queries, `readingsPage`, `readingCount`, and `latest`.
[HealthDatabase.swift](Sources/Store/HealthDatabase.swift) can throw while querying or
decoding rows. A failure after a successful startup can therefore look like no readings,
no overlap, or an empty export. The existing startup recovery work does not distinguish
these later query failures.

**Improve it**

- Return an explicit query outcome through the store/snapshot boundary and provide a
  retryable “History temporarily unavailable” state.
- Keep a previous successful snapshot visible only with an explicit stale/error label.
  Do not turn a failed refresh into a new agreement conclusion.
- Fail an export visibly if its input query fails; do not successfully share a header-only
  file that appears to represent an empty history.
- Preserve the existing database and startup protections; a read error must not trigger
  automatic deletion, reset, or reimport.

**Done when**

Injected query/decode failures after successful startup produce an actionable error in
Now, Compare, detail, and export flows. A truly empty database still uses the normal empty
state, and retry restores the successful result without changing stored readings.

### 18. Use stable source IDs for chart series, colors, and selection

**Observed behavior**

`MetricDetailSnapshot` in
[MetricDetailSnapshot.swift](Sources/Views/MetricDetailSnapshot.swift) builds its style
domain from `displayName`. `ChartPoint` carries `sourceName`, and
[MetricDetailView.swift](Sources/Views/MetricDetailView.swift) uses that name as both the
`LineMark` series key and foreground-style key. Two distinct sources with the same name
therefore share a chart grouping key, even though the store and comparison engine retain
different IDs. Renaming is a label change but currently also changes the chart key.

**Improve it**

- Carry `sourceID` through chart projections and key series, colors, filters, and selections
  by that ID. Keep names as display text only.
- Disambiguate duplicate visible names with transport/model or a short identifier suffix.
- Add shape or line-style distinctions alongside color, including in accessible legends.

**Done when**

A fixture with two same-named sources produces two independent series and distinguishable
legend entries. Renaming either source preserves its history, color assignment, selected
data, and pairwise results. Verify the chart on screen as well as its projection.

### 19. Make every historical summary and export honest about compaction

**Observed behavior**

The pairwise engine/export already preserve compacted counts and unknown spread. However,
`MetricDetailSnapshot.perSourceStats` still averages stored row values, uses their minimum
and maximum, and reports `samples.count`.
[MetricDetailRows.swift](Sources/Views/MetricDetailRows.swift) labels these as mean, Low,
High, and Samples without a compaction qualification. A mixture of raw rows and window
medians is not the original raw distribution.

`HealthStore.exportCSV()` labels raw versus compacted rows, but omits original count/spread,
measurement-quality fields, explicit units, and source descriptions. It is the export
offered before retention shortening.

**Improve it**

- Define the per-device summary explicitly: for example, consistently summarize comparable
  window medians and label the count as windows, with known original sample counts separate.
- Distinguish stored-window extrema from original raw minima/maxima. Do not reconstruct a
  raw mean from medians, even when their original counts are known.
- Reuse the pairwise conventions for raw/compacted/unknown evidence in summary text and
  VoiceOver labels.
- Extend the full-history export with a documented schema, units, source metadata, and
  available `ReadingMetadata`, including original sample count/spread and quality facts.
  Keep unknown values empty or explicitly unknown and preserve locale-independent numbers.
- Describe that export's limits accurately; it is not a restorable backup unless a separate,
  validated import/restore workflow exists.

**Done when**

Raw-only, compacted-only, mixed, and legacy-unknown fixtures have unambiguous summaries and
exports. No ordinary row count is presented as the number of original measurements, and no
discarded raw minimum, maximum, or mean is implied to remain available.

### 20. Show whether paired readings actually describe the same time

**Observed behavior**

[ComparisonEngine.swift](Sources/Analysis/ComparisonEngine.swift) assigns each reading to
an epoch-aligned bucket using its midpoint and pairs sources that occupy that bucket.
The aggregate retains value/count/spread/quality counts, but not the contributing time span
or separation between the sources' observations.

Consequently, two instantaneous heart-rate samples almost a minute apart can be paired,
while samples two seconds apart across a minute boundary are not. The existing overlap
percentage measures shared occupied buckets, not continuous simultaneous coverage.
The metric-detail chart also connects successive source points without an explicit gap
segment key.

**Improve it**

- Preserve contributing timestamps or observation intervals in the analysis projection.
  Show per-pair timing separation, contributing duration, and sparse coverage.
- Define a metric-appropriate timing policy for point samples versus interval summaries.
  Mark or exclude temporally weak pairs before counting them toward a supported conclusion.
  Keep the existing window method available and document any changed pairing semantics.
- Treat unknown duration as unknown. Do not automatically shift timestamps to improve
  agreement or treat an overnight summary as a simultaneous spot reading.
- Break chart lines across meaningful missing-data gaps. Keep isolated observations visible
  as points; drawing a connecting curve must not imply uninterrupted measurement.
- Add timing/coverage facts to the selected-window card and export so a user can investigate
  an individual disagreement instead of guessing from the line shapes.

**Done when**

Fixtures cover near/far samples within one bucket, close samples across a boundary,
bursty delivery, long interval summaries, and sparse sources. Charts, evidence counts, and
exports use the documented timing policy. Raw timestamps and canonical A-minus-B ordering
remain unchanged.

### 21. Move expensive history work out of synchronous view rendering

**Observed behavior and risk**

The SQLite migration is already implemented. Its remaining performance risk is where work
runs: `HealthDatabase` is called through the main-actor `HealthStore`, and
`CompareView`/`MetricDetailView` construct full-range analysis snapshots in `body`.
Reading rows also decodes their JSON payloads. Chart thinning does not reduce this input
query and analysis cost.

`RetentionConfirmationView` constructs `ShareLink(item: model.store.exportCSV())` while
rendering; `exportCSV()` materializes all readings and one complete CSV string.
The existing [device workload](PerformanceTests/HealthStorePerformanceTests.swift) exercises
insertion and a one-day indexed query, but does not measure these complete UI/export flows.
This review did not measure a freeze or a device latency.

**Improve it**

- Load and compute immutable snapshots asynchronously, keyed by data generation, selected
  sources, metric, and a fixed range. Cancel superseded work and reject late results.
- Give database access an explicit serialized execution boundary if profiling warrants it;
  do not share the existing SQLite handle across arbitrary detached tasks.
- Prepare exports only after the user requests them, page through a consistent database
  snapshot into a temporary file, and expose progress, cancellation, and failures.
- Extend the existing representative-device workload to two or more sources, month-range
  comparison, range changes during ingestion, and opening the retention/export flow.
  Record query/analysis duration, peak memory, and UI responsiveness with explicit budgets.

**Done when**

Recorded device measurements meet the chosen budgets; scrolling, cancellation, and range
selection remain responsive during import/export. Older async results cannot replace a
newer selection. Statistics still use the full eligible data, independently of chart thinning.

### 22. Add repeatable comparison sessions with exact dates and context

**Product proposal**

The comparison screens expose rolling `TimeRange` presets and already support rich pairwise
plots and exports. Add a way to revisit the same walk, resting capture, or other selected
period after cloud/HealthKit data arrives, rather than having the analyzed range move with
the current time.

**Improve it**

- Start with custom start/end dates and a saved session containing source IDs, metric,
  timing policy, optional title, and user-entered context such as rest/walk/run.
- Offer a guided capture screen with source readiness, measurement age, paired-window
  progress, and missing-data explanations. Completion must still obey the evidence rules.
- Keep context labels explicitly user-entered until actual workout metadata is supported.
  If workout selection is later added, make HealthKit scope and mapping changes deliberate.
- Reuse HealthKit as the watch measurement ingestion path. Opening a comparison session
  must not silently start another workout or duplicate samples over WatchConnectivity.
- On revisit, disclose whether results include data imported or corrected since the previous
  view; saved session settings should not be mistaken for an immutable exported result.

**Done when**

A session reopens with identical time boundaries and source selection after relaunch.
Late imports, missing/removed sources, time-zone changes, and insufficient evidence have
explicit behavior. Starting a session alone writes no workout to Apple Health.

### 23. Let users select comparison sources without pausing collection

**Observed behavior and product proposal**

The store already has source enablement and relationship metadata. Bluetooth Pause in
[DevicesView.swift](Sources/Views/DevicesView.swift) also disconnects the peripheral, while
comparison queries default to enabled sources. There is no independent source selection
control in the reviewed comparison screens. The existing same-upstream warning appears in
pairwise detail, but the Compare overview does not distinguish those pairs from independent
device pairs.

**Improve it**

- Add comparison-only source selection, separate from collection enablement. Hiding a noisy
  ring from one comparison must not disconnect it or delete its data.
- Allow clear aliases for every transport and reversible user-confirmed relationships such
  as “same device through another app.” Preserve stable IDs and original writer metadata.
- Reuse `upstreamDeviceRelationshipID` and existing relationship warnings. Offer a
  device-comparison view that excludes confirmed same-device transport pairs, with a
  separate way to inspect those paths for sync troubleshooting.
- Surface the relationship at the overview/pair-list level as well as in detail/export.
  Unknown identity must remain unknown; do not automatically merge similar names/models.

**Done when**

Selection changes only the requested comparison, with history and collection preserved.
Two confirmed paths from one ring remain separately inspectable but do not inflate the
independent-device count. Relationship edits can be undone without ID migration or data loss.

### 24. Keep Compare's range picker visible when there is nothing to compare

**Observed behavior**

In [CompareView.swift](Sources/Views/CompareView.swift), `snapshot.metrics.isEmpty` replaces
the entire list with an empty state. The range picker exists only in the nonempty branch,
yet the empty-state text tells the user to widen the range. If a narrow range contains no
comparable metrics, the required control disappears.

**Improve it**

Keep the range control outside the conditional result content. Offer a direct wider-range
action and, where useful, distinguish no stored data, one eligible source, and no data in
this range. Preserve the existing pair-specific no-overlap state.

**Done when**

With two sources that have readings two days ago and none in the last 24 hours, a user can
switch from Day to Week directly on Compare and see the available comparison. Narrowing back does not hide the
control. A truly empty install also remains navigable.

### 25. Test the watch workout lifecycle beyond payloads and compilation

**Observed coverage gap**

[WatchWorkoutManager.swift](WatchApp/Sources/WatchWorkoutManager.swift) has asynchronous
authorization, collection, pause/resume, stop/review, save retry, discard, recovery, and
delegate-event paths. Existing watch-related tests cover display payloads, projections,
freshness, and complications. [CI](.github/workflows/ios.yml) builds the watch companion and
runs the iOS-hosted suites; there is no dedicated workout-manager lifecycle test suite in
the reviewed tree. This is a coverage recommendation, not a claim that recovery is broken.

**Improve it**

- Introduce a small testable event/transition seam or narrowly injected HealthKit adapter;
  avoid a broad dependency-injection rewrite.
- Cover duplicate Start/Stop taps, delayed callbacks from an old session, interrupted
  collection, save failure followed by retry, discard, and recovered running/paused states.
- Check that a stopped workout remains reviewable, that repeated events cannot save twice,
  and that a late callback cannot revive a discarded or replaced session.
- Extend the existing watch device checklist with interruption by another workout app,
  relaunch/recovery, locked-watch save, and delayed iPhone HealthKit arrival. Record results
  on a signed build separately from deterministic tests.

**Done when**

The lifecycle regression suite runs in CI through an appropriate target. Physical-device
results separately confirm recovery and save behavior, including one saved workout and
idempotent iPhone sample import. Build-only evidence remains labeled as compilation.

### Validation for this follow-up

- Read the existing audit, repository guide, project configuration, and relevant
  store/query, comparison, chart, source, export, HealthKit, watch-workout, and test code
  at the commit above.
- Cross-checked recommendations against already implemented features; items 19, 21, 23,
  and 25 explicitly extend prior work.
- This update changes only `improvements.md`. No Swift implementation, schema, signing,
  capabilities, or user health data was changed.
- No Xcode build, runtime test suite, live integration, or physical-device check was run
  for this documentation-only review. Each “Done when” paragraph is future acceptance
  criteria, not a claim of completed validation.

---

## Historical audit (2026-09-02; implementation notes 2026-09-05)

This is a fresh review of the current repository at commit
`3e46f364632261225337f840181130c947d50a53` (2026-09-02). It replaces the previous
resolved backlog rather than carrying old findings forward.

## Implementation status (2026-09-05)

All 16 numbered improvements below have been implemented in the current working tree. The
implementation includes transactional indexed SQLite storage and legacy migration,
measurement-quality and HRV interval corrections, estimate and cloud reconciliation,
truthful startup/HealthKit/Bluetooth states, compaction provenance, staged data controls,
source relationships, evidence grades and confidence intervals, advanced optional Oura
onboarding, a String Catalog, simulator CI, focused UI coverage, an isolated physical-device
performance workload, and `RELEASE_CHECKLIST.md`.

The historical **Current behavior** sections below remain as the evidence that motivated
each change. They do not describe the post-implementation code. Generic simulator
compilation verifies that the app and all test bundles build; it does not satisfy the
physical-device acceptance items. BLE, HealthKit, background/locked-device behavior, OAuth
return, file protection, migration scale, accessibility, and the fourteen-day workload must
still be exercised and recorded using `RELEASE_CHECKLIST.md` before a release claim is made.

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

## Implementation validation (2026-09-05)

- XcodeGen generation succeeds and exposes the app, hosted unit-test, UI-test, and isolated
  physical-device performance-test targets through the `HeartSyncChecker` and
  `HeartSyncCheckerPerformance` schemes.
- Generic iOS Simulator `build-for-testing` succeeds for the main scheme and the performance
  scheme, compiling the app and every test bundle together.
- A disposable host-side database smoke run opens WAL mode, commits a source/reading batch,
  proves an injected transaction rolls back, checkpoints, reopens, and reads the committed
  generation. This does not validate iOS file-protection behavior.
- Localization export succeeds and populates `Resources/Localizable.xcstrings` from the
  app's localized and SwiftUI string literals.
- The current test sources contain 268 Swift Testing `@Test` declarations across 38 suites,
  seven XCTest UI flows, and one isolated fourteen-day performance workload.
- `.github/workflows/ios.yml` generates the project, chooses an installed iPhone simulator,
  runs the complete main scheme on pushes and pull requests, and retains the `.xcresult`.

No local runtime suite was executed because this host has no installed concrete iOS
Simulator runtime. The connected physical iPhone was deliberately not used for automated
tests because installing a test build could replace the user's app and affect its local
health data. The release checklist remains the acceptance gate for all hardware and
signed-build behavior.

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
