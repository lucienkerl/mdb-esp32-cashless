/* Host harness for the F02DC frame parser: includes the driver so the
 * static parser state machine can be driven byte by byte. */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <stdint.h>

int64_t g_fake_time_us = 0;

#include "rfid_reader.c"  /* the driver itself, for its static state machine */

static rfid_card_t last_card;
static int cb_calls;

static void on_card(const rfid_card_t *c, void *ctx) { (void) ctx; last_card = *c; cb_calls++; }

static void feed_bytes(const uint8_t *b, size_t n) { for (size_t i = 0; i < n; i++) rfid_feed(b[i]); }

/* Build 0x02 | LEN | TYPE | DATA | XOR | 0x03 */
static size_t build(uint8_t *out, uint8_t len_byte, uint8_t type, const uint8_t *uid, size_t n) {
    size_t k = 0;
    out[k++] = 0x02;
    out[k++] = len_byte;
    out[k++] = type;
    memcpy(&out[k], uid, n); k += n;
    uint8_t x = len_byte ^ type;
    for (size_t i = 0; i < n; i++) x ^= uid[i];
    out[k++] = x;
    out[k++] = 0x03;
    return k;
}

static void reset_state(void) {
    s_cb = on_card; s_ctx = NULL;
    s_collecting = false; s_frame_len = 0;
    s_last_uid[0] = '\0'; s_last_uid_us = 0;
    s_frames_ok = s_frames_bad = s_cards_reported = s_cards_deduped = 0;
    s_rx_bytes = 0;
    s_burst_len = 0; s_burst_seen = 0; s_last_dump_us = 0;
    cb_calls = 0; g_fake_time_us = 1000000;
}

int main(void) {
    uint8_t buf[64];
    size_t n;

    /* 1. plain 4-byte UID */
    reset_state();
    const uint8_t uid4[] = { 0x04, 0xA1, 0xB2, 0xC3 };
    n = build(buf, 0x07, 0x02, uid4, 4);
    feed_bytes(buf, n);
    assert(cb_calls == 1);
    assert(strcmp(last_card.uid_hex, "04A1B2C3") == 0);
    assert(last_card.uid_len == 4);
    assert(last_card.card_type == 0x02);
    assert(rfid_frames_ok() == 1 && rfid_frames_bad() == 0);

    /* 2. the LEN byte is not trusted: same frame, absurd LEN, still parsed */
    reset_state();
    n = build(buf, 0xFE, 0x02, uid4, 4);
    feed_bytes(buf, n);
    assert(cb_calls == 1 && strcmp(last_card.uid_hex, "04A1B2C3") == 0);

    /* 3. 5-byte EM4100 serial with a leading zero byte */
    reset_state();
    const uint8_t uid5[] = { 0x00, 0x0F, 0x12, 0x34, 0x56 };
    n = build(buf, 0x08, 0x01, uid5, 5);
    feed_bytes(buf, n);
    assert(cb_calls == 1 && strcmp(last_card.uid_hex, "000F123456") == 0);

    /* 4. 0x03 inside the card data does not end the frame early */
    reset_state();
    const uint8_t uid_etx[] = { 0x03, 0x03, 0xAB, 0x03 };
    n = build(buf, 0x07, 0x02, uid_etx, 4);
    feed_bytes(buf, n);
    assert(cb_calls == 1);
    assert(strcmp(last_card.uid_hex, "0303AB03") == 0);
    assert(last_card.uid_len == 4);

    /* 5. duplicate frames inside the window produce exactly one callback */
    reset_state();
    n = build(buf, 0x07, 0x02, uid4, 4);
    for (int i = 0; i < 20; i++) { g_fake_time_us += 200000; feed_bytes(buf, n); }  /* 4 s of repeats */
    assert(cb_calls == 1);
    assert(rfid_cards_reported() == 1);
    assert(rfid_cards_deduped() == 19);

    /* 6. the window slides: holding the card for a minute still reports once */
    reset_state();
    for (int i = 0; i < 300; i++) { g_fake_time_us += 200000; feed_bytes(buf, n); }  /* 60 s */
    assert(cb_calls == 1);

    /* 7. taking the card away for longer than the window re-arms it */
    reset_state();
    feed_bytes(buf, n);
    g_fake_time_us += (int64_t) CONFIG_RFID_DEDUP_MS * 1000 + 1000;
    feed_bytes(buf, n);
    assert(cb_calls == 2);

    /* 8. a different card is reported immediately, not deduped */
    reset_state();
    feed_bytes(buf, n);
    const uint8_t uid_other[] = { 0x0B, 0xAD, 0xC0, 0xDE };
    size_t n2 = build(buf, 0x07, 0x02, uid_other, 4);
    g_fake_time_us += 100000;
    feed_bytes(buf, n2);
    assert(cb_calls == 2 && strcmp(last_card.uid_hex, "0BADC0DE") == 0);

    /* 9. reset_dedup lets the same card through again at once */
    reset_state();
    n = build(buf, 0x07, 0x02, uid4, 4);
    feed_bytes(buf, n);
    rfid_reader_reset_dedup();
    feed_bytes(buf, n);
    assert(cb_calls == 2);

    /* 10. a corrupted checksum byte is not reported */
    reset_state();
    n = build(buf, 0x07, 0x02, uid4, 4);
    buf[n - 2] ^= 0xFF;
    feed_bytes(buf, n);
    assert(cb_calls == 0);

    /* 11. a flipped data bit is not reported */
    reset_state();
    n = build(buf, 0x07, 0x02, uid4, 4);
    buf[4] ^= 0x01;
    feed_bytes(buf, n);
    assert(cb_calls == 0);

    /* 12. line noise before the frame does not stop it being parsed */
    reset_state();
    const uint8_t noise[] = { 0xFF, 0x00, 0x55, 0xAA };
    feed_bytes(noise, sizeof(noise));
    n = build(buf, 0x07, 0x02, uid4, 4);
    feed_bytes(buf, n);
    assert(cb_calls == 1);

    /* 13a. a truncated frame, then the line goes idle (what the reader task
     *      does after RFID_IDLE_MS): the next frame parses normally */
    reset_state();
    n = build(buf, 0x07, 0x02, uid4, 4);
    feed_bytes(buf, 4);                 /* cut mid-frame, no ETX */
    rfid_reset_frame();                 /* the task's idle-timeout path */
    feed_bytes(buf, n);
    assert(cb_calls == 1 && strcmp(last_card.uid_hex, "04A1B2C3") == 0);

    /* 13b. no idle gap at all — a byte lost mid-burst. 0x02 is legal card
     *      data so the parser cannot cut a partial frame short on sight; the
     *      buffer cap bounds the loss, and a repeating reader gets through
     *      within a few frames. */
    reset_state();
    feed_bytes(buf, 4);                 /* cut mid-frame, no ETX */
    for (int i = 0; i < 5; i++) feed_bytes(buf, n);
    assert(cb_calls == 1 && strcmp(last_card.uid_hex, "04A1B2C3") == 0);

    /* 14. an overlong burst without a valid end resynchronises */
    reset_state();
    uint8_t junk[80];
    junk[0] = 0x02;
    for (size_t i = 1; i < sizeof(junk); i++) junk[i] = 0x41;
    feed_bytes(junk, sizeof(junk));
    assert(rfid_frames_bad() >= 1);
    n = build(buf, 0x07, 0x02, uid4, 4);
    feed_bytes(buf, n);
    assert(cb_calls == 1);

    /* 15. a UID longer than the buffer is rejected, not overrun */
    reset_state();
    uint8_t big[RFID_UID_MAX_BYTES + 4];
    for (size_t i = 0; i < sizeof(big); i++) big[i] = (uint8_t) (i + 1);
    uint8_t frame[64];
    n = build(frame, 0x20, 0x02, big, sizeof(big));
    feed_bytes(frame, n);
    assert(cb_calls == 0);

    /* 16. the longest accepted UID still works */
    reset_state();
    uint8_t max_uid[RFID_UID_MAX_BYTES];
    for (size_t i = 0; i < sizeof(max_uid); i++) max_uid[i] = (uint8_t) (0x10 + i);
    n = build(frame, 0x14, 0x02, max_uid, sizeof(max_uid));
    feed_bytes(frame, n);
    assert(cb_calls == 1 && last_card.uid_len == RFID_UID_MAX_BYTES);
    assert(strlen(last_card.uid_hex) == RFID_UID_MAX_BYTES * 2);

    /* 17. back-to-back frames from two cards are both parsed */
    reset_state();
    uint8_t two[64];
    size_t a = build(two, 0x07, 0x02, uid4, 4);
    size_t b = build(two + a, 0x07, 0x02, uid_other, 4);
    feed_bytes(two, a + b);
    assert(cb_calls == 2);

    /* 18. every byte on the line is counted, frame or not — the counter
     * that separates "reader is mute" from "reader speaks another dialect" */
    reset_state();
    const uint8_t ascii[] = "0004A1B2C3\r\n";   /* an ASCII-output reader */
    feed_bytes(ascii, sizeof(ascii) - 1);
    assert(rfid_rx_bytes() == sizeof(ascii) - 1);
    assert(cb_calls == 0 && rfid_frames_ok() == 0);
    assert(rfid_frames_bad() == 0);              /* no STX, so no frame to spoil */
    rfid_idle();                                 /* the burst gets reported once */
    assert(rfid_frames_bad() == 0);
    assert(s_burst_seen == 0);                   /* and is not reported twice */

    /* 19. a frame cut short is counted bad when the line goes quiet, and
     * the next complete frame still parses */
    reset_state();
    n = build(buf, 0x07, 0x02, uid4, 4);
    feed_bytes(buf, n - 2);                      /* stop before XOR + ETX */
    rfid_idle();
    assert(rfid_frames_bad() == 1 && cb_calls == 0);
    feed_bytes(buf, n);
    assert(cb_calls == 1 && rfid_rx_bytes() == (uint32_t) (n - 2 + n));

    printf("rfid parser: all 20 scenarios passed\n");
    return 0;
}
