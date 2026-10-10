#!/usr/bin/env sh
# Host test for main/mdb_trace.h — no board needed, it is pure C11.
#
#   ./run.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -Wall -Wextra \
   -I "$DIR/../../main" \
   -o "$OUT/test_mdb_trace" "$DIR/test_mdb_trace.c"

"$OUT/test_mdb_trace"
