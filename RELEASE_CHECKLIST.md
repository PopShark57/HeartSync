# HeartSync physical-device release checklist

Compilation, simulator tests, and fixture-driven UI checks are required gates, but they do
not prove the device integrations below. Complete this checklist on a signed Release
candidate installed on a physical iPhone before distribution. Record the device, iOS
version, app commit, sensor models and firmware, date, and tester beside the release evidence.

## Build and migration

- [ ] Generate the project from project.yml; archive with automatic signing team 7RLDYXQTNX.
- [ ] Confirm the embedded provisioning profile carries HealthKit and HealthKit background
  delivery entitlements.
- [ ] Upgrade an install containing version-1 readings.json and sources.json; confirm source
  IDs, reading counts, newest values, and comparisons match before and after migration.
- [ ] Run the `HeartSyncCheckerPerformance` scheme on a representative supported iPhone. It
  writes the full fourteen-day 1 Hz fixture and verifies indexed retrieval without adding the
  workload to ordinary PR CI. Measure launch, one-day and 30-day queries, scrolling,
  compaction, and background ingestion; attach Instruments evidence and record peak memory
  and main-thread stalls.
- [ ] In the same run, record `liveScreensDuringIngest`: Now's p95 reload time, the
  steady-state main-thread share with a 30-day detail open during 1 Hz ingest, and the time
  of one 30-day detail load. Confirm or tune the initial 50 ms and 25% budgets in
  `HealthStorePerformanceTests`. A single load that blocks the main actor for seconds is
  improvement 21's open work, not a pass.
- [ ] Lock after first unlock and confirm SQLite database and WAL writes continue. Reboot
  without unlocking and confirm startup blocks without overwriting history, then recovers on
  Retry after unlock.

## Bluetooth sensors

- [ ] Exercise a standard heart-rate device, PLX continuous and spot-check pulse oximeter,
  and health thermometer. Confirm supported characteristics subscribe before the UI says
  Ready.
- [ ] Exercise no supported service, partial service discovery, subscription refusal, value
  error, no-value stream stall, disconnect and reconnect, and state restoration.
- [ ] Confirm off-body heart rate and provisional, questionable, or invalid PLX frames do not
  enter history or Apple Health. Verify PLX status bits 13 through 15, device bit 15, and
  Pulse Amplitude Index caveats with captured packets.
- [ ] Confirm a packet containing many R-R intervals uses its reconstructed capture interval;
  RMSSD waits for 20 seconds and SDNN waits for a full five minutes.
- [ ] Background and lock the app during collection, walk out of range and return, then
  terminate and relaunch through CoreBluetooth restoration. Confirm no duplicate or invented
  readings.
- [ ] Standard heart rate without R-R intervals says "Ready for 1 metric", not three, and
  never shows HRV. With the sensor off the body, the stall message names the rejection
  ("sensor reports no contact"); with the sensor silent, it says no packets arrived.
- [ ] Reconnect on a connected device disconnects, reconnects once, and rediscovers. Pause
  during Reconnect does not reconnect. A foreground refresh leaves a streaming device alone.
- [ ] Run Bluetooth diagnostics and export the report. Confirm it lists every service and
  characteristic, per-characteristic packet counts, rejections, and raw packets only from
  the 60-second diagnostic session.

### Vendor ring (YCBT candidate, RingFix.md)

Keep every other ring app disconnected so the result belongs to HeartSync's own session.
Record the ring's model, firmware, and the diagnostic report with each result.

- [ ] The ring row reaches "Connected; waiting for ring measurement." and offers Measure
  heart rate. A ring without the YCBT service, or one that never answers the identity
  query, keeps the standard path and never offers the button.
- [ ] Measure heart rate on the finger: the row shows provisional values, then "Last measured
  N BPM at T". Exactly one reading appears in history under the ring's Bluetooth source,
  timed at the last live value, and it matches the ring's own app within its tolerance.
- [ ] Off the finger: the ring's no-contact result is shown and nothing is stored. No warm-up
  or zero value is stored. Cancel stops the ring. Repeat a measurement after completion,
  after Cancel, and after Reconnect.
- [ ] Standard `2A37` notifications from the same ring are not stored while the vendor
  session owns heart rate (diagnostics count them as superseded).
- [ ] Measure blood oxygen and Measure blood pressure: each shows provisional values and then
  stores exactly one completed value (blood pressure as a systolic/diastolic pair labelled
  Estimated). Compare with SmartHealth's figures taken at the same time.
- [ ] Import stored readings with SmartHealth closed: every type either imports or is named
  as not read. Values and times match SmartHealth's history (this checks the ring clock is
  read in local time; record the phone's time zone). SmartHealth still shows its history
  afterwards. A second import adds nothing. With the ring's clock never set, records are
  skipped, not imported at a wrong time.
- [ ] Battery: after identification the ring's percent appears on its Devices row and Now chip
  and matches SmartHealth's figure. On the charger the meter turns green with a bolt within 15
  minutes; off it, the level updates within 15 minutes. The diagnostics report shows one
  "Battery query" command per interval and none during a measurement or import.
- [ ] Automatic measuring: choose Every 30 min. The row reports what the ring accepted for
  heart rate and blood oxygen (or names the one it refused), and the diagnostics report shows
  exactly one "Set automatic … measuring" command per monitor. SmartHealth's Health monitoring
  › Interval then shows 30 min. After an hour on the finger, Import stored brings in about two
  new heart-rate values. Choose Off: SmartHealth shows monitoring off, and no new automatic
  values appear. Reconnecting sends no setting.
- [ ] A chest strap and a standard pulse oximeter still work unchanged.

## Liquid Glass (iOS 26+, and the iOS 18 fallback)

- [ ] On an iOS 26+ iPhone: Now's large title shares the Refresh button's row with no empty band
  above the source chips; cards, chips, and the History and agreement buttons are glass; Compare's
  Sessions and Sources menus both sit at the trailing edge. Check light, dark, Increase Contrast, and Reduce
  Transparency (glass must fall back to legible solid surfaces).
- [ ] On iOS 18: the same screens keep the material cards and bordered buttons, with the same
  layout, and the navigation bar has its material background.
- [ ] iPad: the sidebar, Compare's split view, and Now's adaptive grid look right with glass.

## Apple Health

- [ ] Test read authorization with all types, selected types, denied types, and no returned
  samples. Confirm the UI never claims per-type read authorization.
- [ ] Test complete, partial, failed, permission-unknown, and object-budget-deferred syncs;
  verify Last complete sync changes only after an all-success pass.
- [ ] With write-back enabled, confirm only measured Bluetooth values are saved. Derived,
  estimated, Health-origin, Oura-origin, and rejected PLX values must not be written.
- [ ] Delete an uncompacted Health sample and confirm it leaves HeartSync. Confirm the UI and
  exports disclose that a compacted historical median cannot be revised by a later deletion.
- [ ] Exercise one writer reporting two device models and Oura through both Health and Cloud;
  verify writer, multiple-device, and non-independent-source warnings.
- [ ] Background the app and create a new Health sample; verify hourly delivery with the
  screen locked instead of inferring it from entitlement presence.

## Oura

- [ ] Verify the advanced personal and developer onboarding, exact redirect URI, state
  validation, partial scopes, authorization expiry, and OAuth return from the system browser.
- [ ] Complete a full-window sync where one upstream record was withdrawn; confirm the cache,
  normalized reading store, and relaunch all omit it.
- [ ] Confirm incremental, failed, permission-denied, and truncated responses preserve prior
  records. Force a cache-write failure and confirm the prior generation remains active with a
  durability warning.
- [ ] Confirm the token remains device-only in Keychain and no cache, database, or diagnostic
  export contains it.

## Data controls and evidence

- [ ] Shorten retention, inspect the cutoff and count preview, export, cancel once, then
  apply. Confirm cancellation changes nothing and an applied change survives relaunch.
- [ ] Run Clear local cache and verify Oura and Health data can resync; run Forget imported
  history and verify the documented source-specific behavior. Confirm neither action deletes
  Apple Health data.
- [ ] Compare raw, newly compacted, and legacy compacted windows. Confirm unknown sample depth
  stays blank or unknown and confidence intervals appear only with sufficient pairs.
- [ ] Compare Oura Cloud with its Health writer relationship and confirm agreement is labelled
  non-independent instead of corroboration.
- [ ] Swipe fully across a Bluetooth row and an Apple Health row and confirm nothing is
  deleted. Remove must show the reading count and first date. Export first must share only
  that source's rows and leave no temporary file behind. Cancel must change nothing, and
  confirming must delete exactly that source's readings. Disconnect Oura must state the
  14-day resync.

## Interactive charts

- [ ] On metric detail, the pair timeline, the Bland–Altman plot, and the Oura charts,
  start a vertical swipe on the chart and confirm the list scrolls. Then scrub sideways
  and confirm the list does not take the touch over mid-scrub. One external report saw
  that with `chartXSelection` inside an iPhone scroll view; record the result either way.
- [ ] Scrub metric detail from its first window to its last. The callout must stay inside
  the chart at both ends, in light and dark appearance, at the largest accessibility text
  size, in landscape, and on iPad. Each new window must tick once. Lifting the finger keeps
  the callout; touching empty plot area or Clear selection removes it.
- [ ] Zoom a week of heart rate to one hour. The caption must read "1-minute medians", the
  pan buttons must stop at both ends, and a rolling range must keep the newest readings
  reachable while data arrives.
- [ ] Select a period by dragging, check its evidence, and save it as a session. Reopen the
  session from Compare and confirm the same bounds and the same pair statistics.
- [ ] On a Bland–Altman plot with an outlier above a dense cluster, tap the outlier and
  confirm it is the one selected. A tap in empty plot area clears the selection.
- [ ] With VoiceOver, step the pair screen with the Next and Previous paired window actions,
  and read metric-detail points, hypnogram stages, and movement classes with their times.
  Confirm each score and biomarker card reads its fourteen-day sentence.
- [ ] On the Oura tab, confirm the hypnogram rows (Awake at the top, Deep at the bottom),
  the Non-wear legend entry, gaps for missing trend days, and temperature deviation drawn
  around zero and labelled "from baseline".

## Interface and accessibility

- [ ] Now: each card's sparkline breaks at gaps and stops at the last completed window. The
  Sources header is absent when no source is connected; Apple Health and Oura chips say
  "Synced …" or "Waiting", never "Live". The heart glyph pulses only while a Bluetooth
  source streams, and neither it nor the numbers animate with Reduce Motion on.
- [ ] Changing the range on Compare or metric detail immediately shows "Updating for the
  new selection…" and dims the old results until the new ones land.
- [ ] VoiceOver at the largest accessibility size: metric detail, pair, and Oura heart-rate
  points read with source, time, value, and caveats; the Audio Graph names each device.
  No chart's plot area collapses.
- [ ] iPad in both orientations and iPhone in landscape: the sidebar lists five
  destinations, Now shows several card columns, Compare shows metrics beside detail, and no
  metric chip is clipped on Devices. Compare the CI screenshots with the device.

- [ ] Run the complete UI suite, including the doubled-string pseudo-localization launch.
- [ ] Manually inspect all five tabs with VoiceOver, Accessibility Extra Extra Extra Large,
  Bold Text, Increase Contrast, Differentiate Without Color, Reduce Motion, portrait,
  landscape, split-view iPad, and full-screen iPad.
- [ ] Verify loading, empty, unavailable, partial, failed, collecting, estimated, compacted,
  and recovery states remain explicit and actionable at every size.
- [ ] Confirm icon-only controls have names and hints, compound measurement rows read
  coherently, focus order is logical, and no verdict depends on color alone.
- [ ] In light and dark appearance, check the charts:
  - source colours, shapes, and the A/B line-end labels;
  - neutral reference lines with their dash patterns;
  - the hatched Awake sleep stage;
  - no line, band, or area bridges a data gap, and no curve overshoots its samples;
  - a saved session's banner, not the range picker, on metric detail and on the pair
    screen.

## Data safety and background behavior (2026-09 review, items 42–71)

These need a signed build on a physical iPhone and watch; the automated tests cover the logic
but not the platform behavior.

- [ ] Retention: with a 1-year period saved and readings older than 30 days present, force-quit
  and relaunch, then relaunch with the device locked after a restart (first unlock). Nothing older
  than 30 days disappears. Delete `settings.json` from a test build and relaunch: Settings shows
  "Resume deleting readings…" and the startup notice, and nothing is pruned until a period is
  chosen.
- [ ] Ring blood pressure: import stored readings and measure blood pressure on the ring, leave the
  blood-pressure index off, wait five minutes and foreground twice. The ring's values remain.
- [ ] Oura: kill the app while a sync is in progress, relaunch, then use Forget imported history.
  No Oura reading older than 14 days remains. Lock the phone straight after a restart and open the
  app in the background: the account is not signed out.
- [ ] Write-back: with Bluetooth mirroring on, confirm samples appear in Health in batches roughly
  every 30 seconds, attributed to the strap's name, without duplicates after a reconnect. Turn write
  permission off in Health and confirm Settings reports it instead of failing silently.
- [ ] Complications: watch the reload count while a strap streams; a new delivery that changes no
  displayed value must not reload the timelines.
- [ ] Stress complication: add **HeartSync Stress** to a face in each family. A new five-minute
  score updates it, every value is labelled as an estimate, it reads Older after 15 minutes with
  no score, and a tap opens the stress detail.
- [ ] Watch periods: 3H appears between 1H and 24H on the detail and Compare pages, all five
  buttons fit a 41 mm watch, and 3H has its own verdict and chart.
- [ ] Diagnostics: open Devices while a strap streams and confirm the list stays still, and that
  **Export diagnostics…** builds the report only when tapped.

## Second pass: resets, off-main reads, batching, launch, mirroring (items 46–72)

- [ ] Background relaunch (53): connect a strap, background HeartSync, and have iOS terminate it
  (Xcode's Debug › Terminate while backgrounded does not count; use memory pressure or wait).
  The strap keeps recording, and on reopening the readings from the gap are there. The console
  shows one discovery per restored link, not two.
- [ ] Health background delivery (53): with the app terminated, record a heart-rate sample on
  Apple Watch. It appears in HeartSync without opening the app (check `lastAttemptAt` or the
  console), and HealthKit keeps delivering over a day.
- [ ] Resets (47): during an active Apple Watch heart-rate stream, use **Clear local cache; data may
  resync**; older Health history is re-read. Use **Forget imported history** during an Oura sync;
  nothing from before the reset returns, and the Oura account is signed out.
- [ ] Off-main reads (50): with two weeks of a 1 Hz strap, open Compare (30 days), metric detail
  (30 days), and the pair screen while the strap streams; Instruments shows no main-thread hang,
  and the watch publication does not hitch the UI. Run `HeartSyncCheckerPerformance` and write the
  budgets down here.
- [ ] Schema 3 (50): install over a build with existing history. Everything reads unchanged, and
  after a few maintenance runs `rowsAwaitingValueBackfill` reaches zero.
- [ ] Batched ingest (52): run `batchedStrapIngest` on the device and record commits per minute; log
  an hour of real strap use with the Energy Log instrument, before and after.
- [ ] Mirroring (72) no longer applies: watch workouts were removed. Confirm the watch app offers
  no workout, requests no Health permission, and the iPhone shows no mirrored-workout card.
