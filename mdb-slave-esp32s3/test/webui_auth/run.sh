#!/usr/bin/env sh
# Host tests for the captive portal's LAN authentication:
#   - main/webui_auth.h (nonces, single use, expiry, lockout, message layout)
#   - the SHA-256 / HMAC-SHA256 in webui/index.html against Node's crypto
# No board needed. Needs a C compiler and Node.js.
#
#   ./run.sh
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -Wall -Wextra -Werror \
   -I "$DIR/../../main" \
   -o "$OUT/test_webui_auth" "$DIR/test_webui_auth.c"
"$OUT/test_webui_auth"

node "$DIR/hmac_interop.mjs"
