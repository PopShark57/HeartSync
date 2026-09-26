# HeartSync improvement roadmap

Newest review first. Earlier reviews and their implementation notes are retained below as
history; their "Observed behavior" paragraphs describe the checkout they reviewed.

## Current review: visuals, charts, and interaction (2026-09-26)

Reviewed `main` at commit
[`9d611f54c8d94a3f2835e1c1ad3cc0d17f51e352`](https://github.com/PopShark57/HeartSync/commit/9d611f54c8d94a3f2835e1c1ad3cc0d17f51e352),
with emphasis on visual design, chart interactivity, and screen-level UX on iPhone, iPad,
and Apple Watch. Numbering continues from item 25.

This is a source review. Nothing was built or launched: the review ran in a Linux
container with no Xcode, simulator, or device. Each item states its basis:

- **Observed defect:** read directly from the code at the commit above.
- **Measured:** the colour-vision simulation in item 31 (script in the appendix).
- **Performance risk:** inferred from where and how often code runs; not profiled.
- **Design proposal:** a product/UI recommendation.

Swift Charts, SwiftUI, watchOS, and Oura API claims were checked against Apple's WWDC
sessions, Apple documentation, and the Oura schema; sources are listed at the end of this
section. One claim was dropped after checking: watchOS allows a workout app with an active
session to update once per second in Always On, so the workout timer's 1-second
`TimelineView` is not a defect.

**Implementation status (2026-09-26): items 26–35 have since been implemented.** Items 26,
27, 28, 30 and 31 meet the code and test parts of their "Done when" paragraphs. Item 29
is partial. Items 32–35 meet the code and unit-test parts of theirs. Their UI tests are
written, and CI gives them their first compile and run. Each item below ends with a status
note that says what changed and what is still open. Every open point is a device,
simulator, or on-screen check that this environment could not run. The "Observed
behavior" paragraphs describe the code as reviewed, before those changes. Items 36–41 have
since been implemented too, together with the direct-ring fix in `RingFix.md`. They meet the
code and unit-test parts of their "Done when" paragraphs; their UI tests and screenshots
run first in CI, and the device checks remain. The implementation validation sections for
[items 26–31](#implementation-validation-items-2631),
[items 32–35](#implementation-validation-items-3235), and
[items 36–41 and RingFix](#implementation-validation-items-3641-and-ringfix) say exactly what
was and was not executed.

### Priorities and suggested sequence

| Item | Priority | Improvement | Basis | Size | Status |
| --- | --- | --- | --- | --- | --- |
| 26 | P1 | Confirm before a swipe or button deletes a device's history | Observed defect | S | Done. Splitting "forget device" from "delete history" is still a product decision |
| 27 | P1 | Keep the chosen range and a saved session's period when drilling down | Observed defect | S–M | Done. UI tests written; first run is in CI |
| 28 | P1 | Stop re-running the pairwise analysis on every drag frame | Observed performance risk | M | Done in code. The device Time Profiler trace is still to do |
| 29 | P1 | Bound and coalesce the live screens' reloads during ingest | Performance risk; measure on device | M | Partial. Bounded, throttled and budgeted, but not measured on a device. One 30-day load still blocks the main actor (item 21) |
| 30 | P1 | Break every chart line and band across data gaps; no overshooting curves | Observed honesty gap | S | Done. On-screen check still to do |
| 31 | P1 | Fix colour collisions for colour-blind readers and between meanings | Measured | M | Done. Validator runs as a unit test; on-device visual check still to do |
| 32 | P2 | Make the metric-detail chart scrubbable with an inline callout | Design proposal | M | Done in code. On-screen and VoiceOver checks still to do |
| 33 | P2 | Add pan, zoom, and period selection to history charts | Design proposal (+ observed axis gap) | M–L | Done with buttons, not pinch or scroll (Apple chart bugs); see status |
| 34 | P2 | Rebuild pairwise-chart selection on the native selection API | Design proposal (+ observed gaps) | M | Done in code. The list-scrolling device check is still to do |
| 35 | P2 | Turn the Oura cards into real charts: heart rate, hypnogram, 14-day trends | Design proposal (+ observed legend gap) | M–L | Done in code. On-screen and VoiceOver checks still to do |
| 36 | P2 | Give the Now tab sparklines, motion, and honest "live" labelling | Design proposal (+ observed wording issue) | M | Done in code. UI test written; on-screen and Reduce Motion checks still to do |
| 37 | P2 | Make dense charts work with VoiceOver, Audio Graphs, and Dynamic Type | Accessibility gap | M | Done in code. The AX5 VoiceOver and Audio Graph pass is still to do |
| 38 | P2 | Adapt layouts for iPad and landscape | Design proposal | M | Done in code. iPad screenshots come from CI; a device look is still to do |
| 39 | P2 | Consolidate visual tokens, chart styling, and loading feedback | Polish and maintainability | S–M | Done |
| 40 | P2 | Adopt Always On guidance and gauges on the watch | Design proposal | S–M | Done in code. The physical-watch Always On and face checks are still to do |
| 41 | P2 | Add previews, chart fixtures, and screenshot artefacts for UI work | Developer experience | M | Done. Previews not yet opened in Xcode; vectorized plots evaluated, not adopted |

**P1** here means fix first: data loss, wrong analysis period, misleading drawing, or work
that interactive charts would make worse. **P2** is the interactive and visual roadmap
itself (items 32–36 are the core of it). Most P2 items depend on the P1 fixes.

Suggested order:

1. 26 and 27 are small and self-contained.
2. Do 28 and 29 before 32–35. Selection re-evaluates a chart's `body` on every touch-move,
   so expensive work has to leave `body` before charts become interactive.
3. Land 30 and 31 before adding new charts, so new charts inherit the corrected gap and
   colour conventions. The shared chart-style tokens in 39 can land with 31.
4. The richer fixtures in 41 make every later item easier to check visually. Start them
   early.

### 26. Confirm before a swipe or button deletes a device's history

**Observed behavior**

In [DevicesView.swift](Sources/Views/DevicesView.swift#L67), Bluetooth rows (L67) and
Apple Health rows (L215) attach `.swipeActions(edge: .trailing)` with a destructive
**Remove** as the first action. `allowsFullSwipe` defaults to `true`, so one long swipe
performs Remove with no second tap. `AppModel.removeSource` calls
`HealthStore.remove(sourceID:)`, which runs `DELETE FROM readings WHERE source_id = ?`
([HealthDatabase.swift](Sources/Store/HealthDatabase.swift#L249)). A single gesture
therefore permanently deletes every stored reading from that device. Bluetooth-only
history cannot be downloaded again.

**Disconnect Oura** (L343) also deletes the Oura readings immediately. A later sync
restores only the 14-day window.

Settings already stages retention shortening and both reset actions behind a preview and
a confirmation. These two paths skip that protection.

**Improve it**

- Set `allowsFullSwipe: false` on these rows, or make the first trailing action
  non-destructive (Rename or Pause).
- Route Remove and Disconnect through a `confirmationDialog` that states the consequence
  in numbers. For example: "Deletes 48,210 readings from Polar H10 recorded since 3 Aug.
  Bluetooth history cannot be downloaded again." Offer an export first, as
  `RetentionConfirmationView` does.
- Put the non-destructive alternatives in the same dialog. **Pause collecting** and
  **Hide from comparisons** already exist.
- As a separate product decision, consider splitting "forget this device" from "delete
  its history".

**Done when**

A full swipe cannot delete data. A UI test proves that Cancel leaves the source and its
reading count unchanged, and that confirming removes exactly that source's readings.

**Implementation status (2026-09-26): done.**

- Bluetooth and Apple Health rows use `.swipeActions(edge: .trailing, allowsFullSwipe: false)`.
  **Remove** (swipe or context menu) and **Disconnect Oura** now only *propose* a removal.
- One `confirmationDialog`, attached to the list rather than to a transient row or menu,
  states the consequence in numbers. For example: "Deletes 12 readings from Demo Chest
  Strap recorded since 3 Aug." It then adds a sentence specific to the transport:
  Bluetooth history cannot be downloaded again; Apple Health keeps its own copy, but
  HeartSync will not import those samples again; Oura signs out, and a later sync restores
  only the last 14 days.
- The counts come from `HealthStore.sourceHistorySummaryOutcome(sourceID:)`, a
  `COUNT`/`MIN` query on the covering `readings_source_time` index. A failed count is
  reported as unknown, never as "no readings".
- The same dialog offers **Export its readings first**, which writes a per-source paged
  CSV. The temporary directory is removed when the share sheet is dismissed, and nothing
  is deleted. It also offers **Pause collecting instead** for enabled Bluetooth sensors,
  **Hide from comparisons instead**, and Cancel. The confirm button reads **Remove device**
  when nothing is stored, so it never claims to delete history.
- Wording is built by `SourceRemovalConsequence`, a portable type covered by
  `Tests/SourceRemovalTests.swift`.
- `testRemovalAsksFirstAndDeletesOnlyThatDevice` uses a two-device fixture (12 readings
  each) and checks four things:
  - a full-width drag deletes nothing;
  - the dialog shows "12 readings";
  - Cancel leaves 24 stored readings;
  - confirming leaves exactly the other device's 12.

Still open: splitting "forget this device" from "delete its history" remains a product
decision. The UI tests have not been run in this environment (see Implementation
validation).

### 27. Keep the chosen range and a saved session's period when drilling down

**Observed behavior**

- [MetricDetailView.swift](Sources/Views/MetricDetailView.swift#L65) sets
  `.onAppear { range = initialRange }`. `onAppear` runs again when a pushed view is popped.
  Choosing **7D**, opening a device pair, and tapping Back resets the chart to the range
  it was opened with. `PairwiseAnalysisView` already seeds its `@State` in `init` (L32),
  which is the correct pattern.
- With a saved session open, Compare still passes the rolling picker value into detail
  ([CompareView.swift](Sources/Views/CompareView.swift#L151)).
  `MetricDetailView` and `PairwiseAnalysisView` accept only a `TimeRange`. Opening Heart
  rate from "Morning walk, 3 Sep 07:00–08:00" shows the last 24 hours instead. That is a
  different analysis from the one the session banner describes.

**Improve it**

- Seed `range` in `init` with `State(initialValue:)` and delete the `onAppear` assignment.
- Pass `ComparisonPeriod` (already used by Compare) down to both detail screens. Show the
  session banner there and hide the rolling picker, as Compare does.
- Resolve the interval once per snapshot and store it on the snapshot. Today
  `TimeRange.interval` is re-evaluated relative to `.now` in several places (see 33).

**Done when**

Back-navigation preserves the selected range. Opening a metric and a pair from a saved
session analyses exactly the session's seconds, and an export from there carries that
span. UI tests cover both paths.

**Implementation status (2026-09-26): done.**

- `MetricDetailView` seeds its range in `init` with `State(initialValue:)`, and the
  `onAppear` reset is gone.
- Compare passes its `ComparisonPeriod` down, as `MetricDetailView(kind:initialRange:session:)`
  and then `PairwiseAnalysisView(... session:)`. With a session open, both screens show a
  shared `ComparisonSessionBanner` ("this analysis covers exactly these times, not a
  rolling range") in place of the picker.
- Each snapshot resolves its interval once and stores it (`interval`, `resolvedAt`).
  Chart bucket and axis format follow the resolved span (`TimeRange.fitting(duration:)`).
- `Tests/DrillDownPeriodTests.swift` pins four things:
  - a session's seconds reach metric detail and the pair analysis unchanged;
  - an export from the pair carries the session's span;
  - re-resolving a fixed period later yields the same analysis;
  - the demo session covers 5 of the demo's 8 paired minutes.
- Two UI tests cover the paths in the "Done when" paragraph:
  - `testMetricDetailKeepsTheChosenRangeAfterBack`: choose 7D, open a pair, go Back.
  - `testSavedSessionPeriodReachesDetailAndPair`: open the "Demo walk" session from the
    `--pairwise-demo` fixture. Banners replace pickers, and the pair reads "5 paired of 5"
    where the rolling range would read 8.

Follow-up: the first CI run of `testMetricDetailKeepsTheChosenRangeAfterBack`, on `main`
after the merge, failed at its two checks after Back. The list keeps the scroll offset it
had when the pair was opened, so the picker's row was out of view when the test read it.
The test now scrolls back up first (`scrollUpToElement`). This change landed with items
32–35.

### 28. Stop re-running the pairwise analysis on every drag frame

**Observed behavior and risk**

`PairwiseAnalysisView.body` starts with `let currentAnalysis = analysis`
([PairwiseAnalysisView.swift](Sources/Views/PairwiseAnalysisView.swift#L36)). The
computed `analysis` property (L174–183) runs three steps on the main actor:

1. It reads every reading of the metric in the range from SQLite.
2. It decodes those rows.
3. It runs `ComparisonEngine.pairwiseAnalysis`.

Both chart overlays write `selectedObservationStart` from a
`DragGesture(minimumDistance: 0)` (L492, L515) on every drag change. Each change
re-evaluates `body`. Scrubbing a 30-day heart-rate pair therefore re-queries and
re-windows the whole range on every touch-move event.

Two more effects:

- `body` also re-runs on every store change while the screen is open.
- `range.interval` is relative to `.now`, so each pass analyses a slightly different
  span. A window at the leading edge can disappear mid-drag.

Item 21 moved Compare and metric detail to a cancellable `.task(id:)` snapshot. This screen
was not converted.

**Improve it**

- Build an immutable `PairwiseSnapshot` (analysis, plotted sample, axis domains, notes)
  in `.task(id:)`, keyed like `MetricDetailView.LoadKey`. Selection should then change only
  lightweight `@State`.
- Precompute sorted plotted window starts in the snapshot. Nearest-point lookup during a
  drag then becomes a binary search instead of an O(n) `min` over all points (L498).
  Item 34 covers the Bland–Altman plot's 2-D lookup.
- Leave statistics and export on the full observation set. Only where and how often the
  work runs changes.

**Done when**

A Time Profiler trace on a device with a month of 1 Hz data shows no store query or
pairwise analysis during a scrub. Selection tracks the finger at display rate. Existing
analysis and export tests pass unchanged.

**Implementation status (2026-09-26): done in code; the device trace is still to do.**

- `PairwiseSnapshot` holds the analysis, the plotted sample, the timeline segments, both
  charts' domains, the thinning note, and any query failure. `PairwiseAnalysisView` builds
  it in `.task(id:)`, keyed by metric, pair, period, retry, and data generation, and
  rejects late results. Selection now changes only `@State`.
- Nearest-point lookup uses sorted window starts, and sorted pair means for the
  Bland–Altman plot, searched by binary search.
- Statistics and export still use the full observation set.
- `Tests/PairwiseSnapshotTests.swift` (8 tests) pins three things: equality with a
  direct `ComparisonEngine` analysis, the lookups against a linear scan, and thinning.

Still open: no Time Profiler trace on a device with a month of 1 Hz data has been
recorded, so "selection tracks the finger at display rate" is not yet demonstrated.

### 29. Bound and coalesce the live screens' reloads during ingest

**Observed behavior and risk**

- `DashboardView.body` builds `DashboardSnapshot` inline
  ([DashboardView.swift](Sources/Views/DashboardView.swift#L29)). It reads **all
  readings of all metrics** for `lookback`, which is twice the longest comparison window:
  48 hours (L184, L199). Heart rate, SpO₂, respiratory rate, and temperature use
  60-second windows, and the rows show only the last 15 minutes.
- `readingsOutcome(in:)` reads the observed `dataGeneration`
  ([HealthStore.swift](Sources/Store/HealthStore.swift#L481)). Bluetooth readings are
  ingested one at a time (`ingest([reading])`,
  [AppModel.swift](Sources/App/AppModel.swift#L107)), and each one bumps that value.
- Together: with one heart-rate strap (commonly about 1 Hz), the Now tab can re-read and
  decode up to two days of rows, for every metric, about once a second.
- `MetricDetailView` and `CompareView` include `store.changeToken` in their `LoadKey`.
  A 30-day chart is therefore re-read and re-windowed on the main actor 16 ms after every
  Bluetooth reading as well.

This review did not measure a hitch. The existing device performance bundle measures
ingestion and indexed queries, but not these screens while live ingest is running.

**Improve it**

- Query each metric with its own lookback: twice its `comparisonWindow`, plus the
  15-minute live window. Fast metrics then read minutes of data instead of two days.
  Daily metrics can use a `latest`-style indexed query.
- Move the Now snapshot to the same `.task(id:)` pattern and throttle live reloads. For
  example: at most once a second on Now, and once per chart bucket (or every 30 s) for
  ranges of 24 hours or longer. Where a chart lags ingest, say so with a small "Updated
  12 s ago" note.
- Add a performance test that ingests a simulated 1 Hz source while Now and a 30-day
  detail screen are open, with an explicit main-thread budget.

**Done when**

Device measurements show Now and metric detail within the chosen main-thread budget
during 1 Hz ingest with two weeks of history. Displayed values and verdicts are unchanged.

**Implementation status (2026-09-26): partial.** The code changes are in; the
device measurement that the "Done when" paragraph asks for is not.

- **Bounded read.** The Now read is bounded per metric. `DashboardSnapshot.lookback(for:)`
  is twice the metric's comparison window plus the 15-minute live window, capped at the
  previous two days: 17 minutes for heart rate, 25 for HRV, two days for daily metrics.
  An end-indexed read (`readings_end`) adds any long reading that ended inside the live
  window, such as an overnight average. `Tests/LiveReloadTests.swift` proves that the
  bounded read shows the same rows, headlines, and verdicts as the two-day read. The only
  possible difference is the "not compared" explanation text, and only when the last
  shared window is older than the bounded look-back. Daily metrics still use the two-day
  read rather than a `latest`-style query.
- **Throttled reloads.** Now runs in `.task(id:)` and reloads at most once a second.
  Compare, metric detail, and the pair screen load a changed selection at once. A reload
  caused only by new data waits `max(2 s, chart bucket ÷ 30)` since the last load:
  2 s for 1H, 10 s for 6H, 30 s for 24H, 2 min for 7D, and 12 min for 30D
  (`LiveReloadPolicy`). A screen that trails ingest shows "Updated … ago. Newer readings
  appear at the next refresh."
- **Performance test.** `liveScreensDuringIngest` was added to the device performance
  bundle. It ingests 1 Hz for 120 s on top of 14 days of history while reloading Now and
  a 30-day detail on that schedule. It asserts a Now p95 of 50 ms or less and a
  steady-state main-thread share of 25% or less. These are initial budgets, to be
  confirmed on a device.

In a Linux release build of the scratch harness (x86-64 container, not a device), the
test passed:

- Now p95: 26.5 ms, max 39.5 ms.
- Steady-state share: 5.9%.
- One 30-day heart-rate detail load over 1.2 million rows: **25.9 s**.

Still open:

- None of this has been measured on an iPhone.
- The share budget passes only because 30-day reloads are now 12 minutes apart. A single
  30-day load still runs its query, decode, and windowing on the main actor. That
  per-load cost is item 21's unfinished work, and this change does not reduce it.

### 30. Break every chart line and band across data gaps; no overshooting curves

**Observed behavior**

Item 20 added gap segmentation to the metric-detail lines (`MetricDetailSnapshot.segmented`,
[MetricDetailSnapshot.swift](Sources/Views/MetricDetailSnapshot.swift#L301)). Three
drawings still show continuity that was never measured:

- **Disagreement band.** `bandPoints` (L209) carry no segment key. The `AreaMark` band is
  one continuous area, interpolated across windows where fewer than two devices reported.
  It shades "disagreement" over time when nothing was compared.
- **Pairwise timeline.** Each device is one series keyed only by source ID
  ([PairwiseAnalysisView.swift](Sources/Views/PairwiseAnalysisView.swift#L365), L381).
  The line joins paired windows hours apart. After thinning (500 of N windows), it also
  joins samples that were never adjacent.
- **Oura heart rate.** [OuraHeartRateSection.swift](Sources/Views/Oura/OuraHeartRateSection.swift#L54)
  uses `.catmullRom` interpolation (L54, L62) on one series. Catmull-Rom curves can
  overshoot and draw peaks and dips that no sample had; `.monotone` preserves the data's
  monotonicity. That contradicts the series' own contract, "Nothing here averages,
  interpolates, or invents a value"
  ([OuraHeartRateSeries.swift](Sources/Views/Oura/OuraHeartRateSeries.swift#L18)). The
  line also runs straight through the ring's charging gap.

**Improve it**

- Generalise `segmented` into a shared helper that takes a series key and a gap threshold.
  Apply it to:
  - the band, using `AreaMark(x:yStart:yEnd:series:)`;
  - the pairwise timeline, with the threshold taken from `windowSize` (and from the
    thinning stride when the plot is thinned);
  - Oura heart rate, with the threshold at a multiple of the median sample spacing.
- Use `.monotone` or `.linear` for Oura heart rate, consistent with the other charts.
- Keep isolated observations visible as `PointMark`s, as metric detail already does.

**Done when**

Projection tests (like the existing segmentation test in `PresentationIdentityTests`)
show separate segments across a mid-range gap for the band, the pairwise timeline, and
Oura heart rate. An on-screen check confirms that no drawn curve rises above the highest
sample or falls below the lowest.

**Implementation status (2026-09-26): done in code; the on-screen check is still to do.**

- `ChartSegmentation` is the shared helper. A gap strictly larger than the threshold
  starts a new segment, series keys combine series and segment, and isolated points are
  flagged.
- **Band.** The disagreement band is split into runs at gaps and at severity changes
  (`MetricDetailSnapshot.bandRuns`). Each run is its own
  `AreaMark(x:yStart:yEnd:series:)`, because one area series takes a single style. A
  compared window with no compared neighbour is drawn as a vertical `RuleMark` across
  its range, not stretched into an area.
- **Pairwise timeline.** It breaks at 1.5 × the window size, times the thinning stride
  when the plot is thinned.
- **Oura heart rate.** It breaks at 2.5 × the median spacing of the drawn samples. It uses
  `.monotone` instead of `.catmullRom`, and draws isolated samples as points.
- `Tests/ChartGapTests.swift` (12 tests) shows separate segments across a mid-range gap
  for all three drawings.

Monotone interpolation is a cubic spline that preserves the data's monotonicity (Apple
documentation, linked below). The curve between two neighbouring samples therefore stays
between them and cannot rise above the highest sample or fall below the lowest.

Still open: the on-screen check has not been done.

### 31. Fix colour collisions for colour-blind readers and between meanings

**Measured**

`DataSource.palette` is documented as "Distinct, colour-blind-tolerant hues"
([DataSource.swift](Sources/Model/DataSource.swift#L151)). The six entries were
simulated with the Machado et al. (2009) colour-vision model at full severity, and the
pairwise difference was measured as ΔE in CAM02-UCS (Python `colorspacious`; script in the
appendix). As a rule of thumb, a ΔE below about 10 is hard to separate at chart-mark sizes.

| Pair | Normal | Protan | Deutan | Tritan |
| --- | ---: | ---: | ---: | ---: |
| Source 0 blue vs source 3 purple | 33.3 | **7.0** | **6.8** | 40.1 |
| Source 2 green vs source 4 rose | 60.6 | 30.0 | **4.8** | 67.2 |
| Source 1 orange vs source 4 rose | 20.5 | 28.1 | 17.8 | **5.8** |
| Source 2 green vs source 5 teal | 24.6 | 28.3 | 28.2 | **4.4** |
| Oura sleep: deep (`.indigo`) vs REM (`.purple`) | 24.1 | **4.1** | 11.5 | 38.2 |

Metric detail compensates with per-source symbols. The pairwise timeline does not: A and B
are both drawn as the default circle and differ by colour only. The Oura sleep ribbon also
relies on colour alone.

Colour also carries two meanings on one screen. In
[PairwiseAnalysisView.swift](Sources/Views/PairwiseAnalysisView.swift#L429), the
timeline colours the devices from the palette. The Bland–Altman plot directly below uses
`.blue` for mean bias and `.purple` for the limits of agreement and for out-of-limit
points (L429–437, L631). Those match palette sources 0 and 3 almost exactly (normal-vision
ΔE 0.1 and 0.3), so "Device A" and "mean bias" share a colour.

Palette orange and green also sit near the severity orange and green (normal-vision ΔE 16
and 9.7). On metric detail, source lines are drawn over a severity-tinted band.

**Improve it**

- Re-derive the palette against a validator that enforces a minimum ΔE for every pair
  under protan, deutan, and tritan simulation. Run the validator as a unit test. Because
  `colorIndex` persists, change the colour at each index rather than renumbering, so every
  device keeps its slot.
- Assign each source's symbol from `colorIndex`, not from its position in the current
  chart (MetricDetailSnapshot.swift L325, L356). Today a device's symbol changes when
  another device enters or leaves the range. Use the same symbols on the pairwise timeline,
  and add A and B labels at the line ends.
- Reserve neutral ink (primary or secondary, told apart by dash pattern) for statistical
  reference lines: bias, limits, and tolerances. They must never look like a device.
- Encode sleep stages as a lightness ramp that follows sleep depth, and add a text or
  pattern cue for Awake, so depth never depends on hue alone.
- Add dark-appearance variants. The palette is fixed sRGB, while the system colours around
  it adapt to dark mode.

**Done when**

An automated test enforces the chosen ΔE floor for every palette pair, and between the
palette and the reserved reference colours, under all three simulations. Every chart that
shows two sources distinguishes them by shape as well as colour.

**Implementation status (2026-09-26): done in code; the on-device visual check is still to do.**

- **Source palette.** `DataSource.paletteSlots` changes each of the six slots in place, so
  no device changes slot. Each slot has a light and a dark value, resolved with the trait
  environment through a dynamic `UIColor`.
- **Validator.** `Tests/ColourVisionTests.swift` ports the appendix method to Swift:
  Machado 2009 at full severity, then CAM02-UCS ΔE with the colorspacious 1.1.2
  parameters. It is pinned to the appendix table within 0.001. It enforces:
  - ΔE ≥ 15 between every two slots under normal, protan, deutan, and tritan vision, in
    both appearances (minimum measured: 15.3);
  - ΔE ≥ 15 between every slot and the primary and secondary ink reserved for statistical
    reference lines (minimum measured: 15.9);
  - at least 3:1 contrast against the grouped-list backgrounds (3.01 minimum in light
    appearance, 3.65 in dark);
  - ΔE ≥ 15 from the green, orange, and red agreement colours in ordinary vision.
- **Shapes.** A source's chart shape now comes from its `colorIndex`
  (`DataSource.symbol`), so it no longer changes when another device enters the range.
  A sixth shape (`.cross`) gives every slot its own. If two visible devices share a
  slot, the later one takes an unused shape.
- **Pairwise timeline.** It uses the same shapes and labels its line ends "A" and "B".
  Both legends draw the plotted shape (`SourceSymbolGlyph`) instead of a dot.
- **Reference lines.** Mean bias, limits of agreement, zero, and the tolerances use
  neutral ink told apart by dash pattern and weight (`HeartSyncTheme.Chart`). The legend
  draws the real strokes. Out-of-limit points keep their severity tint and gain a neutral
  ring instead of turning purple.
- **Sleep stages.** Stages are drawn as a lightness ramp in one hue: deep is darkest,
  and REM is lighter than light sleep. Awake is pale amber and also hatched, in the
  ribbon and in the legend. The minimum stage-to-stage ΔE is 19.2 under every simulated
  condition.

Still open: an on-device look at both appearances and at the hatch rendering.

### 32. Make the metric-detail chart scrubbable with an inline callout

**Observed behavior**

The metric-detail chart ([MetricDetailView.swift](Sources/Views/MetricDetailView.swift#L189))
has no selection, annotation, or gesture. Values can be estimated only from gridlines.
The per-window facts the snapshot already computes cannot be read for a chosen moment:
each device's window median, the band width, its severity, and the estimate and
compacted flags.

**Improve it**

- Add `.chartXSelection(value:)` (iOS 17). The framework handles gesture recognition and
  writes the selected x value to a binding. Snap the raw date to the nearest bucket with a
  binary search over sorted bucket starts precomputed in the snapshot.
- At the selected bucket, draw a `RuleMark` and enlarge that bucket's points. Attach an
  annotation that fits within the chart horizontally, so the callout never clips at the
  edges. The callout lists:
  - the window's time span;
  - each device's median, with its colour and symbol;
  - the band width and severity;
  - Estimate and Compacted flags, where they apply.
- Play `.sensoryFeedback(.selection, trigger:)` on the snapped bucket, so each new window
  ticks once rather than on every pixel.
- Make legend entries toggles that emphasise one series (dimming the others) without
  removing data.
- Clear the selection on a range change and on a tap outside the plot. Label the callout
  values as window medians, because that is what the chart draws.

```swift
@State private var selectedDate: Date?

Chart {
    // … existing band, LineMark, and PointMark content …

    if let window = snapshot.window(nearest: selectedDate) {   // O(log n), precomputed
        RuleMark(x: .value("Selected window", window.start))
            .foregroundStyle(.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(
                position: .top,
                spacing: 4,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
                SelectedWindowCallout(window: window, series: snapshot.series, kind: kind)
            }
    }
}
.chartXSelection(value: $selectedDate)
.sensoryFeedback(.selection, trigger: snapshot.window(nearest: selectedDate)?.start)
```

**Done when**

Scrubbing shows a callout for every bucket, including the first and last, without
clipping. No store query runs during a scrub (depends on 28/29). VoiceOver can reach the
same values (see 37). Estimated values stay labelled and never enter the band.

**Implementation status (2026-09-26): done in code. The on-screen, haptic, and VoiceOver
checks are still to do.**

- **Selection.** The chart is now its own view, `MetricDetailChart`, so a touch-move
  re-evaluates only the chart and not the list around it. It uses
  `.chartXSelection(value:)`. The raw date snaps to the nearest drawn window by a binary
  search over window starts, which `MetricChartProjection` sorts once per load. Selection
  is `@State`, and it is not part of any load key, so a scrub never reads the store.
- **Sticky selection with an empty-area rule.** A touch snaps to a window only when that
  window is within 22 pt, half of Apple's 44 pt minimum hit target. The 22 pt are
  converted to seconds from the chart's measured width. A touch farther than that from
  every window is in empty plot area and clears the selection, instead of jumping to a
  window hours away. Lifting the finger keeps the selection so the callout can be read.
  **Clear selection**, a range change, a zoom, or a pan also clear it. Together, the
  empty-area touch and **Clear selection** replace the proposed "tap outside the plot".
- **Callout.** The selected window gets a dashed rule in the neutral selection ink and
  larger points. Its annotation uses `overflowResolution` `.fit(to: .chart)` on both axes,
  so it stays inside the chart at the first and last window. The callout
  (`MetricWindowCallout`) lists:
  - the window's span, and the words "window medians";
  - each device's median, with its glyph and legend label;
  - the spread against the metric's tolerances, for example "Spread 7 bpm, at or over the
    5 bpm warning tolerance". When fewer than two measured devices reported, it says "Not
    compared: fewer than two measured devices" instead;
  - "Estimate: modelled, not measured" and "Compacted median: raw samples no longer
    stored", where they apply.

  The spread wording never says "agree". One window is not evidence, and the app requires
  at least five paired windows for a conclusion. As on the band, estimates are excluded
  from the spread.
- **Haptics.** `.sensoryFeedback(.selection, trigger:)` fires on the snapped window's start,
  so each new window ticks once rather than on every pixel.
- **Legend emphasis.** Legend entries are now buttons. One emphasises a device and dims the
  others' lines and points; no data is hidden. Entries are 44 pt tall and expose an
  "Emphasised" value and the selected trait to VoiceOver.
- **VoiceOver.** Each point has a label (device and time) and a value, for example "72 bpm,
  window median", plus "estimate, not measured" or "compacted" where they apply. Lines and
  band are hidden from VoiceOver, so each device's window is one stop. The callout is
  hidden too, because it repeats those values.
- **Tests.** `Tests/MetricDetailSelectionTests.swift` (12 tests) covers:
  - every drawn window can be selected, including the first and the last;
  - a touch in empty plot area selects nothing;
  - the callout's order and flags;
  - an estimate never creates or widens the spread;
  - the tolerance wording, which never claims agreement;
  - the callout's spread equals the band drawn at that window;
  - the pinned domain;
  - the screen-to-seconds conversion.

Still open:

- An on-screen look at the callout at the first and last window, in both appearances, at
  large Dynamic Type sizes, and on iPad.
- The haptic tick on a device.
- A VoiceOver pass. The wider Audio Graph work stays with item 37.

### 33. Add pan, zoom, and period selection to history charts

**Observed behavior**

- Each range draws fixed buckets from `TimeRange.chartBucket`: 15-minute medians at 24H,
  hourly at 7D, and 6-hour at 30D. A 20-minute episode inside a week cannot be inspected
  except by switching to 1H, and 1H always ends at "now".
- No history chart pins its x-axis domain; none calls `chartXScale`. The axis spans only
  the data extent. A 7D chart with data from the last day looks like a one-day chart with
  date labels, which hides the six empty days.
- Creating a saved session requires typing a start and an end into two `DatePicker`s
  ([ComparisonSessionsView.swift](Sources/Views/ComparisonSessionsView.swift#L132)).

**Improve it**

- Pin `.chartXScale(domain:)` to the snapshot's resolved interval, so empty spans stay
  visibly empty.
- Use the iOS 17 scrolling API:
  - `.chartScrollableAxes(.horizontal)`;
  - `.chartXVisibleDomain(length:)`, in seconds for a date axis;
  - `.chartScrollPosition(x:)`;
  - `.chartScrollTargetBehavior(.valueAligned(…))`, to snap to hours or days.

  The API scrolls a fixed visible length and has no built-in pinch zoom. Implement zoom by
  changing that length: from buttons, or from a `MagnifyGesture` that has been checked on
  a device to coexist with `List` scrolling.
- **Semantic zoom.** When the visible length shrinks, reload just the visible span at a
  finer bucket, down to the metric's `comparisonWindow`. Zooming then reveals real detail
  instead of magnifying 6-hour medians. State the current bucket, for example "15-minute
  medians".
- **Period selection.** `chartXSelection(range:)` exists, but on iOS its default gesture
  is a two-finger tap, which few people will discover. A visible "Select period" mode is
  easier: drag via `chartGesture` and `ChartProxy`. Show that span's pair evidence and
  offer **Save as session…** pre-filled with its bounds. This delivers the guided capture
  that item 22 deferred, directly from the chart.
- An Apple Developer Forums report says annotation overflow resolution misbehaves
  together with `chartScrollableAxes` on iOS 17. The reported workaround is
  `y: .fit(to: .chart)`. Verify the callout from item 32 inside a scrolling chart.

**Done when**

A week of data can be panned and zoomed to a one-hour span drawn from one-minute medians,
and the visible bucket is stated. A brushed period can be saved and reopened with
identical bounds. The statistics for a brushed period match those of the same span opened
as a saved session.

**Implementation status (2026-09-26): done, with zoom and pan on buttons rather than pinch
or chart scrolling. On-screen checks are still to do.**

- **Pinned x domain.** Metric detail pins `.chartXScale(domain:)` to the resolved span. The
  domain is widened back to the first bucket boundary so the first window is drawn inside
  the plot. A 7D chart with one day of data now shows six empty days. The pair timeline and
  the Oura charts pin their domains too (items 34 and 35).
- **Why not chart scrolling.** This departs from the proposal. The chart does not use
  `chartScrollableAxes`, `chartXVisibleDomain`, or a `MagnifyGesture`, because of two
  Apple bugs reported in the Developer Forums:
  - With `chartScrollableAxes`, a selection's annotation stops displaying at all
    (FB12584128, [thread 733711](https://developer.apple.com/forums/thread/733711)).
    Reports there run from July 2023 to June 2024, the most recent on iOS 18. The only
    workaround posted overlays a second, non-scrolling chart to draw the annotation. The
    `y: .fit(to: .chart)` workaround mentioned above (thread 737244) is about the
    callout's placement, not this.
  - Changing `chartXVisibleDomain` after the user has scrolled makes the chart jump to a
    different stretch (FB14091989, [thread 757099](https://developer.apple.com/forums/thread/757099)).
    Apple staff confirmed the jump in July 2024. The workaround they offered does not
    cover animated changes.

  The callout is the point of item 32, so zoom uses a pinned domain instead.
  `ChartViewport` holds the visible span, and four buttons move it: **Zoom in**, **Zoom
  out**, **Show earlier**, and **Show later**. Each is 44 pt and labelled, so VoiceOver and
  UI tests can reach it.
  - Zoom steps through the `TimeRange` spans shorter than the period: for a week, 24
    hours, 6 hours, then 1 hour. It never goes narrower than one hour, or than four of the
    metric's comparison windows.
  - Zoom in centres on the selected window, or else on the newest drawn window.
  - A pan moves half a span and stops at the period's edges. The last position ends
    exactly at the period's end, so a rolling range's newest readings stay reachable even
    though "now" is not on the bucket grid.
  - A live reload leaves a viewport that still fits where the user put it.
- **Semantic zoom.** A zoomed span is re-read from the store at its own bucket
  (`MetricZoomSnapshot`). The bucket is the metric's comparison window, widened to the
  preset that fits the span: the same rule the whole period uses. A week of heart rate
  zooms in three steps to one hour drawn from 1-minute medians. A caption states the bucket
  and span, for example "Showing 1-minute medians, 3 Sep 2026 at 10:00 – 11:00".
  - The zoom read runs in `.task(id:)`, rejects late results, and coalesces data-only
    reloads with `LiveReloadPolicy`.
  - Until it arrives, the previous chart stays up, dimmed, with a progress indicator.
  - A failed zoom read shows the retryable unavailable view, never an empty hour.
  - Statistics, device pairs, and the per-device table still describe the whole analysed
    period.
- **Period selection.** **Select period** puts the chart in period mode. There, a drag
  chooses a span, drawn as a neutral band, and **Use the span shown** takes the visible
  span instead. The drag layer sits in `chartOverlay` rather than the proposed
  `chartGesture`. It exists only in period mode, so the rest of the time the chart keeps the
  built-in selection gesture. The span snaps outward to the drawn buckets and stays inside
  the chart. Both ends are whole seconds, because the sessions archive stores ISO-8601
  dates without fractions. The chosen period gets a **Selected period** section with:
  - pair evidence for exactly that span (`MetricPeriodEvidence`), from the same read and
    engine call that metric detail uses for a saved session over the same seconds;
  - **Save as session…**, which opens the existing save sheet with the bounds and, new,
    the metric filled in;
  - **Clear period**.
- **Tests.** `Tests/ChartZoomTests.swift` (13 tests) covers:
  - the zoom steps and their floor;
  - a week zoomed to one hour at 1-minute medians, with the bucket named;
  - centring, zooming out, the pan edges, and the live edge;
  - reload stability, the finer re-read, and a failed read;
  - snapping.

  Two of those tests pin the "Done when" paragraph. A brushed period has exactly the
  statistics of the same span opened as a saved session. A brushed period saved through the
  sessions archive reopens with identical bounds. The UI test
  `testMetricDetailZoomNamesItsBucketAndOffersAPeriod` zooms from 15- to 5- to 1-minute
  medians, takes the span shown, opens the save sheet, and zooms back out.

Still open:

- Pinch and swipe. If they are wanted, first re-test the two bugs above on the current iOS.
  The buttons stay as the accessible path either way.
- An on-screen look at the period band, the dimmed loading state, and the controls row at
  large Dynamic Type sizes.
- The zoom read with a month of 1 Hz data on a device. A one-hour zoom reads one hour,
  but the whole-period snapshot still loads first, on the main actor (item 21).

### 34. Rebuild pairwise-chart selection on the native selection API

**Observed behavior**

The pairwise screen is the only interactive chart, and it does link its two charts:
selecting a window highlights it in both. Five gaps remain:

- **Scrolling.** Selection comes from a transparent `Rectangle` plus a
  `DragGesture(minimumDistance: 0)` overlay
  ([PairwiseAnalysisView.swift](Sources/Views/PairwiseAnalysisView.swift#L483), L483–527).
  A zero-distance drag inside a `List` competes with vertical scrolling. Two charts of
  250 and 280 pt cover much of the screen, where a swipe may start a selection instead of
  a scroll. Verify on a device.
- **Unreachable outliers.** The Bland–Altman overlay picks the point with the nearest
  *paired mean* and ignores the vertical axis (L520–523). When many windows share a
  similar mean (resting heart rate around 60–70 bpm), the outliers a Bland–Altman plot
  exists to show cannot be selected apart from the dense cluster at the same x.
- **Details off-screen.** The selected window's details appear in a separate section below
  both charts (L94–98). They are off-screen while a finger is on the timeline.
- **Selection feedback.** A selection cannot be cleared except by changing the range, and
  there is no haptic feedback.
- **VoiceOver.** The overlay is invisible to VoiceOver, and the accessibility hint tells
  VoiceOver users to "Drag across the chart".

**Improve it**

- On the timeline, use `.chartXSelection(value:)`.
- On the Bland–Altman plot, use `.chartGesture` with `ChartProxy` and pick the point
  nearest in **screen space** in both x and y, so stacked outliers can be selected.
- Add a compact on-chart callout (A, B, A − B, and the timing flag). Keep the full card
  below for details.
- Tap empty plot area to deselect, and add selection haptics.
- Add accessibility actions that step the selection to the next or previous paired
  window, and label each plotted observation. For example: "14:32, A 72, B 75, A minus B
  −3 bpm, outside limits".

**Done when**

The list scrolls normally when a vertical swipe starts on a chart (device check). Any
plotted point, including vertically stacked outliers, can be selected. VoiceOver users can
step through windows. The selected window's key values are visible without scrolling.

**Implementation status (2026-09-26): done in code. The list-scrolling device check and a
VoiceOver pass are still to do.**

- **Timeline.** Both charts are now views of their own (`PairwiseCharts.swift`). The
  zero-distance drag overlays are gone. The timeline uses `.chartXSelection(value:)` with
  the same sticky rule as metric detail. A touch snaps to a paired window within 22 pt,
  a touch farther than that clears the selection, and lifting the finger keeps it. Its x
  domain is pinned to the analysed span, so a stretch with no paired window stays visible.
- **Bland–Altman.** A tap selects the point drawn nearest the finger in both x and y
  (`ChartLookup.nearestIndex(to:in:within:)`). Each plotted point is placed with
  `ChartProxy.position(forX:)` and `position(forY:)`, and the nearest one within 22 pt
  wins. An outlier stacked above the dense cluster at the same paired mean can therefore
  be selected on its own. A tap farther than that from every point clears the selection.
  The recogniser is a tap in `chartOverlay`, not the proposed `chartGesture` drag. A tap
  gives up as soon as the finger moves, so it cannot hold on to a scroll. This replaces
  item 28's binary search over sorted paired means, which ignored the vertical axis. The
  per-tap search is linear over at most 500 plotted points, and it runs once per tap, not
  once per frame.
- **Callouts.** Both charts show a compact callout at the selected window
  (`PairwiseObservationCallout`). It fits inside the chart on both axes and shows:
  - the time;
  - A, B, and A − B, tinted by severity;
  - the timing flag;
  - "Outside the observed 95% limits", where that applies.

  The full card below the charts stays for the other details.
- **Deselect and haptics.** A touch in empty plot area on either chart clears the
  selection, and so does **Clear selection**. `.sensoryFeedback(.selection, trigger:)`
  ticks once per newly selected window.
- **Stepping and VoiceOver.** **Previous window** and **Next window** buttons (44 pt,
  labelled) step through the drawn windows and stop at either end. Both charts expose the
  same steps as the named accessibility actions "Next paired window" and "Previous paired
  window". Each paired window is one VoiceOver stop, with a spoken summary such as "3 Sep,
  14:32, A 72, B 75, A minus B −3 bpm, outside limits", plus the timing and compacted
  caveats. The old "Drag across the chart" hint is gone.
- **Tests.** `Tests/PairwiseSnapshotTests.swift` grows from 8 to 13 tests. The item 28
  nearest-mean test is replaced by a two-dimensional one, checked against a linear scan.
  New tests cover:
  - selecting a stacked outlier;
  - a tap in empty plot area on either chart;
  - stepping and its ends;
  - the spoken summary;
  - the pinned timeline domain.

  The UI test `testPairSelectionStepsWithoutADragAndClears` steps with **Next**, finds the
  selected card, and clears it.

Still open:

- The device check that a vertical swipe starting on either chart scrolls the list, and
  that a sideways scrub on the timeline is not taken over by the list. One external
  report describes the second problem with `chartXSelection` inside an iPhone scroll view
  ([bainluck PR #8582](https://github.com/alexander-bain/bainluck/pull/8582): "a
  press-and-drag drew a crosshair for a moment, then the page scrolled under his thumb").
  If a device shows the same, **Previous** and **Next** still reach every window. A
  hold-to-scrub recogniser is the fallback that report adopted.
- A VoiceOver pass over the stepping actions and the spoken summaries.

### 35. Turn the Oura cards into real charts: heart rate, hypnogram, 14-day trends

**Observed behavior**

- The Oura heart-rate chart is static; item 30 covers its interpolation and gaps.
- The sleep and movement ribbons are `Canvas` drawings
  ([OuraCardComponents.swift](Sources/Views/Oura/OuraCardComponents.swift#L203)) with no
  time axis. A user cannot tell when a stage or activity class happened. VoiceOver hears
  only "Sleep-stage timeline with 96 five-minute intervals".
- In the movement ribbon, the colour map draws code `"0"` (Oura: non-wear) as grey
  ([OuraMovementSection.swift](Sources/Views/Oura/OuraMovementSection.swift#L85)), but the
  legend (L48) lists only Rest to High. Grey segments are unexplained.
- The score and biomarker cards show only the latest value, although the cache keeps up to
  14 days per collection (`OuraManager.sync(days: 14)`). There is no trend or baseline
  context.

**Improve it**

- Draw the sleep ribbon as a Swift Charts hypnogram. Use one `RectangleMark` per run of
  consecutive identical stages, timed from `bedtime_start` in five-minute steps. Order
  stages conventionally (Awake on top, Deep at the bottom), add an hour axis, and add
  `chartXSelection` to read, for example, "REM 02:10–02:35". Do the same for movement
  over the activity day. Keep the "Oura's classification, not HeartSync's" wording.
- Add **Non-wear** to the movement legend.
- Add a 14-day sparkline or small bar chart to each score card (Readiness, Sleep,
  Activity) and to relevant biomarkers (RMSSD, lowest heart rate, temperature deviation).
  Highlight the latest day and let a tap reveal a day's value. Show missing days as gaps.
  Draw temperature deviation around a zero baseline and label it as a deviation, never an
  absolute temperature.
- Make the heart-rate chart selectable (time plus bpm callout), with the gap handling
  from item 30.

**Done when**

The stage or class at a chosen time can be read both visually and with VoiceOver. The
legend covers every code the colour map draws. Trends use cached documents only, and add
no new scopes or requests.

**Implementation status (2026-09-26): done in code. On-screen and VoiceOver checks are
still to do.**

- **Hypnogram.** `OuraTimelineChart` draws the night in Swift Charts, with one
  `RectangleMark` per run of identical stages. `OuraCategoryTimeline` times each run from
  `bedtime_start` in five-minute steps.
  - Rows run Awake, REM, Light, Deep from top to bottom, under an hour axis.
  - `chartXSelection` shows the run under the finger, for example "REM · 02:10–02:35 ·
    25m". The selection stays after the finger lifts, and a touch in an unclassified gap
    clears it.
  - Each run is its own VoiceOver element that names the stage and its times. The chart
    as a whole reads the night's span and the total per stage.
  - A code Oura does not define becomes a counted gap, never a guessed stage.
  - Without stage codes or a parseable bedtime, the card keeps the untimed ribbon from
    item 31.
  - The caption keeps "Oura's stage classification, not HeartSync's". Stage colours
    follow item 31's lightness ramp. The row already identifies a stage, so Awake is not
    hatched on the chart; the fallback ribbon and its legend keep the hatch.
- **Movement.** The same chart shows the activity day's classes, timed from
  `DailyActivity.timestamp`. Oura's activity day is a 24-hour period that starts at
  4 a.m. The DTO gains `timestamp` as an optional field. A cache written before this
  change decodes unchanged and keeps the untimed ribbon, because no clock is guessed for
  it. The legend now includes **Non-wear**. It is generated from `OuraMovementClass`, the
  same type the colour map uses, so it covers every code the map can draw.
- **Fourteen-day trends.** The Readiness, Sleep, and Activity score cards show bars. The
  lowest heart rate and RMSSD biomarkers show lines, and temperature deviation shows bars
  above and below a neutral zero rule. `OuraDailyTrend` builds each one from the cached
  snapshot only:
  - fourteen calendar days, ending at the newest cached day;
  - the first document per day wins, as in the card's headline;
  - nightly values come from each day's main sleep, the one the headline shows;
  - a missing day is an empty slot, and lines break there;
  - days are keyed by Oura's own day string, so a day never shifts to its neighbour in a
    time zone west of Greenwich.

  The latest day is drawn strongest. A tap shows another day's value in the card, for
  example "Sep 3: 82" or "Sep 1: no score". Temperature deviation reads "… from baseline"
  and is never drawn as an absolute temperature. VoiceOver hears one sentence per card,
  for example "Last 14 days: 12 of 14 days reported, from 61 to 88, latest 82 on Sep 3".
  No request, scope, or sync window changed.
- **Heart rate.** `OuraHeartRateChart` is selectable. A drag snaps to the nearest drawn
  sample within 22 pt and shows its time and bpm; a touch in an upload gap clears the
  selection. The x domain is pinned to the 24 hours that end at the newest cached sample,
  so a gap stays visible. Item 30's segmentation is unchanged.
- **Fixture.** In Debug builds, `--ui-test-ouraCharts` injects fourteen days of Oura
  documents. They include a charging gap, a missing night, and a missing readiness day.
  The UI test `testOuraChartsDrawStagesMovementHeartRateAndTrends` scrolls through the
  new charts' captions and the trend sentence.
- **Tests.** `Tests/OuraChartTests.swift` (16 tests) covers:
  - run timing and the run at a chosen moment;
  - undefined codes, and the ribbon fallback;
  - movement timing, and a legacy cache that decodes without a clock;
  - legend coverage, including non-wear;
  - the fourteen-day span, first-document-wins, and gaps and line breaks;
  - the spoken summary;
  - temperature as a signed deviation;
  - main-sleep selection;
  - the UI fixture;
  - heart-rate selection, which selects nothing inside a gap.

Still open: an on-screen look at the hypnogram, movement chart, and trends in both
appearances and at large Dynamic Type sizes, and a VoiceOver pass that reads a stage and a
class with their times.

### 36. Give the Now tab sparklines, motion, and honest "live" labelling

**Observed behavior**

- Each card shows only the latest value per device, with no trend.
- Values change without transition. Nothing beyond a timestamp shows which sources are
  actively streaming.
- The **Live sources** header ([DashboardView.swift](Sources/Views/DashboardView.swift#L90))
  counts every Apple Health source as live whenever HealthKit is authorised (L84), and
  Oura whenever it is connected. VoiceOver reads each chip as "connected". This conflicts
  with `SourceTransport.isLive`, whose documentation says only Bluetooth streams live and
  that "the UI says so rather than showing a stale value as live". When no source
  qualifies, the header title still renders above an empty row.
- The only navigation on a card is the small "History and agreement" pill. Check it
  against Apple's minimum hit target of 44 × 44 pt.

**Improve it**

- Add a sparkline to each card, per source colour, with no axes and the gap rules from
  item 30: the last hour for fast metrics, the last 14 days for daily ones. Omit the
  sparkline when there is a single point. The data comes from the bounded per-metric read
  in item 29.
- Animate value changes with `.contentTransition(.numericText(value:))`. Pulse the heart
  glyph with `symbolEffect(.pulse)` only while a Bluetooth source is streaming; SF Symbol
  effects honour Reduce Motion automatically.
- Rename the header to **Sources**. Give each chip a status derived from `isLive` and
  freshness: Live, Synced 5 min ago, or Waiting. Hide the header when it is empty.
- Make the whole card the navigation target, or enlarge the pill to meet the minimum.

**Done when**

A card shows a trend that never implies unmeasured continuity. Apple Health and Oura
chips never claim to be live. Motion is disabled under Reduce Motion, apart from the
system's own symbol handling. A UI test covers the no-connected-sources state.

**Implementation status (2026-09-26): done in code. On-screen and Reduce Motion checks are
still to do.**

- **Sparklines.** `Sparkline` (in `DashboardSnapshot.swift`) draws one line per source on
  the card: the median of each completed comparison window, over the last hour for fast
  metrics and fourteen days for daily ones. Lines break at a missing window
  (`ChartSegmentation`), a lone window is a dot, interpolation is monotone, and the x domain
  is pinned. With fewer than two windows there is no sparkline. It stops at the start of
  the current window, so `DashboardSnapshot` keeps it in `sparklineCache` and re-reads only
  when a window closes. The 1 Hz reload does not re-read an hour of rows each second.
  VoiceOver hears one sentence per source: first and last value, range, and gaps.
- **Motion.** The headline uses `.numericText(value:)` and `.snappy`, both off under Reduce
  Motion. The heart-rate glyph pulses (`symbolEffect(.pulse)`) only while a Bluetooth
  source on that card is streaming.
- **Sources header.** Renamed **Sources** and hidden when empty. `SourceChipStatus` gives
  each chip Live, Synced *n* ago, or Waiting. Only a transport with `isLive` (Bluetooth)
  that is streaming can be Live. Apple Health and Oura show their managers' last sync time.
- **Target.** The History and agreement pill is at least 44 pt tall, with a capsule hit
  shape and the label "History and agreement for *metric*".
- **Tests.** `Tests/DashboardTrendTests.swift`: window medians, gaps and dots, the
  single-point rule, spans, the spoken summary, caching until the window closes, and chip
  status. `testNowWithoutConnectedSourcesHidesTheSourcesHeader` checks the empty header,
  the trend's label, and the pill's height.

### 37. Make dense charts work with VoiceOver, Audio Graphs, and Dynamic Type

**Observed behavior**

- Swift Charts builds an accessibility tree and an Audio Graph automatically. Metric
  detail, however, emits a `LineMark` and a `PointMark` for every bucket of every source,
  plus the band. Its marks carry no custom accessibility label or value, so the source
  name, estimate, and compacted status are not spoken per point. Check on a device how
  many elements VoiceOver visits on a 30-day chart.
- `PairwiseAnalysisView` sets chart-level hints that ask the user to drag (see 34).
- Chart heights are fixed at 240, 250, 280, and 210 pt. At accessibility text sizes the
  axis labels grow while the plot shrinks. On iPad, charts stay phone-sized.
- The metric-detail and Oura heart-rate charts have no y-axis unit. The Bland–Altman plot
  has axis labels with units.

**Improve it**

- Give the `PointMark`s `.accessibilityLabel` and `.accessibilityValue`: source label,
  time, value with unit, and Estimate or Compacted where relevant. Hide the duplicate line
  and band marks from accessibility. Alternatively, supply an `accessibilityChartDescriptor`
  that summarises one series per device for the Audio Graph.
- Add `.chartYAxisLabel` with the metric's unit.
- Scale chart height with Dynamic Type (`@ScaledMetric`) and with the available width on
  iPad (`containerRelativeFrame` or an aspect ratio).

**Done when**

A VoiceOver pass at the largest accessibility text size can read each device's values on
metric detail, pairwise, and Oura charts. The Audio Graph is available and names the
series. No chart's plot area collapses at AX5.

**Implementation status (2026-09-26): done in code. The VoiceOver and Audio Graph pass at
AX5 is still to do.**

- Metric-detail points already carried source, time, value, and Estimate or Compacted
  (item 32), with lines and band hidden. The chart now also has a `chartYAxisLabel` with
  the unit, and `MetricAudioGraph` (`ChartAudioGraph.swift`) replaces the automatic Audio
  Graph. The automatic one names series by the stable source ID; this one names each
  device by its label and marks estimated and compacted points.
- Oura heart rate: each sample is spoken with its time and bpm. The area and duplicate dots
  are hidden. It has a `bpm` y-axis label and its own Audio Graph descriptor.
- Every history chart's height comes from `heartSyncChartHeight(_:)`. The base height grows
  with Dynamic Type (up to 2.2×), by 1.4× in a regular width, and by 1.2× in a compact
  height (landscape iPhone).
- The pair charts kept their existing summaries, named step actions, and axis labels from
  item 34.

### 38. Adapt layouts for iPad and landscape

**Observed behavior**

`project.yml` targets iPhone and iPad (`TARGETED_DEVICE_FAMILY: "1,2"`) and declares every
orientation, but no view reads a size class. Specifically:

- The `TabView` in [RootView.swift](Sources/App/RootView.swift#L19) uses the default style.
- Now is a single-column `LazyVStack` of cards.
- Charts have fixed heights.
- The metric chips in `SourceRow` are one non-wrapping `HStack`
  ([DevicesView.swift](Sources/Views/DevicesView.swift#L407)). A HealthKit writer that
  reports seven metrics can overflow a compact width at larger text sizes.

**Improve it**

- Apply `.tabViewStyle(.sidebarAdaptable)` (iOS 18). iPad gets a sidebar that can become
  a tab bar; iPhone keeps its tab bar.
- On Now, use `LazyVGrid(columns: [GridItem(.adaptive(minimum: 320))])`.
- On Compare in a regular width, use a `NavigationSplitView`: metrics on the left, the
  selected metric's detail on the right.
- Replace the chip `HStack` with a small flow `Layout`.
- Increase chart height in landscape on iPhone.

**Done when**

UI screenshots (see 41) of iPad in both orientations and iPhone in landscape show no
clipped chips, charts use the extra space, and the sidebar lists the five destinations.

**Implementation status (2026-09-26): done in code. The iPad screenshots come from the next
CI run; a device look is still to do.**

- `RootView` uses `.tabViewStyle(.sidebarAdaptable)`.
- Now lays its cards out in a `LazyVGrid` of adaptive 320 pt columns.
- In a regular width, Compare is a `NavigationSplitView`: the metric list selects into a
  detail column. A compact width pushes, as before.
- Metric chips on Devices use a new wrapping `FlowLayout` (`Components.swift`).
- Chart heights grow in landscape and on iPad (item 37).
- `testChartGalleryScreenshots` captures Now, metric detail, and the pair screen, then the
  pair screen and Now in landscape. CI runs it on an iPhone and on an iPad simulator.

### 39. Consolidate visual tokens, chart styling, and loading feedback

**Observed behavior**

- **Card styles.** The app uses two card vocabularies:
  - `metricCard` on Now ([Theme.swift](Sources/Views/Theme.swift#L90)): glass material,
    gradient, shadow, 22 pt radius;
  - `ouraCard` on the Oura tab
    ([OuraCardComponents.swift](Sources/Views/Oura/OuraCardComponents.swift#L17)): flat
    secondary background, 16 pt radius.

  The Oura header has its own gradient. Compare, Devices, and Settings are plain grouped
  lists.
- **Chart colours.** Chart code scatters hard-coded colours (`.blue`, `.purple`, `.orange`,
  `.red`, `.pink`) instead of tokens.
- **Loading feedback.** `CompareView.isLoading` is written (L12, L115–116) but never read.
  After the first load, changing the range keeps showing the previous range's results,
  with no "updating" cue, until the new snapshot lands. Metric detail behaves the same way.
- **Duplicated chart styling.** Axis formats, heights, interpolation, and point sizes are
  repeated across files. `axisFormat` is identical in `MetricDetailView` and
  `PairwiseAnalysisView`.

**Improve it**

- Choose one card treatment for content cards. Add a `HeartSyncTheme.Chart` token group
  (reference-line ink, tolerance dash patterns, band opacity, heights) and a shared
  `axisFormat(for:)`. As `Theme.swift` already requires, keep semantic colours owned by
  the model types.
- While a load for a new key is in flight, show a small `ProgressView` in the section
  header and dim the stale content.

**Done when**

Chart colours and dash patterns come from one place. A range change shows immediate
feedback, and results never silently describe the previous range.

**Implementation status (2026-09-26): done.**

- `HeartSyncTheme.Chart` now also holds the caution ink, the heart-rate ink, the band
  opacity, every chart height, the shared `axisFormat(span:)` (moved out of
  `MetricDetailChart`), and a spoken `axisDescription`. The chart files use these instead of
  `.orange` and `.pink` literals. Semantic colours stay owned by the model types.
- One card surface: `ouraCard()` now draws `HeartSyncCardBackground`, the Now card surface,
  at the compact radius.
- Loading feedback: Compare's unused `isLoading` is gone. When the question changes (range,
  session, sources, threshold, estimates) but the snapshot still answers the old one,
  Compare and metric detail show "Updating for the new selection…" and dim the old results
  and make them inert and hidden from VoiceOver. New data alone still shows the existing lag
  note.

### 40. Adopt Always On guidance and gauges on the watch

**Observed behavior**

- The watch app never reads `isLuminanceReduced`. Apple's Always On guidance is to
  highlight what matters and hide what should stay private while luminance is reduced.
- The complications already mark measurements `privacySensitive()`
  ([HeartSyncComplications.swift](WatchComplications/Sources/HeartSyncComplications.swift#L50)),
  but the workout screen's live heart rate stays readable on a wrist-down display.
- The watch workout screen is a list of text, with no trend or zone context.
- The circular complication is text-only (L53). Heart rate and SpO₂ suit a gauge.

**Improve it**

- Use `@Environment(\.isLuminanceReduced)` on the workout and dashboard screens: dim
  secondary text and tints, and keep the heart rate and elapsed time prominent.
- Decide whether live heart rate should be privacy-sensitive in Always On, consistent with
  the complications, and document the decision.
- Add a small five-minute heart-rate trend from the samples the workout builder already
  delivers. Keep it in memory and add no new persistence. Any heart-rate zones based on
  age-predicted maximum must be labelled as estimates.
- Draw the circular complication as a `Gauge` with `.gaugeStyle(.accessoryCircular)`,
  keeping the Older and Median labels.

**Done when**

On a physical watch, Always On shows the chosen reduced presentation during a workout. The
circular complication renders as a gauge in tinted and full-colour faces, with the current
freshness labels.

**Implementation status (2026-09-26): done in code. The physical-watch checks are still to
do.**

- The workout and dashboard screens read `isLuminanceReduced`: labels lose their tint,
  secondary lines dim, and the trend hides. Heart rate and elapsed time stay prominent.
- **Decision:** live heart rate on the workout and dashboard is `privacySensitive()`, like
  the complications. The watch's own privacy settings decide redaction; elapsed time is not
  sensitive. Recorded in `WatchApp/README.md`.
- `WorkoutHeartRateTrend` (in `Shared/WorkoutPresentation.swift`) keeps the last five
  minutes of builder samples in memory. It drops repeats and out-of-order samples, is
  bounded to 600 samples, breaks after 30 seconds without a sample, and resets at Start and
  Discard. No zones are drawn, so no age-predicted maximum is involved.
- The circular complication is an `accessoryCircular` `Gauge` over the metric's display
  range. It shows Older or Median in the ring's opening, and a dash with an empty ring when
  the reading is older.
- Tests: `Tests/Watch/WorkoutTrendTests.swift` (4). Previews: the circular gauge (current,
  older, compacted) and watch metric detail.

### 41. Add previews, chart fixtures, and screenshot artefacts for UI work

**Observed behavior**

- No iOS or watch view has a `#Preview`, although `OuraDashboardView`'s header says its
  sections take data slices "so the sections stay independently previewable".
- `DebugAnalysisFixtures` holds 8 minutes of heart rate and 6 minutes of SpO₂ for two
  sources. That proves the evidence flow, but it is not enough to judge gaps, thinning,
  three or more sources, same-name series, estimates, compaction, or month ranges.
- CI uploads the `.xcresult`, but the UI tests attach no screenshots, so a pull request
  cannot show its visual changes.
- The thinning caps (500 pairwise points, 240 Oura points) exist partly because every
  point is a separate mark.

**Improve it**

- Add `#Preview`s for each chart view and each Oura section, fed from fixtures, in light,
  dark, and large-text variants.
- Add a Debug-only `--chart-gallery` fixture with 30 days of data: gaps, four sources
  (two of them same-named), estimates, and compacted windows.
- In UI tests, attach `XCTAttachment(screenshot:)` with `lifetime = .keepAlways` for key
  screens, so the CI artefact shows the UI.
- Evaluate the iOS 18 vectorized plots (`LinePlot`, `PointPlot`) for dense, uniformly
  styled series such as Oura heart rate and the Bland–Altman cloud. Measure before
  raising the caps. Keep per-mark APIs where marks need individual styling, such as
  estimates and selection.

**Done when**

Chart and Oura views render in Xcode previews from fixtures. The CI artefact contains
screenshots of Now, metric detail, pairwise, Oura, and an iPad layout.

**Implementation status (2026-09-26): done. The previews have not been opened in Xcode yet.**

- `--chart-gallery` (`DebugChartGallery`, Debug only, in memory) installs thirty days:
  - four measuring sources, two of them named "Polar H10";
  - gaps of hours and days;
  - estimated VO₂ max beside measured values;
  - compacted heart-rate windows older than fourteen days;
  - the last two hours at one-minute resolution.
  Values are smooth functions of time, so runs are repeatable. It starts no transport.
- `Sources/Debug/ChartPreviews.swift` has previews for metric detail (30 days, and with
  estimates), the pair timeline, Bland–Altman, and every Oura section. Each draws light,
  dark, and AX3 variants. The Oura previews use `OuraManager.chartFixtureSnapshot`, the same
  documents as the `--ui-test-ouraCharts` test.
- UI tests keep screenshots (`XCTAttachment`, `.keepAlways`) of Now, metric detail, the pair
  screen, Oura, and landscape. CI adds an iPad run of the screenshot test. Both results are
  in the uploaded `.xcresult`.
- Vectorized plots (`LinePlot`, `PointPlot`) were evaluated and not adopted. Raising the
  thinning caps needs a device measurement first. The marks that would move also carry
  per-mark accessibility labels and selection styling.
- Tests: `ChartGalleryFixtureTests` checks the gallery's promises and that Now draws a
  trend and a comparison from it.

### UI strengths to preserve

- One immutable snapshot per load, with `.task(id:)` cancellation and late-result
  rejection, in Compare and metric detail.
- Gap-segmented metric-detail lines, series keyed by stable source ID, disambiguated
  labels, and a legend that speaks each symbol's name.
- Linked selection between the two pairwise charts.
- Explicit empty, unavailable, collecting, and insufficient-evidence states. Evidence is
  never coloured green by default.
- Thinning disclosed on screen, estimates drawn dashed and kept out of the band, and
  compound VoiceOver labels on rows and cards.

### Validation for this review

- Read every file in `Sources/Views` and `Sources/App`, the watch app and complication
  views, and the model, store, and analysis code that feeds them, at the commit above.
- Ran the palette simulation in the appendix (Python 3, `colorspacious` 1.1.2).
- Checked the API and platform claims against the sources below.
- Did not build, run tests, launch a simulator, or use a device. This environment has no
  Xcode. Each "Done when" paragraph is an acceptance criterion, not completed validation.
- Changed only `improvements.md`. No Swift, schema, signing, capability, or user health
  data was touched.

### Implementation validation (items 26–31)

The implementation ran in a Linux container without Xcode, an iOS simulator, or a device.

**Executed**

- The real source files ran through a scratch SwiftPM harness outside the repository, as
  `AGENTS.md` describes. It used Swift 6.1.2 on Linux, Swift 6 language mode, and
  complete concurrency checking.
- The harness compiles the store, model, analysis, Oura, Debug-fixture, `Shared`, and
  portable view-projection files. Small shims stand in for SwiftUI `Color`, UIKit colours,
  Charts symbol shapes, OSLog, CryptoKit, CoreBluetooth UUIDs, Security, and
  AuthenticationServices, plus an in-memory Keychain stub.
- 363 of the 417 hosted unit tests ran, including every new suite:

  | Suite | Tests |
  | --- | ---: |
  | `SourceRemovalTests` | 9 |
  | `DrillDownPeriodTests` | 6 |
  | `PairwiseSnapshotTests` | 8 |
  | `LiveReloadTests` | 8 |
  | `ChartGapTests` | 12 |
  | `ColourVisionTests` | 11 |

- 362 passed. The one failure is the existing `isExcludedFromBackup` check in the watch
  complication cache test; Linux Foundation does not implement that resource value.
- The 54 tests not run are in `HealthKitConversionTests`, `HealthKitSessionTests`, and
  `ImprovementTests`. They need HealthKit or CoreBluetooth, and none of them calls an API
  this change altered.
- `liveScreensDuringIngest` ran in a release build of the same harness. Its numbers are in
  item 29.

**Not compiled or run here**

- Not compiled: the SwiftUI screens (`DevicesView`, `MetricDetailView`,
  `PairwiseAnalysisView`, `CompareView`, `DashboardView`, `ComparisonSessionsView`,
  `Components`, `Theme`, `SourceSymbolGlyph`, `ReadingsShareSheet`, and the Oura views),
  `AppModel`, and the UI tests. These were reviewed by reading only. CI's `xcodebuild test`
  is their first compile and the first run of the three new UI tests.
- Not done:
  - simulator or device runs;
  - VoiceOver, Dynamic Type, or dark-appearance passes;
  - on-screen chart checks;
  - Time Profiler traces;
  - the removal dialog's hand-off to the export share sheet.
- New interface strings reach `Resources/Localizable.xcstrings` on the next Xcode build,
  as with earlier changes. The catalog was not edited by hand.

### Implementation validation (items 32–35)

This implementation also ran in a Linux container without Xcode, an iOS simulator, or a
device.

**Executed**

- The same scratch SwiftPM harness, outside the repository, with Swift 6.1.3 on Linux
  (x86-64), Swift 6 language mode, and complete concurrency checking. Its closure gains
  the new Foundation-only files: `ChartLookup`, `ChartViewport`, `MetricChartProjection`,
  `Oura/OuraCategoryTimeline`, `Oura/OuraMovementClass`, and `Oura/OuraDailyTrend`.
- 409 of the 463 hosted unit tests ran, including every new or changed suite:

  | Suite | Tests |
  | --- | ---: |
  | `MetricDetailSelectionTests` | 12 |
  | `ChartZoomTests` | 13 |
  | `OuraChartTests` | 16 |
  | `PairwiseSnapshotTests` | 13 |

- 404 passed. The five failures belong to this container, and the same five fail on
  `main` here:
  - Four archive and settings tests make a file unreadable with `chmod 000` and expect
    the read to fail. The container runs as root, which ignores file permissions.
  - The watch complication cache test checks `isExcludedFromBackup`, which Linux
    Foundation does not implement. It was the one failure in the items 26–31 run.
- The 54 tests not run are the same HealthKit and CoreBluetooth suites as before. None of
  them calls an API this change altered.
- The Oura chart fixture behind `--ui-test-ouraCharts` compiled and ran in the harness,
  through its unit test.

**Not compiled or run here**

- Not compiled: the new and changed SwiftUI views (`MetricDetailChart`,
  `MetricDetailView`, `PairwiseCharts`, `PairwiseAnalysisView`, `ComparisonSessionsView`,
  `OuraTimelineChart`, `OuraTrendChart`, and the Oura card and section views), the
  `AppModel` scenario hook, and the UI tests. Their Swift Charts and SwiftUI calls were
  checked against Apple's documentation, for example `chartXSelection(value:)`,
  `ChartProxy.position(forX:)`, `plotFrame`, `value(atX:as:)`,
  `AnnotationOverflowResolution`, `sensoryFeedback(_:trigger:condition:)`, and
  `onGeometryChange(for:of:action:)`. CI's `xcodebuild test` is their first compile and
  the first run of the three new UI tests.
- Not done:
  - simulator or device runs;
  - VoiceOver, Dynamic Type, and dark-appearance passes;
  - on-screen checks of the callouts, the period band, the hypnogram, and the trends;
  - haptics;
  - the list-scrolling device check in item 34.
- Persisted data: `DailyActivity.timestamp` is optional, so earlier Oura caches decode
  unchanged (tested). `ComparisonSession` is unchanged; the save sheet now fills its
  existing optional `metric`. No stable ID, persisted raw value, or database schema changed.
- New interface strings reach `Resources/Localizable.xcstrings` on the next Xcode build.
  The catalog was not edited by hand.

### Implementation validation (items 36–41 and RingFix)

This implementation also ran in a Linux container without Xcode, an iOS simulator, a
watch, or a ring.

**Executed**

- The scratch SwiftPM harness, outside the repository, with Swift 6.1.3 on Linux (x86-64),
  Swift 6 language mode, and complete concurrency checking. Its closure gains the new
  Foundation-only files: `BluetoothDiagnostics`, `R11MRingSession`, `YCBTFrameCodec`, and
  `DebugChartGallery`. It also compiles the Oura manager and OAuth files through small
  shims, and `BluetoothManager.swift` through a CoreBluetooth shim, as a type check only.
- 446 of the hosted unit tests ran, including every new suite:

  | Suite | Tests |
  | --- | ---: |
  | `YCBTFrameCodecTests` | 7 |
  | `R11MRingSessionTests` | 10 |
  | `BluetoothReadinessDiagnosticsTests` | 8 |
  | `DashboardTrendTests` | 7 |
  | `ChartGalleryFixtureTests` | 1 |
  | `WorkoutTrendTests` | 4 |

- 441 passed. The five failures are the same container-only ones as before: four
  `chmod 000` checks, which root ignores, and `isExcludedFromBackup`, which Linux Foundation
  does not implement.
- Not run: `HealthKitConversionTests`, `HealthKitSessionTests`, and `ImprovementTests`. They
  need HealthKit, and none of them calls an API this change altered. The Bluetooth
  discovery tests in `ImprovementTests` use `PeripheralConnectionState`, which moved files
  unchanged.

**Not compiled or run here**

- Not compiled: the SwiftUI and watch views, `AppModel`, `ChartAudioGraph`, the previews,
  and the UI tests. They were checked by reading. The API shapes used were checked against
  Apple's documentation and WWDC sessions: `AXChartDescriptor`, `accessoryCircular` label
  placement, and `isLuminanceReduced`. CI's `xcodebuild test` is their first compile and the
  first run of the new UI tests and the iPad screenshot run.
- Not done:
  - any ring, simulator, device, or watch run;
  - VoiceOver, Audio Graph, Dynamic Type, Reduce Motion, and appearance passes;
  - an Xcode preview render;
  - the vendor-ring acceptance list in `RELEASE_CHECKLIST.md`.
- Persisted data: unchanged. No stable ID, persisted raw value, schema, or `Codable` field
  changed. `PeripheralConnectionState` moved from `BluetoothManager.swift` to
  `BluetoothDiscoveryState.swift` unchanged, apart from its titles for zero metrics.
- Capabilities: none added. The only new framework import is Accessibility, for the Audio
  Graph descriptors. `Charts` is now also imported by the watch app.
- New interface strings reach `Resources/Localizable.xcstrings` on the next Xcode build.

### Sources

- Apple, WWDC23: [Explore pie charts and interactivity in Swift Charts](https://developer.apple.com/videos/play/wwdc2023/10037/).
  Covers `chartXSelection(value:)` and `chartXSelection(range:)` (iOS range default: a
  two-finger tap), `chartAngleSelection`, `chartGesture`, `chartScrollableAxes`,
  `chartXVisibleDomain`, `chartScrollPosition`, `chartScrollTargetBehavior`, and
  annotation `overflowResolution`.
- Apple Developer Forums: [RuleMark annotation not respecting overflow resolution with chartScrollableAxes](https://developer.apple.com/forums/thread/737244).
- Apple, WWDC24: [Swift Charts: Vectorized and function plots](https://developer.apple.com/videos/play/wwdc2024/10155/).
- Apple documentation: [`InterpolationMethod.monotone`](https://developer.apple.com/documentation/charts/interpolationmethod/monotone)
  and [`AreaMark.init(x:yStart:yEnd:series:)`](https://developer.apple.com/documentation/charts/areamark/init(x:ystart:yend:series:)).
- Apple, WWDC21: [Bring accessibility to charts in your app](https://developer.apple.com/videos/play/wwdc2021/10122/).
  See also Create with Swift, [Making charts accessible with Swift Charts](https://www.createwithswift.com/making-charts-accessible-with-swift-charts/).
- Apple, WWDC24: [Elevate your tab and sidebar experience in iPadOS](https://developer.apple.com/videos/play/wwdc2024/10147/),
  and [`SidebarAdaptableTabViewStyle`](https://developer.apple.com/documentation/swiftui/sidebaradaptabletabviewstyle).
- Apple documentation: [`ContentTransition.numericText(value:)`](https://developer.apple.com/documentation/swiftui/contenttransition/numerictext(value:)).
  Use Your Loaf: [SwiftUI Sensory Feedback](https://useyourloaf.com/blog/swiftui-sensory-feedback/).
- Use Your Loaf: [SwiftUI Swipe Actions](https://useyourloaf.com/blog/swiftui-swipe-actions/)
  (`allowsFullSwipe` defaults to `true`; a full swipe performs the first action).
- Mehmet Baykar: [SwiftUI NavigationStack view lifecycle patterns](https://mehmetbaykar.com/posts/swiftui-navigationstack-view-lifecycle/)
  (`onAppear` fires again when a pushed view is popped).
- Apple, WWDC21: [What's new in watchOS 8](https://developer.apple.com/videos/play/wwdc2021/10002/)
  (`isLuminanceReduced`; apps with an active session may update once per second in
  Always On; others once per minute).
- Apple, WWDC22: [Go further with Complications in WidgetKit](https://developer.apple.com/videos/play/wwdc2022/10051/)
  (accessory gauges).
- Apple: [UI Design Dos and Don'ts](https://developer.apple.com/design/tips/) (44 × 44 pt
  minimum hit target).
- Oura API v2 schema field descriptions for `class_5_min` (0 = non-wear … 5 = high
  activity) and `sleep_phase_5_min` (1 = deep … 4 = awake), as mirrored in the
  [@pinta365/oura-api type documentation](https://jsr.io/@pinta365/oura-api/doc).
  The [official Oura API reference](https://cloud.ouraring.com/v2/docs) could not be
  fetched from this environment.

Checked while implementing items 26–31:

- Apple Developer Forums: [How to handle alert when deleting row from List](https://developer.apple.com/forums/thread/805352)
  (a confirmation dialog declared inside `.swipeActions` or `.contextMenu` disappears
  with them; declare it on a stable view).
- Apple Developer Forums: [AreaMark Always alignsMarkStylesWithPlotArea for linear gradients](https://developer.apple.com/forums/thread/766936)
  (each `AreaMark` is a point of one area, not a shape of its own; hence one series per
  severity run).
- Apple documentation: [`Text.DateStyle.relative`](https://developer.apple.com/documentation/swiftui/text/datestyle/relative)
  (example output "2 hours, 23 minutes", with no "ago", so the lag note supplies it).
- Apple documentation: [`ChartSymbolShape`](https://developer.apple.com/documentation/charts/chartsymbolshape)
  (built-in shapes include `circle`, `square`, `triangle`, `diamond`, `pentagon`, and
  `cross`), and Swift with Majid, [Mastering charts in SwiftUI: mark styling](https://swiftwithmajid.com/2023/01/18/mastering-charts-in-swiftui-mark-styling/).

Checked while implementing items 32–35:

- Apple Developer Forums: [SwiftUI chart annotation not working when using chartScrollableAxes](https://developer.apple.com/forums/thread/733711)
  (FB12584128; reports from July 2023 to June 2024, the most recent on iOS 18; the only
  posted workaround draws the annotation on a second, non-scrolling chart).
- Apple Developer Forums: [Swift Charts: Changing chartXVisibleDomain changes chartScrollPosition](https://developer.apple.com/forums/thread/757099)
  (FB14091989; an Apple staff reply in July 2024 confirms the jump and offers a workaround
  that does not cover animated changes).
- alexander-bain/bainluck, [PR #8582](https://github.com/alexander-bain/bainluck/pull/8582)
  (with `chartXSelection` inside an iPhone scroll view, "a press-and-drag drew a crosshair
  for a moment, then the page scrolled under his thumb"; the project moved to a
  hold-to-scrub recogniser).
- Apple documentation: [`chartXSelection(value:)`](https://developer.apple.com/documentation/swiftui/view/chartxselection(value:)),
  [`ChartProxy.plotFrame`](https://developer.apple.com/documentation/charts/chartproxy/plotframe),
  [`ChartProxy.position(forX:)`](https://developer.apple.com/documentation/charts/chartproxy/position(forx:))
  (positions are relative to the plot), [`ChartProxy.value(atX:as:)`](https://developer.apple.com/documentation/charts/chartproxy/value(atx:as:)),
  [`AnnotationOverflowResolution`](https://developer.apple.com/documentation/charts/annotationoverflowresolution),
  [`sensoryFeedback(_:trigger:condition:)`](https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:condition:)),
  and [`onGeometryChange(for:of:action:)`](https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)).
- Oura for Organizations: [Understanding the Different Types of Oura Days in Oura API Data](https://partnersupport.ouraring.com/hc/en-us/articles/29160913203219-Understanding-the-Different-Types-of-Oura-Days-in-Oura-API-Data)
  (the Activity Day runs from 4 a.m. to 4 a.m. and carries the first day's date). The
  field descriptions for `daily_activity.timestamp` ("Timestamp of the daily activity"),
  `class_5_min`, `sleep_phase_5_min`, and `bedtime_start` were checked in the
  [@pinta365/oura-api type documentation](https://jsr.io/@pinta365/oura-api/doc) listed
  above.

### Appendix: palette colour-vision check

<details>
<summary>Python script used for item 31 (<code>pip install colorspacious</code>)</summary>

```python
"""Pairwise distinguishability of HeartSync chart colours under simulated colour-vision
deficiency. Machado et al. (2009) model at severity 100, CAM02-UCS deltaE.
Rule of thumb: deltaE below ~10 is hard to tell apart at chart-mark sizes."""
from itertools import combinations

import colorspacious as cs
import numpy as np

def rgb(r, g, b):  # 0...1 components, as written in DataSource.palette
    return (r * 255, g * 255, b * 255)

palette = {
    "src0 blue":   rgb(0.00, 0.48, 1.00),
    "src1 orange": rgb(1.00, 0.42, 0.21),
    "src2 green":  rgb(0.20, 0.72, 0.47),
    "src3 purple": rgb(0.69, 0.32, 0.87),
    "src4 rose":   rgb(0.93, 0.26, 0.45),
    "src5 teal":   rgb(0.12, 0.70, 0.78),
}
# Approximate iOS light-appearance system colours used as semantic tints on the same charts.
semantic = {
    "sev green (.green)":   (52, 199, 89),
    "sev orange (.orange)": (255, 149, 0),
    "sev red (.red)":       (255, 59, 48),
    "bias (.blue)":         (0, 122, 255),
    "LoA (.purple)":        (175, 82, 222),
}
sleep = {"deep (.indigo)": (88, 86, 214), "REM (.purple)": (175, 82, 222)}

conditions = {
    "normal": None,
    "protan": {"name": "sRGB1+CVD", "cvd_type": "protanomaly", "severity": 100},
    "deutan": {"name": "sRGB1+CVD", "cvd_type": "deuteranomaly", "severity": 100},
    "tritan": {"name": "sRGB1+CVD", "cvd_type": "tritanomaly", "severity": 100},
}

def simulate(colour, condition):
    unit = tuple(v / 255 for v in colour)
    if condition is None:
        return unit
    return tuple(np.clip(cs.cspace_convert(unit, condition, "sRGB1"), 0, 1))

def delta_e(a, b, condition):
    return cs.deltaE(simulate(a, condition), simulate(b, condition), input_space="sRGB1")

def report(title, pairs):
    print(f"\n== {title} ==")
    print(f"{'pair':44s}" + "".join(f"{name:>8s}" for name in conditions))
    for (name_a, a), (name_b, b) in pairs:
        values = [delta_e(a, b, condition) for condition in conditions.values()]
        flag = "  <-- weak" if min(values) < 10 else ""
        print(f"{name_a + ' vs ' + name_b:44s}" + "".join(f"{v:8.1f}" for v in values) + flag)

report("Source palette, pairwise", list(combinations(palette.items(), 2)))
report("Source palette vs semantic tints", [(p, s) for p in palette.items() for s in semantic.items()])
report("Oura sleep ribbon", list(combinations(sleep.items(), 2)))
```

</details>

---


## Previous follow-up review (2026-09-08)

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
