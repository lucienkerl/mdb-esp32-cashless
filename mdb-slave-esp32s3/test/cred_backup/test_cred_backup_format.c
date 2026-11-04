/* Host test for cred_backup_format.h. */
#include <stdio.h>
#include <stdlib.h>
#include "cred_backup_format.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

static size_t build_sample(uint8_t *buf, size_t cap) {
    cb_writer_t w;
    cb_writer_init(&w, buf, cap);
    cb_writer_add_str(&w, "company_id", "3f2a8c1e-0000-4000-8000-000000000001");
    cb_writer_add_str(&w, "device_id", "7b1d2e3f-0000-4000-8000-000000000002");
    cb_writer_add_str(&w, "passkey", "ABCDEFGHIJKLMNOPQR");
    uint8_t addr = 2;
    cb_writer_add(&w, CB_T_U8, "mdb_addr", &addr, 1);
    uint32_t port = 1883;
    cb_writer_add(&w, CB_T_U32, "mqtt_port", &port, 4);
    cb_writer_add_str(&w, "#wifi_ssid", "Machine WLAN");
    cb_writer_add_str(&w, "#wifi_pass", "");
    return cb_writer_finish(&w);
}

static void test_round_trip(void) {
    uint8_t buf[CB_MAX_SIZE];
    size_t len = build_sample(buf, sizeof(buf));
    CHECK(len > CB_HEADER_SIZE);

    size_t total = 0;
    CHECK(cb_image_valid(buf, sizeof(buf), &total));
    CHECK(total == len);

    cb_record_t r;
    CHECK(cb_image_find(buf, "passkey", &r));
    CHECK(r.type == CB_T_STR && r.val_len == 18 && memcmp(r.val, "ABCDEFGHIJKLMNOPQR", 18) == 0);
    CHECK(cb_image_find(buf, "mdb_addr", &r));
    CHECK(r.type == CB_T_U8 && r.val_len == 1 && r.val[0] == 2);
    CHECK(cb_image_find(buf, "mqtt_port", &r));
    CHECK(r.type == CB_T_U32 && r.val_len == 4 && cb_get_u32(r.val) == 1883);
    CHECK(cb_image_find(buf, "#wifi_pass", &r));
    CHECK(r.val_len == 0);
    CHECK(!cb_image_find(buf, "prov_code", &r));

    int n = 0;
    cb_reader_t rd;
    cb_reader_init(&rd, buf);
    while (cb_reader_next(&rd, &r)) n++;
    CHECK(n == 7);
}

static void test_erased_flash_is_invalid(void) {
    uint8_t buf[CB_MAX_SIZE];
    memset(buf, 0xFF, sizeof(buf));
    CHECK(!cb_image_valid(buf, sizeof(buf), NULL));
    memset(buf, 0x00, sizeof(buf));
    CHECK(!cb_image_valid(buf, sizeof(buf), NULL));
}

static void test_any_bit_flip_is_detected(void) {
    uint8_t buf[CB_MAX_SIZE];
    size_t len = build_sample(buf, sizeof(buf));
    for (size_t i = 0; i < len; i++) {
        if (i >= 5 && i < 8) continue;      /* reserved header bytes */
        if (i >= 10 && i < 12) continue;
        for (int b = 0; b < 8; b++) {
            buf[i] ^= (uint8_t)(1 << b);
            if (cb_image_valid(buf, sizeof(buf), NULL)) {
                printf("FAIL: flip at byte %zu bit %d not detected\n", i, b);
                failures++;
            }
            buf[i] ^= (uint8_t)(1 << b);
        }
    }
    CHECK(cb_image_valid(buf, sizeof(buf), NULL));
}

static void test_torn_write_is_invalid(void) {
    /* Power cut halfway through the write: the tail stays erased (0xFF). */
    uint8_t buf[CB_MAX_SIZE];
    size_t len = build_sample(buf, sizeof(buf));
    memset(buf + len / 2, 0xFF, sizeof(buf) - len / 2);
    CHECK(!cb_image_valid(buf, sizeof(buf), NULL));
}

static void test_overflow_produces_no_image(void) {
    uint8_t buf[64];
    cb_writer_t w;
    cb_writer_init(&w, buf, sizeof(buf));
    CHECK(cb_writer_add_str(&w, "a", "short"));
    CHECK(!cb_writer_add_str(&w, "b", "this value does not fit into the remaining space at all"));
    CHECK(w.overflow);
    CHECK(cb_writer_finish(&w) == 0);

    cb_writer_init(&w, buf, sizeof(buf));
    CHECK(!cb_writer_add_str(&w, "key_longer_than15", "x"));   /* NVS key limit */
    CHECK(cb_writer_finish(&w) == 0);
}

static void test_same_content_same_bytes(void) {
    /* The device only rewrites flash when the image changes. */
    uint8_t a[CB_MAX_SIZE], b[CB_MAX_SIZE];
    size_t la = build_sample(a, sizeof(a));
    size_t lb = build_sample(b, sizeof(b));
    CHECK(la == lb && memcmp(a, b, la) == 0);
}

static void test_crc_reference(void) {
    /* Standard CRC-32 check value. */
    CHECK(cb_crc32((const uint8_t *)"123456789", 9) == 0xCBF43926u);
}

int main(void) {
    test_crc_reference();
    test_round_trip();
    test_erased_flash_is_invalid();
    test_any_bit_flip_is_detected();
    test_torn_write_is_invalid();
    test_overflow_produces_no_image();
    test_same_content_same_bytes();
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("cred_backup_format: all tests passed\n");
    return 0;
}
