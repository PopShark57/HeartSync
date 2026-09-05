# HeartSync

An iOS app that pulls heart-rate and related metrics from several wearables at once, shows
them side by side, and quantifies where they disagree.

## What it reads, and from where

Three transports, because these devices genuinely do not speak one protocol:

| Source | Transport | Why |
|---|---|---|
| Chest straps, generic rings, pulse oximeters | **Bluetooth LE** | They implement the standard GATT profiles, so they can be read directly and live. |
| Apple Watch | **HealthKit** | Apple Watch readings reach iPhone through HealthKit. The native companion also records live heart-rate workouts on the watch; it is not a BLE peripheral. |
| Oura Ring | **Oura Cloud API v2** | The ring's Bluetooth protocol is proprietary and undocumented. The Cloud API is the supported route. |

Bluetooth support covers the SIG-standard services:

- **Heart Rate (0x180D)** — heart rate, plus R–R intervals where the sensor reports them
- **Pulse Oximeter (0x1822)** — SpO₂ and pulse rate, continuous and spot-check
- **Health Thermometer (0x1809)** — body temperature
- **Battery (0x180F)** and **Device Information (0x180A)**

Metrics tracked: heart rate, resting heart rate, HRV (RMSSD and SDNN), SpO₂, respiratory
rate, body temperature, VO₂ max, and blood pressure.

## The comparison

Devices sample on their own schedules, so raw pairwise comparison would mostly measure
timing offsets. Instead readings are bucketed into epoch-aligned windows sized per metric,
reduced to a **median** per source per window (a mean would let one motion spike
manufacture a discrepancy), and then compared.

Pairs are summarised with **Bland–Altman** statistics — mean bias and 95% limits of
agreement — because none of these devices is a reference standard, and correlation would
happily call two devices equivalent while one reads 10 bpm high all day. The app
distinguishes a *consistent offset* (calibration difference) from a *scattered* one
(noise), and needs at least five overlapping windows before calling anything a
disagreement.

The pairwise analysis screen keeps the evidence behind that summary inspectable. It shows
the two aggregated timelines, a Bland–Altman difference-versus-mean plot, the number and
percentage of overlapping windows, the samples contributed by each source, and explicit
"collecting" or "no overlap" states when there is not enough evidence. A green agreement
result is never shown until at least five paired windows exist.

Each pair and time range can be exported from that screen as two local files: a CSV of the
paired, normalized windows and a plain-text methodology/statistics summary. Exports use UTC
timestamps, contain no Oura token or unrelated readings, and are handed to the standard iOS
share sheet.

Tolerances are per metric and reflect real measurement error: 5 bpm for heart rate, 2% for
SpO₂ (consumer oximeters are specified to roughly ±2% ARMS), 15 ms for HRV.

The "Flag disagreements at" setting controls how much detail Compare lists, never whether a
result is green. Raising it to "Major only" stops a notable pair from being written out in
full, but the pair is still counted as outside tolerance — choosing not to be told about a
gap is not the same as the devices agreeing.

Charts on the pair screen draw at most a few hundred points, always including the widest
differences, and say so when they are showing a subset. Statistics and exports always use
every paired window.

## Honest limitations

**Blood pressure cannot be measured optically by a ring or watch.** What the app offers is
a *trend index*: how far your heart rate and HRV have drifted from where they were when you
entered a real cuff reading. It is clamped to a narrow band, carries a wide interval that
widens as the calibration ages, expires after 30 days, and refuses to extrapolate more than
25 bpm from its anchor. It is not a blood pressure measurement. Real cuff readings arriving
through Health are shown separately, as measurements.

**VO₂ max estimates** use the Uth–Sørensen formula (`15.3 × HRmax/HRrest`). Its error is
10–15%, far wider than the gap between two real measurements, so estimates are labelled and
excluded from disagreement analysis.

**Oura's temperature stays on its own scale.** It is a deviation from your personal
baseline, not an absolute temperature. The Oura dashboard shows the deviation, but the
comparison engine never places it beside a thermometer's 36.8 °C reading.

**Oura's `average_hrv` maps to RMSSD, not SDNN.** Filing it under SDNN would place it beside
the Apple Watch's SDNN — a different measure — and the resulting gap would be pure artefact.

**SpO₂ scale conversion.** HealthKit stores oxygen saturation as a fraction (0.97) while the
Bluetooth spec uses whole percent (97). These are normalised on ingest.

## Data handling

HeartSync's local history stays on your devices; the paired watch receives a display snapshot.
There is no HeartSync account and no server. Oura authentication
opens `cloud.ouraring.com`; subsequent read-only requests go to `api.ouraring.com` using an
OAuth access token stored in the device-only keychain (never synced to iCloud). No Oura
client secret is embedded in the app. The iPhone's optional Bluetooth write-back is off by
default and only writes directly measured values. The watch separately records user-started
workouts in Apple Health; estimated values are never written there.

Readings and sources live in one indexed SQLite database under Application Support. Source
metadata and reading changes commit in the same transaction, and range queries seek by metric,
source, and time instead of decoding the whole history. A first launch after upgrade migrates
the previous version-1 JSON archives without changing stable IDs. Settings and the token-free
Oura cache remain small versioned JSON archives.

The database, its write-ahead log, and the remaining archives use file protection until the
first device unlock after boot and remain eligible for encrypted device backup; a temporarily
unreadable store is never treated as empty or overwritten. Readings older than 14 days are
irreversibly reduced to one median per source, metric, and comparison window. New compacted
rows retain their original sample count and within-window spread; older migrated compacted rows
show those facts as unknown. Individual samples and later corrections or upstream deletions for
a compacted window cannot be recovered.

### Oura OAuth setup

Oura is an **advanced optional integration for personal/developer builds**. The core Bluetooth
and Apple Health experience works without it. HeartSync does not currently ship a registered
first-party Oura client identity, so this setup intentionally asks each user who enables Oura
to create an OAuth application. A consumer distribution would need a separately reviewed
production client registration and onboarding design.

Personal access tokens were retired by Oura in December 2025. HeartSync uses Oura's
documented client-side OAuth flow so the app can remain serverless and no client secret has
to be shipped in the IPA. In [Oura API Applications](https://developer.ouraring.com/applications),
create an OAuth application and register this exact redirect URI:

```
com.heartsync.heartsyncchecker://oauth/oura
```

Paste the application's public Client ID into HeartSync, then choose **Continue with Oura**.
The client-side flow does not issue a refresh token, so Oura asks you to authorize again
when the access token expires (currently about 30 days).

### Oura dashboard

The dedicated Oura tab keeps a local, token-free cache of recent cloud records and presents:

- activity, readiness, sleep, stress, resilience, and contributor scores
- heart rate, resting heart rate, RMSSD, respiratory rate, SpO₂, breathing disturbances,
  temperature deviation, VO₂ max, cardiovascular age, and pulse-wave velocity
- sleep stages, overnight movement, activity classes, MET samples, workouts, sessions, and tags
- ring battery, charging state, model, finish, firmware, size, and setup date
- an inspectable OAuth permission and per-collection sync status area

Oura does not expose raw ring accelerometer samples through its public API. HeartSync's
movement ribbons use Oura-processed five-minute activity classes, 30-second sleep movement,
and session motion counts, and label them accordingly. Oura data is cloud-synced rather than
live; sleep and readiness may not update until the Oura app syncs the ring.

## Building

```bash
xcodegen generate
open HeartSyncChecker.xcodeproj
```

Requires Xcode 16+ (developed against Xcode 27 / Swift 6.4, strict concurrency enabled).
The generated project currently pins development team `7RLDYXQTNX`; change it only as a
deliberate deployment decision. A physical-device build also requires the App ID and
provisioning profile to carry both HealthKit and HealthKit Background Delivery capabilities.

**Bluetooth and HealthKit only work on a real device** — the simulator has no BLE radio and
no Health data.

## Apple Watch companion

HeartSync includes a native **watchOS 11+** app with two screens:

- **Dashboard:** latest readings from your iPhone, source names, measured/derived/estimated
  badges, timestamps, and comparison evidence. Tap a metric for the available sources and
  evidence details. Open HeartSync on iPhone to sync; Refresh requests an update when reachable.
- **Workout:** start Other, Walking, Running, or Cycling; view live heart rate and elapsed
  time; pause/resume; then review and save to Apple Health or discard. Workout recording works
  without a connected iPhone. It requires permission on the watch.

Watch faces also offer **HeartSync Measurement** and **HeartSync Workout** complications in
circular, rectangular, inline, and corner slots. Choose heart rate, resting heart rate, SpO₂,
RMSSD, SDNN, respiratory rate, or temperature for each measurement slot. Old readings are
explicitly labelled, estimates are excluded, and tapping opens the corresponding details.
The workout shortcut opens controls without starting a recording. Rectangular versions also
support the Smart Stack. Updates use the last iPhone snapshot and watchOS scheduling.

The dashboard is a snapshot, not a live stream from iPhone. Older readings stay labelled;
missing overlap never becomes agreement. It shows up to four sources per metric and compares
all enabled sources using the iPhone engine. Fast metrics use the past hour; daily metrics use
seven days. Full plots and exports remain on iPhone.

Saved watch readings arrive through HealthKit sync and the existing iPhone import. Connect
Apple Health in HeartSync on iPhone and refresh after system sync. HeartSync does not create a
second copy over WatchConnectivity. The watch receives no Oura credentials.

Select the **HeartSyncWatch** scheme to run the watch app. The iPhone scheme embeds it.
The watch App ID needs HealthKit and App Groups provisioning under the existing development
team. Its embedded complication extension shares `group.com.heartsync.HeartSyncChecker.watch`
with the watch app. Both profiles must include this group; the extension has no HealthKit access.
See [Watch setup and validation](WatchApp/README.md) for commands and device checks.

## Tests

The hosted bundle includes Swift Testing coverage for GATT/PLX admission,
Bluetooth discovery state, transactional SQLite migration and indexed queries, retention and
compaction provenance, archive/settings recovery, HealthKit outcomes and source relationships,
real HRV observation intervals, pairwise grades/confidence intervals, exports, estimates, OAuth,
and Oura deletion/durability behavior. A 7-flow XCUI suite exercises deterministic recovery,
empty/error, data-control, evidence, and pseudo-localization states in the normal CI scheme.
The separate `HeartSyncCheckerPerformance` scheme writes the full fourteen-day 1 Hz workload;
run it on a representative physical iPhone with Instruments before release.

Bluetooth and HealthKit integration, background delivery, and locked-device behavior still
require representative hardware. Compiling any bundle is not evidence that its tests ran.

```bash
xcodebuild test -project HeartSyncChecker.xcodeproj -scheme HeartSyncChecker \
  -destination 'platform=iOS Simulator,id=<simulator UDID>'
```

## Layout

```
Sources/
  Watch/       iPhone snapshot builder and coalesced companion publisher
  Model/       MetricKind (units, tolerances), Reading, DataSource, Discrepancy
  Bluetooth/   GATT UUIDs, BinaryReader, measurement parsers, BluetoothManager
  Health/      HealthKitManager — Apple Watch and anything else writing to Health
  Oura/        OAuth, Cloud API v2 models/client, dashboard cache, document→reading mapping
  Analysis/    ComparisonEngine, pair export, HRVCalculator, Estimators
  Store/       SQLite-backed store, legacy/small JSON archives, keychain, settings
  Views/       Dashboard, Oura explorer, Compare, pair analysis, Devices, Settings
Shared/        Display payload, WatchConnectivity, workout presentation values
WatchApp/      watchOS dashboard, live heart-rate workouts, watch resources
```

For UI development without physical wearables, launch a Debug build with
`--pairwise-demo`. It uses an in-memory fixture containing agreeing, biased, noisy,
collecting, no-overlap, and outlier examples; it does not load or save the normal archive
and does not start any transport.
