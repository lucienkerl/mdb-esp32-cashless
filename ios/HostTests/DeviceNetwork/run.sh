#!/usr/bin/env sh
# Host test for VMflow/Models/DeviceNetwork.swift — the same cases as
# management-frontend/app/lib/__tests__/network.test.ts, so iOS and the web
# agree on signal levels. Pure Foundation, runs with any Swift toolchain.
#
#   ./run.sh            (uses `swiftc` from PATH, or $SWIFTC)
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

"${SWIFTC:-swiftc}" \
  "$DIR/../../VMflow/Models/DeviceNetwork.swift" \
  "$DIR/main.swift" \
  -o "$OUT/device-network-tests"

"$OUT/device-network-tests"
