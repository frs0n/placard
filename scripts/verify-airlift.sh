#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
shasum -a 256 -c Vendor/AirCard/SHA256SUMS

if [[ $# -eq 0 ]]; then
  exit 0
fi

app_path="$1"
expected_version="$2"
# Rust resolves this symbol with dlsym, so a successful link alone is insufficient.
exports=$(xcrun dyld_info -exports "$app_path/placard")
if ! grep -q '_ALGetGrappaToken$' <<< "$exports"; then
  echo "Archive is missing the exported Grappa token provider" >&2
  exit 1
fi
python3 - "$app_path/Info.plist" "$expected_version" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
assert info['CFBundleShortVersionString'] == sys.argv[2], 'Archive version mismatch'
assert '_remotepairing-pairable-host._tcp' in info['NSBonjourServices']
assert '_aircardprobe._tcp' in info['NSBonjourServices']
assert info['NSLocalNetworkUsageDescription']
assert 'audio' in info['UIBackgroundModes']
print('Archive version, Grappa export and Airlift permissions verified')
PY
