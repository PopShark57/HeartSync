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

## Interface and accessibility

- [ ] Run the complete UI suite, including the doubled-string pseudo-localization launch.
- [ ] Manually inspect all five tabs with VoiceOver, Accessibility Extra Extra Extra Large,
  Bold Text, Increase Contrast, Differentiate Without Color, Reduce Motion, portrait,
  landscape, split-view iPad, and full-screen iPad.
- [ ] Verify loading, empty, unavailable, partial, failed, collecting, estimated, compacted,
  and recovery states remain explicit and actionable at every size.
- [ ] Confirm icon-only controls have names and hints, compound measurement rows read
  coherently, focus order is logical, and no verdict depends on color alone.
