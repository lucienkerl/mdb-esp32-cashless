/*
 * rfid_reader.h — serial RFID card reader (F02DC and compatibles)
 *
 * The F02DC is wired to the board's *pulse input* (PIN_PULSE_1 / GPIO 13).
 * No hardware change is needed: the pin is routed through the GPIO matrix
 * to a spare UART receiver, so the reader's TX line is simply read as
 * 9600 8N1 serial data.
 *
 * UART allocation on this board:
 *   UART0 — free (the console runs over USB-Serial-JTAG, see sdkconfig)
 *   UART1 — DEX / EVA-DTS telemetry
 *   UART2 — SIM7080G modem
 * so the reader takes UART0 by default (overridable in menuconfig).
 *
 * Frame format (hex), per the reader's datasheet:
 *
 *   0x02 | LEN | TYPE | CARD DATA … | XOR | 0x03
 *
 *   LEN   frame length byte
 *   TYPE  card type
 *   DATA  card serial number, MSB first
 *   XOR   XOR of LEN, TYPE and every CARD DATA byte
 *
 * The parser is delimiter-driven and validated by the XOR byte rather than
 * trusting LEN, because vendors disagree on what LEN counts (whole frame,
 * payload only, payload+checksum). A 0x03 that happens to occur inside the
 * card data simply fails the XOR check and parsing continues to the real
 * frame end.
 *
 * Duplicate suppression: these readers re-send the same serial for as long
 * as the card sits on the antenna (typically every 100-500 ms). Only the
 * first sighting is handed to the callback; further sightings of the same
 * serial refresh a sliding window (CONFIG_RFID_DEDUP_MS) and are dropped,
 * so one card presentation produces exactly one backend request no matter
 * how long the card is held there.
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>

/* 16 bytes covers every UID length in the wild (4/5/7/10) with headroom. */
#define RFID_UID_MAX_BYTES  16
#define RFID_UID_HEX_LEN    (RFID_UID_MAX_BYTES * 2 + 1)

typedef struct {
    uint8_t card_type;                 /* TYPE byte, verbatim               */
    uint8_t uid_len;                   /* number of card-data bytes         */
    uint8_t uid[RFID_UID_MAX_BYTES];   /* card serial, MSB first            */
    char    uid_hex[RFID_UID_HEX_LEN]; /* uppercase hex, NUL-terminated     */
} rfid_card_t;

/*
 * Called from the reader task once per card presentation (never once per
 * frame — duplicates are filtered first). The callback runs on the reader
 * task, so it may block on network I/O; incoming frames are dropped while
 * it does, which is harmless because they would be duplicates anyway.
 */
typedef void (*rfid_card_cb_t)(const rfid_card_t *card, void *ctx);

/*
 * Configure the UART and spawn the reader task. Returns false if the
 * feature is disabled in menuconfig or the UART could not be claimed.
 * Safe to call once from app_main; further calls are no-ops.
 */
bool rfid_reader_start(rfid_card_cb_t cb, void *ctx);

/*
 * Forget the last-seen serial so the very next frame is treated as a fresh
 * presentation. Called when a card could not be reported (e.g. the broker
 * was offline) so the customer can simply present the card again instead
 * of waiting out the dedup window.
 */
void rfid_reader_reset_dedup(void);

/* Diagnostics counters, surfaced in the MDB diagnostics MQTT payload. */
bool     rfid_reader_is_running(void);
uint32_t rfid_frames_ok(void);
uint32_t rfid_frames_bad(void);
uint32_t rfid_cards_reported(void);
uint32_t rfid_cards_deduped(void);
