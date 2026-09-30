# HeartSync for Apple Watch

The watchOS 11+ companion shows the iPhone's latest readings and device comparisons, with
WidgetKit complications for measurements. It uses native SwiftUI and WatchConnectivity and
does not use HealthKit. The phone remains the authority for imported history, comparison
analysis, Oura configuration, and exports. Workout recording was removed; Apple Watch
readings still reach HeartSync through Apple Health on iPhone.

On watchOS 26 and later the rows, buttons, and period picker are Liquid Glass
(`WatchTheme.swift`); watchOS 11–25 get tinted translucent fills of the same shapes.

## Build and install

Run from the repository root:

```sh
xcodegen generate
xcodebuild build -project HeartSyncChecker.xcodeproj -scheme HeartSyncWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath /tmp/HeartSync-Watch-DerivedData CODE_SIGNING_ALLOWED=NO
```

For a real watch, sign in under **Xcode > Settings > Accounts**, with access to the existing
development team **7RLDYXQTNX**. Keep automatic signing enabled. Register the App Group
**group.com.heartsync.HeartSyncChecker.watch** and enable it on both the watch App ID
**com.heartsync.HeartSyncChecker.watchkitapp** and the extension App ID **com.heartsync.HeartSyncChecker.watchkitapp.complications**. Refresh both
provisioning profiles. The iPhone does not need this App Group; its snapshot travels over
WatchConnectivity. Neither watch target needs HealthKit. Do not replace the existing iPhone
bundle ID or signing team to bypass provisioning errors.

1. Regenerate and open `HeartSyncChecker.xcodeproj`.
2. Select **HeartSyncWatch**, then your paired Apple Watch. Enable Developer Mode on the
   devices if Xcode requests it, and run the app.
3. Build/run **HeartSyncChecker** on the paired iPhone as well; its app embeds the watch app.
4. Open both apps to establish dashboard sync. Connect Apple Health on iPhone if you want
   saved watch heart-rate samples imported for comparison.

`project.yml` generates `WatchApp/Resources/Info.plist` and `HeartSyncWatch.entitlements`.
It also generates the extension's plist and entitlements in `WatchComplications/Resources`.
The watch declares the exact iPhone companion ID and an App Group, and nothing else: no
HealthKit, workout processing, Oura token, location access, BLE sensor manager, or separate
history database.

## Add complications

After installing the updated watch app, touch and hold your watch face, choose **Edit**, and
select a complication slot. Choose **HeartSync Measurement** and the desired measurement. Slot availability depends on the watch face. The measurement
recommendations include heart rate, resting heart rate, SpO₂, RMSSD, SDNN, respiratory rate,
and absolute body temperature. Each slot can use a different measurement. The widget supports circular, rectangular, inline, and corner families; rectangular widgets also work
in the Smart Stack.

- **HeartSync Stress** is a separate complication with nothing to configure. It shows
  HeartSync's stress index, a score out of 100 against the user's own baseline, in the same
  four families. It is the only complication that shows an estimate, and every family says
  so: **Est.** in the circular opening, **Estimated** in the others, and "HeartSync's
  estimate, not a measurement" for VoiceOver. No band or colour judges the score. It ages
  like other fast metrics (**Older** after 15 minutes without a new score) and a tap opens
  the stress detail and its caveat.
- Measurements use the most recent non-estimated reading among the dashboard's displayed
  enabled sources. RMSSD and SDNN stay separate. Derived readings and compacted medians keep
  their labels. The complication does not make device-agreement or medical-accuracy claims.
- The rectangular layout shows the value, measurement age, and source or derivation label.
  After the dashboard's freshness limit, it explicitly says **Older**; smaller layouts replace
  the value with an older-reading state. Freshness uses measurement time, not phone sync time.
- Tap a measurement to open its source details. Measurements are phone snapshots, not a
  live feed.
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
  sources, the existing engine, and unthinned inputs. Periods are 1H, 3H, 24H, 7D, and 30D (daily metrics: 7D and 30D), chosen with the picker on the detail and Compare screens and stored in
  `@AppStorage("watch.chart.range")`. Estimates do not contribute evidence.
- Charts: `WatchSnapshotBuilder` sends each shown source's window medians (windows are whole
  multiples of the comparison window, about 30 per period), the source's iPhone palette colour
  and shape (a second source on a shared colour slot gets a free shape, as on iPhone), and the Bland–Altman figures of one ready pair (outside tolerance first) with a
  thinned difference series. The standard period stays in `WatchMetric.chart`, so either app
  can be older; the other periods are in `rangeCharts`. 1H and 3H are rebuilt with every
  publication; `WatchChartCache` keeps 24H, 7D, and 30D between publications and discards them on source changes or a store removal that
  reaches the period (routine pruning of rows older than 30 days does not). Charts
  are dropped, longest period first, before the 60 KB cap would be exceeded. The x axis uses
  two or three round local times (or weekdays, or numeric dates) inside the plot edges. The watch draws
  them with `WatchTrendChart` and `WatchDifferenceChart` (neutral reference inks, lines broken
  at gaps, estimates dashed) and hides them in Always On. A tap, or a touch-and-hold then
  slide, selects the nearest window and shows its time and each source's median in a popup;
  it stays until a touch in empty plot area. VoiceOver steps windows with swipe up and down. The Compare page is the second
  vertical page, after the dashboard. Incomplete pairs prevent an overall
  green agreement claim. The detail screen explicitly describes the result as **at sync**.
- Ordinary phone changes coalesce to at most one queued snapshot every 30 seconds while the
  process runs; foreground refresh and connection activation can publish sooner. Delivery
  timing is controlled by watchOS/iOS. Offline refresh explains how to reconnect.
- **Sync all sources** sends a reachable message the iPhone answers within 25 seconds with
  what happened to Health, Oura, Bluetooth, and ring imports; anything still running
  continues on iPhone and its readings arrive with a later snapshot. Requests less than a
  minute apart start nothing.
- Renames, disabled/removed sources, deletions, and local resets invalidate the projection.
  An empty context clears old watch rows when delivered. A disconnected watch can retain its
  previous snapshot until that update arrives. Newer contexts supersede late older ones;
  incompatible/corrupt updates preserve the last readable context with an error message.
- Background WatchConnectivity tasks stay open until activation and pending content delivery
  finish.
- **Always On.** With luminance reduced, the dashboard keeps values prominent, dims labels
  and secondary lines, and hides trends. Measurement values are `privacySensitive()`, the same
  as the complications.

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
- On 2026-09-05 the external native harness passed **114 tests**, including **11 complication
  tests** for source selection, age transitions, empty/estimated states, cache round-trip,
  duplicate/late deliveries, reset persistence, invalid/corrupt/unavailable storage, and links.
  These tests do not exercise WidgetKit rendering, App Group entitlement enforcement, or
  WatchConnectivity delivery.
- No iOS/watchOS simulator runtime is installed. The connected watch's signed build is blocked
  by **No Accounts**, a missing extension profile, and the watch profile lacking the new App
  Group entitlement. No device install, complication gallery/face rendering, tap navigation,
  or watch UI interaction is claimed as validated.

Before release, use a signed paired iPhone/watch to check:

1. First launch, empty data, offline cached data, reachable refresh, Sync all sources with the
   iPhone locked, in the background, and in the foreground (Health, Oura, and a connected
   ring's import), chart tap and touch-and-hold selection while the list still scrolls,
   source rename/hide/remove,
   and reset propagation. Confirm dashboard changes also arrive while the watch app is closed.
2. Small and large watch layouts, Dynamic Type, VoiceOver, metric details, and stale values.
   `--watch-demo` in a Debug build supplies deterministic dashboard data without connectivity.
3. Apple Watch heart rate reaching iPhone through Health, reimport without duplicate UUIDs, and
   comparison against an enabled BLE source. Confirm no watch import is written back by the phone.
4. The 3H period on the detail and Compare pages: five period buttons fit a 41 mm watch, 3H has
   its own verdict and chart, and a daily metric shows it disabled.
5. Liquid Glass rows and buttons on watchOS 26, and the translucent fallback on watchOS 11.
6. The complication in each family and in the Smart Stack; choose different metrics, verify
   tinting, long source names, VoiceOver, large text, and privacy/Always On redaction. The
   circular gauge must render in tinted and full-colour faces with its Older and Median
   labels. Lower the wrist and confirm the reduced presentation: values prominent, secondary
   text dimmed, trends hidden. Tap each measurement. Add **HeartSync Stress** in each family:
   every value reads as an estimate (Est. / Estimated), it turns Older 15 minutes after the
   last score, and a tap opens the stress detail.
7. Change phone data with the watch app closed, then check eventual complication reloads.
   Verify first-use empty state, no selected metric, old measurement after a fresh sync, aging
   without new data, source removal, reset, unavailable phone storage, and locked-watch reads.
   Confirm a reset removes old values once delivered.

Snapshot transport follows [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)
and [WatchConnectivity background tasks](https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask).
Complications follow Apple's [accessory widget guidance](https://developer.apple.com/documentation/widgetkit/creating-accessory-widgets-and-watch-complications)
and [WidgetKit refresh model](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).
