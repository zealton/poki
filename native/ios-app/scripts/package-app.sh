#!/bin/bash
# Package an unsigned build. Checks that the app and every extension carry the release version, as
# xcodebuild set it (MARKETING_VERSION and CURRENT_PROJECT_VERSION); a build without it is refused,
# not fixed up here, so ios-app.yml's check of the IPA can catch it.
set -euo pipefail
if [ "$#" != 5 ]; then
  echo "Usage: package-app.sh Poki.app local|external output.ipa version build" >&2
  exit 2
fi
app="$1"; edition="$2"; output="$3"; version="$4"; build="$5"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/Poki.app"
python3 - "$stage/Payload/Poki.app" "$edition" "$version" "$build" <<'PY'
import pathlib, plistlib, sys
app, edition, version, build = pathlib.Path(sys.argv[1]), *sys.argv[2:]
if edition not in ('local', 'external'):
    raise SystemExit('Expected local or external connection edition')
extensions = {p.name for p in (app / 'PlugIns').glob('*.appex')}
expected = {'PokiWidgets.appex', 'PokiKeyboard.appex'} | ({'PokiTunnel.appex'} if edition == 'local' else set())
if extensions != expected:
    raise SystemExit(f'Wrong extensions for {edition}: {sorted(extensions)}')
if edition == 'local':
    with (app / 'PlugIns/PokiTunnel.appex/Info.plist').open('rb') as f:
        extension = plistlib.load(f).get('NSExtension', {})
    if extension.get('NSExtensionPointIdentifier') != 'com.apple.networkextension.packet-tunnel':
        raise SystemExit('Missing packet-tunnel extension point')
    if extension.get('NSExtensionPrincipalClass') != 'PokiTunnel.PacketTunnelProvider':
        raise SystemExit('Wrong packet-tunnel entry point')
for bundle in [app, *sorted((app / 'PlugIns').glob('*.appex'))]:
    with (bundle / 'Info.plist').open('rb') as f:
        info = plistlib.load(f)
    found = (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion'))
    if found != (version, build):
        raise SystemExit(f'{bundle.name} was built as {found[0]} ({found[1]}), expected {version} ({build}): pass MARKETING_VERSION and CURRENT_PROJECT_VERSION to xcodebuild')
print(f'{edition}: app and {len(extensions)} extensions, version {version} ({build})')
PY
mkdir -p "$(dirname "$output")"
ditto -c -k --keepParent --norsrc "$stage/Payload" "$output"
