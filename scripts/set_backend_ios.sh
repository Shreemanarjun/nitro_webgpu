#!/usr/bin/env bash
# Switches the iOS build between wgpu-native and Dawn (mirrors
# set_backend_macos.sh — SwiftPM manifest caching keys on file content).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/ios/nitro_webgpu/Package.swift"
case "${1:-}" in
  dawn)
    "$REPO_ROOT/scripts/stage_dawn_ios.sh"
    perl -pi -e 's/^let useDawnBackend = false$/let useDawnBackend = true/' "$MANIFEST"
    ;;
  wgpu)
    perl -pi -e 's/^let useDawnBackend = true$/let useDawnBackend = false/' "$MANIFEST"
    ;;
  *) echo "usage: $0 {dawn|wgpu}" >&2; exit 1 ;;
esac
grep -n "let useDawnBackend" "$MANIFEST"
