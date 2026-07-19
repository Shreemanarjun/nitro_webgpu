#!/usr/bin/env bash
# Switches the macOS build between the wgpu-native and Dawn backends by
# rewriting the toggle literal in macos/nitro_webgpu/Package.swift (SwiftPM
# manifest caching keys on file content — env vars would go stale).
#
#   scripts/set_backend_macos.sh dawn   # stage Dawn + switch
#   scripts/set_backend_macos.sh wgpu   # back to wgpu-native
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/macos/nitro_webgpu/Package.swift"
BACKEND="${1:-}"

case "$BACKEND" in
  dawn)
    "$REPO_ROOT/scripts/stage_dawn_macos.sh"
    perl -pi -e 's/^let useDawnBackend = false$/let useDawnBackend = true/' "$MANIFEST"
    ;;
  wgpu)
    perl -pi -e 's/^let useDawnBackend = true$/let useDawnBackend = false/' "$MANIFEST"
    ;;
  *)
    echo "usage: $0 {dawn|wgpu}" >&2
    exit 1
    ;;
esac
grep -n "let useDawnBackend" "$MANIFEST"
