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

### Priorities and suggested sequence

| Item | Priority | Improvement | Basis | Size |
| --- | --- | --- | --- | --- |
| 26 | P1 | Confirm before a swipe or button deletes a device's history | Observed defect | S |
| 27 | P1 | Keep the chosen range and a saved session's period when drilling down | Observed defect | S–M |
| 28 | P1 | Stop re-running the pairwise analysis on every drag frame | Observed performance risk | M |
| 29 | P1 | Bound and coalesce the live screens' reloads during ingest | Performance risk; measure on device | M |
| 30 | P1 | Break every chart line and band across data gaps; no overshooting curves | Observed honesty gap | S |
| 31 | P1 | Fix colour collisions for colour-blind readers and between meanings | Measured | M |
| 32 | P2 | Make the metric-detail chart scrubbable with an inline callout | Design proposal | M |
| 33 | P2 | Add pan, zoom, and period selection to history charts | Design proposal (+ observed axis gap) | M–L |
| 34 | P2 | Rebuild pairwise-chart selection on the native selection API | Design proposal (+ observed gaps) | M |
| 35 | P2 | Turn the Oura cards into real charts: heart rate, hypnogram, 14-day trends | Design proposal (+ observed legend gap) | M–L |
| 36 | P2 | Give the Now tab sparklines, motion, and honest "live" labelling | Design proposal (+ observed wording issue) | M |
| 37 | P2 | Make dense charts work with VoiceOver, Audio Graphs, and Dynamic Type | Accessibility gap | M |
| 38 | P2 | Adapt layouts for iPad and landscape | Design proposal | M |
| 39 | P2 | Consolidate visual tokens, chart styling, and loading feedback | Polish and maintainability | S–M |
| 40 | P2 | Adopt Always On guidance and gauges on the watch | Design proposal | S–M |
| 41 | P2 | Add previews, chart fixtures, and screenshot artefacts for UI work | Developer experience | M |

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
