Poki CarPlay display-domain integration (experimental Simulator build)
===================================================================

The original Poki iOS ChatModel / PiLoop / ModelKeys now has a CarPlay mode.
It uses the existing OpenRouter account and DeepSeek model, not a model loop
on the Mac. The Mac still prepares the Simulator and privileged runtime
injection. This is not a stock-iPhone installation or autonomy claim.

Verified results (Xcode 26.2, iOS 26.2 build 23C52, Apple Silicon)
-------------------------------------------------------------
One Simulator device, two actual displays. Independent TypingPad represents
user typing on the primary display; Apple Notes is absent from this runtime.

Expanded acceptance (current revision):
- Eight real system apps cold-opened/switched: Files, Contacts, Calendar,
  Reminders, Maps, Safari, Photos, Settings, plus the ordinary fixture.
  9,500 exact characters / 158.30 seconds / no focus or foreground events;
  longest inter-key gap 0.130 seconds. This matrix checks scenes, not loaded
  network content or a complete functional task in every app.
- One live DeepSeek run completed five newly tested apps: Maps native search
  for 东方明珠 and actual landmark card/address; Reminders Continue + Not Now
  for its own iCloud welcome prompt, then actual No Reminders state; Files
  On My iPhone > Domain Target > Poki Samples > CarPlay Sample.txt, Quick Look
  code 8421; Contacts native search Kate Bell, detail company Creative
  Consulting; Calendar native tap November 11, header Nov 11, 2026.
  Three original in-app model tasks / 43 tool calls. All actions and all three
  completions occurred within one 158.30-second, 9,500-character exact typing
  gesture, zero focus/foreground events, longest inter-key gap 0.136 seconds.
  The third task was queued through the same Debug trigger after the first
  two completed and its receipt/timing were verified separately.
- Six real fixture checks passed during typing: stale instance, expired
  command and non-input rejection; one real button increment; notification
  request deferred with before/after authorization both notDetermined and
  no grant; restart does not replay previous actions.
- Six selected iOS regression tests passed (three transport tests, existing
  unprepared-app/no-fallback test and two OpenRouter configuration checks).
- Excluded baseline: Calendar's system notification authorization alert
  blocked 1,500 characters and caused a 25.04-second input gap despite zero
  focus events. The isolated notification guard fixed this. Maps originally
  observed a background widget rather than its active full-size window.
- Excluded live attempts had provider timeout/connection errors, or repeated
  invalid model tap arguments. Distinct press/tap/type schemas corrected the
  observed argument failure. Provider reliability is not claimed fixed.
- Files test data is created by the ordinary disposable fixture; only that
  fixture exposes Documents via UIFileSharingEnabled plus
  LSSupportsOpeningDocumentsInPlace. No Poki session directory is exposed to
  make this test work. prepare installs it; launch Domain Target once before
  the Files task to create the synthetic sample.

Earlier three-app acceptance, retained for comparison:
Live original Poki + OpenRouter deepseek/deepseek-v4.1-flash-1017:
- Safari: cold-open the original installed MobileSafari, enter the new query
  "Pikachu forest wallpaper", open the actual image-results page and scroll.
  11 model tool calls, 34.95 seconds; actual images and changed offset reviewed.
- Photos + Settings: cold-open original Photos, visually locate/open a seeded
  Pikachu picture; cold-open Settings, tap General > About, read iOS 26.2,
  return to the same Photos viewer. 11 tool calls, 28.82 seconds. Screenshots
  independently reviewed. Photos contains 9 images: 6 Simulator stock photos
  and 3 test screenshots, including a Pikachu collage. No personal library.
- During both tasks: one uninterrupted XCTest typing gesture, 9,500 exact
  characters over 158.30 seconds, zero recorded focus/foreground interruptions.
  All three target processes started AFTER actual user text changes began.
- Separate cold-open/switch test: Safari > Photos > Settings > Safari during
  1,416 exact characters over 23.56 seconds, zero interruptions; every external
  scene observed. This test is deterministic, separate from the live model run.
- Selected regression tests: three passed (CarPlay refuses unprepared apps
  without foreground fallback; two OpenRouter configuration checks).

Failures are not counted as success: the early live test trigger accidentally
used the handoff busy guard, and another run loaded/scrolled images but did
not finish; its oversized per-key full-history logging also delayed input.
The trigger now uses the normal owner send method. Tool output is compact,
images are one pixel per window point, all gesture coordinates are validated,
and CarPlay has a screenshot-compatible finish_task schema instead of AX refs.
The editor retains every timestamp/focus event and saves full text periodically.

Mechanism / boundaries
----------------------
CarPlayCoordinator runs only in Simulator SpringBoard and CarPlay. It admits
explicitly allowlisted installed bundles, changes scene metadata in memory,
and activates the real dashboard workspace. The launcher's execution-context
hook loads SceneBridge when CarPlay cold-starts a target; ordinary SpringBoard
primary-display launches are not injected. It preserves other injected
libraries. Installed Safari/Photos/Settings bundles are not edited/re-signed.
No host SIP/AMFI configuration is changed.

SceneBridge normalizes the external scene role and idiom, makes its own
external window locally key, suppresses system keyboard focus requests while it has no active primary scene, and
routes native digitizer HID to that window's context ID. Text uses native
UIKeyInput / UITextInput. There are no app-specific button callbacks, DOM
navigation, PhotoKit search or a replacement browser/Photos implementation.
Observation includes native controls, actual target snapshots, and public
WKWebView URL/title/scroll properties. The active full-size external window is preferred over a background widget.
Acceptance recordings are simctl's
actual internal/external display compositor recordings.

Poki's closed carplay_* catalog is separate
from global phone tools and LiveContainer tools. Actions require a fresh
scene/PID-bound observation token. Native controls expose c0/c1 target references;
the current frame, identity and content must still match before acting.
carplay_press uses a native target; carplay_tap requires x/y; carplay_type uses
a native input target. carplay_do is reserved for swipe/wait. This avoids
conflating swipe endX with the starting x of a tap. The
bridge rejects expired commands and commands from a previous process instance,
and writes one terminal result receipt per command. Restart never replays a
previous process action. Unknown/stale inputs fail. Mode changes
reset model context; cancellation revokes observations; finishing an isolated
task does not activate Poki or return the phone foreground. The chat displays
the target screenshot as a labelled preview, refreshed by tool observations.
The Simulator's external CarPlay window renders actual effects continuously.

IPC is an explicit local debug file transport, not an authenticated on-device
service. Some Apple apps have no data container (simctl returns '(null)');
those use a private generated coordinator/targets directory. No API key goes
into target apps, coordinator config, argv or environment values. Normal keys
use Poki's Keychain path; its unsigned Debug Simulator fallback is memory-only.

Run on a dedicated disposable Simulator
--------------------------------------
Requires full Xcode and iOS 26.2 runtime, Apple Silicon, Python 3, xcodegen,
and the original Poki iOS build prerequisites (including its launcher library).
See the repository's existing iOS build instructions. Do not run concurrent
Xcode UI/unit tests against the same Simulator during acceptance.

1. Create/boot a dedicated Simulator. Get its UUID:
   xcrun simctl list devices available
2. From this directory:
   python3 lab.py prepare --device UUID --case safari --allow com.apple.mobilesafari com.apple.mobileslideshow com.apple.Preferences com.apple.DocumentsApp com.apple.MobileAddressBook com.apple.mobilecal com.apple.reminders com.apple.Maps local.poki.DomainTarget
   This restarts only that Simulator's SpringBoard/CarPlay and installs fixtures.
3. Simulator: I/O > External Displays > CarPlay; configure 960 x 1600 pixels,
   scale 2, Touch Screen enabled. If advanced configuration is hidden, quit
   Simulator, run the following, and reopen it:
   defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES
   If previously absent, undo later with:
   defaults delete com.apple.iphonesimulator CarPlayExtraOptions
4. Build original native/ios-app with project-external.yml (no LC dependency):
   xcodegen generate --spec project-external.yml
   xcodebuild build-for-testing -project PokiExternal.xcodeproj -scheme Poki -destination 'platform=iOS Simulator,id=UUID' -derivedDataPath /tmp/poki-carplay-main CODE_SIGNING_ALLOWED=NO POKI_BUNDLE_ID=app.zealton.poki POKI_APP_GROUP=group.app.zealton.poki ARCHS=arm64
5. Back in this directory, stage/install and launch the original Poki app:
   python3 launch_poki.py --device UUID --app /tmp/poki-carplay-main/Build/Products/Debug-iphonesimulator/Poki.app --provision
   Enter your own OpenRouter key at the secure terminal prompt. The helper
   passes it once through an owner-only FIFO. It never creates a key file.
   Without --provision, configure the account through Poki's normal Accounts.
6. In the ordinary chat menu select CarPlay display (experimental), or use
   the already-selected mode above. Send a task normally and use another app.
   The debug helper also enables a bounded Debug acceptance trigger while BackgroundKeeper is on: it sends tasks
   through the same ChatModel.send after the user editor has begun typing.
7. Automatic cold-launch/switch check (original Poki must be installed):
   python3 run_acceptance.py --device UUID --name cold-01 --launch-only
   Add --apps BUNDLE... for a prepared app matrix. Add --protocol-check to
   include six actual fixture transport/permission/restart checks while typing.
8. Live model acceptance, two tasks during the same continuous typing window:
   python3 run_acceptance.py --device UUID --name model-01 --task 'Open Safari, search image results for Pikachu forest wallpaper, scroll once, verify and finish.' --followup 'Open Photos, find and open the Pikachu picture. Open Settings, read General > About iOS version. Return to Photos, verify and finish.'
   Repeat --followup for more sequential tasks in the same typing window.
   Use a unique --name. Seed a disposable test library with simctl addmedia
   before this test; the recorded experiment used a known Pikachu collage.
   The helper records both displays and checks exact text, lifecycle/focus,
   real test execution, matching model completion and completion timing.
   Longest inter-key gap must also be below 1 second: lifecycle and responder
   state alone do not catch an overlay such as a notification permission alert.
   Visually review actual results too; a model's success claim is insufficient.

Generated configuration, app paths, logs, raw model observations and recordings
are ignored by Git. They can contain screen contents and URLs. Reinstallation
can change container paths; rerun prepare when needed. Never copy generated
runtime config/evidence to a public PR. launchctl debug applies to the next
service start; prepare restarts/configures services sequentially to avoid
consuming an injection on the wrong restart. Do not restart services mid-test.

Original deterministic fixture test remains in run_parallel.py (--case fixture,
800 x 480 pixels at scale 2). Safari macro/adaptive test is --case safari with
portrait dimensions above. Resize before restarting/relaunching the target:
live resizing can leave stale geometry. A zero-test Xcode run is a failure;
install/discovery may require a new attempt with another --name.

Limits
------
The expanded matrix covers eight original Apple apps and an ordinary UIKit
fixture; functional coverage is listed separately in RESULTS.json. It is
not every App Store app. Not verified: physical iPhone, ordinary device signing,
Chinese user IME, DRM/protected surfaces, long-term reliability or a virtual
CarPlay receiver/display created autonomously on the phone. Private API and
process-injection privileges are essential here; Simulator privileges are not
evidence that a normal signed iPhone app can obtain them. Only notification authorization is deferred in an isolated target process:
the caller receives an error, and authorization stays unchanged. This prevents
the Calendar notification prompt from blocking the primary keyboard. Requests
in normal primary use reach the original API. Other permission prompts,
extensions and cross-app handoffs are not generally isolated by this guard.
No jailbreak/exploit is installed. There is no silent foreground fallback if isolation is unavailable.

Cleanup: shut down/delete only the dedicated Simulator, then remove generated
local evidence/config/build paths and printed temporary staging directories.

References
----------
https://developer.apple.com/documentation/carplay/using-the-carplay-simulator
https://github.com/WebKit/WebKit/blob/main/Tools/WebKitTestRunner/ios/HIDEventGenerator.mm
https://github.com/pavunato/carsurf/tree/72cd0f8bf8d0bd1086e78fe7c7be6fff715702f8
https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request
https://developer.apple.com/documentation/fileprovider

Experimental AGPL-3.0-only integration in the original Poki fork.
