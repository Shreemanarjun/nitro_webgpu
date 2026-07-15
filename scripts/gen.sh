#!/usr/bin/env bash
# Regenerates Nitro bindings and rewires the build.
#
# Note: the plugin has a mixed-language module set (nitro_webgpu is all-cpp,
# nitro_webgpu_present has Swift/Kotlin impls). The Swift-impl module's bridge
# declares the shared Swift codec types (NitroRecordReader, NitroEncodable, …),
# which also makes the cpp module's generated Swift record bridge compile —
# the all-cpp workaround that used to delete it is no longer needed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

dart run build_runner build
nitrogen link
nitrogen doctor
