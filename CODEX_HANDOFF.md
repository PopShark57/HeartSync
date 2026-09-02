# Historical handoff — improvements.md fixes completed

**Completion update (2026-09-02):** This handoff has been executed. The blocking ring-battery
timestamp conversion is fixed; the external SwiftPM harness now executes 95 portable tests
with no failures; the HealthStore compaction cursor, AppSettings unreadable-load guard,
persisted HealthKit self-source cleanup, dashboard visible-source filtering, and legacy Oura
snapshot decoding have been corrected and regression-tested where the host permits. The app
build and hosted test-bundle compilation succeed. No iOS simulator runtime is installed, so
the 212 hosted iOS test declarations and UI/device flows were not executed here.

The remaining work is external or requires an explicit product decision:

- Enable HealthKit background delivery for the App ID/provisioning profile and validate it
  with a signed physical-iPhone build.
- Supply a first-party Oura client ID if this is meant to ship without personal developer
  setup; no distribution client ID is currently preconfigured.
- Decide whether irreversible old-reading compaction should stay automatic or become an
  explicit opt-in. The UI now discloses exactly what it preserves and discards.

Everything below is retained as the pre-completion snapshot that drove this work; statements
such as “nothing is committed” and the 20-test harness result describe that earlier state.

**Written:** 2026-09-02 · **For:** Codex (or whoever picks this up next)
**Repo:** `/Users/owner/HeartSyncChecker` · **Branch:** `master` (tracks `origin/main`)

The task was *"fix everything in improvements.md"*. Most of it is done and **all of it is
uncommitted**. This document is the state of play, what is verified, what is not, and what is
left — in the order I would do it.

---

## 1. Verified state, right now

I ran these immediately before writing this file. Re-run them before trusting anything here;
they take a few minutes and are the only source of truth.

| Check | Result |
| --- | --- |
| `xcodebuild build` (app target) | ✅ **BUILD SUCCEEDED**, zero warnings from this codebase |
| `xcodebuild build-for-testing` (hosted test bundle) | ✅ **TEST BUILD SUCCEEDED** |
| SwiftPM harness (`swift test`, see §6) | ⚠️ **20 tests, 19 pass, 1 fails** — the failure is a *real bug*, see §4 |
| Xcode test execution | ❌ **Impossible on this machine** — no iOS simulator runtime installed |

```bash
xcodegen generate && xcodebuild build -project HeartSyncChecker.xcodeproj \
  -scheme HeartSyncChecker -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/hs-build CODE_SIGNING_ALLOWED=NO
```

> **`xcrun simctl list runtimes` is empty.** `build-for-testing` is the ceiling for the real
> project. Anything claiming the 119 tests "pass" is claiming something nobody has observed.
> The harness in §6 is the workaround, and it is partial.

**Nothing is committed.** `git status` shows ~30 modified files plus new ones. HEAD is still
`75e56c7` (the improvements.md commit), and [PR #1](https://github.com/PopShark57/HeartSync/pull/1)
contains only that document, not these fixes.

---

## 2. What is done

All 30-odd findings in [improvements.md](improvements.md) have implementations. Highlights,
because a few are subtle:

**§1.1 — HealthKit phantom self-comparing device (the worst bug).**
`HealthKitManager.convert` now drops samples whose `sourceRevision.source.bundleIdentifier`
is the app's own, *and* the anchored-query predicate excludes `HKSource.default()`. Belt and
braces was deliberate: the `convert` filter also cleans up history already written by a build
that had mirroring on, which the predicate alone would not.

**§1.2 — the Now screen comparing readings 15 minutes apart.**
`DashboardView` builds one snapshot per render and the agreement badge is gated on genuinely
aligned `ComparisonEngine` windows, so Now and Compare can no longer contradict each other.

**§2.3/2.4 — store ingest.** `append/upsert(contentsOf:)` return `[Reading]` (were `Int`),
there is an `idIndex` dictionary and a per-`MetricKind` index, batches merge in one linear
pass, and a batch schedules exactly one save.

**§3.1 — retention.** Implemented as *compaction*, not a storage migration: readings older
than 14 days collapse to one median per `ComparisonEngine` window. A SQLite/SwiftData move is
a project-level decision AGENTS.md warns heavily about and was out of scope.

**§3.2/3.3 — archive safety.** `ReadOutcome` distinguishes `missing` / `unreadable` /
`corrupt` / `value`; a versioned envelope with legacy bare-payload fallback; explicit file
protection class. See §5 — **improvements.md gave wrong advice here and needs correcting.**

**§5.4 — localization.** String Catalog + extraction settings + ~80 `String(localized:)`
conversions, with locale-independent `exportTitle`/`exportUnit` accessors so `PairwiseExport`
output stays byte-identical (its CSV is a stable machine format pinned by tests).

**§7.2 — `OuraDashboardView`** split from 1,422 lines into `Sources/Views/Oura/` (10 files).

**§6.1 — tests.** Five new suites, 2,962 lines: `HealthStoreTests`, `ReadingArchiveTests`,
`HealthKitConversionTests`, `OuraSyncTests`, `HRVFilterTests`.

---

## 3. What is NOT done

In priority order. Items 1–2 are correctness; 3–4 are the verification I never got to.

### 3.1 Fix the ring-battery timestamp bug (see §4) — **blocking**
A real bug in new code, caught by a new test. Currently the only failing test.

### 3.2 Wire the remaining suites into the harness
`scratchpad/harness/Tests/HarnessTests/` contains **only `OuraSyncTests.swift`**. The store,
archive and HRV suites are portable and should run there too. `HealthKitConversionTests`
cannot — no HealthKit on macOS.

### 3.3 Adversarial verification — **never ran**
This was the whole point of the last workflow and it was killed before starting. Four lenses
were planned; none executed:

- **headline-bugs** — do §1.1 and §1.2 actually hold? Specifically: are HealthKit samples
  *already written by an earlier mirroring build* excluded on read, or only new ones? If the
  store already holds a phantom `hk.com.heartsync.*` source with readings, **does anything
  clean it up, or does the user keep a fake perfectly-agreeing device forever?** That is an
  unanswered migration question.
- **invariants** — full diff against AGENTS.md. Especially: can any existing archive
  (`readings.json`, `sources.json`, `settings.json`, `oura-dashboard-v1.json`) fail to decode
  or silently lose data? Hand-decode a realistic legacy payload.
- **completeness** — walk improvements.md item by item and rule each fixed/partial/not-fixed.
  Be sceptical about §2.1/§2.2 (are the view snapshots real, or did one property get hoisted
  while others still recompute?), §2.5 (is the Keychain truly read once?), §5.1/§5.2 (is body
  sensor location actually *parsed and persisted*, and HRV quality actually *surfaced*, or is
  it dead state again — which is what the finding complained about).
- **data-safety** — index staleness under interleaved
  append/upsert/remove/prune/compact; compaction idempotence and id collisions; and the load
  guard in §5.

### 3.4 Update improvements.md into a findings-**and-resolution** document
Add a status line per numbered item. **Correct §3.2** (see §5). Be honest that no test has
executed through Xcode, and state exactly what the harness did and did not cover.

---

## 4. The open bug — ring battery timestamps are milliseconds read as seconds

**`Sources/Oura/OuraManager.swift:478`**

```swift
date: { Date(timeIntervalSince1970: TimeInterval($0.timestamp_unix)) }
```

`timestamp_unix` is **milliseconds** everywhere else — `OuraDataTests` pins
`1_777_030_400_000` against ISO `2026-04-22T12:00:00Z`, which is only consistent with ms.
Read as seconds, every battery record dates to roughly the year 58,000, sits comfortably
after any cutoff, and is **never pruned**. The archive accumulates ring-battery samples for
the life of the install even though the merge is documented as dropping anything older than
the window.

Failing test: `OuraSyncTests.swift:581`, *"Ring battery records older than the window are
pruned like every other collection"*.

**Fix:** divide by 1000 (`TimeInterval($0.timestamp_unix) / 1000`). Check
`OuraData.swift:230` (`latestBatteryLevel`) too — comparing raw values is fine there since
it is a relative `max`, but confirm nothing else converts it. This is new code from the §2.6
incremental-sync work, not a pre-existing bug.

---

## 5. improvements.md §3.2 is wrong and must be corrected

I wrote it; it gave bad advice. It recommended `.completeFileProtectionUnlessOpen`. That
class **cannot open an existing closed file while the device is locked**, and this app
declares `UIBackgroundModes: bluetooth-central` with CoreBluetooth state restoration — so iOS
can relaunch it in the background after a reboot, *before first unlock*. The archive read
would fail, the store would treat that as "no data", and the next coalesced save would write
an empty store over the user's entire history.

**What was actually implemented** (keep this, it is correct):

- `.completeFileProtectionUntilFirstUserAuthentication`, set explicitly rather than relied on
  as the platform default — the strongest class that cannot break a documented background path.
- `ReadOutcome` separates *unreadable* from *missing*; only `corrupt` moves a file aside.
- `HealthStore.loadState` is a tri-state; `saveNow` refuses to write unless `.loaded`.

⚠️ **Scrutinise `HealthStore.loadIfNeeded` / `performLoad` / `saveNow` carefully.** An agent
was killed mid-edit there and left the build broken; I finished the migration by hand under
repair conditions. It shares an in-flight load via `loadTask`, requires *both* archive reads
to be conclusive before adopting either (a readable `sources.json` beside an unreadable
`readings.json` is the dangerous case — it looks exactly like "devices but no history"), and
sets `.failed` otherwise. Open questions I never verified:

- Can `loadTask` be left non-nil after cancellation and permanently wedge loading?
- Does **`AppSettings` have the same hazard without the same fix?** It still uses a plain
  `isLoaded` Bool. I believe it does. Nobody has checked.

---

## 6. The SwiftPM harness

`/private/tmp/claude-501/-Users-owner-HeartSyncChecker/9dde72d5-0cd3-4ab9-92f7-dc27e2000900/scratchpad/harness`

```bash
cd <that path> && swift test
```

Because there is no simulator runtime, this compiles the **real source files via symlinks**
(never copies — a copy would drift and you would be testing something the app does not ship)
and runs the portable suites natively on macOS.

**Caveats you must know:**

- It lives entirely outside the repo, deliberately. Do not add `Package.swift` or symlinks to
  the repository; it stays an XcodeGen iOS project exactly as AGENTS.md describes.
- **It contains `OuraOAuthStub.swift`** — a stub standing in for `Sources/Oura/OuraOAuth.swift`,
  which imports UIKit and cannot build on macOS. `OuraManager` depends on it, so Oura sync
  tests run against a *stubbed* credential store. Sync logic is genuinely exercised; the OAuth
  path is not.
- Not portable, and therefore never executed anywhere: anything importing **HealthKit**
  (so `HealthKitConversionTests` — including the §1.1 regression guard, the app's worst bug)
  or **UIKit** (`Sources/Views`, `OuraOAuth`).
- Do **not** modify app source to make the harness compile. Exclude and document instead.

---

## 7. Ground rules

- **`AGENTS.md` is binding.** Read it first. Its "Things Agents Must Not Do" and
  "Analysis and Data-Integrity Invariants" sections are the ones that bite.
- `project.yml` is the XcodeGen source of truth; `HeartSyncChecker.xcodeproj` is generated.
  Run `xcodegen generate` after project changes; never hand-edit the pbxproj.
- Swift 6, complete strict concurrency. **Never** silence a diagnostic with
  `@unchecked Sendable` or `nonisolated(unsafe)`. The one legitimate pre-existing exception is
  the documented `willRestoreState` handoff in `BluetoothManager`.
- Never weaken medical or evidence language. Insufficient evidence must never render as
  agreement. Estimates never enter device-agreement verdicts or get written to HealthKit.
- `PairwiseExport`'s CSV and summary are a **stable machine format** pinned by tests. The
  `exportTitle`/`exportUnit` split exists to keep it byte-identical under localization.
- Never delete a failing test or weaken an assertion to get green. Fix the implementation.

---

## 8. Two things needing the user's decision

1. **§4.5 — HealthKit background delivery entitlement** was added to `project.yml` and
   `Resources/HeartSyncChecker.entitlements`. This requires the App ID to have that capability
   enabled in the Apple developer portal, and can **only be verified with a signed build on a
   physical device**. A simulator build proves nothing about it.
2. **§5.3 — Oura onboarding** is partially blocked. Shipping a first-party client ID is
   impossible here (no credentials). The reachable parts were done — copyable redirect URI,
   client-ID validation, proactive expiry prompt. Whether to ship a real client ID is the
   user's call.

Also unresolved and worth raising: **compaction is lossy and irreversible, and the user never
opts in.** `SettingsView`'s retention footer explains it, but "your raw samples older than two
weeks are permanently replaced by medians" is a data decision, not a storage detail.

---

## 9. Suggested order

1. Fix the battery-timestamp bug (§4) → harness green at 20/20.
2. Wire store/archive/HRV suites into the harness (§3.2) → run them; expect new failures,
   they are the point.
3. Check whether `AppSettings` shares the load-guard hazard (§5).
4. Answer the phantom-source migration question (§3.3, headline-bugs).
5. Run the four verification lenses (§3.3), fix what they find.
6. Update improvements.md with resolutions and correct §3.2 (§3.4).
7. `git add -A && git commit` — nothing here is committed yet.
