#!/usr/bin/env sh
# Host test for main/scale_factor.h — no board needed, it is pure arithmetic.
#
#   ./run.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -Wall -Wextra \
   -I "$DIR/../../main" \
   -o "$OUT/test_scale_factor" "$DIR/test_scale_factor.c" -lm

"$OUT/test_scale_factor"
