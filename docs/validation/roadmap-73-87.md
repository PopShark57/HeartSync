# Roadmap implementation validation — 2026-10-21

Environment: macOS 27.2 (26B118), Xcode 27.2 (27B48), Apple silicon.
All fixtures are synthetic. No personal health history, credentials or exported readings are
committed. XcodeGen remains the project source of truth.

## Automated evidence

- The portable macOS logic harness runs real repository sources and 756 tests in 101 suites;
  its final run passed. The harness lives outside the repository and uses a
  WatchConnectivity stand-in and a UIKit-free OAuth presentation adapter. It does not prove
  iOS/watch UI or hardware integration.
- The final Mac unit target passed 27 tests in six suites, including real TLS-PSK on loopback,
  wrong-key rejection, pending erase recovery at durable boundaries, superseded receiver
  rejection, bounded silent-peer/confirmation waits and actual Network receive cancellation.
- The first signed native Mac UI run passed setup, keyboard navigation and unavailable
  storage. A later export run reached the native Save picker, then desktop focus and macOS
  automation authorization interrupted cancellation. This run is not counted as a pass.
- The final iOS `build-for-testing` compiled the app, all hosted unit/UI sources, the embedded
  watch app and its complication extension with Swift warnings treated as errors.
- A full hosted iOS unit attempt on iOS 27.0 compiled and launched the host but recorded no
  test cases; it was interrupted after about seven minutes. No hosted test pass is inferred.
- The pre-existing App Intents metadata-extraction warning appears on targets without App
  Intents. CoreBluetooth/WatchConnectivity and macOS automation/shortcut-service environment
  diagnostics are separate from Swift compiler warnings.

## Final results

- Hosted iOS: **756 tests in 101 suites passed**, on the iOS 27.0 iPhone simulator, against
  the final Swift implementation. Disabling parallel simulator workers resolved the earlier
  stall; the successful final run took 94.9 seconds including launch (13.7 seconds of tests).
- Mac unit: **27 tests in six suites passed** against the final implementation.
- Mac UI: setup/keyboard navigation, gallery navigation and unavailable storage passed in
  the initial native smoke run. The export retry also **passed**, exercising the shortcut,
  the native Save destination picker, cancellation back to the prepared export, and a full
  Save of both CSV and summary to a disposable chosen folder. Both files remained nonempty
  after export-sheet cleanup. Explicit app activation and keyboard cancellation avoided the
  earlier focus interruption.
- The final iOS and embedded watch builds passed with Swift warnings treated as errors.
- Native Mac inspection in `--mirror-demo` confirmed distinct left/right Polar source labels
  in the Now rows and canonical fact sentences in a brief generated on this Mac. This uses
  synthetic readings and does not validate physical iPhone/Mac sync.
- The focused iPhone setup UI test **passed** after routing its action through the existing
  Devices tab and scrolling to Apple Health. The initial test reached setup but expected an
  offscreen action without scrolling; no pass is claimed for that attempt.
- The complete iPhone UI tour was interrupted while its first chart-gallery test waited for
  the app to become idle. The remainder of that tour is **not verified locally**. CI retains
  the complete UI bundle. No simulator services or permission settings were reset.

CI now disables parallel workers for hosted unit/UI execution, matching the successful local
invocation. No build products, test-result bundles or temporary harness package are committed.

## Repeatable commands

```sh
xcodegen generate
xcodebuild test -project HeartSyncChecker.xcodeproj -scheme HeartSyncMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/HeartSyncRoadmap-MacSigned \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
xcodebuild build-for-testing -project HeartSyncChecker.xcodeproj -scheme HeartSyncChecker \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/HeartSyncRoadmap-iOS \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO
```

Discover the installed iPhone destination before `test-without-building`; the repository's
CI runs full iOS unit and UI bundles and the Mac unit/UI scheme on both runner versions.

## Release gates still open

- Physical iPhone/Mac pairing and Local Network denial/restoration; a month of 1 Hz history,
  measured first-copy time/size, network changes, resume, deletion and pairing replacement.
  Complete the checklist in [MacApp/README.md](../../MacApp/README.md).
- Signed-device Bluetooth restoration and representative ring traffic; HealthKit access,
  background delivery and measured-only write-back; live Oura OAuth/permissions/rate limits.
- WatchConnectivity and complication delivery during storage failures and recovery; the
  40 mm watch at large text sizes, VoiceOver, Reduce Motion and scrolling measurements.
- Real-device performance/energy traces and the existing device workload. No synthetic
  benchmark or successful build is substituted for these measurements.
