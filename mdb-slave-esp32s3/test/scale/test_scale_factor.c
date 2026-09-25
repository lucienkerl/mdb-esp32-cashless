/*
 * Host test for main/scale_factor.h — the real header, not a copy.
 *
 * Guards the field bug where a card balance of 8.20 reached the machine as
 * 8.18: the backend truncated 819.9999999999999 to 819 on the way out, and
 * the firmware truncated it again to 818 on the way in.
 */
#include <stdio.h>
#include <stdint.h>
#include <assert.h>

#include "scale_factor.h"

/* The configured build: scale factor 1, 2 decimal places — one unit is a cent. */
#define SCALE 1
#define DEC   2

/* xorDecodeWithPasskey: wire cents -> MDB credit units. */
static uint16_t decode_credit(uint32_t wire_cents) {
    return (uint16_t) TO_SCALE_FACTOR(FROM_SCALE_FACTOR(wire_cents, 1, 2), SCALE, DEC);
}

/* xorEncodeWithPasskey: MDB price units -> wire cents. */
static uint32_t encode_price(uint16_t mdb_units) {
    return (uint32_t) TO_SCALE_FACTOR(FROM_SCALE_FACTOR(mdb_units, SCALE, DEC), 1, 2);
}

int main(void) {
    /* The reported case, both directions. */
    assert(decode_credit(820) == 820);   /* 8.20 credit arrives as 8.20 */
    assert(decode_credit(819) == 819);
    assert(encode_price(205) == 205);    /* a 2.05 item is reported as 2.05 */

    /* The values the truncating version got wrong, spot-checked. */
    static const uint32_t regressions[] = { 29, 58, 59, 116, 117, 118, 119,
                                            205, 207, 209, 211, 213,
                                            232, 234, 236, 238, 819, 820 };
    for (size_t i = 0; i < sizeof(regressions) / sizeof(regressions[0]); i++) {
        uint32_t c = regressions[i];
        assert(decode_credit(c) == c);
        assert(encode_price((uint16_t) c) == c);
    }

    /* Exhaustive over the whole uint16 credit range the MDB field can hold. */
    int bad_decode = 0, bad_encode = 0;
    for (uint32_t c = 0; c <= 65535; c++) {
        if (decode_credit(c) != c) { if (!bad_decode) printf("decode %u -> %u\n", c, decode_credit(c)); bad_decode++; }
        if (encode_price((uint16_t) c) != c) { if (!bad_encode) printf("encode %u -> %u\n", c, encode_price((uint16_t) c)); bad_encode++; }
    }
    assert(bad_decode == 0);
    assert(bad_encode == 0);

    /* FROM_SCALE_FACTOR still yields a currency amount, not a rounded unit —
     * publish_mdb_diag and the credit log print it. */
    double eur = FROM_SCALE_FACTOR(820, SCALE, DEC);
    assert(eur > 8.19 && eur < 8.21);

    /* Other scale factors the Kconfig offers still behave. */
    assert((uint32_t) TO_SCALE_FACTOR(FROM_SCALE_FACTOR(82u, 10, 2), 10, 2) == 82);
    assert((uint32_t) TO_SCALE_FACTOR(FROM_SCALE_FACTOR(8u, 100, 2), 100, 2) == 8);
    assert((uint32_t) TO_SCALE_FACTOR(FROM_SCALE_FACTOR(820u, 1, 3), 1, 3) == 820);

    printf("scale factor: all conversions exact over 0..65535 units\n");
    return 0;
}
