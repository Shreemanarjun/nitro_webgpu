#!/usr/bin/env bash
# Regenerates Nitro bindings and rewires the build.
#
# Workaround baked in: nitro_generator 0.5.12 emits a Swift record bridge for
# NativeImpl.cpp modules that references shared codec types (NitroRecordReader,
# NitroEncodable, …). Those are only declared when the plugin also has a
# Swift-impl module — this plugin is all-cpp, so the file can never compile.
# We delete it before `nitrogen link` can sync it into macos|ios SPM Sources/
# and Classes/. (Framework fix candidate: skip RecordGenerator.generateSwift in
# swift_cpp_module_generator.dart for all-cpp plugins.)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

dart run build_runner build

rm -f lib/src/generated/swift/nitro_webgpu.bridge.g.swift \
      macos/Classes/nitro_webgpu.bridge.g.swift \
      ios/Classes/nitro_webgpu.bridge.g.swift \
      macos/nitro_webgpu/Sources/NitroWebgpu/nitro_webgpu.bridge.g.swift \
      ios/nitro_webgpu/Sources/NitroWebgpu/nitro_webgpu.bridge.g.swift

nitrogen link
nitrogen doctor
