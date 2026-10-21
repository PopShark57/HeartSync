# HeartSync for Mac

The macOS 15+ app keeps a read-only copy of the iPhone's HeartSync history and shows it with
the iPhone's own Now cards, Compare, metric detail, pair analysis, and saved sessions. It has
no Bluetooth, HealthKit, or Oura connection of its own. The iPhone stays the authority: the
Mac never validates, compacts, prunes, or edits what it receives, and anything the iPhone
deletes is deleted on the Mac at the next sync.

## How sync works

- **Pairing** (`Sources/MacSync/MacMirrorPairing.swift`, `MacMirrorPairingExchange.swift`).
  The Mac advertises `_heartsync-pair._tcp` only while its pairing window is open. The phone
  connects over plain TCP and runs an ephemeral X25519 exchange, committing to its key before
  it sees the Mac's. Both screens show a six-digit code derived from the exchange. Each side
  sends an HMAC confirmation only after its person confirms, and stores the pairing only once
  it holds the other side's. A decline on either device stops both. The result is a 256-bit
  pre-shared key and an identity, kept in each device's Keychain (`Keychain.Key.macMirrorPairings`).
- **Transport** (`MacMirrorTransport.swift`). A paired Mac advertises `_heartsync._tcp` with
  its install id in the TXT record and accepts TLS 1.2 PSK connections
  (`TLS_PSK_WITH_AES_128_GCM_SHA256`) made with the pairing key. A handshake with any other key
  fails. Session resumption is off, so every connection proves the current key rather than
  resuming a session cached under an earlier one. Frames are a four-byte length, a type byte,
  and a body.
- **Change log** (`HealthDatabase`, schema 4). While at least one Mac is paired, SQLite
  triggers record the id of every inserted, updated, or deleted reading in `change_log`
  (AUTOINCREMENT, so sequence numbers are never reused). The log has an epoch (new each time
  logging is switched on) and a floor (every change after it is in the log). A reset or a
  migration suspends the triggers and raises the floor past every old entry. Entries every
  paired Mac has acknowledged are trimmed, and the log is capped at two million entries; a Mac
  behind the floor gets a snapshot.
- **Sessions** (`MacMirrorSession.swift`). The phone says hello and the Mac answers with its
  epoch and cursor. If they belong to this log, the phone sends the readings named after the
  cursor as they now are, and the ids that no longer exist as deletions. Otherwise it sends a
  snapshot: every row in keyset pages, then a closing batch that deletes whatever the snapshot
  did not name. The log resumes from the position read before the first page. Each batch is
  applied in one transaction with its cursor and acknowledged before the next is sent.
  Batches are a compact binary format, LZFSE-compressed (`MacMirrorBatch.swift`).
- **When.** The phone syncs while HeartSync is in the foreground on it, coalescing changes for
  two seconds. Backgrounding ends the session; the Mac keeps its position.

A Mac mirrors one iPhone. Pairing a different iPhone deletes the copy first; unpairing
deletes it. A pairing change is recorded in the Keychain before the mirror is erased. If
SQLite erasure or the final Keychain write fails, sync stops and iPhone Sync offers a retry.
Startup completes a pending erase before accepting another phone's history. The existing
array-form pairing records remain readable. The iPhone can pair several Macs.

Every stopped receiver is invalidated and drained before its store is cleared or handed to
a replacement. Connection setup has a 15-second deadline; protocol frames, sends and
acknowledgements have 30 seconds; code confirmation has two minutes. Cancellation closes
the underlying connection. An established connection waiting for new history has no idle
whole-session deadline.

Not mirrored: Oura's dashboard cache (sleep stages, scores), live Bluetooth state such as
streaming and HRV quality, the iPhone's settings, and its saved sessions. The Mac's
comparison choices (Settings) and saved sessions are its own.

## Build and run

```sh
xcodegen generate
xcodebuild build -project HeartSyncChecker.xcodeproj -scheme HeartSyncMac \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/HeartSyncMac-DerivedData CODE_SIGNING_ALLOWED=NO
```

To run it locally without the team's provisioning, sign ad hoc:

```sh
xcodebuild build -project HeartSyncChecker.xcodeproj -scheme HeartSyncMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/HeartSyncMac-Run \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
open /tmp/HeartSyncMac-Run/Build/Products/Debug/HeartSync.app
```

`--mirror-demo` (Debug) fills an in-memory mirror with the chart gallery's month of data and
starts no listener: `open …/HeartSync.app --args --mirror-demo`.

The `HeartSyncMac` scheme includes native unit and UI smoke tests. Run them with local ad-hoc
signing (the UI runner needs a runnable signature and macOS automation authorization):

```sh
xcodebuild test -project HeartSyncChecker.xcodeproj -scheme HeartSyncMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/HeartSyncMac-Tests \
  -parallel-testing-enabled NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Navigate offers Command-1 (Now), Command-2 (Compare), Command-3 (Devices), and Command-4
(iPhone Sync). In a pair detail, Shift-Command-E opens export. Save uses the native destination
picker; Cancel keeps the prepared export available until the export sheet is dismissed.
The UI smoke test checks that Save opens that picker and that cancelling it returns to the
sheet; it does not save through the picker, which the system draws in another process. The
exported files' contents are covered by the export unit tests.
Launch sweeps only HeartSync export folders from before that launch, off the main actor.

The App ID is `com.heartsync.HeartSyncChecker.mac` under team `7RLDYXQTNX`. It is sandboxed
with the incoming and outgoing network entitlements and user-selected file access (Save in the
export sheet). It needs no App Group, iCloud, or HealthKit.

## Device validation still to do

Tested so far: the unit suites, including both session halves over real TLS on the loopback
interface and a wrong key being refused, and the Mac screens in `--mirror-demo`. Not yet run:

1. Pair a physical iPhone and a Mac on the same Wi-Fi network. Confirm both Local Network
   prompts, matching codes, and that declining on either device stops both.
2. First sync of a real history (a month of 1 Hz). Check the progress on both devices, the
   time it takes, and that the Mac's Compare matches the iPhone's for the same period.
3. Changes: a new reading, a HealthKit deletion, an Oura revision, a removed device, a reset.
   Each should reach the Mac within a few seconds while the iPhone app is open.
4. Leave the iPhone backgrounded for a day, then open it: the Mac should catch up from the
   log, not with a snapshot.
5. Unpair on each side, then pair a different iPhone: the Mac's copy is replaced.
