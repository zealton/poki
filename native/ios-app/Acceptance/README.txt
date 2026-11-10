Manual acceptance driver for the ORIGINAL Poki app (not Workspace).

PokiMainAcceptanceTests.m submits the owner's Safari/Pikachu task through Poki's real chat UI,
then types into the independent TypingPad helper. It never receives a model key or performs
Agent actions. Bundle ID of the tested fork: app.zealton.poki.

Build and launch original native/ios-app with its OpenRouter account configured. For the
Simulator use the documented in-process interactive diagnostic setup; it includes a finite
UIApplication background-task grant, not a Mac Agent loop. Apple Notes is absent on this image.

For the UI test runner, copy native/ios-workspace into a temporary directory (exclude .build),
replace its Tests/UI/ConcurrencyTests.m with this file, and run scripts/generate-project.py.
Build PokiWorkspaceHelpers for testing in a temporary DerivedData directory, then run:
  xcodebuild test-without-building -xctestrun PATH_TO_GENERATED_XCTESTRUN \
    -destination id=SIMULATOR_UUID -only-testing:WorkspaceTests/PokiMainAcceptanceTests
Those helpers provide only the user editor and XCTest driver. The Agent is original Poki.

This is a currently FAILING product acceptance case. Do not invert the assertion or silently
switch to a fixture/custom browser. A passing input assertion alone is also insufficient:
independently verify a NEW completed Agent task and real Safari image results, and cross-check
TypingPad's Documents/evidence.json for foreground loss and text corruption. XCTest can
reactivate an input target, so its application-state checks alone do not prove isolation.

RESULTS.txt records the observed failure. API keys must stay outside source, logs and arguments.
