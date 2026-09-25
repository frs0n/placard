#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
aircard_revision="097a058c984ffc33ccb697b9dfe8058be3e86244"
destination="$project_root/AirliftFFI.xcframework"

if [[ -f "$destination/ios-arm64/libairlift_ffi.a" && -f "$destination/ios-arm64-simulator/libairlift_ffi.a" ]]; then
    echo "AirliftFFI.xcframework is already prepared."
    exit 0
fi

temporary_checkout="$(mktemp -d)"
trap 'rm -rf "$temporary_checkout"' EXIT
git -C "$temporary_checkout" init -q
git -C "$temporary_checkout" remote add origin https://github.com/Mak5er/AirCard-iOS.git
git -C "$temporary_checkout" fetch --depth 1 origin "$aircard_revision"
git -C "$temporary_checkout" checkout -q FETCH_HEAD

if [[ "$(git -C "$temporary_checkout" rev-parse HEAD)" != "$aircard_revision" ]]; then
    echo "Unexpected AirCard-iOS revision" >&2
    exit 1
fi
cp -R "$temporary_checkout/AirliftFFI.xcframework" "$destination"
echo "Prepared AirCard-iOS AirliftFFI at $aircard_revision"
