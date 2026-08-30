# HeartSync

An iOS app that pulls heart-rate and related metrics from several wearables at once, shows
them side by side, and quantifies where they disagree.

## What it reads, and from where

Three transports, because these devices genuinely do not speak one protocol:

| Source | Transport | Why |
|---|---|---|
| Chest straps, generic rings, pulse oximeters | **Bluetooth LE** | They implement the standard GATT profiles, so they can be read directly and live. |
| Apple Watch | **HealthKit** | The Watch is not a BLE peripheral third-party apps can connect to. Its data only exists in Health. |
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

Tolerances are per metric and reflect real measurement error: 5 bpm for heart rate, 2% for
SpO₂ (consumer oximeters are specified to roughly ±2% ARMS), 15 ms for HRV.

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

Everything stays on device. There is no HeartSync account and no server. Oura authentication
opens `cloud.ouraring.com`; subsequent read-only requests go to `api.ouraring.com` using an
OAuth access token stored in the device-only keychain (never synced to iCloud). No Oura
client secret is embedded in the app. Writing readings back into Apple Health is off by
default, and only ever writes directly measured values — never an estimate.

### Oura OAuth setup

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
Set your development team in the target's Signing settings before running on hardware.

**Bluetooth and HealthKit only work on a real device** — the simulator has no BLE radio and
no Health data.

## Tests

69 tests cover the parts where a silent error would corrupt every comparison downstream:
GATT frame parsing against hand-built spec vectors (IEEE-11073 SFLOAT special values,
R–R interval unit conversion, optional-field skip order), HRV artefact rejection, window
alignment, bias-versus-noise classification, estimator clamping, and Oura mapping.

```bash
xcodebuild test -project HeartSyncChecker.xcodeproj -scheme HeartSyncChecker \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Layout

```
Sources/
  Model/       MetricKind (units, tolerances), Reading, DataSource, Discrepancy
  Bluetooth/   GATT UUIDs, BinaryReader, measurement parsers, BluetoothManager
  Health/      HealthKitManager — Apple Watch and anything else writing to Health
  Oura/        OAuth, Cloud API v2 models/client, dashboard cache, document→reading mapping
  Analysis/    ComparisonEngine, HRVCalculator, Estimators
  Store/       In-memory store, atomic file persistence, keychain, settings
  Views/       Dashboard, Oura explorer, Compare, Devices, Settings
```
