#!/usr/bin/env bash
# Switches non-Apple builds (Android/Windows/Linux) between wgpu-native and
# Dawn via the src/third_party/BACKEND marker (content change reconfigures
# CMake). Dawn must be staged first: scripts/stage_dawn_android.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  dawn|wgpu) printf '%s' "$1" > "$REPO_ROOT/src/third_party/BACKEND" ;;
  *) echo "usage: $0 {dawn|wgpu}" >&2; exit 1 ;;
esac
echo "backend: $(cat "$REPO_ROOT/src/third_party/BACKEND")"
