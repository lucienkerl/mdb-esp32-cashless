/* Host test for main/webui_auth.h — LAN challenge-response for the
 * captive-portal API. Pure logic: the HMAC is a recording fake here, so
 * the test also pins the exact message layout the browser has to sign
 * (hmac_interop.mjs checks the browser side against the same layout with
 * a real HMAC-SHA256). */
#include <stdio.h>
#include <stdlib.h>
#include "webui_auth.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

/* Fake HMAC: records key + concatenated message, derives 32 bytes from
 * both with FNV-1a so a different key or message gives a different MAC. */
static char   last_msg[1024];
static size_t last_msg_len;
static char   last_key[64];

static void fake_hmac(const uint8_t *key, size_t key_len,
                      const uint8_t *const *parts, const size_t *lens,
                      size_t n, uint8_t out[WA_SIG_BYTES]) {
    last_msg_len = 0;
    for (size_t i = 0; i < n; i++) {
        memcpy(last_msg + last_msg_len, parts[i], lens[i]);
        last_msg_len += lens[i];
    }
    last_msg[last_msg_len] = '\0';
    memcpy(last_key, key, key_len);
    last_key[key_len] = '\0';

    uint32_t h = 2166136261u;
    for (size_t i = 0; i < key_len; i++) { h ^= key[i]; h *= 16777619u; }
    h ^= 0xFF; h *= 16777619u;
    for (size_t i = 0; i < last_msg_len; i++) { h ^= (uint8_t)last_msg[i]; h *= 16777619u; }
    for (int i = 0; i < WA_SIG_BYTES; i++) { h ^= (uint32_t)i; h *= 16777619u; out[i] = (uint8_t)(h >> 24); }
}

static void sign(const char *pwd, const char *nonce, const char *method,
                 const char *path, const char *body, char sig_hex[WA_SIG_HEX_LEN + 1]) {
    const uint8_t NL = '\n';
    const uint8_t *parts[7] = { (const uint8_t *)nonce, &NL, (const uint8_t *)method, &NL,
                                (const uint8_t *)path, &NL, (const uint8_t *)body };
    const size_t lens[7] = { strlen(nonce), 1, strlen(method), 1, strlen(path), 1, strlen(body) };
    uint8_t mac[WA_SIG_BYTES];
    fake_hmac((const uint8_t *)pwd, strlen(pwd), parts, lens, 7, mac);
    wa_hex(mac, WA_SIG_BYTES, sig_hex);
}

static void issue(wa_state_t *st, uint32_t now, uint8_t seed, char nonce[WA_NONCE_HEX_LEN + 1]) {
    uint8_t rnd[WA_NONCE_BYTES];
    for (int i = 0; i < WA_NONCE_BYTES; i++) rnd[i] = (uint8_t)(seed * 31 + i);
    wa_issue_nonce(st, now, rnd, nonce);
}

#define PWD "Kp7mQx2RtW9z"
#define VERIFY(st, now, pwd, nonce, sig, method, path, body) \
    wa_verify((st), (now), (pwd), (nonce), (sig), (method), (path), (body), strlen(body), fake_hmac)

static void test_valid_request_and_message_layout(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    issue(&st, 1000, 1, nonce);
    CHECK(strlen(nonce) == WA_NONCE_HEX_LEN);
    sign(PWD, nonce, "POST", "/api/v1/system/reset", "{}", sig);
    CHECK(VERIFY(&st, 1500, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_OK);

    char want[256];
    snprintf(want, sizeof(want), "%s\nPOST\n/api/v1/system/reset\n{}", nonce);
    CHECK(strcmp(last_msg, want) == 0);
    CHECK(strcmp(last_key, PWD) == 0);
}

static void test_empty_body(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    issue(&st, 0, 2, nonce);
    sign(PWD, nonce, "GET", "/api/v1/wifi/scan", "", sig);
    CHECK(wa_verify(&st, 10, PWD, nonce, sig, "GET", "/api/v1/wifi/scan", NULL, 0, fake_hmac) == WA_OK);
    char want[128];
    snprintf(want, sizeof(want), "%s\nGET\n/api/v1/wifi/scan\n", nonce);
    CHECK(strcmp(last_msg, want) == 0);
}

static void test_nonce_single_use(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    issue(&st, 0, 3, nonce);
    sign(PWD, nonce, "POST", "/api/v1/system/reset", "{}", sig);
    CHECK(VERIFY(&st, 1, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_OK);
    CHECK(VERIFY(&st, 2, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_BAD_NONCE);
}

static void test_nonce_consumed_by_failed_attempt(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], good[WA_SIG_HEX_LEN + 1], bad[WA_SIG_HEX_LEN + 1];
    issue(&st, 0, 4, nonce);
    sign("wrong-password", nonce, "POST", "/api/v1/system/reset", "{}", bad);
    sign(PWD, nonce, "POST", "/api/v1/system/reset", "{}", good);
    CHECK(VERIFY(&st, 1, PWD, nonce, bad, "POST", "/api/v1/system/reset", "{}") == WA_BAD_SIG);
    /* one guess per nonce: even the right signature is too late now */
    CHECK(VERIFY(&st, 2, PWD, nonce, good, "POST", "/api/v1/system/reset", "{}") == WA_BAD_NONCE);
}

static void test_nonce_expiry(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    issue(&st, 1000, 5, nonce);
    sign(PWD, nonce, "POST", "/api/v1/auth/check", "{}", sig);
    CHECK(VERIFY(&st, 1000 + WA_NONCE_TTL_MS + 1, PWD, nonce, sig, "POST", "/api/v1/auth/check", "{}") == WA_BAD_NONCE);

    issue(&st, 5000, 6, nonce);
    sign(PWD, nonce, "POST", "/api/v1/auth/check", "{}", sig);
    CHECK(VERIFY(&st, 5000 + WA_NONCE_TTL_MS, PWD, nonce, sig, "POST", "/api/v1/auth/check", "{}") == WA_OK);
}

static void test_expiry_across_counter_wrap(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    uint32_t t0 = 0xFFFFFF00u;
    issue(&st, t0, 7, nonce);
    sign(PWD, nonce, "POST", "/api/v1/auth/check", "{}", sig);
    CHECK(VERIFY(&st, t0 + 1000u, PWD, nonce, sig, "POST", "/api/v1/auth/check", "{}") == WA_OK);
}

static void test_signature_binds_method_path_body(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];

    issue(&st, 0, 8, nonce);
    sign(PWD, nonce, "POST", "/api/v1/auth/check", "{}", sig);
    CHECK(VERIFY(&st, 1, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_BAD_SIG);

    issue(&st, 0, 9, nonce);
    sign(PWD, nonce, "POST", "/api/v1/wifi/configure", "{\"ssid\":\"a\",\"password\":\"b\"}", sig);
    CHECK(VERIFY(&st, 1, PWD, nonce, sig, "POST", "/api/v1/wifi/configure",
                 "{\"ssid\":\"evil\",\"password\":\"b\"}") == WA_BAD_SIG);

    issue(&st, 0, 10, nonce);
    sign(PWD, nonce, "GET", "/api/v1/wifi/scan", "", sig);
    CHECK(VERIFY(&st, 1, PWD, nonce, sig, "POST", "/api/v1/wifi/scan", "") == WA_BAD_SIG);
}

static void test_no_password_refuses(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    issue(&st, 0, 11, nonce);
    sign("", nonce, "POST", "/api/v1/system/reset", "{}", sig);
    CHECK(VERIFY(&st, 1, "", nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_NO_PASSWORD);
    CHECK(VERIFY(&st, 1, NULL, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_NO_PASSWORD);
}

static void test_missing_and_malformed(void) {
    wa_state_t st; wa_init(&st);
    CHECK(VERIFY(&st, 0, PWD, "", "", "POST", "/api/v1/system/reset", "{}") == WA_MISSING);
    CHECK(VERIFY(&st, 0, PWD, NULL, NULL, "POST", "/api/v1/system/reset", "{}") == WA_MISSING);
    CHECK(st.fails == 0);   /* an unsigned request is not a guess */

    char nonce[WA_NONCE_HEX_LEN + 1];
    issue(&st, 0, 12, nonce);
    CHECK(VERIFY(&st, 1, PWD, "zz", "00", "POST", "/x", "") == WA_BAD_NONCE);
    CHECK(VERIFY(&st, 1, PWD, nonce, "not-hex", "POST", "/x", "") == WA_BAD_SIG);
    CHECK(st.fails == 2);
}

static void test_lockout_and_recovery(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    uint32_t t = 100;
    for (int i = 0; i < WA_MAX_FAILS; i++) {
        issue(&st, t, (uint8_t)(20 + i), nonce);
        sign("guess", nonce, "POST", "/api/v1/system/reset", "{}", sig);
        CHECK(VERIFY(&st, t, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_BAD_SIG);
    }
    CHECK(wa_is_locked(&st, t));

    /* locked: even the right password is refused */
    issue(&st, t + 10, 40, nonce);
    sign(PWD, nonce, "POST", "/api/v1/system/reset", "{}", sig);
    CHECK(VERIFY(&st, t + 10, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_LOCKED);

    /* lock lifts after WA_LOCK_MS */
    uint32_t later = t + WA_LOCK_MS;
    CHECK(!wa_is_locked(&st, later));
    issue(&st, later, 41, nonce);
    sign(PWD, nonce, "POST", "/api/v1/system/reset", "{}", sig);
    CHECK(VERIFY(&st, later + 1, PWD, nonce, sig, "POST", "/api/v1/system/reset", "{}") == WA_OK);
}

static void test_success_resets_fail_counter(void) {
    wa_state_t st; wa_init(&st);
    char nonce[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    for (int round = 0; round < 3; round++) {
        for (int i = 0; i < WA_MAX_FAILS - 1; i++) {
            issue(&st, 0, (uint8_t)(50 + round * 10 + i), nonce);
            sign("guess", nonce, "POST", "/x", "", sig);
            CHECK(VERIFY(&st, 0, PWD, nonce, sig, "POST", "/x", "") == WA_BAD_SIG);
        }
        issue(&st, 0, (uint8_t)(90 + round), nonce);
        sign(PWD, nonce, "POST", "/x", "", sig);
        CHECK(VERIFY(&st, 0, PWD, nonce, sig, "POST", "/x", "") == WA_OK);
        CHECK(st.fails == 0);
    }
    CHECK(!wa_is_locked(&st, 0));
}

static void test_slot_eviction(void) {
    wa_state_t st; wa_init(&st);
    char first[WA_NONCE_HEX_LEN + 1], other[WA_NONCE_HEX_LEN + 1], sig[WA_SIG_HEX_LEN + 1];
    issue(&st, 0, 60, first);
    for (int i = 0; i < WA_NONCE_SLOTS; i++) issue(&st, (uint32_t)(10 + i), (uint8_t)(61 + i), other);
    /* the oldest nonce was replaced by the flood */
    sign(PWD, first, "POST", "/x", "", sig);
    CHECK(VERIFY(&st, 20, PWD, first, sig, "POST", "/x", "") == WA_BAD_NONCE);
    /* the newest still works */
    sign(PWD, other, "POST", "/x", "", sig);
    CHECK(VERIFY(&st, 20, PWD, other, sig, "POST", "/x", "") == WA_OK);
}

static void test_hex_helpers(void) {
    uint8_t b[3];
    CHECK(wa_unhex("00aFff", b, 3) && b[0] == 0x00 && b[1] == 0xAF && b[2] == 0xFF);
    CHECK(!wa_unhex("00aF", b, 3));
    CHECK(!wa_unhex("00aFfg", b, 3));
    const uint8_t x[4] = {1, 2, 3, 4}, y[4] = {1, 2, 3, 5};
    CHECK(wa_ct_equal(x, x, 4));
    CHECK(!wa_ct_equal(x, y, 4));
}

int main(void) {
    test_valid_request_and_message_layout();
    test_empty_body();
    test_nonce_single_use();
    test_nonce_consumed_by_failed_attempt();
    test_nonce_expiry();
    test_expiry_across_counter_wrap();
    test_signature_binds_method_path_body();
    test_no_password_refuses();
    test_missing_and_malformed();
    test_lockout_and_recovery();
    test_success_resets_fail_counter();
    test_slot_eviction();
    test_hex_helpers();
    if (failures) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    printf("webui_auth: all tests passed\n");
    return 0;
}
