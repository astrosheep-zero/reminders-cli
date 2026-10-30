#!/bin/bash
# Use the installed real Swift Testing implementation. Some CLT releases ship
# TestingMacros but omit its plugin search path from SwiftPM's default build.
set -euo pipefail
cd "$(dirname "$0")/.."
developer="$(xcode-select -p)"
plugin="$developer/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
args=(--disable-xctest)
if [[ -f "$plugin" ]]; then
  args+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin")
fi
exec swift test "${args[@]}" "$@"
