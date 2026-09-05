# HeartSyncChecker Agent Guide

This file applies to the entire repository. It records the architecture and working conventions that are present in the code as of the current checkout. Treat the code, `project.yml`, and the tests as the final authority when they disagree with prose.

## Project at a Glance

HeartSync is a SwiftUI iOS 18+ application for collecting and comparing health measurements from three transport paths:

1. Standards-based Bluetooth Low Energy health sensors.
2. Apple Health/HealthKit, which is also the app's only path to Apple Watch data.
3. The Oura Cloud API through an OAuth bearer token.

All three paths normalize data into the same `DataSource` and `Reading` model. `AppModel` routes normalized readings into `HealthStore`, optional derived estimates, comparison analysis, and optional HealthKit write-back. The app is deliberately careful to distinguish measured, derived, and estimated data and to represent insufficient comparison evidence honestly.

The repository contains one iOS application module, one hosted Swift Testing bundle, one UI-test bundle, and a separate device-performance test bundle. There is no server, watchOS app, app extension, widget, framework target, or local Swift package.

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

- `HeartSyncApp` owns the single root `AppModel` in `@State`, injects it with `.environment(model)`, starts it in `.task`, and forwards `scenePhase` changes.
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
| `Sources/Bluetooth` | CoreBluetooth lifecycle, SIG GATT constants, safe binary reader, and typed measurement parsers. |
| `Sources/Health` | HealthKit authorization, anchored queries, unit/source conversion, background delivery, and measured-value write-back. |
| `Sources/Oura` | OAuth, Keychain-backed credentials, API transport/DTOs, endpoint status, token-free cache, sync orchestration, and scalar mapping. |
| `Sources/Analysis` | Comparison/windowing/statistics, HRV, estimators, and pairwise export. These are mostly pure or value-oriented. |
| `Sources/Views` | SwiftUI screens and reusable components, Charts usage, plus the narrow UIKit share-sheet bridge. |
| `Sources/Debug` | Deterministic pairwise demo fixtures guarded by `#if DEBUG`. |
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
| `HeartSyncChecker` | iOS application | All of `Sources` and the non-plist contents of `Resources` | Bundle ID `com.heartsync.HeartSyncChecker`; product/executable `HeartSync`; Swift module `HeartSyncChecker` |
| `HeartSyncCheckerTests` | Hosted iOS unit-test bundle | All of `Tests` | Imports `@testable import HeartSyncChecker`; explicit host is `HeartSync.app/HeartSync` |
| `HeartSyncCheckerUITests` | iOS UI-test bundle | All of `UITests` | Drives deterministic Debug-only launch scenarios; targets `HeartSyncChecker` |
| `HeartSyncCheckerPerformanceTests` | Hosted iOS unit-test bundle | All of `PerformanceTests` | Manual physical-device release workload; explicit host is `HeartSync.app/HeartSync` |

The `HeartSyncChecker` scheme runs the normal unit and UI bundles. `HeartSyncCheckerPerformance` isolates the intentionally large device workload from PR CI. Debug and Release configurations are generated.

The target/product/module naming difference is intentional and fragile: the target, scheme, and module are `HeartSyncChecker`, but the installed bundle and executable are `HeartSync`. Preserve `PRODUCT_NAME`, `PRODUCT_MODULE_NAME`, `TEST_HOST`, and `BUNDLE_LOADER` together.

There are no:

- watchOS, macOS, visionOS, tvOS, or Mac Catalyst targets;
- app extensions, widgets, notification extensions, or reusable framework targets;
- `Package.swift`, `Package.resolved`, SwiftPM package dependencies, CocoaPods, or Carthage dependencies.

The app uses only Apple system frameworks and libraries: SwiftUI, Observation, Charts, Combine, Foundation, OSLog, CoreBluetooth, HealthKit, AuthenticationServices, Security, UIKit, CryptoKit, and SQLite3. Tests use Foundation, Swift Testing, and XCTest/XCUIAutomation for the UI bundle.

## Shared Versus Platform-Specific Code

Every file under `Sources` is compiled into the one iOS app module. “Shared” in this repository means logically reusable code, not a separately compiled cross-platform module.

- Mostly value-oriented and reusable: `Sources/Analysis`, most of `Sources/Model`, `OuraClient`/Oura DTOs, `ReadingArchive`, and stable IDs.
- iOS/UI-specific: `Sources/App` and `Sources/Views`.
- Framework-specific: `Sources/Bluetooth` for CoreBluetooth, `Sources/Health` for HealthKit, and the OAuth presentation code in `Sources/Oura/OuraOAuth.swift` for AuthenticationServices/UIKit.
- Security-specific: `Sources/Store/Keychain.swift` and CryptoKit-based `StableID.swift`.

Do not assume the model layer can already be moved into a Foundation-only package: `DataSource`, `MetricKind`, and `Discrepancy` currently import SwiftUI for presentation colors.

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

`AppModel.dataVersion` is incremented during ingest, but no current view reads it. Do not assume that it drives invalidation; Observation on the actual store/managers is the active mechanism.

## Concurrency Conventions

The XcodeGen settings enable Swift 6 with complete strict-concurrency checking.

- UI-visible mutable state and transport orchestration stay on `MainActor`.
- Domain values, DTOs, parser results, and analysis inputs are generally value types conforming to `Sendable` and, where useful, `Codable`/`Hashable`/`Identifiable`.
- `ReadingArchive` is an actor and is the explicit off-main boundary for JSON file I/O.
- Networking uses `async`/`await` and `URLSession.data(for:)`.
- Authentication and HealthKit callback APIs are bridged to async continuations or explicit `Task { @MainActor in ... }` hops.
- Repeating work uses cancellable `Task` loops. The derived-estimate loop runs every 300 seconds; Oura auto-sync has a 300-second minimum; BLE scanning has a 60-second timeout.
- Use `Task {}` to bridge synchronous SwiftUI/framework callbacks into isolated work. Long-lived tasks should check cancellation and weakly capture app-lifetime owners where the existing code does so.
- Do not use detached work to mutate observed state.

CoreBluetooth has an important actor assumption. `BluetoothManager` creates `CBCentralManager` with `queue: nil`, so delegate callbacks arrive on the main queue. Delegate requirements are `nonisolated` and use `MainActor.assumeIsolated`; state restoration also contains a documented `nonisolated(unsafe)` handoff for framework objects. Do not change the central-manager queue, remove those bridges, or copy that pattern to callbacks without an equivalent queue guarantee.

HealthKit callbacks convert framework samples into Sendable value data inside the callback and then hop to `MainActor`. Keep non-Sendable `HKSample` objects out of unconstrained tasks.

Oura endpoint requests currently run sequentially. Do not casually convert them to a task group: endpoint status, token invalidation, partial-permission behavior, cached-data preservation, and API rate behavior are coupled to the current flow. `OuraClient` also has shared `nonisolated(unsafe)` ISO-8601 formatters that must be re-audited before concurrent use is expanded.

## Bluetooth Architecture

`BluetoothManager` owns scanning, restoration, connection/reconnection, discovery, notification handling, source metadata, and ingestion. Strong references to peripherals are mandatory; removing them can silently break connections.

Supported measurement paths are Bluetooth SIG standards, not arbitrary vendor protocols:

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

HRV is derived per peripheral with `HRVAccumulator`/`HRVCalculator`, artifact rejection, a five-minute window, at least 20 clean beats, and rate-limited emission. Preserve those semantics and their tests.

The restoration identifier is `com.heartsync.central`. `UIBackgroundModes = bluetooth-central` enables CoreBluetooth background/restoration behavior; it is not a generic background-execution entitlement.

## HealthKit and Apple Watch Architecture

There is no watchOS app and no WatchConnectivity code. Apple Watch measurements arrive only after HealthKit syncs them to the iPhone. Do not add or imply direct Apple Watch BLE access.

`HealthKitManager.TypeMapping` owns the HealthKit identifier, metric, unit, and scale. Current reads include heart rate, resting heart rate, SDNN HRV, oxygen saturation, respiratory rate, VO2 max, body temperature, and blood pressure. HealthKit oxygen saturation is a fraction and is multiplied by 100 on ingestion. There is no HealthKit RMSSD mapping.

Authorization and synchronization rules:

- Read types include the supported measurements plus birth date. Biological sex is not
  requested or retained because no current feature uses it.
- Share types are restricted to directly measurable BLE-compatible metrics: heart rate, oxygen saturation, SDNN, and body temperature.
- Completion of the HealthKit authorization sheet does not prove that each read permission was granted. Do not make the UI claim otherwise.
- Anchored queries request a recent 30-day window and then install update handlers. Local retention settings do not imply a one-year HealthKit backfill.
- Background delivery is requested hourly. There are no `BGTaskScheduler` identifiers or task handlers.
- The committed entitlements declare `com.apple.developer.healthkit.background-delivery`, and the code requests hourly delivery. The capability still needs to be enabled for the App ID/provisioning profile and exercised with a signed build on a physical device; do not describe background wake behavior as guaranteed until that validation succeeds.
- Anchored queries apply HealthKit deletions: `HealthKitManager.deletedReadingIDs` maps each `HKDeletedObject.uuid` to a reading id (the same sample UUID used at ingest), and `AppModel.ingest` commits source updates, readings, and deletions from one anchor page through `HealthStore` in a single transaction. Unknown ids are a no-op. Remaining limits: an already-exported pairwise analysis is unchanged; after compaction, raw sample UUIDs are gone so an upstream deletion cannot remove the stable window median that replaced them.
- Optional write-back is allowed only for `.measured` readings from Bluetooth sources. Estimated or HealthKit/Oura-originating values must never be written back.

HealthKit readings currently use `hk.<source bundle identifier>` as the source ID and keep the device model as metadata. A nearby model comment describes a more specific identity than the implementation supplies. Treat the implemented ID formula as migration-sensitive; changing it can split or duplicate historical sources.

The manager starts each process with authorization state `.notDetermined`, and startup synchronization depends on current manager state. Relaunch behavior, enabling write-back after prior read-only authorization, and per-type permissions require on-device validation before changing their UI or lifecycle behavior.

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
- The bearer credential is stored in the device-only Keychain, not UserDefaults or the JSON archive.

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
- Oura records are upserted because a stable cloud record can be corrected.
- Stable identity comes from framework sample IDs or `UUID(stableFrom:)` recipes. Identity changes require migration analysis; otherwise a refresh can duplicate or orphan history.
- Reading and source mutations commit transactionally and incrementally. The database indexes stable ID, metric/time, source/time, and end time. Settings persistence remains one-second coalesced. Startup refuses to attach transports until the database and any pending legacy migration are conclusive; an unavailable protected file is retried rather than treated as empty.
- Default reading retention is 30 days and can be configured by the existing settings model. Before pruning, readings at least 14 days old are irreversibly compacted to one median per source/comparison window. New compacted rows preserve original count and standard deviation; migrated legacy medians represent unavailable facts as unknown. A compacted window is final: late rows and cloud revisions for it are rejected because the discarded distribution cannot be recombined without median-of-medians bias.

`HealthDatabase` stores `health.sqlite3` plus its WAL/SHM companions under Application Support in the `HeartSync` directory. A durable metadata marker makes the version-1 JSON migration retry across process termination. `ReadingArchive` continues to serialize the small ISO-8601 JSON archives atomically and supplies the legacy migration inputs:

- `readings.json`
- `sources.json`
- `settings.json`
- `oura-dashboard-v1.json`

JSON writes use a versioned envelope and reads retain compatibility with the earlier bare-payload format. If a file can be opened but cannot be decoded, the actor preserves it under a unique timestamped `.corrupt-*` name instead of silently deleting it. If it exists but cannot be opened, the actor leaves it untouched and reports it as unreadable. Beyond the explicit JSON-to-SQLite reading/source migration there is no general payload schema-migration layer. Adding or changing non-optional `Codable` fields, enum raw values, or stable-ID formulas can invalidate or duplicate user history and needs an explicit compatibility plan plus tests.

The database, WAL/SHM files, and JSON writes explicitly use complete file protection until first user authentication. This keeps them usable while locked after the first unlock, which is necessary for ordinary Bluetooth background collection. The boot-to-first-unlock gap remains; retryable startup guards are what prevent that gap from overwriting history. Do not change this to complete protection or complete-unless-open without re-evaluating the background path. Files remain eligible for encrypted device backups so Bluetooth-only history can be restored; the bearer credential remains device-only in Keychain.

The Oura snapshot is schema-versioned and token-free. Its `schemaVersion` is recorded but there is no implemented general migration mechanism.

OAuth credentials are encoded as one Keychain generic-password value using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. No Keychain access group is configured, so the item is not shared and does not migrate through iCloud. The Oura client ID is deliberately public configuration in `@AppStorage`; never put the bearer token there.

HealthKit query anchors use `UserDefaults` keys prefixed with `hk.anchor.`. Pairwise exports use per-export temporary directories and remove them after the share sheet is dismissed.

The version-1 whole-file reading/source archives are migration inputs only. Do not reintroduce a parallel reading persistence path beside SQLite. Compaction bounds old high-frequency history but still sacrifices individual samples, the full within-window distribution, and later corrections; preserve its explicit aggregation metadata and unknown legacy evidence.

There is no Core Data, SwiftData, CloudKit, App Group container, shared Keychain group, or remote database.

## Analysis and Data-Integrity Invariants

These abstractions encode product correctness and should be reused rather than reimplemented:

- `MetricKind`: title, unit, symbol, color, plausible range, chart range, tolerance, comparison window, continuous/discrete behavior, and formatting. Adding a case requires auditing every exhaustive switch, mapping, view, and test.
- `Reading`, `DataSource`, `SourceTransport`, and `Provenance`: canonical normalized record types.
- `UUID(stableFrom:)`: deterministic import identity.
- `HealthStore`: ingestion, validation, de-duplication, querying, pruning, and persistence seam.
- `ComparisonEngine`: epoch-aligned windows, per-source medians, pairing, evidence state, discrepancies, and Bland-Altman statistics.
- `PairwiseExporter`: stable CSV and summary semantics, RFC 4180 escaping, UTC formatting, and explicit source metadata.
- `HRVCalculator`/`HRVAccumulator`: RR filtering and HRV derivation.
- `Estimators`: estimated VO2 max and blood-pressure trend rules/provenance.
- `Components.swift`: `SourceDot`, `SourceValueRow`, `AgreementBadge`, `EmptyStateView`, `EstimateDisclaimer`, `BatteryBadge`, `SignalBars`, and `metricCard()`.

Preserve these comparison rules:

- Windows are aligned to Unix-epoch boundaries and use the per-source median.
- Canonical source ordering determines A-minus-B sign and export stability.
- Estimated readings are excluded from device comparison by default.
- At least five paired windows are required before drawing a conclusion.
- Insufficient evidence and out-of-tolerance data can never be presented as green merely because an alert preference is disabled.
- Bland-Altman limits use sample variance.
- UI chart thinning is presentation-only; statistics and exports use the full paired set.
- `CompareView` intentionally creates one `ComparisonSnapshot` per render so all subviews use the same time boundary and do not repeat expensive windowing.

Preserve measurement semantics:

- Measured, derived, and estimated provenance are distinct.
- Oura `average_hrv` maps to RMSSD, not HealthKit SDNN.
- Oura temperature deviation is not an absolute body-temperature reading and must not be compared as one.
- VO2 max and blood-pressure models stay labelled as estimates, keep their disclaimers, and stay outside device-disagreement claims.
- A comparison measures agreement between devices; it does not establish which device is a medical reference standard.

## SwiftUI and UIKit Conventions

The application is SwiftUI-first and targets iOS 18:

- Use Observation environment state, the iOS 18 `Tab` API, `NavigationStack`, `List`/`Form`, sheets, toolbars, `refreshable`, and Swift Charts consistently with nearby screens.
- Prefer existing semantic components in `Sources/Views/Components.swift` and the existing Oura card helpers before introducing another visual vocabulary.
- Use SF Symbols, semantic system colors, monospaced digits for measurements, and existing source colors.
- Keep empty, loading, unavailable, insufficient-evidence, and estimated states explicit. Do not hide uncertainty to make a screen look complete.
- Add accessibility labels/hints for icon-only controls and compound measurement rows, following existing views.
- Keep business, parser, network, and statistical logic out of SwiftUI view bodies. Compute one immutable analysis snapshot and pass it through where a view needs multiple projections.
- Keep large point sets bounded for chart rendering with the existing thinning approach; do not thin analysis/export inputs.

UIKit is used only where the platform API requires it:

- OAuth supplies an `ASWebAuthenticationSession` presentation anchor by finding/retaining an active `UIWindow`.
- Pairwise export wraps `UIActivityViewController` with `UIViewControllerRepresentable`.

There are no storyboards or XIBs. Do not introduce UIKit architecture for an isolated SwiftUI feature.

## Platform Constraints and Capabilities

- Minimum deployment target: iOS 18.0.
- Supported device families: iPhone and iPad.
- Mac Catalyst is disabled. “Designed for iPhone/iPad” execution on Apple silicon is not a supported native macOS target and does not validate device integrations.
- iPhone supports portrait and both landscape orientations. iPad declares all four orientations.
- Real Bluetooth and meaningful HealthKit behavior require a physical iPhone; simulator builds only validate compilation, pure logic, mocked networking, and fixture-driven UI.
- The app declares base HealthKit and HealthKit background-delivery entitlements; the HealthKit access array is empty. The background-delivery capability and provisioning remain unverified on a signed physical-device build.
- The shipped plist contains Bluetooth and Health privacy descriptions, the Oura custom URL scheme, and `bluetooth-central` background mode.
- There are no App Groups, Keychain sharing groups, iCloud/CloudKit containers, widgets, local/push notification code, notification extensions, WatchConnectivity sessions, or background-task registrations.

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

The hosted unit bundle uses Apple's Swift Testing package (`import Testing`, `@Suite`, `@Test`, `#expect`, and `#require`). It currently contains 268 test declarations in 38 suites. The UI bundle uses XCTest/XCUIAutomation, and the separate performance bundle uses Swift Testing:

- `Tests/AnalysisTests.swift`: 53 tests covering HRV, comparison/windowing/statistics/evidence, chart thinning, estimators, Oura mapping, debug fixtures, and stable identifiers.
- `Tests/ParsingTests.swift`: 22 tests covering binary reads and GATT measurement parsing, including units, optional fields, PLX status fields, and invalid frames.
- `Tests/OuraOAuthTests.swift`: 13 tests covering exact authorization URL/scopes, callback/state/token metadata, scope-related 401 behavior, expiry, and compatibility behavior.
- `Tests/OuraDataTests.swift`: 14 tests covering decoding, snapshot/upsert behavior, injected-`URLProtocol` request/error behavior, and the Oura heart-rate chart series (window anchoring, unparseable timestamps, and plot thinning).
- `Tests/PairwiseExportTests.swift`: 10 tests covering stable schemas, canonical A/B semantics, aggregation evidence, RFC escaping, evidence language, metadata isolation, UTC, and fallback output.
- `Tests/HealthStoreTests.swift`: 38 tests covering validation, indexed queries, batch ingestion, deletion, persistence safety, retention, and bounded compaction.
- `Tests/ReadingArchiveTests.swift`: 20 tests covering envelopes, legacy payloads, unique corrupt preservation, unreadable-file handling, and Oura cache compatibility.
- `Tests/HealthKitConversionTests.swift`: 19 tests covering type mappings, minimal read scope, self-source rejection and cleanup, writer identity, scaling, and deletion conversion.
- `Tests/OuraSyncTests.swift`: 23 tests covering endpoint isolation, pagination, scope failures, cache preservation, deletion reconciliation, cache/database failure rollback, truncation, and battery timestamps.
- `Tests/HRVFilterTests.swift`: 20 tests covering artefact filtering, body-location versus technology metadata, accumulator thresholds, and rate limiting.
- `Tests/AppSettingsTests.swift`: 2 tests covering unreadable-load write refusal and recovery.
- `Tests/ImprovementTests.swift`: 28 tests covering PLX admission, Bluetooth discovery/stream state, real HRV intervals, HealthKit outcomes and relationships, data minimization, transactional migration, rollback and deletion ordering, revisable estimates, and pairwise uncertainty.
- `UITests/HeartSyncCheckerUITests.swift`: 7 deterministic recovery, settings, device-action, retention, evidence, Oura-partial, and pseudo-localization flows.
- `PerformanceTests/HealthStorePerformanceTests.swift`: the manual physical-iPhone fourteen-day 1 Hz indexed persistence workload.

There is no snapshot-test target, live Oura test, Bluetooth hardware integration-test target, or HealthKit integration-test target.

Do not use `swift test`; this is a hosted Xcode unit-test bundle in an XcodeGen iOS project, not a SwiftPM package.

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
- Do not claim proprietary/vendor BLE support. The current implementation supports standards-compliant GATT profiles only.
- Do not add a watchOS target or WatchConnectivity path merely because Apple Watch data appears in the product; HealthKit is the current architecture.
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
