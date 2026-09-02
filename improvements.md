# HeartSync — Improvement Notes

A review of the code as it stands at `6f52d71`. Everything below was found by reading the
sources; the app builds cleanly for `generic/platform=iOS Simulator` with no warnings from
this codebase. Nothing here has been changed.

Items are grouped by kind and ordered roughly by impact within each group. Where a claim
needs a physical device to confirm, that is said explicitly.

---

## 1. Correctness

### 1.1 Mirroring to Apple Health creates a phantom "HeartSync" device that compares against itself

**High.** When `mirrorBluetoothToHealthKit` is on, [`AppModel.ingest`](Sources/App/AppModel.swift:99)
writes measured Bluetooth readings into HealthKit. The anchored queries that read HealthKit
back use only a date predicate ([`recentPredicate`](Sources/Health/HealthKitManager.swift:255))
and [`convert`](Sources/Health/HealthKitManager.swift:265) derives the source ID from
whichever app wrote the sample:

```swift
let sourceID = "hk.\(hkSource.bundleIdentifier)"
```

HealthKit always returns an app its own samples, so every mirrored reading comes straight
back as `hk.com.heartsync.HeartSyncChecker`. The consequences:

- A source called "HeartSync" appears in the device list beside the real sensors.
- It is a byte-for-byte copy of the chest strap's stream, so `ComparisonEngine` pairs the
  strap against it and reports **perfect agreement over thousands of windows** — the single
  most misleading result this app can produce, in an app whose entire thesis is honest
  device disagreement.
- Every mirrored reading is stored twice, doubling the archive for that metric.

**Fix:** drop the app's own samples in `convert`, which is `static` and pure, so this is
directly unit-testable:

```swift
guard hkSource.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
```

Alternatively compound the query predicate with
`NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))`.
The `convert` filter is preferable: it also cleans up history already written by a build
that had mirroring enabled, and it can be tested without a device.

### 1.2 The "Now" screen calls devices "in agreement" using readings up to 15 minutes apart

**High.** [`MetricCard`](Sources/Views/DashboardView.swift:113) computes:

```swift
let spread = (values.max() ?? 0) - (values.min() ?? 0)
let severity = values.count >= 2 ? kind.agreement.severity(forDelta: spread) : .agreeing
```

over `model.liveValues(kind:)`, which is
[`latestBySource`](Sources/Analysis/ComparisonEngine.swift:293) with its default
`staleAfter: 15 * 60`. So one device's reading may be 14 minutes old and the other's one
second old, and the `AgreementBadge` still renders "Agree within 3 bpm" or "12 bpm apart ·
Major gap" from that pair.

This is exactly the failure mode the README calls out — *"raw pairwise comparison would
mostly measure timing offsets"* — reintroduced on the app's primary screen. The Compare tab
gets it right with epoch-aligned windows; the Now tab does not, and the two screens can
contradict each other for the same devices at the same moment.

**Fix options, in order of preference:**

1. Build the badge from one `ComparisonEngine.windows(...)` pass over the current window
   instead of from `latestBySource`, so Now and Compare use the same rule.
2. Failing that, only show the badge when the contributing readings fall inside
   `kind.comparisonWindow` of each other, and label the row "last reported 12 min ago —
   not compared" otherwise.

Either way the per-row `deltaFromConsensus` in
[`SourceValueRow`](Sources/Views/Components.swift:55) has the same problem and needs the
same gate.

### 1.3 Write-back mirrors readings the store rejected

**Medium.** [`AppModel.ingest`](Sources/App/AppModel.swift:91) guards on `accepted > 0` and
then filters the *input* array, not the accepted subset:

```swift
guard accepted > 0 else { return }
...
let mirrorable = readings.filter { ... }
```

A batch containing one new reading and nine duplicates writes all ten to HealthKit. Today
the Bluetooth path delivers one reading at a time so the practical impact is small, but the
seam is shared and any future batching Bluetooth source would silently duplicate the user's
health record. Have `HealthStore.append(contentsOf:)` return the accepted readings (or their
IDs) rather than just a count, and mirror from that.

### 1.4 An Oura authorization failure leaves a collection stuck on "syncing"

**Medium.** [`OuraManager.load`](Sources/Oura/OuraManager.swift:297) sets
`endpointStates[endpoint] = .syncing` before the request. On a non-scope 401 it calls
`handleAuthorizationFailure` and throws `SyncAbort.authorization`
([line 324](Sources/Oura/OuraManager.swift:324)) **without** resetting that endpoint's
state. The Oura tab then shows a permanent spinner on that collection until the next
successful sync — and there will not be one, because the credential was just cleared.

**Fix:** set `endpointStates[endpoint] = .failed(message)` before throwing, and reset the
still-`.idle` endpoints so the screen reflects "not attempted" rather than "in progress".

### 1.5 The HRV artefact filter does not do what its comment says, and stalls after a sustained rate change

**Medium.** [`HRVCalculator.filterArtefacts`](Sources/Analysis/HRVCalculator.swift:51) is
documented as a *successive-difference* filter — *"A genuine sinus rhythm does not jump more
than ~20% from one beat to the next"* — but the implementation compares each interval to an
exponentially-weighted running reference, not to its predecessor:

```swift
let deviation = abs(interval - reference) / reference
if deviation <= maximumSuccessiveChange {
    clean.append(interval)
    reference = reference * 0.8 + interval * 0.2
}
```

Two separate issues:

- **Comment/implementation mismatch.** Per `AGENTS.md`, this should be resolved by
  documenting actual behaviour and testing it, not by "fixing" one side blind. The current
  tests (*"A single ectopic beat does not inflate RMSSD"*) pass under either reading, so
  they do not pin the distinction down.
- **The reference only updates on accepted beats.** Going from rest (~1000 ms) to exercise
  (~600 ms) is a 40% shift: every new interval is rejected, so `reference` never moves, so
  every subsequent interval is rejected too. `artefactFraction` climbs past
  `maximumArtefactFraction` and HRV emission stops. It self-heals only once the old slow
  beats age out of the 5-minute window, because `filterArtefacts` re-seeds from the median
  on each call — so the user loses roughly one window of HRV on every meaningful pace
  change. Add test vectors for a ramping rate and consider seeding the reference from a
  rolling median of the last *N* accepted intervals.

### 1.6 Oura `day` strings are parsed in the phone's current time zone

**Low.** [`OuraClient.dayFormatter`](Sources/Oura/OuraClient.swift:501) uses
`timeZone = .current`. Oura's `day` is the ring's local day. After the user flies across
time zones, the same document decodes to a different `start`, which shifts it into different
comparison windows. Reading IDs are stable (derived from the document ID), so `upsert`
correctly replaces rather than duplicates — but the historical window alignment silently
changes. Consider pinning to UTC and treating the day boundary explicitly, or storing the
originating offset alongside the reading.

### 1.7 `presentationAnchor` force-unwraps a window

**Low.** [`OuraOAuth.swift:225`](Sources/Oura/OuraOAuth.swift:225) is
`presentationWindow!`. The comment argues it is captured before the session starts, which is
true for the normal path — but `ASWebAuthenticationSession` can ask for the anchor again,
and the completion handler nils the field. A defensive fallback to
`Self.activePresentationWindow()` costs nothing and removes a crash from an OAuth flow.

### 1.8 Loading settings immediately schedules a save of what was just loaded

**Low.** [`AppSettings.snapshot`](Sources/Store/AppSettings.swift:28) has
`didSet { scheduleSave() }`, and [`loadIfNeeded`](Sources/Store/AppSettings.swift:52)
assigns to it. Every launch therefore re-writes `settings.json` one second later with
identical content. Harmless, but it means a launch always dirties the file — assign through
a private setter that skips the save on hydration.

---

## 2. Performance

The store is designed for "tens of thousands of readings" (see the
[`HealthStore` header](Sources/Store/HealthStore.swift:5)). A single 1 Hz chest strap at the
default 30-day retention produces about **2.6 million**. The items below are fine at the
documented scale and become serious well before the retention limits the UI actually offers.

### 2.1 The dashboard rescans the entire archive about 20 times per second

**High.** [`DashboardView`](Sources/Views/DashboardView.swift:14) ticks a
`Timer.publish(every: 1)` into `@State`, invalidating the whole view every second. On each
pass:

- [`visibleMetrics`](Sources/Views/DashboardView.swift:65) calls
  `model.liveValues(kind:)` once per available metric (up to 10).
- Each [`MetricCard`](Sources/Views/DashboardView.swift:108) calls it *again*.

`liveValues` is [`store.readings(kind:)`](Sources/Store/HealthStore.swift:164) with no range
— a full `filter` over every reading ever stored, allocating a fresh array each time, plus a
fresh `Set(enabledSources.map(\.id))` per call. That is up to 20 full passes and 20 large
allocations per second on the main thread.

**Fix:** apply the pattern `AGENTS.md` already prescribes and `CompareView` already uses —
build one immutable snapshot per render and pass it to the cards. Layering on top:

- Give `readings(kind:in:)` a range so it does not scan history for a live view.
- Consider indexing the store by `MetricKind` (a `[MetricKind: [Reading]]` alongside the
  flat array) so per-metric queries stop being O(total).
- The 1 Hz tick only exists to keep relative timestamps honest; SwiftUI's
  `Text(_:format: .relative)` already self-updates, so the timer may be removable outright.

`visibleMetrics` also sorts with `MetricKind.allCases.firstIndex(of: lhs)!` *inside* the
comparator — an O(n) lookup per comparison plus two force-unwraps. Precompute the index map.

### 2.2 `MetricDetailView` recomputes its windowing roughly eight times per render

**High.** [`chartWindows`](Sources/Views/MetricDetailView.swift:161) is a computed property
that re-reads the store and re-runs `ComparisonEngine.windows`. It is consumed through three
other computed properties, each of which is itself read multiple times in the body:

| Accessor | Read at |
| --- | --- |
| `points` | `points.isEmpty` (:25), chart `ForEach` (:102), `yDomain` (:212) |
| `bandPoints` | footer (:40), chart `ForEach` (:92) |
| `sourcesInRange` | `legend` (:129), `styleDomain` (:205), `styleRange` (:206) |

That is eight full store scans plus eight bucketing passes, and then
[`perSourceStats`](Sources/Views/MetricDetailView.swift:242) and
[`pairwiseAnalyses`](Sources/Views/MetricDetailView.swift:262) each do another scan — the
latter also running full pairwise analysis. Ten passes over the archive to draw one screen.
Hoist a single `let` snapshot at the top of `body`, exactly as
[`CompareView`](Sources/Views/CompareView.swift:14) and
[`PairwiseAnalysisView`](Sources/Views/PairwiseAnalysisView.swift:36) already do.

### 2.3 Ingest is O(n) per reading and schedules a save per reading

**High.** [`HealthStore.append`](Sources/Store/HealthStore.swift:117):

- `readings.lastIndex { $0.end <= reading.end }` scans backwards — cheap for in-order live
  data, O(n) for the out-of-order batches the comment itself anticipates.
- `readings.insert(at:)` is an O(n) memmove *regardless* of position.
- `scheduleSave()` runs at the end of **every** call, and
  [`append(contentsOf:)`](Sources/Store/HealthStore.swift:138) loops over it. Importing a
  4,000-point Oura heart-rate batch creates and cancels 4,000 `Task`s.

**Fix:** add a batch path that validates and de-duplicates the whole array, merges it in one
pass (both sides are sorted, so a linear merge beats *m* insertions), and calls
`scheduleSave()` once at the end.

### 2.4 `upsert(contentsOf:)` is O(n·m)

**High.** [Line 153](Sources/Store/HealthStore.swift:153) does
`readings.firstIndex(where: { $0.id == reading.id })` — a *forward* scan from index 0 over
the entire array, for every incoming reading. With a large local history and a 14-day Oura
batch, this is the worst hot spot in the store, and it runs on the main actor every 15
minutes. `knownReadingIDs` already exists as a `Set<UUID>`; extend it to a
`[UUID: Int]` index, or an `OrderedDictionary`-style structure, so identity lookup is O(1).

### 2.5 The Oura tab hits the Keychain about 34 times per render

**Medium.** [`hasAuthorization`](Sources/Oura/OuraManager.swift:52),
`authorizationExpiresAt`, `reportedGrantedScopes` and `missingRequestedScopes` each perform
`OuraOAuthCredentialStore.load()` — a `SecItemCopyMatching`, a base64 decode, and a JSON
decode. [`OuraDashboardView`](Sources/Views/OuraDashboardView.swift) reads
`hasAuthorization` 14 times per body, and
[`scopeState`](Sources/Views/OuraDashboardView.swift:958) runs once per requested scope (10
of them), doing two loads each.

Beyond the cost: these are *not* observable state, so SwiftUI has no dependency on them.
Views only happen to refresh because `status` changes nearby. Cache the credential in an
observable `private(set) var` on `OuraManager`, refreshed on authorize/disconnect/sync, and
let Observation drive invalidation properly.

### 2.6 Oura sync refetches everything every 15 minutes, and parses every response twice

**Medium.** [`OuraManager.sync`](Sources/Oura/OuraManager.swift:156) issues 19 sequential
requests covering a rolling 14-day window on every cycle, including collections that
essentially never change (`personal_info`, `ring_configuration`). At the default 900-second
interval that is ~1,800 requests a day re-downloading the same fortnight.

Separately, [`OuraClient.get`](Sources/Oura/OuraClient.swift:458) decodes the error envelope
before checking the status code:

```swift
let detail = (try? JSONDecoder().decode(APIProblem.self, from: data))?.bestMessage
switch http.statusCode {
case 200...299: break
```

so every successful response — including multi-megabyte heart-rate pages — is fully JSON
parsed twice. Move that line into the non-2xx branches.

For the sync itself: keep a per-collection high-water mark and request only new days, with a
periodic full backfill. `AGENTS.md` correctly warns against parallelising these requests
(endpoint status, 401 classification and cached-data preservation are coupled to the
sequential flow) — narrowing the *window* achieves most of the win without touching that.

### 2.7 The Bluetooth scan sorts and invalidates on every advertisement packet

**Medium.** [`startScan`](Sources/Bluetooth/BluetoothManager.swift:133) passes
`CBCentralManagerScanOptionAllowDuplicatesKey: true`, and
[`didDiscover`](Sources/Bluetooth/BluetoothManager.swift:406) responds to each packet with a
full `discovered.sort`. Since `discovered` is `@Observable`, every packet also invalidates
the scan sheet. In a busy room with `scanForAllDevices` on, that is a sustained stream of
sorts and view rebuilds — on top of the already power-hungry duplicate-allowing scan the 60
second timeout exists to bound.

Coalesce: update the backing dictionary on every packet, but publish and re-sort on a timer
(2–3 Hz is far more than the UI needs).

---

## 3. Storage and scale

### 3.1 The whole-file JSON archive is offered a retention setting it cannot support

[`SettingsView`](Sources/Views/SettingsView.swift:59) lets the user pick **1 year**.
`HealthStore` holds everything in memory and
[`saveNow`](Sources/Store/HealthStore.swift:250) re-encodes and rewrites the *entire*
readings array — coalesced to every 3 seconds while data streams. A year of 1 Hz data is
roughly 31 million `Reading` values; even 30 days is 2.6 million, at which point each save
is a multi-hundred-megabyte encode on a background actor with the full array snapshotted on
the main actor first.

The header comment already names the right seam. Concretely: either

- cap the offered retention at what JSON can carry and say why, or
- move to SQLite/SwiftData behind the existing `append` / `readings(kind:in:)` / `prune`
  API, with a tested migration. Downsampling readings older than a few days would also cut
  the problem by orders of magnitude and costs nothing analytically, since comparison
  already works on windowed medians.

### 3.2 The health archive gets no file protection and is not excluded from backup

[`ReadingArchive.write`](Sources/Store/ReadingArchive.swift:38) uses `options: .atomic` only,
so `readings.json` lands with the default protection class and is included in iCloud/iTunes
backups. The Keychain item is deliberately `…ThisDeviceOnly`
([Keychain.swift:30](Sources/Store/Keychain.swift:30)), but the actual health measurements —
arguably the more sensitive payload — get no equivalent treatment.

Add `.completeFileProtectionUnlessOpen` (not `.complete`: Bluetooth background delivery must
write while the device is locked), and decide deliberately whether the archive should carry
`isExcludedFromBackup`. Also, [`directory`](Sources/Store/ReadingArchive.swift:24) calls
`createDirectory` on every single access; hoist it to init.

### 3.3 No schema migration path

`ReadingArchive` preserves an undecodable file as `.corrupt` — good — but that is recovery,
not migration. Adding one non-optional `Codable` field to `Reading` or renaming a
`MetricKind` raw value orphans the user's entire history. A `schemaVersion` on the readings
and sources files (as `OuraSnapshot` already has) plus a versioned decode path would make
model changes routine instead of destructive.

---

## 4. Robustness

### 4.1 Pagination truncates silently

[`OuraClient.paged`](Sources/Oura/OuraClient.swift:418) stops after 25 pages and returns
whatever it has, with no signal. The endpoint is then marked `.available(count)` and the UI
presents a partial collection as complete. Return a "truncated" flag, or throw, so partial
data is labelled.

### 4.2 A 429 fails the whole collection

`Failure.rateLimited` carries `Retry-After` but nothing acts on it — the endpoint is marked
failed and the sync moves on. Given 19 sequential requests per cycle, one rate limit can
cascade. A bounded retry honouring `Retry-After`, plus backing off the sync timer, would make
partial syncs much rarer.

### 4.3 Bluetooth reconnection has no backoff or ceiling

[`didDisconnectPeripheral`](Sources/Bluetooth/BluetoothManager.swift:447) immediately calls
`connect(peripheral)` with no delay, no attempt counter, and no check that the radio is still
powered on. A device that connects and drops repeatedly produces a tight reconnect loop with
no visible end state. Add exponential backoff and surface "gave up — tap to retry" after a
few attempts. *(Needs a physical device to confirm the loop's real-world behaviour.)*

### 4.4 HealthKit deletions are ignored

Both anchored-query handlers discard the `[HKDeletedObject]` argument
([HealthKitManager.swift:180](Sources/Health/HealthKitManager.swift:180) and
[:213](Sources/Health/HealthKitManager.swift:213)). A sample the user deletes from Health
lives on in HeartSync and keeps contributing to comparisons. Honouring deletions needs a
store API for removal by ID plus a decision about what a deleted sample means for an already
exported analysis — worth designing, not patching.

### 4.5 Background delivery is requested without the entitlement

[`startObserving`](Sources/Health/HealthKitManager.swift:241) calls
`enableBackgroundDelivery(for:frequency:.hourly)`, but
`Resources/HeartSyncChecker.entitlements` does not declare
`com.apple.developer.healthkit.background-delivery`. Either add it (and verify on a signed
device build) or drop the call and the UI language that implies it. Right now the code
expresses an intent the app is not provisioned to fulfil.

---

## 5. Product and UX opportunities

### 5.1 Body sensor location is read from every device and thrown away

[`GATT.readOnceCharacteristics`](Sources/Bluetooth/GATT.swift:75) subscribes to Body Sensor
Location (0x2A38), and [`BodySensorLocation`](Sources/Bluetooth/GATT.swift:97) is fully
implemented, including:

```swift
/// Finger and wrist sensors are optical (PPG); chest sensors are electrical (ECG).
/// This matters for interpreting a discrepancy: PPG and ECG disagreeing on HRV is
/// expected behaviour, not a fault.
var isOptical: Bool { self != .chest }
```

Nothing reads it. [`didUpdateValueFor`](Sources/Bluetooth/BluetoothManager.swift:543) has no
case for the characteristic, so the value is fetched and discarded.

This is the single best-value unfinished feature in the codebase. The app is built to answer
"do these two devices agree?" and this is the field that answers the far more useful "*why
don't they?*". Surfacing it would let `PairwiseAnalysisView` say "an optical ring and an ECG
strap are not measuring the same signal — this gap is expected" instead of leaving the user
to infer it from a static HRV footnote. It requires: a case in `didUpdateValueFor`, a field
on `DataSource`, and a sentence in the interpretation text.

`plxFeatures` (0x2A60) and `firmwareRevisionString` (0x2A26) are likewise read and dropped —
the first would let the UI explain which optional PLX fields a device actually populates.

### 5.2 HRV mean heart rate and pNN50 are computed and discarded

[`HRVMetrics`](Sources/Analysis/HRVCalculator.swift:8) produces `pnn50` and `meanHeartRate`;
only `rmssd` and `sdnn` are ever emitted. The comment on `meanHeartRate` describes exactly
the feature that is missing:

> a useful cross-check against the HR the same device reports directly

A device whose reported HR disagrees with the HR implied by its own R–R intervals is
self-inconsistent — a *stronger* signal than two devices disagreeing, and one no other
screen in the app can surface. `artefactFraction` is likewise only used internally, though
"this HRV window rejected 22% of beats" is precisely the caveat the pairwise screen should
show next to an HRV comparison.

### 5.3 Oura onboarding requires the user to register their own OAuth application

[`OuraSetupView`](Sources/Views/OuraSetupView.swift:37) walks the user through creating an
Oura developer application, registering a redirect URI, and pasting a Client ID. That is a
sound choice for a serverless personal build and the reasoning is documented — but it is a
hard wall for anyone else, and the client-side flow issues no refresh token, so the user
repeats the OAuth dance roughly monthly. Worth an explicit decision: keep it and say so in
the README's positioning, or ship a first-party client ID (which does not require shipping a
secret, since the flow is client-side).

### 5.4 No localization at all

Zero uses of `NSLocalizedString` / `String(localized:)` and no String Catalog; every string
is a hardcoded English literal. That is a reasonable v1 stance, but it matters more than
usual here because a substantial fraction of those strings are **medical disclaimers** —
`Estimators.BloodPressureEstimate.disclaimer`, the "not a reference standard" language, the
insufficient-evidence wording. Shipping to a non-English user means shipping health caveats
they may not read. Adding a String Catalog now is mechanical; adding it after another
thousand lines of UI is not.

### 5.5 Accessibility is uneven

Five of eleven view files contain no accessibility modifiers at all:
`DevicesView`, `SettingsView`, `BluetoothScanView`, `OuraSetupView`, `InfoViews`.
`PairwiseAnalysisView` and `CompareView` are genuinely well done by comparison
(`accessibilityElement(children: .combine)`, chart hints, labelled drag targets), so this is
a consistency gap rather than a blind spot.

The concrete misses: `SourceRow` in `DevicesView` is a compound row (colour dot + status
dot + name + status text + battery + metric chips) that VoiceOver reads as disconnected
fragments; `BatteryBadge` has no label; the metric chips read as bare abbreviations ("RHR",
"SpO2"). Two icons use `.font(.system(size:))`
([Components.swift:107](Sources/Views/Components.swift:107),
[OuraDashboardView.swift:64](Sources/Views/OuraDashboardView.swift:64)) and so do not scale
with Dynamic Type — minor, since both are decorative.

---

## 6. Testing

The 99 existing tests are genuinely good: the parser vectors, evidence-state tests, and
"a threshold cannot produce a green result" cases pin down the things that actually matter.
The gaps are all on one side of the line.

### 6.1 The store, the archive, and HealthKit conversion have no tests

Every suite covers pure analysis, parsing, OAuth, or export. Nothing covers:

- **`HealthStore`** — de-duplication, plausibility rejection, sorted insertion of
  out-of-order batches, `prune` at the retention boundary, `remove(sourceID:)`. It is used
  incidentally in three fixtures and one Oura upsert test, but its own invariants are
  unpinned. Given §2.3/§2.4 propose rewriting exactly these paths, tests here are a
  prerequisite.
- **`ReadingArchive`** — the `.corrupt` preservation behaviour is called out in `AGENTS.md`
  as something agents must never break, and nothing verifies it. Injecting a directory URL
  would make it testable.
- **`HealthKitManager.convert`** — `nonisolated static`, pure, takes value types, needs no
  device. It owns the SpO₂ ×100 scale conversion and the source-ID formula, both flagged as
  migration-sensitive. It would also be the natural home for a regression test on §1.1.

### 6.2 One test writes to the real Application Support container

[`Tests/OuraDataTests.swift:191`](Tests/OuraDataTests.swift:191) constructs `HealthStore()`
with persistence on, against the project's own convention (`AGENTS.md`: *"Use
`HealthStore(persistenceEnabled: false)` where a unit test must not touch Application
Support"*). It writes `readings.json` and `sources.json` into the test host's container, so
the suite is order-dependent on any future test that reads them. One-word fix.

### 6.3 Tests cannot execute on this machine

No iOS simulator runtimes are installed (`xcrun simctl list runtimes` is empty), so only
`build`/`build-for-testing` can run here. The app target builds clean. This is an
environment gap, not a code issue, but it means none of the 99 tests have been *executed*
during this review.

---

## 7. Code health

### 7.1 Dead code and stale references

| Item | Where | Note |
| --- | --- | --- |
| `DeviceProfile` | [GATT.swift:8](Sources/Bluetooth/GATT.swift:8) | Doc comment points at a type that does not exist anywhere in the repo. |
| `BodySensorLocation`, `isOptical` | [GATT.swift:97](Sources/Bluetooth/GATT.swift:97) | Fully implemented, never referenced. See §5.1 — implement rather than delete. |
| `HRVMetrics.pnn50`, `.meanHeartRate` | [HRVCalculator.swift:14](Sources/Analysis/HRVCalculator.swift:14) | Computed, never surfaced. See §5.2. |
| `showEstimates` | [MetricDetailView.swift:12](Sources/Views/MetricDetailView.swift:12) | `@State` that is always `true`; no toggle exists. Either add the toggle (the chart already dashes estimate lines for it) or inline the constant. |
| `AppModel.dataVersion` | [AppModel.swift:22](Sources/App/AppModel.swift:20) | Incremented in four places, read nowhere. `AGENTS.md` already flags this. Delete it, or use it as the invalidation key its comment describes. |

### 7.2 `OuraDashboardView` is 1,422 lines

It is 12% of the entire codebase in one file, with around 30 computed section properties and
14 private helper types, against a stated convention of *"one principal type or closely
related group per file"*. Splitting by section (scores / biomarkers / heart / sleep /
movement / timeline / ring / OAuth) into their own files, each taking an `OuraSnapshot`
slice rather than reaching into `model`, would also make the sections independently
previewable and testable. Worth doing before the next feature lands in it.

### 7.3 Minor

- `HealthStore.deleteAllReadings()` clears `observedMetrics` but leaves `lastSeenAt`, so a
  wiped source still claims a recent sighting.
- `BluetoothManager.forget(sourceID:)` clears four dictionaries but not `pendingModelInfo`.
- The derived-metrics loop
  ([AppModel.swift:118](Sources/App/AppModel.swift:118)) uses `self?` inside
  `while !Task.isCancelled`, so it keeps looping every 300 s after the model is gone rather
  than returning. Immaterial for an app-lifetime object, but the Oura loop
  ([:251](Sources/App/AppModel.swift:251)) already does it correctly with
  `guard let self else { return }`.

---

## Suggested order

1. **§1.1** — one guard clause, removes the app's most misleading possible output.
2. **§1.2** — the primary screen contradicts the app's own stated method.
3. **§2.1 / §2.2** — mechanical snapshot hoisting, large win, pattern already established
   in `CompareView`.
4. **§6.1** — store and archive tests, as a prerequisite for the next item.
5. **§2.3 / §2.4** — batch ingest and O(1) identity lookup.
6. **§1.4, §4.1, §2.6** — the Oura sync's honesty and cost.
7. **§5.1** — the highest-value unfinished feature, and it is nearly built already.
8. **§3.1** — decide the storage ceiling before a user picks "1 year".
