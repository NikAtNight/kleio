# Call detection and recording prompt

## Requirement and owner

The September 15, 2026 user request asks for a small bottom-left popup when a call is detected, offering audio or audio plus screen recording. The main implementation agent owns this flow. Recording requires a button click. Calendar scheduling, automatic stopping, and mute synchronization retain their existing behavior.

## Intended behavior and acceptance checks

- Two consecutive joined-call observations show one prompt without activating Kleio. An open app, unrelated audio, muted microphone, or unreadable call controls cannot substitute for joined-call evidence.
- Audio captures the detected application's audio and the microphone, regardless of the saved video toggle. Audio + screen opens the native display picker first. Browser audio includes all audible tabs.
- Dismissing suppresses that call. Unknown observations preserve dismissal. Ten seconds of observed native inactivity or an explicit browser prejoin screen rearms that call. Process exit clears its history. New call contexts can prompt independently, while switching back to a dismissed context preserves its dismissal.
- An existing recording consumes the detected call without prompting. Dictation, backup work, and calendar countdowns defer prompts. Multiple detected calls do not select an arbitrary app.
- A failed start offers another attempt with the error in the popup. Cancelling the display picker creates no recording and restores the choices. A stale popup rechecks the same app and call context before starting.
- Settings → General → Recording can disable prompts and open Accessibility settings. Detection defaults on, but does not request or grant Accessibility access automatically. No audio is captured by detection.

Tests selected for these boundaries are `CallPromptTests`, `MeetingMuteReaderTests`, `MeetingReaderAccessibilityTests`, and `RecordingSessionLifecycleTests`. Native Accessibility behavior, popup focus/placement, and actual screen selection require separate acceptance.

## Implemented path

`ScribeApp` configures one `CallDetectionController` alongside the existing recorder. A two-second timer gathers supported running applications. `CallPresenceScanner` confines per-app `MeetingMuteReader` caches to a serial background queue. No window text, meeting URLs, or participant information is logged or saved unless the opt-in diagnostics below are on.

`MeetingMuteReader` shares snapshot traversal between the existing mute reader and `CallPresenceParser`. Call presence requires a unique enabled provider-specific leave or hang-up control and rejects prejoin controls. It does not require a readable microphone button. Candidate rules cover native Slack, Teams, Zoom, FaceTime and recognized Meet, Teams, and Slack browser origins. FaceTime mute synchronization remains unsupported.

The reader reads every window in `AXWindows` plus `AXMainWindow` and `AXFocusedWindow`, de-duplicated. Windows on another Space are missing from `AXWindows`, and a full-screen meeting Space can hide the meeting window while the main window stays visible. macOS only sometimes reports the main window of an app on another Space. On September 23, 2026, Slack and Teams on another Space returned no main or focused window either, so a call there still reads as unknown.

`CallPromptCore` confirms presence, handles ambiguity, and remembers the latest 128 dismissed contexts per application. Explicit enabled browser join controls produce `readyToJoin` for that context; missing controls alone remain unknown. `CallRecordingPrompt` hosts the SwiftUI buttons in a nonactivating AppKit panel at status-bar level, so it sits above other apps' floating call windows, 20 points from the bottom-left of the pointer's display's usable area. It works independently of the main window and joins Spaces. The screen-recording choice is display capture; the existing Home flow still offers window capture.

After a click, the controller rechecks presence and calls the explicit-video overload of `RecordingSession.startUsingPreferences`. Both the Home path and prompt share speaker and mute preferences. Capture, permission handling, app-only audio resolution, persistence, and cancellation remain in `RecordingSession`. Startup never falls back to all system audio when app resolution fails. Successful startup selects the recording in Kleio without activating the main window.

## Ending recordings when the call ends

With "End meeting recordings when the call ends" on, `AutoRecordArbiter` passes the recorded app's latest call read from `CallDetectionController.presence(for:)` to `ManualAutoStopCore`. Once that app has read as active during the recording, 15 seconds of `inactive` or `readyToJoin` reads stop it. An `unknown` read, a pause, or a read older than 6 seconds restarts the wait, so a call window on another Space never counts as ended. This needs call detection on and Accessibility access. The existing app-quit and silence rules still apply after two minutes.

## Read limits

| | Mute sync (`read`) | Call detection (`readCall`) |
| --- | --- | --- |
| Time per read | 180 ms | 400 ms |
| Nodes per read | 1,800 | 4,000 |
| Time per AX call | 15 ms | 50 ms |
| Depth | 28, then the read fails | 48, then that branch is skipped |

Mute sync keeps its limits and still fails closed at the depth limit, because an unread branch could hide a second microphone control. Call detection keeps what it has read past the depth limit, so a leave button in the shallower part still counts. Running out of time or nodes still makes the read unknown.

Measured on September 23, 2026 with Slack 4.52.155 exposed and idle in a DM (no huddle): the full window tree was 466 nodes, 26 levels deep, and the web area started at depth 7. The reader visited 170 nodes (it skips text, lists and outlines) in 425 AX calls. The first read took 43 ms and later reads 5 ms. In separate probe runs, single cold AX calls to Slack and Teams took 13 to 25 ms, at or over the 15 ms mute-sync limit. Teams could not be measured with content because its windows were on another Space. Teams was also idle, so neither in-call tree is measured. The call-detection limits leave room for a tree several times larger.

## Slack and Teams content exposure

Slack (Electron) and Teams (WebView2) hide their web content from Accessibility until an assistive client asks for it. Before this change, an earlier read-only check found 11 nodes in Slack's window and 19 in Teams', all empty groups with no web area or buttons. On the first `readCall` for each process, the reader asks for the content:

- Slack: `AXManualAccessibility = true` on the application element. The getter keeps returning 0 after the set, and setting it back to false doesn't remove the tree, so the reader never reads it back or clears it.
- Teams: `AXEnhancedUserInterface = true`. Teams returns kAXErrorAttributeUnsupported for `AXManualAccessibility`. It returns kAXErrorNotImplemented for the `AXEnhancedUserInterface` set but applies it anyway, so the result is ignored.

The request happens once per process ID and only from `readCall`, which runs only while detection is on. Mute sync never sets either attribute. For five seconds after the request, and whenever no web area is exposed, a read that finds no leave button is unknown instead of inactive. A leave button found during that time still counts.

`AXEnhancedUserInterface` also makes AppKit animate window frame changes, which interferes with window managers, so it's only used for Teams. Turning detection off clears it again if Kleio turned it on. If it was already on (VoiceOver or another tool), Kleio leaves it alone and doesn't clear it. Quitting Kleio clears it too, waiting at most half a second so an unresponsive Teams can't hold up quit. If Kleio couldn't read the flag first (for example the read timed out), it still sets it but never clears it, since it might belong to VoiceOver.

Browsers are unchanged. Chrome, Edge, Brave, Arc, Vivaldi, and Opera are Chromium and probably hide web content the same way until an assistive client asks, which would leave browser calls unknown. None was running to confirm, and Safari and Firefox-based browsers weren't checked.

## Diagnostics

Call detection can log each poll to `~/Library/Application Support/Scribe/diagnostics.log`:

```sh
defaults write app.talix.scribe callDetectionDebug -bool true
```

It writes a line for a supported app whenever its result or button labels change, with the presence result (and the reason when it's unknown), the number of windows or web contexts, the nodes visited, and the labels of enabled buttons. Button labels can include people's and channel names, such as "Start huddle with Dan". Window titles and URLs are never logged. These lines go to diagnostics.log only, not the macOS system log. It's off by default and takes effect on the next poll. Turn it off with `defaults delete app.talix.scribe callDetectionDebug`.

To confirm the leave-button labels:

1. Turn diagnostics on, then join a Slack huddle and keep it running for about 10 seconds.
2. Run `grep 'call detection com.tinyspeck.slackmacgap' ~/Library/Application\ Support/Scribe/diagnostics.log | tail -5`. The huddle's leave button should appear in the label list and the result should say `active (Slack Huddle)`.
3. Repeat with a Teams meeting (`com.microsoft.teams2`), once with the meeting in its own window and once in a full-screen Space.
4. If the result is `unknown (ambiguous controls)`, two windows or two buttons matched. If it's `inactive`, the leave label isn't in `MeetingMuteParser.isLeave`.

## Verification and gaps

Base revision: `1699825376da588ec70842e972335971bd243133`. Changes are uncommitted.

- Initial Command Line Tools build: BLOCKED by the existing SwiftUI preview macros, `plugin for module 'PreviewsMacros' not found`. `/usr/bin/git` and the default Xcode toolchain launcher also report an unaccepted Xcode license. Direct Command Line Tools Git works.
- PASS: debug app and test bundle compilation with the installed Xcode compiler, Command Line Tools SDK, and explicit Xcode preview and XCTest paths. No license, developer-directory preference, or permission setting was changed. Log: `build/call-detection/focused-tests.log`. SwiftPM's runner discovered zero XCTest cases in this setup, so verification used the direct XCTest runner instead.
- PASS: 52 focused tests through the direct runner. `CallPromptTests` covers confirmation, stale/unknown observations, recording and UI conflicts, ambiguity, dismissal, A → B → A context changes, brief prejoin, and rearming only the matching context. `MeetingMuteReaderTests` covers provider labels and parser uncertainty. `RecordingSessionLifecycleTests` covers explicit audio/display selection, app targeting, picker cancellation, and existing capture failures. Log: `build/call-detection/focused-xctest.log`.
- FAIL, environment prerequisite: the full runner executed 298 tests; 295 passed and three existing crash-recovery tests produced 10 failed assertions. `LibraryBackupTests.testNextLaunchFinishesCommittedRestoreWithoutRollingBack`, `LibraryBackupTests.testNextLaunchRollsBackRestoreInterruptedByProcessExit`, and `RecordingVideoTests.testInterruptedVideoRetainsClosedFragments` spawn `/usr/bin/xcrun` with a replaced environment. That command exits 69 for the unaccepted Xcode license before the fixture executes. No source in those tests or their production implementations changed. Log: `build/call-detection/all-xctest.log`.
- PASS: independent review, including fixes and regression tests for browser dismissal history and same-room rejoining. `git diff --check` passed. The uncommitted diff is retained at `build/call-detection/changes.patch`.
- PASS (this change, September 23, 2026): `swift test` in the agent copy, full suite. `MeetingReaderAccessibilityTests` drives the real `read` and `readCall` through a scripted Accessibility tree: main-window fallback, depth cutoff, time budgets, the once-per-process exposure request and its release, warm-up, and debug logging off by default.
- PASS: the reader, built into a throwaway probe, read live Slack after exposure. The web area and 31 buttons appeared, named through `AXDescription` or `AXTitle`. No button used `AXTitleUIElement`, and child text only repeated the description, so label reading is unchanged.
- NOT RUN: Teams with content, because its windows were on another Space. Its two hidden helper windows did show Chromium web areas after `AXEnhancedUserInterface` was set.
- Live calls: NOT RUN. English control labels are candidates, not verified provider support. Background browser tabs can remain unknown; same-room rejoining needs a sustained readable prejoin state to clear dismissal. Native calls reusing a window need an observed inactive interval to reset dismissal. Application UI changes and other languages may prevent detection.
- PASS: native synthetic Slack popup rendered at 360 × 148 points at the display's bottom-left usable corner. Both buttons and explanatory text fit. The harness remained inactive before and after showing the panel. Image and harness: `build/call-detection/prompt.png` and `PromptPreview.swift`. This checks presentation without inspecting or recording a real call.
- NOT RUN: actual screen-picker permissions, live call transitions, multiple displays/Spaces, release packaging, or installation. Automated recording tests use synthetic capture drivers and temporary libraries.

Build the test bundle on this machine:

```sh
call_toolchain=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain
call_platform=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
DEVELOPER_DIR=/Library/Developer/CommandLineTools "$call_toolchain/usr/bin/swift" test \
  --build-system native --disable-automatic-resolution \
  -Xswiftc -plugin-path -Xswiftc "$call_platform/usr/lib/swift/host/plugins" \
  -Xswiftc -F -Xswiftc "$call_platform/Library/Frameworks" \
  -Xswiftc -I -Xswiftc "$call_platform/usr/lib" \
  -Xlinker -F -Xlinker "$call_platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$call_platform/Library/Frameworks" \
  -Xlinker -L -Xlinker "$call_platform/usr/lib" \
  -Xlinker -rpath -Xlinker "$call_platform/usr/lib" \
  --filter 'CallPrompt|MeetingMuteReader|RecordingSessionLifecycle'
```

That invocation compiles but does not discover the XCTest cases with this toolchain configuration. Execute them directly:

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest 'ScribeTests.CallPromptTests,ScribeTests.MeetingMuteReaderTests,ScribeTests.RecordingSessionLifecycleTests' \
  .build/arm64-apple-macosx/debug/KleioPackageTests.xctest
```

Omit `-XCTest` and its value for the full suite. The three subprocess tests still require the default Xcode installation's license prerequisite to be resolved by the user.
