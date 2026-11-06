#pragma once
/* LAN access to the captive-portal API, authenticated with the SoftAP
 * password (challenge-response).
 *
 * The REST server listens on every interface. A client joined to the
 * device's own SoftAP is trusted the way it always was: the AP is WPA2
 * once the device is claimed, so being on it already proves knowledge of
 * the SoftAP password. A client that reaches the device over the STA side
 * (the operator's LAN) or the cellular link has proven nothing, so every
 * request that changes state must carry a signature:
 *
 *   1. GET /api/v1/auth/nonce            -> {"nonce":"<32 hex>"}
 *   2. <METHOD> <path>?n=<nonce>&s=<sig>  with
 *      sig = hex(HMAC-SHA256(key = softap_pwd,
 *                            msg = nonce "\n" METHOD "\n" path "\n" body))
 *
 * The password itself never crosses the network (there is no TLS on the
 * device), a nonce is good for exactly one attempt and expires after
 * WA_NONCE_TTL_MS, and the signature covers method, path and the exact
 * body bytes, so a captured request can be neither replayed nor rewritten
 * into another action. After WA_MAX_FAILS consecutive bad signatures LAN
 * access is locked for WA_LOCK_MS (online guessing; the password itself is
 * 12 random characters from a 55-symbol alphabet, ~69 bits, so offline
 * guessing from a sniffed nonce/signature pair is not practical either).
 *
 * This header is pure logic — no ESP-IDF, no mbedtls — so the host test in
 * test/webui_auth/ compiles it as-is. The HMAC is injected (wa_hmac_fn);
 * the firmware passes an mbedtls implementation. The state is only touched
 * from the single httpd task, so it needs no lock. The browser side of the
 * same protocol lives in webui/index.html (search for "BEGIN sha256"). */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define WA_NONCE_BYTES    16
#define WA_NONCE_HEX_LEN  (WA_NONCE_BYTES * 2)
#define WA_SIG_BYTES      32
#define WA_SIG_HEX_LEN    (WA_SIG_BYTES * 2)
#define WA_NONCE_SLOTS    4
#define WA_NONCE_TTL_MS   120000u
#define WA_MAX_FAILS      5
#define WA_LOCK_MS        300000u

typedef enum {
    WA_OK = 0,
    WA_NO_PASSWORD,   /* device has no SoftAP password: LAN access impossible */
    WA_LOCKED,        /* too many bad signatures recently */
    WA_MISSING,       /* request carries no nonce/signature */
    WA_BAD_NONCE,     /* unknown, already used or expired nonce */
    WA_BAD_SIG,       /* signature does not match */
} wa_result_t;

typedef struct {
    uint8_t  nonce[WA_NONCE_BYTES];
    uint32_t issued_ms;
    bool     live;
} wa_nonce_slot_t;

typedef struct {
    wa_nonce_slot_t slots[WA_NONCE_SLOTS];
    uint32_t        fails;          /* consecutive bad signatures */
    uint32_t        locked_since_ms;
    bool            locked;
} wa_state_t;

/* HMAC-SHA256 over the concatenation of n parts. */
typedef void (*wa_hmac_fn)(const uint8_t *key, size_t key_len,
                           const uint8_t *const *parts, const size_t *lens,
                           size_t n, uint8_t out[WA_SIG_BYTES]);

static inline void wa_init(wa_state_t *st) { memset(st, 0, sizeof(*st)); }

/* Elapsed time that survives the 32-bit millisecond counter wrapping. */
static inline uint32_t wa_elapsed(uint32_t now_ms, uint32_t since_ms) {
    return now_ms - since_ms;
}

static inline void wa_hex(const uint8_t *in, size_t n, char *out) {
    static const char HEX[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i]     = HEX[in[i] >> 4];
        out[2 * i + 1] = HEX[in[i] & 0x0F];
    }
    out[2 * n] = '\0';
}

static inline int wa_hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decodes exactly n bytes from 2n hex characters followed by NUL. */
static inline bool wa_unhex(const char *hex, uint8_t *out, size_t n) {
    if (!hex || strlen(hex) != 2 * n) return false;
    for (size_t i = 0; i < n; i++) {
        int hi = wa_hexval(hex[2 * i]), lo = wa_hexval(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}

/* Constant-time equality, so response timing does not leak how many
 * leading bytes of a guessed signature were right. */
static inline bool wa_ct_equal(const uint8_t *a, const uint8_t *b, size_t n) {
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) d |= (uint8_t)(a[i] ^ b[i]);
    return d == 0;
}

static inline void wa_expire(wa_state_t *st, uint32_t now_ms) {
    for (int i = 0; i < WA_NONCE_SLOTS; i++) {
        if (st->slots[i].live && wa_elapsed(now_ms, st->slots[i].issued_ms) > WA_NONCE_TTL_MS) {
            st->slots[i].live = false;
        }
    }
    if (st->locked && wa_elapsed(now_ms, st->locked_since_ms) >= WA_LOCK_MS) {
        st->locked = false;
        st->fails  = 0;
    }
}

static inline bool wa_is_locked(wa_state_t *st, uint32_t now_ms) {
    wa_expire(st, now_ms);
    return st->locked;
}

/* Stores a fresh nonce (random bytes supplied by the caller) and writes its
 * hex form to out_hex (WA_NONCE_HEX_LEN + 1 bytes). When every slot is in
 * use the oldest one is replaced: a flood of nonce requests can make a
 * legitimate client retry, but can never make a nonce valid twice. */
static inline void wa_issue_nonce(wa_state_t *st, uint32_t now_ms,
                                  const uint8_t rnd[WA_NONCE_BYTES], char *out_hex) {
    wa_expire(st, now_ms);
    int pick = -1;
    for (int i = 0; i < WA_NONCE_SLOTS; i++) {
        if (!st->slots[i].live) { pick = i; break; }
    }
    if (pick < 0) {
        pick = 0;
        for (int i = 1; i < WA_NONCE_SLOTS; i++) {
            if (wa_elapsed(now_ms, st->slots[i].issued_ms) >
                wa_elapsed(now_ms, st->slots[pick].issued_ms)) pick = i;
        }
    }
    memcpy(st->slots[pick].nonce, rnd, WA_NONCE_BYTES);
    st->slots[pick].issued_ms = now_ms;
    st->slots[pick].live      = true;
    wa_hex(rnd, WA_NONCE_BYTES, out_hex);
}

static inline void wa_note_failure(wa_state_t *st, uint32_t now_ms) {
    if (++st->fails >= WA_MAX_FAILS) {
        st->locked          = true;
        st->locked_since_ms = now_ms;
    }
}

/* Verifies one signed request. The nonce is consumed whatever the outcome,
 * so each nonce allows exactly one guess. A bad nonce counts as a failure
 * too (it is the cheaper way to probe), a missing one does not (that is a
 * client that simply does not know it has to sign). */
static inline wa_result_t wa_verify(wa_state_t *st, uint32_t now_ms,
                                    const char *password,
                                    const char *nonce_hex, const char *sig_hex,
                                    const char *method, const char *path,
                                    const char *body, size_t body_len,
                                    wa_hmac_fn hmac) {
    if (!password || password[0] == '\0') return WA_NO_PASSWORD;
    if (wa_is_locked(st, now_ms))         return WA_LOCKED;
    if (!nonce_hex || !nonce_hex[0] || !sig_hex || !sig_hex[0]) return WA_MISSING;

    uint8_t nonce[WA_NONCE_BYTES];
    int slot = -1;
    if (wa_unhex(nonce_hex, nonce, WA_NONCE_BYTES)) {
        for (int i = 0; i < WA_NONCE_SLOTS; i++) {
            if (st->slots[i].live &&
                wa_ct_equal(st->slots[i].nonce, nonce, WA_NONCE_BYTES)) { slot = i; break; }
        }
    }
    if (slot < 0) {
        wa_note_failure(st, now_ms);
        return WA_BAD_NONCE;
    }
    st->slots[slot].live = false;   /* single use */

    uint8_t want[WA_SIG_BYTES], got[WA_SIG_BYTES];
    if (!wa_unhex(sig_hex, got, WA_SIG_BYTES)) {
        wa_note_failure(st, now_ms);
        return WA_BAD_SIG;
    }

    static const uint8_t NL = '\n';
    const uint8_t *parts[7] = {
        (const uint8_t *)nonce_hex, &NL,
        (const uint8_t *)method,    &NL,
        (const uint8_t *)path,      &NL,
        (const uint8_t *)(body ? body : ""),
    };
    const size_t lens[7] = {
        strlen(nonce_hex), 1, strlen(method), 1, strlen(path), 1, body ? body_len : 0,
    };
    hmac((const uint8_t *)password, strlen(password), parts, lens, 7, want);

    if (!wa_ct_equal(want, got, WA_SIG_BYTES)) {
        wa_note_failure(st, now_ms);
        return WA_BAD_SIG;
    }
    st->fails = 0;
    return WA_OK;
}
