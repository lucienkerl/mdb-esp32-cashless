#!/usr/bin/env sh
# Host test for VMflow/Models/DeviceConnectivity.swift — the same cases as
# management-frontend/app/lib/__tests__/connectivity.test.ts, so iOS and the
# web agree on what "online" means. Pure Foundation, so it runs with any Swift
# toolchain (macOS or Linux), no Xcode project needed.
#
#   ./run.sh            (uses `swiftc` from PATH, or $SWIFTC)
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

"${SWIFTC:-swiftc}" \
  "$DIR/../../VMflow/Models/DeviceConnectivity.swift" \
  "$DIR/main.swift" \
  -o "$OUT/connectivity-tests"

"$OUT/connectivity-tests"
