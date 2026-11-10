# Original Poki + contained Apple Safari (experimental)

This optional **arm64 iOS 26.2 Simulator** build retains the original Poki app, ChatModel/PiLoop,
ModelKeys and OpenRouter provider. It embeds the pinned LiveContainer runtime as a scene transport;
it does not replace Poki with the separate Workspace app or move the model loop to a Mac/worker.

Choose **Isolated Safari (experimental)** in the original chat's More menu. This starts a new
conversation and switches to a closed tool catalog: `container_look`, `container_do`, `report_plan`,
`finish_task`. Mode changes are disabled during a task. The host rejects global phone tools in this
mode; runtime failure never falls back to activating system Safari. The normal whole-phone mode
remains available separately.

The original Poki process holds the model credential and performs model requests. A PID-checked
NSXPC broker connects it to a LiveProcess extension loading the actual Apple MobileSafari executable
from the installed Simulator runtime. No credential is passed to Safari. Readback combines local
UIKit rendering, the existing Safari WKWebView's DOM and its independent WebKit snapshot. HTTP(S)
navigation is a URL action to that guest's scene. Native controls and webpage controls use local
callbacks/DOM events, without global touch or keyboard injection. Each action consumes a fresh
observation. Focus/window/app activation requests are blocked for the contained guest; user touch,
disconnect and task cancellation revoke agent ownership. This is **not a security boundary against
an actively malicious guest** or a general virtual iPhone.

The chat uses Poki's existing BackgroundKeeper (continued processing, with its silent-audio fallback)
for the contained task and releases a hold it owns at completion. The original chat uses the same
OpenRouter account and DeepSeek model as normal Poki. Enter a key in Accounts; none belongs in source,
build arguments or tests. Unsigned Simulator Keychain failure has the existing explicitly labelled
process-memory fallback; quitting the app loses that fallback credential.

## Build locally

Prerequisites: Xcode 26.2 + iOS 26.2 Simulator, XcodeGen, and the original Poki Rust launcher library
built for `aarch64-apple-ios-sim` (see the original iOS app build instructions). Use a **new dedicated
Simulator**: Apple's Safari frameworks can access the system Safari data store despite LC's private
home. Existing Safari profiles must not be used as a clean isolation test.

```sh
python3 native/ios-workspace/scripts/build.py --runtime /path/to/pinned-LiveContainer --work /path/to/workspace-build
python3 native/ios-app/scripts/build-contained.py \
  --workspace-build /path/to/workspace-build \
  --safari /path/to/iOS.simruntime/Contents/Resources/RuntimeRoot/Applications/MobileSafari.app \
  --work /path/to/contained-build --device DEDICATED_SIMULATOR_UUID
```

The script transforms a **local unencrypted Simulator copy** of Apple's executable into an LC guest.
It checks the architecture, encryption status and Mach-O header space before editing. The installed
system binary is unchanged. Generated runtime/frameworks/Safari resources are ignored by Git; do not
publish Apple's bundle with this source. The ordinary `project-external.yml` build needs no LC assets.
The contained build is `project-contained.yml`; original `PokiApp` remains its entry point.

## Acceptance and evidence

Build `Acceptance/ContainedSafariTests.m` in the dependency-free ios-workspace UI driver (replace
its `Tests/UI/ConcurrencyTests.m` in a scratch copy, then run `scripts/generate-project.py`). Use
Build for Testing and run the individual `WorkspaceTests/ContainedSafariTests` methods. The driver
only performs the user's chat/input side; Poki itself performs the model/tool side. Launch original
Poki with `-pokiScreen chat -pokiContainedSafari YES -pokiContainedEvidence YES` and configure its
OpenRouter account before the live model tests. The test runner must inherit a minimal environment,
without credentials. The existing Debug Simulator FIFO bootstrap is optional, same-user 0600 and
one-shot; never replace it with a plaintext key file.

- `testTransportWhileTyping`: launch with the Debug `contained` probe; navigate to Example Domain
  and read eight real background WebKit snapshots while typing 18 lines (414 characters).
- `testDeepSeekSearchWhileTyping`: ask the original chat to search for Pikachu images, then type
  40 lines (920 characters) in independent TypingPad.
- `testSearchButtonWithFloatingPreview`: request Safari's native refresh, webpage search-input fill,
  ordinary Search-button click and a changed Pikachu wallpaper result while typing another 920
  characters. It attempts PiP first, **but input-test success does not mean PiP success**.

Collect an opted-in model run only after it finishes:

```sh
python3 native/ios-app/scripts/collect-contained.py DEDICATED_SIMULATOR_UUID UI_TEST.log EVIDENCE_DIR
```

The collector checks exact text and app-owned lifecycle/focus events **within the logged typing
window**, and requires real Safari snapshots during that same window. Initial focus setup before
typing is reported separately in raw events. Inspect image pixels independently; DOM image counts
and `finish_task` self-reports alone do not prove a visible image grid.

2026-11-10, Xcode 26.2 / iOS 26.2 Simulator: transport and both live OpenRouter DeepSeek runs passed.
Both model runs produced real Pikachu image grids while each 920-character typing window had zero
focus/foreground loss and exact text. The second run used native refresh, `web_fill` and `web_click`,
and changed the URL/title to Pikachu wallpaper; system Safari remained not running. This used the
independent TypingPad, **not Apple Notes**, which is absent from this Simulator image.

## Limits

This Simulator returns `isPictureInPictureSupported == NO`. Poki's in-app preview shows the latest
real guest screenshot; the floating preview path is present but **cross-app PiP was not verified**.
A later repeat hit an OpenRouter request timeout before any tool call. Its input/liveness test passed
but the collector rejects the missing Agent evidence; it is not counted as a completed model run.

No physical iPhone, Apple Notes, encrypted device Safari, arbitrary third-party app, long-running
reliability, device signing or App Store compatibility has been established. Safari's shared system
storage behavior means LC is not proven to isolate browser accounts/cookies/history. Keep the
Simulator acceptance separate from those unresolved device and sandbox questions.
