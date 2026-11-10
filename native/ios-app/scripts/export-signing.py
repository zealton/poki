#!/usr/bin/env python3
"""Export concrete signing entitlements using the built app's actual shared group."""
import pathlib
import plistlib
import sys

app, edition, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
if edition not in ("local", "external"):
    raise SystemExit("Expected local or external connection edition")
root = pathlib.Path(__file__).resolve().parent.parent
with (app / "Info.plist").open("rb") as source:
    group = plistlib.load(source)["PokiAppGroup"]
if not group.startswith("group.") or "$" in group:
    raise SystemExit("The built app has no resolved App Group")
templates = {
    "Poki": root / "Poki" / ("PokiLocal.entitlements" if edition == "local" else "Poki.entitlements"),
    "PokiWidgets": root / "PokiWidgets/PokiWidgets.entitlements",
    "PokiKeyboard": root / "PokiKeyboard/PokiKeyboard.entitlements",
}
if edition == "local":
    templates["PokiTunnel"] = root / "PokiTunnel/PokiTunnel.entitlements"
output.mkdir(parents=True, exist_ok=True)
for name, template in templates.items():
    with template.open("rb") as source:
        entitlements = plistlib.load(source)
    if "com.apple.security.application-groups" in entitlements:
        entitlements["com.apple.security.application-groups"] = [group]
    with (output / (name + ".entitlements")).open("wb") as destination:
        plistlib.dump(entitlements, destination)
print(f"{edition}: exported {len(templates)} concrete entitlement files")
