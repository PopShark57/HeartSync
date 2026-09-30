# HeartSyncChecker Agent Guide

This file applies to the entire repository. It records the architecture and working conventions that are present in the code as of the current checkout. Treat the code, `project.yml`, and the tests as the final authority when they disagree with prose.

## Project at a Glance

HeartSync is a SwiftUI iOS 18+ application for collecting and comparing health measurements from three transport paths:

1. Standards-based Bluetooth Low Energy health sensors.
2. Apple Health/HealthKit, which is also the app's only path to Apple Watch data.
3. The Oura Cloud API through an OAuth bearer token.

All three paths normalize data into the same `DataSource` and `Reading` model. `AppModel` routes normalized readings into `HealthStore`, optional derived estimates, comparison analysis, and optional HealthKit write-back. The app is deliberately careful to distinguish measured, derived, and estimated data and to represent insufficient comparison evidence honestly.

The repository contains iOS and watchOS applications, a watchOS WidgetKit complication extension, an iOS hosted Swift Testing bundle, an iOS UI-test bundle, and a separate device-performance test bundle. There is no server, reusable framework target, or local Swift package.

## High-Level Architecture

The main flow is:

```text
HeartSyncApp
  -> AppModel (composition root and lifecycle coordinator)
       -> BluetoothManager -- GATT parsers ----\
       -> HealthKitManager -- type mappings ----> Reading + DataSource -> HealthStore
       -> OuraManager ------ OuraClient --------/                       -> HealthDatabase
       -> derived estimators / HRV                                      -> ComparisonEngine
                                                                        -> SwiftUI views/export
```

- `HeartSyncApp`'s `AppDelegate` (`@UIApplicationDelegateAdaptor`) owns the single root `AppModel`. `application(_:didFinishLaunchingWithOptions:)` calls `AppModel.launch()` — the Bluetooth central with its restoration identifier, and HealthKit's `HKObserverQuery` background delivery — and starts `start()`, because a background relaunch runs no view `.task`. The scene injects the model with `.environment`, keeps a `.task { start() }` (idempotent), and forwards `scenePhase` changes.
- `AppModel` is the concrete composition root. It creates `HealthStore`, `AppSettings`, `BluetoothManager`, `HealthKitManager`, and `OuraManager`, configures their callbacks, and owns periodic derived-metric and Oura-sync tasks.
- `RootView` presents five tabs: Now, Oura, Compare, Devices, and Settings.
- Transport managers convert framework/API-specific values into repository models. Views must not parse transport payloads or write alternate stores.
- `AppModel.ingest` is the common routing seam. Bluetooth and HealthKit readings use idempotent append behavior. Oura readings use upsert behavior because cloud documents may be revised.
- Views observe live state directly and invoke pure analysis helpers for projections. `ComparisonEngine` is the principal pure analysis boundary.

## Repository Structure

| Path | Purpose |
| --- | --- |
| `project.yml` | XcodeGen source of truth for targets, scheme, build settings, Info.plist properties, and entitlements. |
| `README.md` | Product scope, supported measurements, setup, build, and testing overview. Verify implementation details against current code. |
| `Resources/Info.plist` | Tracked, shipped plist materialized from the XcodeGen specification; contains OAuth URL handling, privacy strings, orientations, and Bluetooth background mode. |
| `Resources/HeartSyncChecker.entitlements` | Tracked HealthKit entitlement file materialized from the XcodeGen specification. |
| `Resources/Assets.xcassets` | Universal iOS app icon asset catalog. |
| `Sources/App` | App entry point, root tabs, lifecycle, service construction, ingestion, timers, and derived-metric orchestration. |
| `Sources/Model` | Canonical metric, reading, source, provenance, user-profile, discrepancy, and evidence value types. |
| `Sources/Store` | Observable store boundary, transactional indexed SQLite database, small atomic JSON archives, settings, Keychain wrapper, and stable-ID generation. |
| `Sources/Bluetooth` | CoreBluetooth lifecycle, SIG GATT constants, safe binary reader, typed measurement parsers, per-connection diagnostics, and the topology-gated YCBT ring session and frame codec. |
| `Sources/Watch` | iPhone snapshot projection and coalesced WatchConnectivity publication. |
| `Shared` | Versioned display payload, WatchConnectivity session, and complication projection compiled into both apps. |
| `WatchApp` | Native watchOS SwiftUI dashboard and Compare pages, `WatchTheme` glass surfaces, resources, and entitlements. |
| `WatchComplications` | WidgetKit measurement complication, metric intent, resources, and App Group entitlement. |
| `Sources/Health` | HealthKit authorization, anchored queries, unit/source conversion, background delivery, and measured-value write-back. |
| `Sources/Oura` | OAuth, Keychain-backed credentials, API transport/DTOs, endpoint status, token-free cache, sync orchestration, and scalar mapping. |
| `Sources/Analysis` | Comparison/windowing/statistics, HRV, estimators, and pairwise export. These are mostly pure or value-oriented. |
| `Sources/Views` | SwiftUI screens and reusable components, Charts usage, plus the narrow UIKit share-sheet bridge. |
| `Sources/Debug` | Deterministic fixtures guarded by `#if DEBUG`: the pairwise demo, UI-test scenarios, the thirty-day `--chart-gallery`, and the Xcode previews for every chart and Oura section. |
| `Tests` | Swift Testing suites for parsers, analysis, OAuth/API behavior, stable IDs, and export. |
| `UITests` | Deterministic UI recovery, data-control, comparison, Oura failure, and pseudo-localization flows. |
| `PerformanceTests` | Separate physical-device 14-day, 1 Hz indexed-store release workload. |
| `HeartSyncChecker.xcodeproj` | Ignored XcodeGen output. Regenerate it; do not treat it as source. |
| `build`, `DerivedData`, `*.xcresult` | Ignored generated build/test artifacts. Never edit or commit them as implementation. |

`.DS_Store` and Xcode user-state files are ignored and have no project meaning.

## Targets, Products, Schemes, and Dependencies

`project.yml` defines exactly these targets:

| Target | Type | Sources | Important identity |
| --- | --- | --- | --- |
| `HeartSyncChecker` | iOS application | All of `Sources`, `Shared`, and the non-plist contents of `Resources` | Bundle ID `com.heartsync.HeartSyncChecker`; product/executable `HeartSync`; Swift module `HeartSyncChecker` |
| `HeartSyncWatch` | watchOS application | `WatchApp/Sources`, `Shared`, selected model files, `ChartLookup` | Bundle ID `com.heartsync.HeartSyncChecker.watchkitapp`; product/module `HeartSyncWatch`; display name HeartSync |
| `HeartSyncWatchComplications` | watchOS app extension | `WatchComplications/Sources`, selected shared/model files | Bundle ID `com.heartsync.HeartSyncChecker.watchkitapp.complications`; embedded in watch app |
| `HeartSyncCheckerTests` | Hosted iOS unit-test bundle | All of `Tests` | Imports `@testable import HeartSyncChecker`; explicit host is `HeartSync.app/HeartSync` |
| `HeartSyncCheckerUITests` | iOS UI-test bundle | All of `UITests` | Drives deterministic Debug-only launch scenarios; targets `HeartSyncChecker` |
| `HeartSyncCheckerPerformanceTests` | Hosted iOS unit-test bundle | All of `PerformanceTests` | Manual physical-device release workload; explicit host is `HeartSync.app/HeartSync` |

The `HeartSyncChecker` scheme runs the normal unit and UI bundles and embeds the watch app and its complication extension. `HeartSyncWatch` builds/runs the watch app with its extension. `HeartSyncCheckerPerformance` isolates the intentionally large device workload from PR CI, which is `.github/workflows/ios.yml` (unit, UI on an iPhone simulator, and the watch build on the iOS 18 and newest runtimes, warnings as errors; iPad is not run in CI because the owner uses only iPhone and Apple Watch). Debug and Release configurations are generated.

The target/product/module naming difference is intentional and fragile: the target, scheme, and module are `HeartSyncChecker`, but the installed bundle and executable are `HeartSync`. Preserve `PRODUCT_NAME`, `PRODUCT_MODULE_NAME`, `TEST_HOST`, and `BUNDLE_LOADER` together.

There are no:

- macOS, visionOS, tvOS, or Mac Catalyst targets;
- iOS widget extensions, notification extensions, or reusable framework targets;
- `Package.swift`, `Package.resolved`, SwiftPM package dependencies, CocoaPods, or Carthage dependencies.

The app uses only Apple system frameworks and libraries: SwiftUI, Observation, Charts, Combine, Foundation, OSLog, CoreBluetooth, HealthKit, AuthenticationServices, Security, UIKit, CryptoKit, Accessibility (Audio Graph descriptors), WatchConnectivity, WatchKit, WidgetKit, AppIntents, SQLite3, and FoundationModels (the Now brief only; iOS 26+, weak-linked, behind `#if canImport(FoundationModels)` so an SDK without it builds). Tests use Foundation, Swift Testing, and XCTest/XCUIAutomation for the UI bundle.

## Shared Versus Platform-Specific Code

Every file under `Sources` is compiled into the iOS app module. `Shared` plus `MetricKind`, `DiscrepancySeverity`, `Provenance`, and the Foundation-only `Sources/Views/ChartLookup.swift` are also compiled directly into the watchOS app. There is no separate shared framework or package. The watch does not compile the iPhone store, transports, or views.

The complication extension compiles only its own sources, the watch snapshot/projection/cache,
and the selected metric/provenance models. It does not compile `CompanionSession` and does not access HealthKit. App Group sharing is local to the watch, not a phone sync path.

- Mostly value-oriented and reusable: `Sources/Analysis`, most of `Sources/Model`, `OuraClient`/Oura DTOs, `ReadingArchive`, and stable IDs.
- iOS/UI-specific: `Sources/App` and `Sources/Views`.
- Framework-specific: `Sources/Bluetooth` for CoreBluetooth, `Sources/Health` for HealthKit, and the OAuth presentation code in `Sources/Oura/OuraOAuth.swift` for AuthenticationServices/UIKit.
- Security-specific: `Sources/Store/Keychain.swift` and CryptoKit-based `StableID.swift`.

Do not assume the model layer can already be moved into a Foundation-only package: `DataSource`, `MetricKind`, and `Discrepancy` currently import SwiftUI for presentation colors. `DataSource` also imports UIKit, behind `#if canImport(UIKit)`, so that each source palette slot resolves a light or dark value. Source colours are defined as numbers (`SourcePaletteSlot`, `SRGBColor`) so that `Tests/ColourVisionTests.swift` measures exactly what is drawn. Change a slot's values in place, never renumber the slots, and keep that test passing. There are ten slots. The first six are checked under colour-vision simulation; red, gold, teal, and orchid (added later) are checked for ordinary vision only, by owner decision, and rely on shapes for colour-blind readers. A new source takes a random least-worn slot (`DataSource.leastUsedColorIndex`, random among equals so devices do not always get the same colours), and load repairs devices that share one (`colorIndexRepairs`: enabled first, oldest keeps it), so devices are never drawn in fewer colours than there are slots. There are seven shapes (`SourceSymbol`); slots past the seventh repeat one, and `MetricDetailSnapshot.symbols(for:)` gives a visible repeat a spare.

## State Management and Dependency Injection

The project uses the iOS 17+ Observation framework rather than `ObservableObject`/`@Published`:

- Mutable app-facing reference types are `@MainActor @Observable`: `AppModel`, `HealthStore`, `AppSettings`, `BluetoothManager`, `HealthKitManager`, and `OuraManager`.
- The root model is owned with `@State` and injected through the SwiftUI environment.
- Views retrieve it with `@Environment(AppModel.self)`.
- Settings forms create a local `@Bindable` view of `model.settings` for two-way bindings.
- View-local presentation/transient values use `@State`.
- The public Oura client ID uses `@AppStorage("oura.oauth.client-id")`. It is configuration, not a secret.
- Views generally derive display state from observed models and immutable snapshots rather than maintaining duplicate source-of-truth state.

There is no protocol registry or dependency-injection container. `AppModel` constructs concrete services. Reuse the injection seams that do exist:

- Transport managers are configured with the shared `HealthStore` and main-actor ingest/status closures.
- `OuraClient` accepts a `URLSession`; tests use this to inject a custom `URLProtocol`.
- `HealthStore(persistenceEnabled:)` supports isolated unit tests and debug fixtures.
- `AppSettings(snapshot:)` accepts an initial settings snapshot.

Do not introduce a broad DI framework for a local change. Add a small constructor or configuration seam only when it is needed for testability or a real alternate implementation.

Invalidation is Observation on the actual store and managers. `HealthStore.changeToken` and `removalGeneration` are the tokens external projections (the watch publisher and its chart cache) key on.

`AppModel.init` accepts the store, settings, sessions, managers, and an `AppModel.TransportActions` value: the handful of calls the model makes on Bluetooth, HealthKit, and Oura, as closures. Production forwards them unchanged (`.live`); tests pass `.inert` or a recording copy, so startup order, retention, derived metrics, and refresh run without any transport.

## Concurrency Conventions

The XcodeGen settings enable Swift 6 with complete strict-concurrency checking.

- UI-visible mutable state and transport orchestration stay on `MainActor`.
- Domain values, DTOs, parser results, and analysis inputs are generally value types conforming to `Sendable` and, where useful, `Codable`/`Hashable`/`Identifiable`.
- `ReadingArchive` is an actor and is the explicit off-main boundary for JSON file I/O.
- History reads and analysis run off the main actor. `HealthStore.history` is a `Sendable` `HealthHistory` (sources, generations, and a pool of read-only SQLite connections, `HealthDatabase.ReaderPool`); snapshot builders take it and run inside `HealthHistory.offMain`, and only the finished snapshot is published on the main actor. Writes stay on the store's writer connection on the main actor.
- Networking uses `async`/`await` and `URLSession.data(for:)`.
- Authentication and HealthKit callback APIs are bridged to async continuations or explicit `Task { @MainActor in ... }` hops.
- Repeating work uses cancellable `Task` loops. The derived-estimate loop runs every 300 seconds; Oura auto-sync has a 300-second minimum; BLE scanning has a 60-second timeout.
- Use `Task {}` to bridge synchronous SwiftUI/framework callbacks into isolated work. Long-lived tasks should check cancellation and weakly capture app-lifetime owners where the existing code does so.
- Do not use detached work to mutate observed state.

CoreBluetooth has an important actor assumption. `BluetoothManager` creates `CBCentralManager` with `queue: nil`, so delegate callbacks arrive on the main queue. Delegate requirements are `nonisolated` and use `MainActor.assumeIsolated`; state restoration also contains a documented `nonisolated(unsafe)` handoff for framework objects. Do not change the central-manager queue, remove those bridges, or copy that pattern to callbacks without an equivalent queue guarantee.

HealthKit callbacks convert framework samples into Sendable value data inside the callback and then hop to `MainActor`. Keep non-Sendable `HKSample` objects out of unconstrained tasks.

Oura endpoint requests currently run sequentially. Do not casually convert them to a task group: endpoint status, token invalidation, partial-permission behavior, cached-data preservation, and API rate behavior are coupled to the current flow. A 429 that `OuraClient` cannot absorb inline ends the cycle (`SyncAbort.rateLimited`): collections fetched before it are committed, the rest are not asked for, the cycle is not counted as a full backfill, and the deadline is kept until a cycle finishes without another 429. Foreground returns and the timer are unattended and go through `syncIfDue(minimumInterval:)` (the scheduled interval, floor five minutes); pull-to-refresh and **Sync now** call `sync()`. A watch's refresh request pulls Health and republishes; it never reconnects Bluetooth or asks Oura. A watch's **Sync all sources** request (`WatchSyncReport.requestKey`, `AppModel.syncAllFromWatch`) is the user's own request and does what the Devices tab's buttons do: reconnect known Bluetooth devices, start Import stored on every identified idle ring, `syncAll` Health, and a full `sync()` of Oura. Runs are at least 60 seconds apart; the iPhone replies with a `WatchSyncReport` by a 25-second deadline, marking any transport still running, and the readings follow in the next snapshot. `OuraClient` also has shared `nonisolated(unsafe)` ISO-8601 formatters that must be re-audited before concurrent use is expanded.

## Bluetooth Architecture

`BluetoothManager` owns scanning, restoration, connection/reconnection, discovery, notification handling, source metadata, and ingestion. Strong references to peripherals are mandatory; removing them can silently break connections.

Supported measurement paths are Bluetooth SIG standards, plus one topology-gated vendor candidate described below:

- Heart Rate Service `180D` and Heart Rate Measurement `2A37`.
- Pulse Oximeter Service `1822` and PLX continuous/spot-check measurements.
- Health Thermometer Service `1809` and Temperature Measurement `2A1C`.
- Battery Service and Device Information Service metadata after connection.

Reuse `GATT`, `BinaryReader`, `HeartRateMeasurement`, `PulseOximeterMeasurement`, and `TemperatureMeasurement`; do not hand-parse characteristic bytes inside views or duplicate unit logic. Parser invariants include:

- RR intervals are in 1/1024-second units before conversion.
- Heart-contact flags can invalidate an off-body heart-rate frame.
- PLX optional fields must be skipped in specification order.
- Device flags can invalidate SpO2 values.
- IEEE-11073 reserved/special float values are not valid measurements.
- Fahrenheit temperatures are normalized to Celsius.

HRV is derived per peripheral with `HRVAccumulator`/`HRVCalculator`, artifact rejection, a five-minute window, at least 20 clean beats, and rate-limited emission. Preserve those semantics and their tests. A Heart Rate Measurement subscription counts as heart rate only in readiness; HRV appears only from real R–R intervals.

Readiness and diagnostics (`RingFix.md`):

- `BluetoothDiscoveryState` tracks measurement candidates and vendor control channels separately. A control channel can make a link ready but never adds a metric.
- `PeripheralConnectionState.resolving` keeps observed streaming state when a late discovery callback arrives.
- The no-data watchdog follows `StreamCadence` (30 s to 10 min) and explains itself from `BluetoothDiagnostics`: silence, rejected packets (with the reason), or a stopped stream.
- `BluetoothDiagnostics` counts packets per characteristic before any parser or admission guard and names every rejection. Record new rejection paths there. Raw packets are captured only during an explicit 60-second diagnostic session (`runDiagnostics`, which runs `discoverServices(nil)` once), bounded to 200, and leave the app only through the user's export. Never log them.
- Reconnect is a fresh session: a connected link is cancelled and one connection starts from its disconnect callback, bypassing the backoff. Per-peripheral state is one `PeripheralLink` per connection session (discovery, metrics, cadence, watchdog, HRV accumulator, `RingLink`) and one `PeripheralRecord` per device (reconnect backoff, fresh-reconnect wait, device information), in `PeripheralState.swift`. Ending a session replaces the link; Forget removes both; a radio power-off ends every link like a disconnect. The link's globally unique `session` number invalidates delayed work. `connect` does not rediscover a link that already has a session, so a foreground refresh leaves a healthy session alone.
- Restoration (`willRestoreState`) only adopts peripherals; discovery of restored, connected links runs once at `.poweredOn`. The central is created at launch, before history loads; values arriving earlier wait in the store's bounded pre-load buffer, and `resumeBluetoothAfterLoad` reconnects known devices once the source list exists.
- Live values are batched by `AppModel` (`BluetoothIngestBuffer`): one transaction per two seconds or 240 values, flushed when a link ends (`onLinkEnded`), before a reset, and at background. A ring history import flushes first and commits as its own batch.

Vendor ring candidate (`R11MRingSession`, `YCBTFrameCodec`):

- It is selected only from GATT topology: the YCBT service with a writable, subscribable command characteristic and a subscribable event characteristic. Never select it from the advertised name.
- Nothing is written until both channels confirm their subscription. The only unprompted write is the read-only identity query, which is repeated every 15 minutes while the session is idle (`refreshBattery`, `RingLink.batteryTask`, purpose `.batteryQuery`) and never during a measurement or import. A measurement or history import starts only after a CRC-valid identity reply, and only from the user's Measure heart rate / blood oxygen / blood pressure / temperature, Stress level (a heart-rate measurement), or Import stored readings action, or the watch's Sync all sources request, which starts Import stored only on a connected, enabled ring whose session is identified and idle (`importStoredReadingsFromReadyRings`).
- Live values are provisional. Only the ring's completion event for the running sensor emits a reading (the last live value, through `emit`). Zero, no-contact, rejection, timeout, and another sensor's frames store nothing.
- Temperature (`03 2F 01 04`, PulseLoop's mode table) has no live frame. Its successful completion starts a read-only import of the temperature and combined records (`Measurement.storedIn`), and the outcome is `.readFromMemory` with the newest record no older than `storedResultTolerance` before completion, or none. The vitals capture shows an R11M whose capability bitmap lacks temperature, HRV, and stress, so such a ring is expected to reject the start; a rejection stores nothing. Unverified on hardware. HRV (`0A`) and stress (`0C`) modes are never requested.
- The Measure menu's Stress level runs the ring's heart-rate measurement (`AppModel.checkStress`, `TransportActions.measureRingHeartRate`); when that value arrives (`BluetoothManager.onRingMeasurement`), `AppModel` flushes the Bluetooth batch, recomputes estimates, and records the result in `stressChecks`. The ring contributes heart rate only; the stress index is HeartSync's.
- Battery: the identity reply (`02 00`) is decoded as `YCBTFrameCodec.DeviceInfo`; payload byte 4 is the charging state (non-zero while charging) and byte 5 the percent (above 100 is discarded), as `SmartRingWatcher`'s `YCParsers.deviceInfo` reads them. The session emits `.battery`, which `BluetoothManager` stores with `HealthStore.updateBattery(_:isCharging:forSource:)` on `DataSource.batteryPercent`/`batteryIsCharging`. It is source metadata, never a reading.
- `YCBTHistory` reads stored heart-rate, blood-pressure, combined, SpO₂, and temperature records (`05` group). A type is decoded only when its concatenated bytes match the terminal block's length and CRC; the app then acknowledges (`05 80 00`, or `04` on failure). Nothing is ever deleted from the ring. Timestamps are the ring's local wall clock since 2000; records older than 30 days, in the future, or with a repeated timestamp are skipped. History IDs are `UUID(stableFrom:)` of source, metric, and timestamp, and a batch goes through `onReadings`, bypassing receipt-time admission only because it is one user-started, checked import.
- Ring blood pressure and temperature are `.estimated` (`R11MRingSession.provenance(for:)`); heart rate, SpO₂, and respiratory rate are measured, as other vendor values are. The vendor HRV byte is not imported (RMSSD versus SDNN is undocumented); vendor stress and sleep are not imported.
- While the session owns heart rate, the same ring's `2A37` frames are counted as superseded, not ingested.
- The framing is from public reverse-engineering and is unverified on hardware. Do not add commands (clock, settings, delete, keepalive, periodic-monitoring schedules) without captured evidence and tests. Do not describe the path as verified.

The restoration identifier is `com.heartsync.central`. `UIBackgroundModes = bluetooth-central` enables CoreBluetooth background/restoration behavior; it is not a generic background-execution entitlement.

## HealthKit and Apple Watch Architecture

Apple Watch data reaches iPhone only through the HealthKit import. The watchOS companion is display only: it records no workouts, does not use HealthKit, and has no workout-mirroring path (workout recording, `MirroredWorkoutPayload`, and `MirroredWorkoutMonitor` were removed at the user's request). WatchConnectivity carries a display snapshot from iPhone, and refresh and sync-all requests (with the sync-all's per-transport report) between them; it never carries measurements. Do not add or imply direct Apple Watch BLE access.

`HealthKitManager.TypeMapping` owns the HealthKit identifier, metric, unit, and scale. Current reads include heart rate, resting heart rate, SDNN HRV, oxygen saturation, respiratory rate, VO2 max, body temperature, and blood pressure. HealthKit oxygen saturation is a fraction and is multiplied by 100 on ingestion. There is no HealthKit RMSSD mapping.

Authorization and synchronization rules:

- Read types include the supported measurements plus birth date. Biological sex is not
  requested or retained because no current feature uses it.
- Share types are restricted to directly measurable BLE-compatible metrics: heart rate, oxygen saturation, SDNN, and body temperature.
- Completion of the HealthKit authorization sheet does not prove that each read permission was granted. Do not make the UI claim otherwise.
- Anchored queries request a recent 30-day window and then install update handlers. A page's anchor advances after its SQLite transaction commits, which is already durable; pruning, compaction, and the WAL checkpoint are maintenance (`HealthStore.saveNow`) and run on `AppModel`'s 15-minute timer and at background transitions, never per page. Local retention settings do not imply a one-year HealthKit backfill.
- Background delivery is requested hourly. One `HKObserverQuery` per type is registered at launch (`HealthKitManager+Background`) once Connect has completed; its handler returns at once while the foreground anchored queries run, otherwise waits up to 20 s for startup, drains through `syncAll`, and always calls HealthKit's completion handler. There are no `BGTaskScheduler` identifiers or task handlers.
- A local data reset is exclusive with imports (`AppModel.resetLocalData`): HealthKit's observers stop and a running drain is awaited (`beginDataReset`), a running Oura sync is cancelled and awaited (`clearCachedData`), and only then is the store cleared; HealthKit resumes from cleared anchors for a resync or committed ones for "forget" (`finishDataReset`). Both managers carry a reset epoch, so a page or cycle that began before a reset writes neither the database, an anchor, nor the Oura cache after it. `syncAll` and `OuraManager.sync` join a run already in flight rather than returning at once.
- The committed entitlements declare `com.apple.developer.healthkit.background-delivery`, and the code requests hourly delivery. The capability still needs to be enabled for the App ID/provisioning profile and exercised with a signed build on a physical device; do not describe background wake behavior as guaranteed until that validation succeeds.
- Anchored queries apply HealthKit deletions: `HealthKitManager.deletedReadingIDs` maps each `HKDeletedObject.uuid` to a reading id (the same sample UUID used at ingest), and `AppModel.ingest` commits source updates, readings, and deletions from one anchor page through `HealthStore` in a single transaction. Unknown ids are a no-op. Remaining limits: an already-exported pairwise analysis is unchanged; after compaction, raw sample UUIDs are gone so an upstream deletion cannot remove the stable window median that replaced them.
- Optional write-back is allowed only for `.measured` readings from Bluetooth sources. Estimated or HealthKit/Oura-originating values must never be written back. Accepted readings are queued (`enqueueWrites`) and saved in one batch every 30 seconds and at background transitions; each sample carries an `HKDevice` from the source and `HKMetadataKeySyncIdentifier` (`heartsync.<reading id>`) with sync version 1, so a retried save cannot duplicate it. Write permission is checked before each batch, and a refusal or a full queue is reported in `writeBackIssue`.
- `dateOfBirthComponents()` is Gregorian; `HealthKitManager.dateOfBirth(from:)` converts it with a Gregorian calendar, never `Calendar.current`.

HealthKit readings currently use `hk.<source bundle identifier>` as the source ID and keep the device model as metadata. A nearby model comment describes a more specific identity than the implementation supplies. Treat the implemented ID formula as migration-sensitive; changing it can split or duplicate historical sources.

The manager starts each process with authorization state `.notDetermined`, and startup synchronization depends on current manager state. Relaunch behavior, enabling write-back after prior read-only authorization, and per-type permissions require on-device validation before changing their UI or lifecycle behavior.

## watchOS Companion

`HeartSyncWatch` is a watchOS 11+ application embedded in `HeartSync.app/Watch`, with the
`HeartSyncWatchComplications` WidgetKit extension in its `PlugIns` directory.
The watch app's dashboard requires a snapshot from the paired iPhone and always labels measurement time separately from sync time.

- `WatchSnapshotBuilder` uses `HealthStore` indexed queries and `ComparisonEngine`. Only the
  four most recent sources per metric are displayed, but comparisons include every enabled
  source. The watch offers 1H/3H/24H/7D/30D periods (`WatchChartRange`; a daily metric
  only 7D and 30D). Compatibility with watch builds older than 3H is not a goal: both apps
  ship together. `WatchMetric.chart` and `comparison` carry the standard period (24H, or 7D
  for daily metrics) so an older watch still works; `rangeCharts` carry the others and
  `availableRanges` lists what was computed, so a listed period without a chart means no
  readings, never agreement. Each chart holds its own `comparison`, each shown source's window
  medians (about 30 per period, whole multiples of the comparison window), its iPhone palette
  colour and the shape `MetricDetailSnapshot.symbols(for:)` gives it, and one ready pair's
  Bland–Altman figures; a pair below five paired windows is never sent. `WatchChartCache`
  (owned by the publisher) rebuilds 1H and 3H every publication, reuses 24H for 2 min, 7D for 15 min, and 30D for 60 min, and drops
  an entry at once when shown or enabled sources change or a removal reaches it: one that
  removed a row ending at or after the period's current start (`HealthStore.recentRemovals`,
  `HealthHistory.latestRemovedEnd`). Deletions inside the period, source removal, a shortened
  retention, reset, and reload qualify; routine pruning of rows older than 30 days and
  estimate reconciliation do not. The fingerprint and shapes use sources sorted by stable ID.
  Periods that need building come from one read of the longest of them, sliced by midpoint.
  `fittedPayload` drops 30D, then 7D, then 1H, then 3H, then 24H charts rather than exceed the 60 KB
  cap, and returns the encoding it ended on; the publisher hands those bytes to
  `CompanionSession.publish(encoded:)`, so a snapshot is encoded once, off the main actor. Watch charts label the x axis with round local times inside the plot edges
  (`WatchChartProjection.axisTicks`/`axisFormat`), break at gaps, dash estimates, use neutral
  reference inks, and are hidden in Always On. The watch never recomputes statistics.
  A tap, or a touch-and-hold then slide, on a detail trend or difference chart selects the
  nearest window within `ChartLookup.selectionRadius` (`WatchChartProjection.windows`,
  `nearestDate`) and shows a popup with its local time span and each source's window
  median (never a raw sample); the selection stays when the finger lifts, a touch in empty
  plot area clears it, and it ticks `.sensoryFeedback(.selection)`. VoiceOver steps windows
  with the adjustable action and has a Clear selection action. Row sparklines are not
  selectable, because a tap there opens the metric.
- Do not put `.toolbar` items on the watch pages. Each page of the vertical-page `TabView`
  has its own `NavigationStack`, and a `topBarTrailing` item on the dashboard crashed
  watchOS with "Layout requested for visible navigation bar … when the top item belongs to a
  different navigation bar". Actions go in the list (Sync all sources sits under Compare
  devices).
- `WatchCompanionPublisher` observes source changes, reading generations, and load state;
  it coalesces ordinary publications to at most once every 30 seconds while iOS is running.
  Foreground refresh and WatchConnectivity activation can publish immediately. This is not
  an always-running background timer or a guaranteed delivery interval.
- `CompanionSession` uses `updateApplicationContext` for latest-state delivery and reachable
  messages for user refresh and sync-all (the only message with a reply, sent once through
  `ReplyOnce`; the watch gives up 20 seconds after the iPhone's deadline). Its versioned payload is capped at 60 KB, excludes credentials,
  rejects malformed data, and ignores older contexts after newer resets. The watch restores
  the OS-managed received context. `WatchComplicationStore` caches one replaceable display
  snapshot for the extension; there is no second health history database.
- The App Group holds `WatchSnapshot.complicationProjection`, not the whole payload: per metric, the one reading a complication draws. `WatchComplicationStore.save` returns true, and timelines reload, only when that projection differs (`drawsSameComplications`); a new delivery time, chart, or comparison count reloads nothing.
- Complications share `group.com.heartsync.HeartSyncChecker.watch` between the watch app and
  extension only. Both profiles must include App Groups. The cache is validated, bounded to
  60 KB, atomic, protected until first unlock, and excluded from backup. Cache writes and
  timeline reload requests happen before completing WatchConnectivity background tasks.
- Measurement complications support seven non-estimated metrics in circular, rectangular,
  inline, and corner families, using the newest displayed source with stable tie-breaking.
  The circular family is an `accessoryCircular` gauge over `MetricKind.displayRange`; its
  opening shows Older or Median when either applies.
  Preserve derived/median labels, explicit empty/old states, and measurement-time freshness.
  Schedule a future stale entry; WidgetKit reload timing remains system-controlled. Mark
  measurement views privacy-sensitive. `heartsync-watch` links open metric details only. Preview fixtures must not enter the shared cache.
- Always On: the dashboard reads `isLuminanceReduced`, keeps values prominent, dims secondary
  content, and hides trends. Measurement values are `privacySensitive()`, as the complications are.
- The watch's App ID needs only the App Group and the same team `7RLDYXQTNX`. Its generated
  plist declares `WKApplication` and the exact iPhone companion ID. Do not add HealthKit,
  workout processing, or location/route access without an explicit request.
- Glass: `WatchTheme.swift` (`WatchCardBackground`, `watchGlassButton`, `watchGlassCapsule`)
  uses Liquid Glass on watchOS 26 behind `#if compiler(>=6.2)` and `#available`, with tinted
  fills before.
- `--watch-demo` in Debug displays synthetic dashboard data without activating connectivity.
  See `WatchApp/README.md` for build and hardware checks.

## Oura Networking and OAuth

Oura is the repository's only Internet API.

- `OuraClient` is a bearer-authenticated, read-only REST client rooted at `https://api.ouraring.com/v2/usercollection/`.
- It injects `URLSession`, requests JSON with a 30-second timeout, distinguishes date and date-time query styles, and follows `next_token` pagination for at most 25 pages.
- Its typed failures distinguish missing credentials, 401, 403, 429, other HTTP status, transport, and decoding failures. Preserve structured server detail where available.
- Oura DTO properties intentionally mirror snake_case API keys. If a Swift property is renamed, add and test explicit `CodingKeys`.
- Endpoint paths and casing, including unusual spellings, are API contracts. Do not “clean up” paths without current API evidence and request tests.

`OuraOAuthSession` uses `ASWebAuthenticationSession` with a client-only token flow:

- No client secret or refresh token is embedded.
- A random 32-byte state value is generated and exactly validated.
- Callback scheme, host/path, and state are validated before accepting a token.
- The exact callback is `com.heartsync.heartsyncchecker://oauth/oura`.
- The callback declaration must stay synchronized in `OuraOAuthSession`, `project.yml`, `Resources/Info.plist`, and OAuth tests.
- The bearer credential is stored in the device-only Keychain, not UserDefaults or the JSON archive. Reads distinguish absent, undecodable, and unavailable (`Keychain.lookup`, `OuraOAuthCredentialStore.read`): only the first two may clear the credential. An unavailable read (a locked device) keeps the cached credential, reports a retryable message, and lets scheduling retry (`mayHaveAuthorization`).
- The cached `OuraClient.PersonalInfo` holds only the id and email. The unused body measurements Oura returns are neither decoded nor kept, because `oura-dashboard-v1.json` is included in backups.

Oura sync intentionally starts with the cached snapshot and handles each collection independently. A successful collection replaces its cached field; an unavailable/failed collection retains prior cached data. Do not erase the entire dashboard because one endpoint fails.

Permission handling is deliberately server-authoritative:

- Do not preflight-block an endpoint solely because a callback scope name is absent or unfamiliar.
- `spo2` and `spo2Daily` are recognized aliases in the existing compatibility logic.
- A scope-related 401, including a bare 401 corroborated by callback scopes, is an endpoint permission failure and must not invalidate the whole credential.
- A non-scope 401 represents an expired/invalid credential and clears it.
- Scope changes require coordinated updates to requested scopes, `OuraEndpoint.requiredScope`, UI descriptions, manager behavior, and OAuth tests.

## Persistence and Data Storage

`HealthStore` is the single observed repository boundary. It keeps the small source list in memory and stores readings in one local SQLite database. It rejects implausible values, de-duplicates known reading IDs, updates observed source metrics, and offers indexed, range-shaped and paged read APIs.

- Bluetooth and HealthKit records are appended idempotently.
- Oura records are upserted because a stable cloud record can be corrected. Stored Oura readings outlive the 14-day dashboard cache: only a document dated inside a complete full-window response and absent from it is withdrawn (`OuraManager.withdrawn`); aging out of the cache withdraws nothing, and retention decides when they go.
- Stable identity comes from framework sample IDs or `UUID(stableFrom:)` recipes. Identity changes require migration analysis; otherwise a refresh can duplicate or orphan history.
- Reading and source mutations commit transactionally and incrementally. The database indexes stable ID, metric/time, source/time, and end time. Settings persistence remains one-second coalesced. Startup refuses to attach transports until the database and any pending legacy migration are conclusive; an unavailable protected file is retried rather than treated as empty.
- Default reading retention is 30 days and can be configured by the existing settings model. A store that persists never prunes aged history until `confirmRetention(days:)` has run: the 30 days it starts with is a default, and so is what a failed, reset, or newer-schema settings file reports. `AppModel.applyRetentionSettings` confirms only from settings that loaded intact (or after the user chose a period in this session), and the last confirmed period is recorded in the database's `metadata` table, so a settings file lost and recreated with the default cannot shorten it: pruning is held (`retentionIsPaused`, a startup notice, and a Settings button) until the user chooses a period. Impossible-clock rows (`start > end`) are removed once at load. Before pruning, readings at least 14 days old are irreversibly compacted to one median per source/comparison window. New compacted rows preserve original count and standard deviation; migrated legacy medians represent unavailable facts as unknown. A compacted window is final: late rows and cloud revisions for it are rejected because the discarded distribution cannot be recombined without median-of-medians bias.

`HealthDatabase` stores `health.sqlite3` plus its WAL/SHM companions under Application Support in the `HeartSync` directory. `PRAGMA user_version` is a migration ladder (`HealthDatabase.schemaVersion`, now 3; additive steps only, never lowered). Schema 3 added `value` and `has_metadata`, so a row without metadata is rebuilt from its columns instead of decoding JSON; older rows are decoded from the payload until maintenance backfills them in bounded batches. The payload stays authoritative. The connection keeps `synchronous = FULL` because HealthKit's anchor and Oura's cache advance on a returned commit. A store without persistence uses a private file in the temporary directory, not `:memory:`, so the reader pool can open it. A durable metadata marker makes the version-1 JSON migration retry across process termination. `ReadingArchive` continues to serialize the small ISO-8601 JSON archives atomically and supplies the legacy migration inputs:

- `readings.json`
- `sources.json`
- `settings.json`
- `oura-dashboard-v1.json`

JSON writes use a versioned envelope and reads retain compatibility with the earlier bare-payload format. If a file can be opened but cannot be decoded, the actor preserves it under a unique timestamped `.corrupt-*` name instead of silently deleting it. If it exists but cannot be opened, the actor leaves it untouched and reports it as unreadable. Beyond the explicit JSON-to-SQLite reading/source migration there is no general payload schema-migration layer. Adding or changing non-optional `Codable` fields, enum raw values, or stable-ID formulas can invalidate or duplicate user history and needs an explicit compatibility plan plus tests.

The database, WAL/SHM files, and JSON writes explicitly use complete file protection until first user authentication. This keeps them usable while locked after the first unlock, which is necessary for ordinary Bluetooth background collection. The boot-to-first-unlock gap remains; retryable startup guards are what prevent that gap from overwriting history. Do not change this to complete protection or complete-unless-open without re-evaluating the background path. Files remain eligible for encrypted device backups so Bluetooth-only history can be restored; the bearer credential remains device-only in Keychain.

The Oura snapshot is schema-versioned and token-free. Its `schemaVersion` is recorded but there is no implemented general migration mechanism.

OAuth credentials are encoded as one Keychain generic-password value using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. No Keychain access group is configured, so the item is not shared and does not migrate through iCloud. The Oura client ID is deliberately public configuration in `@AppStorage`; never put the bearer token there.

HealthKit query anchors use `UserDefaults` keys prefixed with `hk.anchor.`. Pairwise exports and per-source removal exports use per-export temporary directories (`ExportDirectory`, `HeartSync-Export-*` and `HeartSync-Pairwise-*`) and remove them after the share sheet is dismissed; launch sweeps any created before it, which a crash or kill while sharing left behind. Reading exports run off the main actor (`ReadingsExportJob`, `ReadingsExportPayload.prepare`, `HealthHistory.writeExportCSV`) on one pooled read connection, in keyset pages on `(end, rowid)` inside one read transaction, with progress and a Cancel that deletes the partial file. Never page an export with `OFFSET`.

The version-1 whole-file reading/source archives are migration inputs only. Do not reintroduce a parallel reading persistence path beside SQLite. Compaction bounds old high-frequency history but still sacrifices individual samples, the full within-window distribution, and later corrections; preserve its explicit aggregation metadata and unknown legacy evidence.

There is no Core Data, SwiftData, CloudKit, shared Keychain group, or remote database. The watch
App Group holds only the disposable complication display cache; iPhone history remains in SQLite.

## Analysis and Data-Integrity Invariants

These abstractions encode product correctness and should be reused rather than reimplemented:

- `MetricKind`: title, unit, symbol, color, plausible range, chart range, tolerance, comparison window, continuous/discrete behavior, and formatting. Adding a case requires auditing every exhaustive switch, mapping, view, and test.
- `Reading`, `DataSource`, `SourceTransport`, and `Provenance`: canonical normalized record types.
- `UUID(stableFrom:)`: deterministic import identity.
- `HealthStore`: ingestion, validation, de-duplication, querying, pruning, and persistence seam.
- `ComparisonEngine`: epoch-aligned windows, per-source medians, pairing, evidence state, discrepancies, and Bland-Altman statistics.
- `PairwiseExporter`: stable CSV and summary semantics, UTC formatting, and explicit source metadata. `CSV.escape` (RFC 4180) and `CSV.spreadsheetSafe` (leading `=`, `+`, `-`, `@` made literal) are the only CSV writers; the whole-history and per-source exports use them for source names and models too.
- Estimates HeartSync computes carry `ReadingMetadata.modelledBy`, and `HealthStore.reconcileEstimates` deletes only within its scope: blood-pressure and stress estimates under `AppModel.estimateSourceID`, VO₂ max estimates that are HeartSync's own. A ring's estimated blood pressure and temperature are never candidates.
- `StressModel`: the stress index (`MetricKind.stress`, 0–100, always `.estimated`, one reading per five-minute slot under the estimate source, never written to Health). Robust z-scores against the user's own history: per-source ln(HRV) median/MAD over 30 days (0.40), heart rate against the same local hours over 14 days from one SQL aggregate (`HealthDatabase.hourOfDayMoments`, 0.30, else resting heart rate plus a waking allowance at half weight), respiration (0.10), a temperature rise (0.08), and an SpO₂ fall (0.07). Weights fade with freshness; a heart-rate reserve above 50% refuses to score (likely exercise) and 30–50% fades the heart-rate and HRV terms; thin evidence is shrunk towards the typical score; a score from the previous 20 minutes is blended in. Blood pressure is not an input (it is modelled from the same signals). The `Baseline` is cached by `AppModel` for six hours and dropped on reset. `StressModel.disclaimer` appears with every stress value.
- `HRVCalculator`/`HRVAccumulator`: RR filtering and HRV derivation.
- `Estimators`: estimated VO2 max and blood-pressure trend rules/provenance.
- `Components.swift`: `SourceDot`, `SourceValueRow`, `AgreementBadge`, `EmptyStateView`, `EstimateDisclaimer`, `BatteryMeter`, `BatteryBadge`, `SignalBars`, and `metricCard()`.

Preserve these comparison rules:

- Windows are aligned to Unix-epoch boundaries and use the per-source median.
- Canonical source ordering determines A-minus-B sign and export stability.
- Estimated readings are excluded from device comparison by default. So are interval averages (`Reading.isIntervalAverage`: longer than the metric's comparison window, such as Oura's night heart rate or daily SpO₂); they are never compacted, and charts draw them as spans. If a caller includes them, their pairs are timed `intervalAverage` and kept out of the threshold and statistics.
- RMSSD and pNN50 use adjacent normal-to-normal pairs only. Confidence intervals use a t quantile on an AR(1) effective sample size of touching windows; the limits of agreement stay at 1.96 SD.
- At least five paired windows are required before drawing a conclusion.
- Insufficient evidence and out-of-tolerance data can never be presented as green merely because an alert preference is disabled.
- Bland-Altman limits use sample variance.
- UI chart thinning is presentation-only; statistics and exports use the full paired set.
- Compare, metric detail, the pair screen, and Now each resolve one immutable snapshot per load in `.task(id:)`, built off the main actor from a `HealthStore.history` value: `ComparisonSnapshot`, `MetricDetailSnapshot`, `PairwiseSnapshot`, and `DashboardSnapshot`. All subviews share one resolved interval, gestures change only lightweight `@State`, and late results are rejected. Reloads caused only by new data are coalesced by `LiveReloadPolicy`: once a second on Now, and at most 30 per chart bucket elsewhere. A screen that trails ingest says so with `SnapshotLagNote`. Metric detail's zoomed span (`MetricZoomSnapshot`) and chosen period (`MetricPeriodEvidence`) load the same way, each under its own key. A selection is never part of a load key, so a scrub never reads the store.
- A saved session's `ComparisonPeriod` travels with every drill-down. Screens opened from a session show `ComparisonSessionBanner`, never the rolling range picker.
- Zoom changes only what a chart draws. `ChartViewport` re-reads the visible span at its own bucket, never finer than the metric's comparison window. Statistics, pairs, and the per-device table keep describing the whole analysed period.
- A period brushed on the metric-detail chart is evidence for exactly those seconds. `MetricPeriodEvidence` uses the same read and engine call as metric detail does for a saved session over them. `ChartViewport.snappedPeriod` rounds both ends to whole seconds, because the sessions archive stores ISO-8601 dates without fractions; a saved period then reopens with identical bounds.

Preserve measurement semantics:

- Measured, derived, and estimated provenance are distinct.
- Oura `average_hrv` maps to RMSSD, not HealthKit SDNN.
- Oura temperature deviation is not an absolute body-temperature reading and must not be compared as one. Its trend is drawn around a zero baseline and labelled as a deviation.
- The Oura hypnogram, movement, and trend charts draw Oura's cached classifications and daily values as they are. Runs are timed from `bedtime_start` or from the activity day's `timestamp`, which is optional because older caches lack it. Without a start time a card keeps its untimed ribbon; never guess a clock. Undefined codes and missing days are gaps. Trends read only cached documents and add no request or scope.
- VO2 max and blood-pressure models stay labelled as estimates, keep their disclaimers, and stay outside device-disagreement claims.
- A comparison measures agreement between devices; it does not establish which device is a medical reference standard.

## SwiftUI and UIKit Conventions

The application is SwiftUI-first and targets iOS 18:

- Use Observation environment state, the iOS 18 `Tab` API, `NavigationStack`, `List`/`Form`, sheets, toolbars, `refreshable`, and Swift Charts consistently with nearby screens.
- Liquid Glass: the theme owns every glass call. `HeartSyncCardBackground` (behind `metricCard()` and `ouraCard()`), `heartSyncGlassCapsule(tint:)`, `GlassChipRow`, `heartSyncButtonStyle(prominent:)`, `heartSyncChrome()`, and `heartSyncScreenBackground()` use glass on iOS 26+ behind `#if compiler(>=6.2)` (CI's macos-15 runner builds with Xcode 16) and `#available`, and fall back to the earlier material styling with the same geometry. Do not call `glassEffect` or the glass button styles directly from a screen. Tab roots use `.toolbarTitleDisplayMode(.inlineLarge)` so the title shares the toolbar row; that title owns the leading edge, so toolbar items on those screens go trailing (a `topBarLeading` item is not shown). The tab bar does not minimize on scroll: a minimized bar hides the other tabs, which UI tests and users reach for directly. Never tint glass with a colour that would change a semantic meaning (severity, source).
- Prefer existing semantic components in `Sources/Views/Components.swift` (including `FlowLayout` for wrapping chips) and the existing Oura card helpers before introducing another visual vocabulary. Content cards share one surface, `HeartSyncCardBackground`.
- Chart heights, inks, band opacity, and `axisFormat(span:)` come from `HeartSyncTheme.Chart`. Size every history chart with `heartSyncChartHeight(_:)`, which grows with Dynamic Type and the available width, never a fixed `.frame(height:)`.
- A chart whose automatic Audio Graph would name series by source ID gets an `AXChartDescriptorRepresentable` (`ChartAudioGraph.swift`) that names devices.
- A screen that loads a snapshot per key shows "Updating for the new selection…" and dims and disables the old results while the question has changed, as Compare and metric detail do.
- Now: only a streaming Bluetooth source can be labelled Live (`SourceChipStatus`). Sparklines draw completed-window medians only and are cached until the window closes. Motion honours Reduce Motion.
- Now keeps each enabled device's last reading of a metric for `DashboardSnapshot.recentHorizon(for:)` (seven days; 30 for daily summaries) through one bounded `LIMIT 1` read per device (`HealthDatabase.latest(kind:sourceID:midpointIn:)`). Such a row is `isCurrent == false`, listed after the live rows, never compared, and a card with no live row says "Last reported … Not a live value." Verdicts still come from the live windows only.
- The Now brief (`NowBriefFacts`, `NowBriefCheck`, `NowBriefGenerator`) is written on the device by Apple's language model from one sentence per card and shown only if `NowBriefCheck` accepts it: every number belongs to the reading it is said of, an estimate is called one and a measurement is not, a reading that is not live keeps its age, and no judgement word, diagnosis, or reading the facts lack appears. Three attempts, then no brief. Regenerated when the rounded facts change, at most every three minutes. Nothing leaves the device; without Apple Intelligence (or on iOS 18) there is no brief.
- Layout adapts to size class: `.sidebarAdaptable` tabs, an adaptive grid on Now, and a split view on Compare in regular widths.
- Use SF Symbols, semantic system colors, monospaced digits for measurements, and existing source colors.
- Keep empty, loading, unavailable, insufficient-evidence, and estimated states explicit. Do not hide uncertainty to make a screen look complete.
- Add accessibility labels/hints for icon-only controls and compound measurement rows, following existing views.
- Keep business, parser, network, and statistical logic out of SwiftUI view bodies. Compute one immutable analysis snapshot and pass it through where a view needs multiple projections.
- Keep large point sets bounded for chart rendering with the existing thinning approach; do not thin analysis/export inputs.
- Break every line, band, and area at data gaps with `ChartSegmentation`, keying series by segment, and draw isolated samples as points. Use `.monotone` or `.linear` interpolation; never use a curve that can overshoot the samples.
- Draw statistical reference lines (bias, limits, zero, tolerances) in the neutral ink and dash tokens of `HeartSyncTheme.Chart`, never in a hue a device could wear. Give each source its slot's shape as well as its colour (`DataSource.symbol`, `SourceSymbolGlyph` in legends).
- Make an interactive chart a view of its own (`MetricDetailChart`, `PairwiseTimelineChart`, `PairwiseDifferenceChart`, `OuraTimelineChart`, `OuraTrendChart`, `OuraHeartRateChart`), so a touch-move re-evaluates only the chart. Lookups during a scrub use arrays sorted once per load (`ChartLookup`); nothing reads the store or scans every mark per frame.
- Scrub with `chartXSelection(value:)` and the sticky rule:
  - snap to the nearest drawn item within `ChartLookup.selectionRadius` (22 pt, converted to seconds from the measured width);
  - keep the selection when the finger lifts;
  - clear it on a touch in empty plot area.

  A two-dimensional plot selects with a tap in `chartOverlay` and a screen-space nearest-point search. Tick `.sensoryFeedback(.selection, trigger:)` on the snapped item, not the raw value. Fit callouts inside the chart with `overflowResolution` `.fit(to: .chart)` on both axes.
- Pin each history chart's x domain with `chartXScale(domain:)`, so an empty stretch stays visibly empty. Zoom and pan move that pinned domain through `ChartViewport` and buttons. Do not switch to `chartScrollableAxes` or `chartXVisibleDomain` without re-testing FB12584128 (the selection annotation disappears) and FB14091989 (changing the visible domain jumps the chart).
- Give every chart gesture a path that needs no gesture: buttons (zoom, pan, Previous and Next, Clear selection) or named accessibility actions. Label each plotted item for VoiceOver with its value and caveats, and hide the lines, bands, and callouts that repeat it.
- A `List` row that holds several buttons needs `.buttonStyle(.borderless)`; otherwise a tap anywhere in the row triggers all of them.
- Removing a source or disconnecting Oura goes through the confirmation dialog in `DevicesView`, which states the consequence with `SourceRemovalConsequence`. Never attach a destructive action to a full swipe.

UIKit is used only where the platform API requires it:

- OAuth supplies an `ASWebAuthenticationSession` presentation anchor by finding/retaining an active `UIWindow`.
- Pairwise export, and the per-source export offered before removal (`ReadingsShareSheet`), wrap `UIActivityViewController` with `UIViewControllerRepresentable`.

There are no storyboards or XIBs. Do not introduce UIKit architecture for an isolated SwiftUI feature.

## Platform Constraints and Capabilities

- Minimum deployment targets: iOS 18.0 and watchOS 11.0.
- Supported device families: iPhone and iPad.
- Mac Catalyst is disabled. “Designed for iPhone/iPad” execution on Apple silicon is not a supported native macOS target and does not validate device integrations.
- iPhone supports portrait and both landscape orientations. iPad declares all four orientations.
- Real Bluetooth and meaningful HealthKit behavior require a physical iPhone; simulator builds only validate compilation, pure logic, mocked networking, and fixture-driven UI.
- The app declares base HealthKit and HealthKit background-delivery entitlements; the HealthKit access array is empty. The background-delivery capability and provisioning remain unverified on a signed physical-device build.
- The shipped plist contains Bluetooth and Health privacy descriptions, the Oura custom URL scheme, and `bluetooth-central` background mode.
- The watch app and its WidgetKit extension share one App Group for complications. There are no iPhone App Groups, Keychain sharing groups, iCloud/CloudKit containers, local/push notification code, notification extensions, or BGTaskScheduler registrations. The watch uses WatchConnectivity; it has no HealthKit, workout-processing, or route/location capability.

Any new capability must be explicitly requested and must update `project.yml`, generated resource files, signing/provisioning, documentation, and validation. Do not infer that a capability exists because a system framework is imported.

## Naming and Code Style

Follow the conventions already present rather than applying a new formatter:

- Four-space indentation.
- PascalCase types and lowerCamelCase members.
- Preserve established acronym spelling: `HRV`, `SpO2`, `Oura`, `HealthKit`, and `sourceID`.
- One principal type or closely related group per file, with descriptive file names.
- `// MARK:` sections in larger types.
- `///` comments for public-to-the-module contracts, invariants, unit conversions, concurrency assumptions, and medical/evidence limitations.
- Early `guard` returns and small, narrowly scoped `private` helpers.
- `private(set)` for observable state that views may read but not freely mutate.
- Value-oriented domain models with `Sendable` and appropriate `Codable`/`Hashable`/`Identifiable` conformances.
- Trailing commas in multiline literals and calls.
- Exhaustive enum switches so new metric/endpoint cases force a complete audit.
- Oura DTO snake_case fields are an intentional wire-format exception, not a general Swift naming convention.
- Tests use human-readable `@Suite` and `@Test` labels with small, explicit fixtures.

There is no SwiftLint or SwiftFormat configuration. Do not add sweeping formatting changes to feature or bug-fix work.

## Project Generation and Build Commands

XcodeGen is required. `project.yml` is authoritative; `HeartSyncChecker.xcodeproj` is ignored generated output.

After changing targets, source membership, build settings, plist properties, capabilities, signing, or entitlements:

```sh
xcodegen generate
```

Review changes to `project.yml`, `Resources/Info.plist`, and `Resources/HeartSyncChecker.entitlements`. Because `GENERATE_INFOPLIST_FILE` is `NO`, confirm that the built `HeartSync.app` actually contains the required privacy, URL-scheme, orientation, and background-mode keys. Never patch `project.pbxproj` or an `.xcscheme` as the durable fix.

Inspect generated targets and currently available destinations:

```sh
xcodebuild -list -project HeartSyncChecker.xcodeproj
xcodebuild -project HeartSyncChecker.xcodeproj \
  -scheme HeartSyncChecker \
  -showdestinations
```

Portable unsigned simulator compilation:

```sh
xcodebuild build \
  -project HeartSyncChecker.xcodeproj \
  -scheme HeartSyncChecker \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/HeartSyncChecker-DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Compile the hosted test bundle even when no simulator runtime is available:

```sh
xcodebuild build-for-testing \
  -project HeartSyncChecker.xcodeproj \
  -scheme HeartSyncChecker \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/HeartSyncChecker-TestDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

For a signed device build, first select an actual device reported by `-showdestinations`, then use the configured automatic signing team:

```sh
xcodebuild build \
  -project HeartSyncChecker.xcodeproj \
  -scheme HeartSyncChecker \
  -configuration Debug \
  -destination 'platform=iOS,name=<device name>' \
  -allowProvisioningUpdates
```

The repository currently pins development team `7RLDYXQTNX`. Do not silently replace it; signing-team changes are checkout/deployment decisions and can affect HealthKit provisioning.

## Tests

The hosted unit bundle uses Apple's Swift Testing package (`import Testing`, `@Suite`, `@Test`, `#expect`, and `#require`). Watch payload, projection, freshness, and companion HealthKit identity regressions are in `Tests/Watch` and `Tests/HealthKitConversionTests.swift`; count declarations from the current source rather than relying on an older total. The UI bundle uses XCTest/XCUIAutomation, and the separate performance bundle uses Swift Testing:

- `Tests/AnalysisTests.swift`: 53 tests covering HRV, comparison/windowing/statistics/evidence, chart thinning, estimators, Oura mapping, debug fixtures, and stable identifiers.
- `Tests/ParsingTests.swift`: 25 tests covering binary reads and GATT measurement parsing, including units, optional fields, PLX status fields, and invalid frames.
- `Tests/OuraOAuthTests.swift`: 13 tests covering exact authorization URL/scopes, callback/state/token metadata, scope-related 401 behavior, expiry, and compatibility behavior.
- `Tests/OuraDataTests.swift`: 14 tests covering decoding, snapshot/upsert behavior, injected-`URLProtocol` request/error behavior, and the Oura heart-rate chart series (window anchoring, unparseable timestamps, and plot thinning).
- `Tests/PairwiseExportTests.swift`: 10 tests covering stable schemas, canonical A/B semantics, aggregation evidence, RFC escaping, evidence language, metadata isolation, UTC, and fallback output.
- `Tests/SourceColourSeparationTests.swift`: 8 tests covering least-worn and random slot
  choice, repair of devices sharing a slot, paused devices yielding, and re-enabling.
- `Tests/HealthStoreTests.swift`: 38 tests covering validation, indexed queries, batch ingestion, deletion, persistence safety, retention, and bounded compaction.
- `Tests/ReadingArchiveTests.swift`: 20 tests covering envelopes, legacy payloads, unique corrupt preservation, unreadable-file handling, and Oura cache compatibility.
- `Tests/HealthKitConversionTests.swift`: 19 tests covering type mappings, minimal read scope, self-source rejection and cleanup, writer identity, scaling, and deletion conversion.
- `Tests/OuraSyncTests.swift`: 35 tests covering endpoint isolation, pagination, scope failures, cache preservation, deletion reconciliation (including that aging out of the dashboard cache withdraws nothing), cache/database failure rollback, truncation, battery timestamps, rate-limit backoff and the early stop, the minimum interval, a clear during a running sync, and Keychain reads that fail versus find nothing.
- `Tests/HRVFilterTests.swift`: 20 tests covering artefact filtering, body-location versus technology metadata, accumulator thresholds, and rate limiting.
- `Tests/AppSettingsTests.swift`: 2 tests covering unreadable-load write refusal and recovery.
- `Tests/ImprovementTests.swift`: 28 tests covering PLX admission, Bluetooth discovery/stream state, real HRV intervals, HealthKit outcomes and relationships, data minimization, transactional migration, rollback and deletion ordering, revisable estimates, and pairwise uncertainty.
- `UITests/HeartSyncCheckerUITests.swift`: 15 deterministic flows, which keep screenshots
  (`XCTAttachment`, `.keepAlways`) of key screens; CI runs them on an iPhone simulator only:
  - recovery and settings;
  - device actions, including removal that asks first and deletes only that device;
  - retention and evidence;
  - drill-down range and saved-session period;
  - metric-detail zoom, the stated bucket, and a chart period's Save as session sheet;
  - pair selection stepped with Next and cleared, without a drag;
  - Oura partial failure;
  - Now without connected sources (no Sources header, trend label, 44 pt target);
  - the `--chart-gallery` screenshot tour, in portrait and landscape;
  - the Oura hypnogram, movement, heart-rate, and fourteen-day trend charts
    (`--ui-test-ouraCharts`);
  - pseudo-localization.
- `Tests/HistoryOutcomeTests.swift`: 12 tests covering query outcomes after a successful
  startup (failure versus emptiness, retry, export failing visibly, paged export) and the
  compaction-honest per-device summary and whole-history export schema.
- `Tests/PresentationIdentityTests.swift`: 14 tests covering chart series keyed by stable
  source ID, duplicate-name disambiguation, rename stability, the Compare empty-state
  distinction, and chart line segmentation across data gaps.
- `Tests/PairTimingTests.swift`: 10 tests covering the pair timing policy — near/far samples
  inside one bucket, close samples across a boundary, bursty delivery, interval summaries,
  unknown timing from compacted rows, evidence grading, and sparse coverage.
- `Tests/AppModelTests.swift`: 20 tests over temporary files and inert transports covering saved retention across relaunch, unreadable/corrupt/newer-schema settings deleting nothing, a lost settings file not shortening a longer period, the user's choice lifting the hold, refresh gating, Oura throttling, the wrist sync-all (every transport asked in order, the 60-second bound, unconnected sources, before load, and the reply deadline), ring blood pressure surviving reconciliation, and a failed removal reporting.
- `Tests/StoreMaintenanceTests.swift`: 22 tests covering source mutations that roll back, estimate reconciliation scope, ingest not pruning, compaction across a pass boundary, SQL-counted retention impact and session summaries, sub-second payload dates, coarse last-seen updates, and CSV formula neutralisation.
- `Tests/HealthKitWriteBackTests.swift`: 7 tests covering the Gregorian date of birth and the write plan (sync identifier, device, scaling, refusals), the bounded queue, and refusal classification.
- `Tests/ComparisonSourceSelectionTests.swift`: 6 tests covering comparison-only source
  hiding, settings archive backward compatibility, and same-device pair disclosure.
- `Tests/ComparisonSessionTests.swift`: 11 tests covering fixed versus rolling periods,
  session persistence and reload, revisit disclosure, and missing sources.
- `Tests/SourceRemovalTests.swift`: 9 tests covering the per-source history count behind
  the removal dialog, failed counts reported as unknown, the per-source export, and the
  consequence wording for each transport.
- `Tests/DrillDownPeriodTests.swift`: 6 tests covering fixed-period resolution: a saved
  session's seconds reach metric detail, the pair analysis, and its export unchanged.
- `Tests/PairwiseSnapshotTests.swift`: 13 tests covering the pairwise snapshot: engine
  equality, binary-search and two-dimensional screen-space lookups against a linear scan,
  a stacked outlier selected on its own, empty-area taps, window stepping, the spoken
  summary, the pinned timeline domain, thinning disclosure, and query failure.
- `Tests/MetricDetailSelectionTests.swift`: 12 tests covering the metric-detail scrub:
  every window selectable (first and last included), empty-area touches, the callout's
  order, flags, and tolerance wording (never "agree"), estimates kept out of the spread,
  the callout's spread equal to the band, and the pinned x domain.
- `Tests/ChartZoomTests.swift`: 13 tests covering `ChartViewport` zoom, pan, and the live
  edge, the finer re-read at the zoomed bucket and its failure, period snapping to buckets
  and whole seconds, and the brushed period's statistics and saved bounds matching a saved
  session's.
- `Tests/OuraChartTests.swift`: 16 tests covering timed sleep-stage and movement runs,
  undefined codes as gaps, legacy caches without `timestamp`, legend coverage including
  non-wear, fourteen-day trends (gaps, first document per day, main sleep, spoken summary,
  temperature as a signed deviation), the chart UI fixture, and heart-rate selection.
- `Tests/LiveReloadTests.swift`: 8 tests covering the reload-coalescing rule and the
  bounded Now read, which shows the same values and verdicts as the two-day read.
- `Tests/ChartGapTests.swift`: 12 tests covering shared gap segmentation for the band,
  the pairwise timeline, and Oura heart rate, including isolated points and thinning.
- `Tests/RingVitalsTests.swift`: 15 tests covering blood-oxygen and blood-pressure
  measurement, sensor codes, the history request against a published capture, history
  transfer (acknowledgement, empty types, bad CRC, silence, cancel, overflow), record
  decoding, clock guards, local wall-clock conversion, estimate provenance, and stable IDs.
- `Tests/NowRecentReadingsTests.swift`: 7 tests covering spot readings kept on Now with their
  age, blood pressure from yesterday, the horizon, the newest earlier reading, old rows kept
  out of a live verdict, paused devices, and the bounded latest-reading query.
- `Tests/StressModelTests.swift`: 18 tests covering robust statistics, the hour-of-day
  aggregate, typical/stressed/relaxed scores and their drivers, the exercise gate, missing
  signals and baselines, per-source HRV scales, smoothing, secondary signals, freshness,
  bands, storage as a slot estimate, baseline lifetime, the metric's contract, and the ring
  stress check.
- `Tests/RingTemperatureTests.swift`: 6 tests covering the temperature start request, a
  refusal storing nothing, completion reading memory and reporting the new value, only an
  old record, no contact, and live measurements reading no memory.
- `Tests/NowBriefTests.swift`: 11 tests covering the facts' order and caveats, the coarse
  key, accepted model drafts, numbers tied to their reading, estimate wording, kept ages,
  judgement and diagnosis, readings the facts lack, and longest-name matching.
- `Tests/Watch/WatchChartTests.swift`: 23 tests covering chart payload compatibility and
  validation, the 1H/3H/24H/7D/30D periods and their windows, per-period evidence, empty periods,
  the long-period cache and its invalidation (only by removals that reach a period, routine
  pruning kept, the bounded removal record), one read sliced into every period, palette
  colours and shared-slot shapes, pair choice and threshold, estimate marking, the size drop
  order and its single encode, axis ticks, gap segmentation, domains, and spoken text.
- `Tests/Watch/WatchChartSelectionTests.swift`: 7 tests covering the wrist chart selection:
  windows grouped across sources at the drawn dates, snapping inside the radius and nothing
  in empty plot area, the radius in seconds, VoiceOver stepping, the popup's time span, and
  the spoken window and difference.
- `Tests/Watch/WatchSyncReportTests.swift`: 6 tests covering the sync-all reply's round trip
  and rejection of impossible, newer, and oversized replies, its lines, and the Health and
  Oura outcome rules (never synced for a run that predates the request or met a rate limit).
- `Tests/ExportStreamingTests.swift`: 8 tests covering keyset export pages (rows sharing an
  end, one source), one snapshot across a mid-export deletion, the off-main writer against
  the whole-string export, progress, Cancel and empty exports leaving no file, a not-loaded
  store, the export job, the launch sweep, and pairwise files written together.
- `Tests/RingSessionTests.swift`: 28 tests covering the YCBT codec (CRC check value,
  framing, reassembly, bad CRC and length, the identity reply's battery bytes), the battery
  query, topology selection, subscription gating,
  identification, warm-up and completion, no contact, rejection, timeouts, cancel and repeat,
  heart-rate-only readiness, control channels, late callbacks, stall diagnosis, raw-capture
  bounds, command stages, and stream cadence.
- `Tests/DashboardTrendTests.swift`: 8 tests covering Now sparklines (window medians, gaps,
  single points, spans, spoken summary, per-window caching), chip status, and the
  `--chart-gallery` fixture.
- `Tests/ComparisonHonestyTests.swift`: 13 tests covering interval averages (no windowed pair, no compaction, never concluding), session titles across days, RMSSD adjacency, the t quantile and effective sample size, and clock skew.
- `Tests/HistoryReaderTests.swift`: 9 tests covering off-main snapshots, reader visibility of commits, column and payload decoding, SQL source filters, failures and not-loaded history, temporary files, and the schema-3 migration and backfill.
- `Tests/ResetAndIngestTests.swift`: 11 tests covering reset order and exclusivity, batched Bluetooth ingest, batched existence checks, changed-source persistence, and launch-time transport setup.
- `Tests/PeripheralStateTests.swift`: 6 tests covering `PeripheralLink`, `RingLink`, and `PeripheralRecord`.
- `Tests/ColourVisionTests.swift`: 12 tests. They pin the Machado/CAM02-UCS validator to
  published values and enforce ΔE ≥ 15 in ordinary vision between all source slots, and
  under protan, deutan, and tritan simulation between the first six slots, against the
  reference-line ink, and between sleep stages. They
  also cover 3:1 graphical contrast and stable per-slot shapes.
- `PerformanceTests/HealthStorePerformanceTests.swift`: the manual physical-iPhone
  fourteen-day 1 Hz indexed persistence workload, plus:
  - a two-source month-range comparison;
  - range changes during ingestion;
  - the paged export flow;
  - Now and a 30-day detail during 1 Hz ingest, against initial main-thread budgets that
    are still to be confirmed on a device;
  - an hour of strap ingest, batched against per-value commits, reporting commits per minute.

There is no snapshot-test target, live Oura test, Bluetooth hardware integration-test target, or HealthKit integration-test target.

Do not use `swift test` on this project; it is a hosted Xcode unit-test bundle in an
XcodeGen iOS project, not a SwiftPM package.

When no iOS simulator runtime is usable (check `xcrun simctl list runtimes`; a runtime can be listed as unavailable when its profile does not match the installed Xcode), `build-for-testing` proves compilation only. To
actually execute the pure logic, build a **scratch** SwiftPM package outside the repository
and copy or symlink the real source files into it — `Sources/Store`, `Sources/Model`,
`Sources/Analysis`, `Sources/Views/MetricDetailSnapshot.swift`,
`Sources/Views/ComparisonEmptyReason.swift`, the other Foundation-only view projections
(`DashboardSnapshot`, `PairwiseSnapshot`, `ChartSegmentation`, `LiveReloadPolicy`,
`SourceRemovalConsequence`, `WindowLabel`, `ChartLookup`, `ChartViewport`,
`MetricChartProjection`, `ReadingsExportJob`, `NowBrief`, `NowBriefGenerator`, `Oura/OuraSleepStage`, `Oura/OuraCategoryTimeline`,
`Oura/OuraMovementClass`, `Oura/OuraDailyTrend`), `Shared`, plus
`Sources/Bluetooth/GATT.swift` for `BodySensorLocation` (CoreBluetooth exists on macOS, so it needs no shim, and
`R11MRingSession`), the Foundation-only Bluetooth files (`BluetoothDiagnostics`,
`BluetoothDiscoveryState`, `YCBTFrameCodec`, `YCBTHistory`, `R11MRingSession`, `Measurements`,
`BinaryReader`, `BluetoothIngestionPolicy`), and `Sources/Debug`'s `DebugChartGallery`. The Oura timeline and trend
projections also need the Foundation-only DTOs in `Sources/Oura/OuraClient.swift`. That closure builds for macOS and runs the store, analysis,
export, presentation-projection and watch-lifecycle suites. Adding `BluetoothManager`,
`HealthKitManager` (and its `+Session`/`+WriteBack` files), `OuraManager`, `OuraData`, `AppModel`,
`WatchCompanionPublisher`, `WatchSnapshotBuilder`, `BackgroundWork`, `BluetoothIngestBuffer`,
`PeripheralState`, `HealthHistory`, `DerivedEstimates`, `HealthKitManager+Background`,
and `Sources/Debug` lets the
`AppModel`, Oura orchestration, and HealthKit conversion suites run too, with two harness-only
stand-ins: a `CompanionSession` stub (WatchConnectivity does not exist on macOS) and a copy of
`Sources/Oura/OuraOAuth.swift` with its UIKit window lookup replaced. It cannot compile the SwiftUI
screens (they import UIKit), the UI tests, or `WatchApp`, and it has no string catalog, so
plural-dependent wording resolves to each `defaultValue`. Never add `Package.swift` to the
repository itself.

Run all tests against an installed simulator. Do not hard-code a model that may not exist on the current machine; discover a destination first and prefer its ID:

```sh
xcodebuild test \
  -project HeartSyncChecker.xcodeproj \
  -scheme HeartSyncChecker \
  -destination 'platform=iOS Simulator,id=<simulator UDID>' \
  -derivedDataPath /tmp/HeartSyncChecker-TestDerivedData
```

Use test filters only during iteration. Before completion, run the whole affected suite and, for shared models/store/transport changes, the full test target. A successful `build-for-testing` proves test compilation only; it does not prove that tests executed.

When adding behavior:

- Add parser vectors for byte-order, flags, units, truncation, and special values.
- Add Oura request/decoding/permission tests through the injected `URLSession`; do not depend on a live account.
- Add comparison/export fixtures that pin evidence state, canonical ordering, statistics, stable IDs, and CSV semantics.
- Use `HealthStore(persistenceEnabled: false)` where a unit test must not touch Application Support.
- Add `@MainActor` to tests that construct or mutate main-actor-isolated state.

## Validation Before a Task Is Complete

Validation must match the changed surface. A compile is necessary after meaningful Swift/project changes, but it is not sufficient for runtime/UI or device-integration work.

Always:

1. Inspect `git diff` and `git status`; make sure only intended files changed and no generated artifacts or secrets were added.
2. Regenerate with XcodeGen if project metadata or generated plist/entitlement inputs changed.
3. Build every affected target through the `HeartSyncChecker` scheme.
4. Run the appropriate test suites, then the complete test target for shared model, store, parser, transport, or project-setting changes.
5. Fix compiler errors and all warnings introduced by the change. Record unrelated pre-existing/environment warnings rather than disguising them.
6. Verify persisted-data compatibility for `Codable`, enum raw-value, stable-ID, or archive changes.
7. Verify error, empty, insufficient-evidence, permission-denied, and cached-data paths—not only success paths.

Use additional validation by area:

| Area changed | Required checks |
| --- | --- |
| SwiftUI layout/state | Launch the app, exercise the affected flow, inspect iPhone and iPad/adaptive layouts as relevant, verify accessibility and non-success states. Use `--pairwise-demo` for deterministic comparison UI without persistence or transports. |
| Bluetooth | Run parser/unit tests and validate scan, connect, notifications, disconnect/reconnect, and restoration on a physical iPhone with representative hardware. Confirm off-body/invalid frames stay rejected. |
| HealthKit | Validate authorization wording, partial access, reads, optional measured-only writes, anchors, foreground refresh, and background delivery on a physical iPhone with Health data. Do not use the simulator as final evidence. |
| Oura API/OAuth | Run mocked transport/OAuth tests; for integration changes, verify the exact live callback, partial-scope behavior, cached partial results, 401 classification, and no secret/token leakage. Avoid destructive account actions. |
| Comparison/statistics | Run all analysis and export tests; verify minimum evidence, canonical A/B sign, units, estimated-value exclusion, alert-off behavior, full-set statistics, and presentation-only thinning. |
| Persistence | Test round-trip and failure recovery, coalesced-save effects, existing archives, corrupt-file preservation, and migration behavior. Preserve user data. |
| Project/capability/privacy | Regenerate, inspect resolved build settings, build signed when capability behavior is involved, and inspect the shipped app's Info.plist/entitlements. Launch once to catch TCC/privacy-key failures. |
| Export/share | Verify CSV/summary tests, share-sheet presentation, correct metadata, and temporary-directory cleanup after dismissal. |

`--pairwise-demo` is a Debug-only launch argument that installs deterministic in-memory fixtures and skips normal archive loading and all transports. It is the preferred safe UI fixture mode, but it does not validate persistence, Bluetooth, HealthKit, or Oura.

`--chart-gallery` is a Debug-only launch argument that installs thirty days of in-memory readings from `DebugChartGallery`: four sources (two named alike), gaps, estimates, and compacted windows. It starts no transport and saves nothing. The chart previews and the screenshot UI test use it.

`--ui-test-ouraCharts` is the Debug-only UI-test scenario for the Oura charts. It installs fourteen days of in-memory Oura documents, with a charging gap, a missing night, and a missing readiness day, and fetches and persists nothing. Like the other `--ui-test-*` scenarios, it does not validate the Oura API or OAuth.

## Fragile and Tightly Coupled Areas

Exercise extra caution around:

- XcodeGen source-of-truth versus ignored generated project files.
- The `HeartSyncChecker` target/module versus `HeartSync` product/test-host naming split.
- Privacy strings, OAuth URL type, HealthKit entitlement, Bluetooth background mode, automatic signing, and the shipped plist/entitlements.
- CoreBluetooth's nil-queue/main-actor delegate assumption and required strong peripheral references.
- Binary parser field ordering, sensor validity flags, RR units, and IEEE-11073 special values.
- Stable reading/source IDs and enum raw values that persist across launches.
- HealthKit source identity, authorization ambiguity, deletion sync to the store (exports and compacted aggregates may not reverse), fixed 30-day query window, and measured-only write-back.
- Oura endpoint path casing, pagination limit, sequential orchestration, cross-file scope mappings, nuanced 401 handling, and preservation of cached collections after partial failures.
- SQLite transaction/migration markers, indexed query semantics, file protection for the
  database/WAL, and the separate representative-device 1 Hz performance gate.
- Metric unit normalization and the RMSSD/SDNN and absolute/deviation distinctions.
- Comparison evidence thresholds, epoch windowing, sample-variance statistics, canonical sign, and the rule that insufficient evidence is never green.
- Estimate provenance/disclaimers and exclusion from device agreement.
- `CompareView` snapshot reuse and bounded chart rendering; avoid repeated O(n) analysis in subviews.
- OAuth window/presentation-anchor lifetime and pairwise share-sheet temporary-file cleanup.

When a comment and implementation disagree, document the discrepancy and test actual behavior before “fixing” either side. In particular, HealthKit source IDs currently use only the writing source bundle identifier even though one model comment suggests device-model uniqueness.

## Things Agents Must Not Do

- Do not manually edit `HeartSyncChecker.xcodeproj`, `project.pbxproj`, generated schemes, `build`, `DerivedData`, or `.xcresult` output as a durable change.
- Do not commit credentials, bearer tokens, Oura client secrets, Health data, generated archives, or personal Xcode user state. Do not log or export tokens.
- Do not store the OAuth bearer token in `UserDefaults`, `Info.plist`, JSON, or `@AppStorage`.
- Do not erase all Oura cache data for one endpoint failure or treat every 401 as token expiry.
- Do not reintroduce local scope-name gating ahead of the Oura server.
- Do not write estimated values to HealthKit or present them as direct measurements.
- Do not include estimated values in device agreement by default or imply that either device is a clinical reference.
- Do not present fewer than five paired windows as a supported agreement/disagreement conclusion.
- Do not map Oura RMSSD to HealthKit SDNN or convert temperature deviation into absolute temperature.
- Do not change stable IDs, source IDs, persisted enum raw values, or non-optional `Codable` fields without a migration/compatibility plan.
- Do not silently delete undecodable archives; preserve the `.corrupt` recovery behavior.
- Do not duplicate `MetricKind`, store, parser, comparison, estimator, OAuth, or export logic in a view or a new parallel service.
- Do not change the CoreBluetooth queue while retaining `MainActor.assumeIsolated` delegate handling.
- Do not weaken validity checks or parser units to accommodate one device without representative frames and regression tests.
- Do not claim proprietary/vendor BLE support beyond the topology-gated YCBT candidate, and do not describe that candidate as verified until a device run in `RELEASE_CHECKLIST.md` records it. Never select a vendor path from a device name, and never write to a characteristic before its session's gating says so.
- Keep Apple Watch data on the HealthKit import. Do not send measurements into the iPhone store over WatchConnectivity or treat the wrist display snapshot as new measurements.
- Do not claim App Groups, CloudKit, Keychain sharing, widgets, notifications, or background tasks that are not configured.
- Do not use a simulator build as proof that BLE, HealthKit, background delivery, signing, OAuth presentation, or TCC/privacy behavior works.
- Do not add broad abstractions, dependencies, style rewrites, or unrelated refactors for a narrowly scoped task.
- Do not change signing, bundle identifiers, callback URLs, capability settings, medical/evidence language, or retention behavior as incidental cleanup.

## Agent Workflow

1. **Inspect relevant existing code before modifying anything.** Read `project.yml`, the owning model/manager/view, nearby tests, and any persistence/capability contract touched by the request. Check the current worktree and preserve unrelated user changes.
2. **Reuse existing abstractions and patterns.** Route measurements through `Reading`/`DataSource` and `HealthStore`; use `MetricKind`, parsers, type mappings, `ComparisonEngine`, exporters, fixtures, Observation, and the existing injection seams instead of creating parallel logic.
3. **Make the smallest coherent change necessary.** Keep behavior, schema, identity, concurrency, and capability changes within explicit scope. Do not perform unrelated refactors or formatting sweeps.
4. **Build affected targets after meaningful changes.** Regenerate first when needed, then build the `HeartSyncChecker` scheme. Remember that this builds the `HeartSync` product and that hosted tests depend on that exact product path.
5. **Run appropriate tests.** Start with focused Swift Testing suites, then run the full test target for changes that cross shared models, storage, transport, analysis, or project boundaries. Distinguish test compilation from test execution.
6. **Fix compiler errors and warnings caused by the change.** Maintain Swift 6 complete-concurrency correctness; do not suppress warnings that reveal isolation, Sendable, availability, or API-contract problems.
7. **Check for regressions across related targets.** Exercise relevant failure/permission/empty states, persisted-data compatibility, and a real-device or live-flow check where framework behavior cannot be simulated. A build alone is not runtime validation.
8. **Summarize what was changed and any unresolved concerns.** Report files and behavior affected, builds/tests/runtime checks actually completed, anything not testable in the current environment, data/capability implications, and remaining risks without overstating confidence.
