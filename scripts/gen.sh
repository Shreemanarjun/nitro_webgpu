#!/usr/bin/env bash
# Regenerates Nitro bindings and rewires the build.
#
# Requires nitro / nitro_generator / nitrogen_cli >= 0.5.14 — earlier CLIs
# re-emitted a target-named SPM umbrella header (nitro_ecosystem#21), synced
# the present bridge .mm into the wrong SPM target, and dropped the all-cpp
# module's JniBridge import from the Android plugin (#16). All three are
# fixed in 0.5.14; keep the GLOBAL activation in sync with the project deps:
#   dart pub global activate nitrogen_cli
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

dart run build_runner build
nitrogen link

# nitrogen 0.5.14 emits trailing commas in Swift argument lists — legal only
# on Swift 6.1+ (Xcode 16.3+); Xcode 15/16.2 (macos-14 CI) fails with
# "Unexpected ',' separator". Strip them until upstream stops emitting them.
for f in lib/src/generated/swift/*.g.swift \
         ios/Classes/*.g.swift macos/Classes/*.g.swift \
         ios/nitro_webgpu/Sources/NitroWebgpu/*.g.swift \
         macos/nitro_webgpu/Sources/NitroWebgpu/*.g.swift; do
  [ -f "$f" ] && perl -0pi -e 's/,(\s*\n\s*\))/$1/g' "$f"
done

# nitrogen re-templates the pubspec plugin platforms block, dropping the
# hand-added desktop pluginClass entries (same bug family as the Android
# import drop — nitro_ecosystem#16). Without them the Windows/Linux texture
# plugins never register and every WebGpuView stays blank (createPresenter
# returns 0). Fail loudly instead of shipping that.
if ! grep -q "pluginClass: NitroWebgpuPluginCApi" pubspec.yaml \
  || ! grep -q "pluginClass: NitroWebgpuPlugin$" pubspec.yaml; then
  echo "ERROR: desktop pluginClass entries missing from pubspec.yaml" >&2
  echo "  windows needs 'pluginClass: NitroWebgpuPluginCApi'" >&2
  echo "  linux needs   'pluginClass: NitroWebgpuPlugin'" >&2
  exit 1
fi

nitrogen doctor
