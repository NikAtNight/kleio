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

Tests selected for these boundaries are `CallPromptTests`, `MeetingMuteReaderTests`, and `RecordingSessionLifecycleTests`. Native Accessibility behavior, popup focus/placement, and actual screen selection require separate acceptance.

## Implemented path

`ScribeApp` configures one `CallDetectionController` alongside the existing recorder. A two-second timer gathers supported running applications. `CallPresenceScanner` confines per-app `MeetingMuteReader` caches to a serial background queue. Reads have the existing 180 ms budget and bounded traversal. No window text, meeting URLs, or participant information is logged or saved.

`MeetingMuteReader` shares snapshot traversal between the existing mute reader and `CallPresenceParser`. Call presence requires a unique enabled provider-specific leave or hang-up control and rejects prejoin controls. It does not require a readable microphone button. Candidate rules cover native Slack, Teams, Zoom, FaceTime and recognized Meet, Teams, and Slack browser origins. FaceTime mute synchronization remains unsupported.

`CallPromptCore` confirms presence, handles ambiguity, and remembers the latest 128 dismissed contexts per application. Explicit enabled browser join controls produce `readyToJoin` for that context; missing controls alone remain unknown. `CallRecordingPrompt` hosts the SwiftUI buttons in a nonactivating AppKit panel, 20 points from the bottom-left of the pointer's display's usable area. It works independently of the main window and joins Spaces. The screen-recording choice is display capture; the existing Home flow still offers window capture.

After a click, the controller rechecks presence and calls the explicit-video overload of `RecordingSession.startUsingPreferences`. Both the Home path and prompt share speaker and mute preferences. Capture, permission handling, app-only audio resolution, persistence, and cancellation remain in `RecordingSession`. Startup never falls back to all system audio when app resolution fails. Successful startup selects the recording in Kleio without activating the main window.

## Verification and gaps

Base revision: `1699825376da588ec70842e972335971bd243133`. Changes are uncommitted.

- Initial Command Line Tools build: BLOCKED by the existing SwiftUI preview macros, `plugin for module 'PreviewsMacros' not found`. `/usr/bin/git` and the default Xcode toolchain launcher also report an unaccepted Xcode license. Direct Command Line Tools Git works.
- PASS: debug app and test bundle compilation with the installed Xcode compiler, Command Line Tools SDK, and explicit Xcode preview and XCTest paths. No license, developer-directory preference, or permission setting was changed. Log: `build/call-detection/focused-tests.log`. SwiftPM's runner discovered zero XCTest cases in this setup, so verification used the direct XCTest runner instead.
- PASS: 52 focused tests through the direct runner. `CallPromptTests` covers confirmation, stale/unknown observations, recording and UI conflicts, ambiguity, dismissal, A → B → A context changes, brief prejoin, and rearming only the matching context. `MeetingMuteReaderTests` covers provider labels and parser uncertainty. `RecordingSessionLifecycleTests` covers explicit audio/display selection, app targeting, picker cancellation, and existing capture failures. Log: `build/call-detection/focused-xctest.log`.
- FAIL, environment prerequisite: the full runner executed 298 tests; 295 passed and three existing crash-recovery tests produced 10 failed assertions. `LibraryBackupTests.testNextLaunchFinishesCommittedRestoreWithoutRollingBack`, `LibraryBackupTests.testNextLaunchRollsBackRestoreInterruptedByProcessExit`, and `RecordingVideoTests.testInterruptedVideoRetainsClosedFragments` spawn `/usr/bin/xcrun` with a replaced environment. That command exits 69 for the unaccepted Xcode license before the fixture executes. No source in those tests or their production implementations changed. Log: `build/call-detection/all-xctest.log`.
- PASS: independent review, including fixes and regression tests for browser dismissal history and same-room rejoining. `git diff --check` passed. The uncommitted diff is retained at `build/call-detection/changes.patch`.
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
