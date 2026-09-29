# HeartSync for Apple Watch

The watchOS 11+ companion provides an iPhone dashboard and independent heart-rate workout
recording, with WidgetKit complications for measurements and a workout shortcut. It uses
native SwiftUI, WatchConnectivity, and HealthKit. The phone remains the
authority for imported history, comparison analysis, Oura configuration, and exports.

## Build and install

Run from the repository root:

```sh
xcodegen generate
xcodebuild build -project HeartSyncChecker.xcodeproj -scheme HeartSyncWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/HeartSync-Watch-DerivedData CODE_SIGNING_ALLOWED=NO
```

For a real watch, sign in under **Xcode > Settings > Accounts**, with access to the existing
development team **7RLDYXQTNX**. Keep automatic signing enabled and enable HealthKit for the
watch App ID **com.heartsync.HeartSyncChecker.watchkitapp**. Register the App Group
**group.com.heartsync.HeartSyncChecker.watch** and enable it on both that watch App ID and the
extension App ID **com.heartsync.HeartSyncChecker.watchkitapp.complications**. Refresh both
provisioning profiles. The iPhone does not need this App Group; its snapshot travels over
WatchConnectivity. The extension does not need HealthKit. Do not replace the existing iPhone
bundle ID or signing team to bypass provisioning errors.

1. Regenerate and open `HeartSyncChecker.xcodeproj`.
2. Select **HeartSyncWatch**, then your paired Apple Watch. Enable Developer Mode on the
   devices if Xcode requests it, and run the app.
3. Build/run **HeartSyncChecker** on the paired iPhone as well; its app embeds the watch app.
4. Open both apps to establish dashboard sync. Connect Apple Health on iPhone if you want
   saved watch heart-rate samples imported for comparison.

`project.yml` generates `WatchApp/Resources/Info.plist` and `HeartSyncWatch.entitlements`.
It also generates the extension's plist and entitlements in `WatchComplications/Resources`.
The watch has HealthKit, workout processing, and the exact iPhone companion ID. Workout
recording works without a reachable phone. No Oura token, location access, route recording,
calorie collection, BLE sensor manager, or separate history database is added on the watch.

## Add complications

After installing the updated watch app, touch and hold your watch face, choose **Edit**, and
select a complication slot. Choose **HeartSync Measurement** (and the desired measurement)
or **HeartSync Workout**. Slot availability depends on the watch face. The measurement
recommendations include heart rate, resting heart rate, SpO₂, RMSSD, SDNN, respiratory rate,
and absolute body temperature. Each slot can use a different measurement. Both widgets
support circular, rectangular, inline, and corner families; rectangular widgets also work
in the Smart Stack.

- Measurements use the most recent non-estimated reading among the dashboard's displayed
  enabled sources. RMSSD and SDNN stay separate. Derived readings and compacted medians keep
  their labels. The complication does not make device-agreement or medical-accuracy claims.
- The rectangular layout shows the value, measurement age, and source or derivation label.
  After the dashboard's freshness limit, it explicitly says **Older**; smaller layouts replace
  the value with an older-reading state. Freshness uses measurement time, not phone sync time.
- Tap a measurement to open its source details. Tap Workout to open the existing controls;
  it never starts or saves a workout automatically. Measurements are phone snapshots, not
  a live feed from an active watch workout.
- The watch writes one bounded, validated display snapshot to its App Group before finishing
  WatchConnectivity background delivery, then requests a timeline reload. Empty/unavailable
  snapshots replace old values. Duplicate/older deliveries cannot resurrect a reset. The
  disposable cache is excluded from backup and protected until first unlock. It is not a
  second history database and contains no credentials.
- WidgetKit reads that local snapshot, schedules an entry for the freshness transition, and
  requests a fallback refresh after 30 minutes. Apple controls refresh budgets and timing;
  neither phone delivery nor complication refresh has a guaranteed interval. A disconnected
  watch can retain old data until a new context arrives. Missing/unreadable data prompts the
  user to open HeartSync. Measurement views use `privacySensitive()` for system redaction.
- The circular complication is an `accessoryCircular` gauge over the metric's nominal
  display range. The value sits in the centre; the ring's opening shows **Older** or
  **Median** when either applies, otherwise the metric's short name. An older reading shows
  an empty ring and a dash rather than a full-strength arc.
- Demo launch data stays in the watch app and never overwrites the complication cache.
  Gallery previews use synthetic samples only in WidgetKit preview/placeholder requests.

## Behavior

- The dashboard restores the OS-managed latest received context and displays the snapshot's
  sync time separately from each measurement's time. Fast measurements older than 15 minutes
  are marked older; daily metrics use their existing daily window for that label.
- The four most recent enabled sources per metric are shown. Comparison uses all enabled
  sources, the existing engine, and unthinned inputs. Periods are 1H, 24H, 7D, and 30D (daily
  metrics: 7D and 30D), chosen with the picker on the detail and Compare screens and stored in
  `@AppStorage("watch.chart.range")`. Estimates do not contribute evidence.
- Charts: `WatchSnapshotBuilder` sends each shown source's window medians (windows are whole
  multiples of the comparison window, about 30 per period), the source's iPhone palette colour
  and shape (a second source on a shared colour slot gets a free shape, as on iPhone), and the Bland–Altman figures of one ready pair (outside tolerance first) with a
  thinned difference series. The standard period stays in `WatchMetric.chart`, so either app
  can be older; the other periods are in `rangeCharts`. `WatchChartCache` keeps 24H, 7D, and
  30D between publications and discards them on source changes or any store removal. Charts
  are dropped, longest period first, before the 60 KB cap would be exceeded. The x axis uses
  two or three round local times (or weekdays, or numeric dates) inside the plot edges. The watch draws
  them with `WatchTrendChart` and `WatchDifferenceChart` (neutral reference inks, lines broken
  at gaps, estimates dashed) and hides them in Always On. The Compare page is the second
  vertical page, between the dashboard and the workout. Incomplete pairs prevent an overall
  green agreement claim. The detail screen explicitly describes the result as **at sync**.
- Ordinary phone changes coalesce to at most one queued snapshot every 30 seconds while the
  process runs; foreground refresh and connection activation can publish sooner. Delivery
  timing is controlled by watchOS/iOS. Offline refresh explains how to reconnect.
- Renames, disabled/removed sources, deletions, and local resets invalidate the projection.
  An empty context clears old watch rows when delivered. A disconnected watch can retain its
  previous snapshot until that update arrives. Newer contexts supersede late older ones;
  incompatible/corrupt updates preserve the last readable context with an error message.
- Background WatchConnectivity tasks stay open until activation and pending content delivery
  finish. The delegate also handles system workout recovery.
- Workouts support Other, Walking, Running, and Cycling, with indoor/outdoor selection where
  relevant. Live heart rate comes from the watch's workout builder. Heart-rate read access
  is not inferred from permission-sheet completion; an empty reading state remains possible.
- **Always On.** With luminance reduced, the workout and dashboard keep the heart rate,
  its value, and elapsed time prominent, dim labels and secondary lines, and hide the trend.
  **Decision:** live heart rate is `privacySensitive()`, the same as the complications. The
  watch's own privacy settings decide whether it is redacted on a lowered wrist; HeartSync
  does not hide it unconditionally, because Apple's workout guidance is to keep the key
  metric readable. Elapsed time is never marked sensitive.
- A small trend shows the last five minutes of the workout's heart rate from the samples
  the builder already delivered. It is kept in memory only, breaks at gaps (a pause or a
  silent sensor), is cleared at Start and Discard, and adds no persistence. No heart-rate
  zones are shown.
- Pausing stops elapsed workout time through HealthKit's own elapsed-time calculation. Values
  older than 15 seconds are labelled as awaiting a new reading. End opens review; Save stores
  the workout in HealthKit; Discard requires confirmation. Save failures keep the builder for
  retry. A successful save with no returned object while locked is still treated as saved.
- Saved readings arrive on iPhone through HealthKit sync using their HealthKit UUIDs, not
  through WatchConnectivity ingestion. The existing measured-only Bluetooth write-back
  policy cannot mirror these watch imports back to HealthKit. Discard does not delete samples
  Apple Watch may have collected independently. Health samples may become visible separately
  from the final workout's save timing, as controlled by HealthKit.

## Validation

The implementation was built using Xcode 27 with Swift 6 strict concurrency. Build results and
runtime results must be reported separately.

- The unsigned watch simulator app, WidgetKit extension, and iOS app with both embedded compile.
- The unsigned Release watch/device build also succeeds. Built plists and extension packaging
  were checked, including generated App Intent metadata for all seven measurement choices.
- The complete iOS unit/UI bundles compile with `build-for-testing`.
- Xcode emits its existing metadata-extraction warning for targets without AppIntents;
  the complication extension's App Intent metadata is generated successfully.
- A temporary native SwiftPM harness executes real source files via symlinks, including the
  watch payload/projection tests and related store/parser/HRV/export regressions.
- The workout lifecycle is now covered by `Tests/Watch/WorkoutLifecycleTests.swift`, which runs
  in the hosted iOS bundle in CI. It exercises `WorkoutLifecycle` in `Shared`, the transition
  rules `WatchWorkoutManager` drives: duplicate Start/Stop taps, stale callbacks from a
  discarded or replaced session, interrupted collection, save failure then retry, double-save
  refusal, discard, and recovered running/paused/stopped sessions. It does **not** exercise
  HealthKit itself, WatchConnectivity, or watch SwiftUI: `WatchWorkoutManager`, the adapter
  that owns `HKWorkoutSession` and `HKLiveWorkoutBuilder`, is still only compiled, not run.
- On 2026-09-05 the external native harness passed **114 tests**, including **11 complication
  tests** for source selection, age transitions, empty/estimated states, cache round-trip,
  duplicate/late deliveries, reset persistence, invalid/corrupt/unavailable storage, and links.
  These tests do not exercise WidgetKit rendering, App Group entitlement enforcement, or
  WatchConnectivity delivery.
- No iOS/watchOS simulator runtime is installed. The connected watch's signed build is blocked
  by **No Accounts**, a missing extension profile, and the watch profile lacking the new App
  Group entitlement. No device install, complication gallery/face rendering, tap navigation,
  watch UI interaction, live sensor collection, or workout save is claimed as validated.

Before release, use a signed paired iPhone/watch to check:

1. First launch, empty data, offline cached data, reachable refresh, source rename/hide/remove,
   and reset propagation. Confirm dashboard changes also arrive while the watch app is closed.
2. Small and large watch layouts, Dynamic Type, VoiceOver, metric details, and stale values.
   `--watch-demo` in a Debug build supplies deterministic dashboard data without connectivity;
   it does not start a workout or grant permissions.
3. Denied Workout and denied Heart Rate permissions, normal sensor acquisition, pause/resume,
   elapsed time, watch lock/background operation, and interruption by another workout app.
4. End/review/save, save failure/retry, discard, and recovery after a terminated active workout.
   Check Apple Health for the saved workout and sample provenance. Specifically confirm on
   hardware, because none of it is provable from the deterministic suite:
   - interruption by another workout app leaves a reviewable workout that still saves;
   - relaunch after the system terminates an active session recovers it in the right state,
     and a session recovered after it had stopped is still reviewable rather than lost;
   - a save started while the watch is locked reports success honestly and the workout is
     present in Health after unlocking;
   - heart-rate samples reach iPhone only after Health syncs, and reimport is idempotent —
     record the delay observed rather than assuming it is immediate.
   Record these on a signed build, separately from the deterministic tests. A green CI run is
   evidence about the transition rules only.
5. HealthKit sync to iPhone, reimport without duplicate UUIDs, and comparison against an enabled
   BLE source. Confirm no watch import is written back by the phone.
6. Both complications in each family and in the Smart Stack; choose different metrics, verify
   tinting, long source names, VoiceOver, large text, and privacy/Always On redaction. The
   circular gauge must render in tinted and full-colour faces with its Older and Median
   labels. During a workout, lower the wrist and confirm the reduced presentation: heart rate
   and elapsed time prominent, secondary text dimmed, trend hidden, and heart rate redacted
   only when the watch's privacy setting asks for it. Tap each
   measurement and the workout shortcut, including while a workout is active.
7. Change phone data with the watch app closed, then check eventual complication reloads.
   Verify first-use empty state, no selected metric, old measurement after a fresh sync, aging
   without new data, source removal, reset, unavailable phone storage, and locked-watch reads.
   Confirm a reset removes old values once delivered and never starts a workout.

The workout lifecycle follows Apple's [Running workout sessions](https://developer.apple.com/documentation/healthkit/running-workout-sessions).
Snapshot transport follows [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
and [WatchConnectivity background tasks](https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask).
Complications follow Apple's [accessory widget guidance](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)
and [WidgetKit refresh model](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).
