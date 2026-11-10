Poki CarPlay display-domain experiment
====================================

Status: experimental Simulator backend in the original Poki fork. This is not
a production iPhone installation path. The existing Poki OpenRouter / DeepSeek
configuration is unchanged; this experiment uses a deterministic executor,
not an LLM run, and is not yet connected to Poki's main chat tool loop.

Verified on Apple Silicon, Xcode 26.2, iOS 26.2 Simulator (23C52):
- An ordinary UIKit test app: native buttons, text input and scrolling overlap
  the user's typing in a separate primary-display app.
- Original Apple MobileSafari: enter Pikachu, submit search, open the actual
  image search page and scroll while the primary display continues typing.
- Safari overlap: 1,416 exact characters over 23.55 seconds, no observed focus
  or foreground interruptions. A separate TypingPad fixture stands in for
  Notes; Apple Notes is not installed in this Simulator runtime.
- These are two displays in ONE Simulator device, not two separate iPhones.

How it works
------------
CarPlayCoordinator is injected into only the Simulator's SpringBoard and
CarPlay services. It admits the explicitly selected installed bundle to the
CarPlay app roster, synthesizes its CarPlay scene metadata in memory, and
requests a dashboard workspace activation. Its allowlist is read once at
process startup. Installed app bundles, Safari's binary and its on-disk Info
are not edited or re-signed. No host SIP/AMFI settings are changed.

SceneBridge is injected into the chosen target process. It normalizes the
external scene role to an ordinary application scene, makes the external
window locally key, and suppresses that process's system keyboard focus
requests. Touch paths are native digitizer HID events stamped with the
target window's context ID, enqueued in that process. Text uses UIKeyInput /
UITextInput on the hit-tested target. It does not call fixture button
callbacks, Safari navigation methods, or DOM navigation APIs.

Observation uses the real view tree and public WKWebView URL/title/scroll
properties. Capture is available as a debug command; the acceptance videos
come from simctl's real internal/external display compositor recordings.

The host's debug file transport writes commands into the target container;
it is not a phone-ready IPC protocol. Commands may contain user text and
observations may contain URLs. Generated evidence stays local and is ignored
by Git. Command files have unique IDs; launch archives stale commands before
restarting. There is no authenticated multi-client transport/session protocol.

Run
---
Requires full Xcode, its iOS 26.2 runtime, Python 3, and an Apple Silicon Mac.
Use a dedicated disposable Simulator: prepare restarts that device's
SpringBoard and CarPlay, and installs only local test fixtures. It never
pairs a physical device or changes host security configuration.

1. Create and boot a dedicated Simulator in Xcode or with simctl. Get its
   UUID from: xcrun simctl list devices available
2. From this directory:
   python3 lab.py prepare --device YOUR_SIMULATOR_UUID --case safari
3. Open Simulator's I/O > External Displays > CarPlay. Configure 960 x 1600
   pixels, scale 2, Touch Screen enabled, then:
   python3 lab.py launch --device YOUR_SIMULATOR_UUID --case safari
4. With the target visible on CarPlay:
   python3 run_parallel.py --device YOUR_SIMULATOR_UUID --case safari --name safari-01
   A unique --name is required per run. The script records both displays,
   runs the user typing test, and checks actual overlap and outcomes.
   Results and raw recordings are under evidence/safari-01/.

For the fixture case, repeat prepare with --case fixture; set CarPlay to
800 x 480 pixels at scale 2, then launch/run with --case fixture. The fixture
test counts actual native button actions and scroll events, not accepted
commands. Resizing a live external scene can leave stale window geometry;
restart CarPlay and relaunch the target after changing display dimensions.

The Safari test currently assumes Baidu is the selected search engine and
uses the portrait layout above. Native address/search fields are located
from fresh observations. The web Images tab is a layout-specific tap; the
loaded URL, exact query and changed scroll offset are checked afterward.
Network/search-page changes may legitimately fail the test. A zero-test
Xcode run is a failure even if xcodebuild exits 0; install/discovery may need
one additional run with a new --name. A failed run is never called success.

If the advanced CarPlay configuration is hidden, quit Simulator, run
defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES
and reopen it. This only exposes Simulator display options. To undo if it
was previously absent: defaults delete com.apple.iphonesimulator CarPlayExtraOptions

An explicit --bundle on prepare/launch allows another installed app to be
probed. That is an experimental admission path, not a compatibility claim.
The automated --case safari and --case fixture checks only support those
two targets. Do not use the test runner against personal app data.

Cleanup: shut down/delete the dedicated Simulator. launchctl debug affects
the next service launch only. Delete local generated paths/evidence and the
temporary build directories printed by prepare when no longer needed.

Limits / next steps
-------------------
Not verified: a physical iPhone, an independent virtual CarPlay receiver on
the phone, stock developer signing, any arbitrary installed app, app clones,
Photos/search authentication, long background lifetimes, Chinese user IME,
or two independent keyboards. The target scene is prepared before typing;
a cold app launch/move into CarPlay during user typing is not established. The agent uses local UITextInput, not a second
system keyboard. Protected/DRM surfaces may need additional investigation.

Private API and injection permissions are essential to this test. Simulator
Mach-O entitlement sections are not evidence that ordinary iPhone signing
can grant the same capabilities. No exploit or jailbreak is installed here.

Next engineering step: expose these observed display/command primitives to
Poki's existing tool loop, then build a real-device capability probe and app
compatibility matrix. Keep ordinary foreground automation as an explicit
fallback, because it cannot meet the concurrent-isolation requirement.

References (API patterns / mechanism research)
--------------------------------------------
Apple CarPlay Simulator:
https://developer.apple.com/documentation/carplay/using-the-carplay-simulator
Apple WebKit TestRunner native HID event construction:
https://github.com/WebKit/WebKit/blob/main/Tools/WebKitTestRunner/ios/HIDEventGenerator.mm
CarSurf scene, policy and workspace research reference:
https://github.com/pavunato/carsurf/tree/72cd0f8bf8d0bd1086e78fe7c7be6fff715702f8

The implementation here is experimental AGPL-3.0-only code in Poki.
