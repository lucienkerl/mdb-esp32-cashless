#!/usr/bin/env sh
# Host-side test for the F02DC frame parser in main/rfid_reader.c.
#
# The parser is pure byte-stream logic, so it runs on the build machine with
# a handful of ESP-IDF stubs instead of needing a flashed board. The test
# includes rfid_reader.c directly so it can drive the static state machine
# byte by byte.
#
#   ./run.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -Wall -Wextra \
   -I "$DIR/stubs" -I "$DIR/../../main" \
   -o "$OUT/test_rfid_reader" "$DIR/test_rfid_reader.c"

"$OUT/test_rfid_reader"
