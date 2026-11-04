#!/usr/bin/env sh
# Host test for main/cred_backup_format.h — the on-flash image format of the
# credentials backup. Pure byte logic, no board needed.
#
#   ./run.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -Wall -Wextra -Werror \
   -I "$DIR/../../main" \
   -o "$OUT/test_cred_backup_format" "$DIR/test_cred_backup_format.c"

"$OUT/test_cred_backup_format"
