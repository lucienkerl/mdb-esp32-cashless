/*
 * rfid_reader.c — serial RFID card reader (F02DC and compatibles)
 *
 * See rfid_reader.h for the wiring rationale and the frame layout.
 */

#include "rfid_reader.h"

#include <string.h>

#include <sdkconfig.h>
#include <driver/gpio.h>
#include <driver/uart.h>
#include <esp_log.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#define TAG "rfid"

#if CONFIG_RFID_READER_ENABLE

/* A UART shared with the console would eat the log output and vice versa.
 * The default config runs the console over USB-Serial-JTAG (see sdkconfig:
 * CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y, CONFIG_ESP_CONSOLE_UART_NUM=-1),
 * which leaves UART0 free — but a menuconfig change could break that
 * silently, so catch it at compile time instead. */
#if defined(CONFIG_ESP_CONSOLE_UART_NUM) && (CONFIG_RFID_UART_PORT == CONFIG_ESP_CONSOLE_UART_NUM)
#error "RFID reader UART collides with the console UART — pick another port in menuconfig"
#endif

#define RFID_STX            0x02
#define RFID_ETX            0x03

/* STX + LEN + TYPE + data + XOR + ETX, minus the STX we never buffer. */
#define RFID_FRAME_MAX      (RFID_UID_MAX_BYTES + 8)
#define RFID_RX_BUF_BYTES   512
#define RFID_READ_CHUNK     32
/* An idle line this long means the frame in flight will never complete. */
#define RFID_IDLE_MS        100

static rfid_card_cb_t   s_cb;
static void            *s_ctx;
static bool             s_running;

static uint8_t          s_frame[RFID_FRAME_MAX];
static size_t           s_frame_len;
static bool             s_collecting;

static char             s_last_uid[RFID_UID_HEX_LEN];
static int64_t          s_last_uid_us;

static uint32_t         s_frames_ok;
static uint32_t         s_frames_bad;
static uint32_t         s_cards_reported;
static uint32_t         s_cards_deduped;

static void rfid_hex(const uint8_t *src, size_t len, char *dst) {
    static const char digits[] = "0123456789ABCDEF";
    for (size_t i = 0; i < len; i++) {
        dst[i * 2]     = digits[src[i] >> 4];
        dst[i * 2 + 1] = digits[src[i] & 0x0F];
    }
    dst[len * 2] = '\0';
}

/* One card presentation → at most one callback. See the dedup note in the
 * header: the window slides while the card stays on the antenna, so the
 * next report needs the card to be taken away for CONFIG_RFID_DEDUP_MS. */
static void rfid_dispatch(const rfid_card_t *card) {

    int64_t now = esp_timer_get_time();

    if (s_last_uid[0] &&
        strcmp(s_last_uid, card->uid_hex) == 0 &&
        (now - s_last_uid_us) < ((int64_t) CONFIG_RFID_DEDUP_MS * 1000)) {
        s_last_uid_us = now;
        s_cards_deduped++;
        return;
    }

    memcpy(s_last_uid, card->uid_hex, sizeof(s_last_uid));
    s_last_uid_us = now;
    s_cards_reported++;

    ESP_LOGI(TAG, "card presented: type=0x%02X uid=%s (%u bytes)",
             card->card_type, card->uid_hex, card->uid_len);

    if (s_cb) s_cb(card, s_ctx);
}

/*
 * Try to close the frame at the ETX candidate sitting in s_frame[len-1].
 * Layout of s_frame (STX already consumed):
 *   [0] LEN  [1] TYPE  [2 .. len-3] DATA  [len-2] XOR  [len-1] ETX
 * Returns true when the XOR checks out and the card was handed on.
 */
static bool rfid_try_complete(void) {

    size_t len = s_frame_len;
    if (len < 5) return false;                  /* LEN+TYPE+≥1 data+XOR+ETX */

    size_t uid_len = len - 4;
    if (uid_len > RFID_UID_MAX_BYTES) return false;

    /* XOR covers LEN, TYPE and every card-data byte — indices 0..len-3. */
    uint8_t chk = 0x00;
    for (size_t i = 0; i + 2 < len; i++) chk ^= s_frame[i];

    if (chk != s_frame[len - 2]) return false;  /* not a frame end after all */

    rfid_card_t card = {
        .card_type = s_frame[1],
        .uid_len   = (uint8_t) uid_len,
    };
    memcpy(card.uid, &s_frame[2], uid_len);
    rfid_hex(card.uid, uid_len, card.uid_hex);

    s_frames_ok++;
    rfid_dispatch(&card);
    return true;
}

/* Drop the partial frame in flight and wait for the next STX. */
static void rfid_reset_frame(void) {
    s_collecting = false;
    s_frame_len  = 0;
}

static void rfid_feed(uint8_t b) {

    if (!s_collecting) {
        if (b == RFID_STX) {
            s_collecting = true;
            s_frame_len  = 0;
        }
        return;
    }

    if (s_frame_len >= sizeof(s_frame)) {
        /* Never found a valid frame end — drop and resynchronise on the
         * next STX, which may well be the byte we are holding. A byte lost
         * mid-burst lands here: 0x02 is legal card data, so a partial frame
         * cannot be cut short on sight, and the buffer cap is what bounds
         * the damage to the couple of frames it takes to fill it. */
        s_frames_bad++;
        rfid_reset_frame();
        if (b == RFID_STX) {
            s_collecting = true;
            s_frame_len  = 0;
        }
        return;
    }

    s_frame[s_frame_len++] = b;

    /* A 0x03 inside the card data fails the XOR check, so keep collecting
     * until the checksum agrees with us about where the frame ends. */
    if (b == RFID_ETX && rfid_try_complete()) {
        rfid_reset_frame();
    }
}

static void rfid_reader_task(void *arg) {

    (void) arg;

    uint8_t buf[RFID_READ_CHUNK];

    for (;;) {
        int n = uart_read_bytes(CONFIG_RFID_UART_PORT, buf, sizeof(buf),
                                pdMS_TO_TICKS(RFID_IDLE_MS));
        if (n > 0) {
            for (int i = 0; i < n; i++) rfid_feed(buf[i]);
            continue;
        }

        /* Line went idle mid-frame: the rest is never coming. */
        if (s_collecting) {
            s_frames_bad++;
            rfid_reset_frame();
        }
    }
}

bool rfid_reader_start(rfid_card_cb_t cb, void *ctx) {

    if (s_running) return true;

    s_cb  = cb;
    s_ctx = ctx;

    const uart_config_t uart_cfg = {
        .baud_rate  = CONFIG_RFID_BAUD,
        .data_bits  = UART_DATA_8_BITS,
        .parity     = UART_PARITY_DISABLE,
        .stop_bits  = UART_STOP_BITS_1,
        .flow_ctrl  = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    esp_err_t err = uart_param_config(CONFIG_RFID_UART_PORT, &uart_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "uart_param_config failed: %s", esp_err_to_name(err));
        return false;
    }

    /* RX only — the reader is a one-way talker. TX stays on whatever pad
     * the port defaults to; nothing ever writes to it. */
    err = uart_set_pin(CONFIG_RFID_UART_PORT, UART_PIN_NO_CHANGE, CONFIG_RFID_RX_GPIO,
                       UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "uart_set_pin(rx=%d) failed: %s", CONFIG_RFID_RX_GPIO, esp_err_to_name(err));
        return false;
    }

    err = uart_driver_install(CONFIG_RFID_UART_PORT, RFID_RX_BUF_BYTES, 0, 0, NULL, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "uart_driver_install failed: %s", esp_err_to_name(err));
        return false;
    }

    /* An unconnected input floats and spews framing errors; idle-high is
     * also what a TTL serial line looks like between frames. */
    gpio_set_pull_mode(CONFIG_RFID_RX_GPIO, GPIO_PULLUP_ONLY);

#if CONFIG_RFID_INVERT_RX
    /* For installations where the pulse input passes through an inverting
     * buffer or optocoupler — a config change, not a hardware change. */
    uart_set_line_inverse(CONFIG_RFID_UART_PORT, UART_SIGNAL_RXD_INV);
#endif

    if (xTaskCreate(rfid_reader_task, "rfid_reader", 4096, NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "task creation failed");
        uart_driver_delete(CONFIG_RFID_UART_PORT);
        return false;
    }

    s_running = true;
    ESP_LOGW(TAG, "RFID reader started: uart%d rx=GPIO%d %d baud, dedup=%dms",
             CONFIG_RFID_UART_PORT, CONFIG_RFID_RX_GPIO, CONFIG_RFID_BAUD, CONFIG_RFID_DEDUP_MS);
    return true;
}

void rfid_reader_reset_dedup(void) {
    s_last_uid[0] = '\0';
    s_last_uid_us = 0;
}

bool     rfid_reader_is_running(void) { return s_running; }
uint32_t rfid_frames_ok(void)         { return s_frames_ok; }
uint32_t rfid_frames_bad(void)        { return s_frames_bad; }
uint32_t rfid_cards_reported(void)    { return s_cards_reported; }
uint32_t rfid_cards_deduped(void)     { return s_cards_deduped; }

#else  /* !CONFIG_RFID_READER_ENABLE */

bool rfid_reader_start(rfid_card_cb_t cb, void *ctx) {
    (void) cb; (void) ctx;
    ESP_LOGI(TAG, "RFID reader disabled in menuconfig");
    return false;
}

void     rfid_reader_reset_dedup(void) {}
bool     rfid_reader_is_running(void) { return false; }
uint32_t rfid_frames_ok(void)         { return 0; }
uint32_t rfid_frames_bad(void)        { return 0; }
uint32_t rfid_cards_reported(void)    { return 0; }
uint32_t rfid_cards_deduped(void)     { return 0; }

#endif /* CONFIG_RFID_READER_ENABLE */
