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
nitrogen doctor
