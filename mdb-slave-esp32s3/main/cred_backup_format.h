/*
 * cred_backup_format.h — on-flash format of the credentials backup
 * (see cred_backup.h). Pure byte logic with no ESP-IDF dependency, so the
 * host test in test/cred_backup/ compiles it directly.
 *
 * Layout (little endian):
 *
 *   offset 0  u32 magic        CB_MAGIC
 *   offset 4  u8  version      CB_VERSION
 *   offset 5  u8  reserved[3]
 *   offset 8  u16 payload_len
 *   offset 10 u16 reserved
 *   offset 12 u32 crc32        over the payload bytes
 *   offset 16 payload: records back to back
 *
 * Record:  u8 type | u8 key_len | key | u16 val_len | val
 *
 * Integers are stored as their native little-endian width (1/2/4/8 bytes),
 * strings without the terminating NUL. Keys starting with '#' are pseudo
 * keys that do not live in NVS (the WiFi STA credentials).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define CB_MAGIC        0x42434D56u   /* "VMCB" */
#define CB_VERSION      1
#define CB_HEADER_SIZE  16
#define CB_MAX_SIZE     4096          /* one flash sector */
#define CB_KEY_MAX      15            /* NVS key limit */

enum {
    CB_T_U8   = 1,
    CB_T_I8   = 2,
    CB_T_U16  = 3,
    CB_T_I16  = 4,
    CB_T_U32  = 5,
    CB_T_I32  = 6,
    CB_T_U64  = 7,
    CB_T_I64  = 8,
    CB_T_STR  = 9,
    CB_T_BLOB = 10,
};

typedef struct {
    uint8_t       *buf;
    size_t         cap;
    size_t         len;      /* bytes used, header included */
    bool           overflow;
} cb_writer_t;

typedef struct {
    uint8_t        type;
    char           key[CB_KEY_MAX + 1];
    const uint8_t *val;
    uint16_t       val_len;
} cb_record_t;

typedef struct {
    const uint8_t *p;
    const uint8_t *end;
} cb_reader_t;

static inline uint32_t cb_crc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1)));
        }
    }
    return ~crc;
}

static inline void cb_put_u16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static inline void cb_put_u32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = v >> 24;
}
static inline uint16_t cb_get_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t cb_get_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void cb_writer_init(cb_writer_t *w, uint8_t *buf, size_t cap) {
    w->buf = buf;
    w->cap = cap;
    w->len = CB_HEADER_SIZE;
    w->overflow = (cap < CB_HEADER_SIZE);
    if (!w->overflow) memset(buf, 0, CB_HEADER_SIZE);
}

/* Appends one record. Sets w->overflow (and writes nothing) when the key is
 * too long or the record does not fit. */
static inline bool cb_writer_add(cb_writer_t *w, uint8_t type, const char *key,
                                 const void *val, size_t val_len) {
    size_t klen = strlen(key);
    if (w->overflow || klen == 0 || klen > CB_KEY_MAX || val_len > 0xFFFF) {
        w->overflow = true;
        return false;
    }
    size_t need = 1 + 1 + klen + 2 + val_len;
    if (w->len + need > w->cap || w->len + need - CB_HEADER_SIZE > 0xFFFF) {
        w->overflow = true;
        return false;
    }
    uint8_t *p = w->buf + w->len;
    *p++ = type;
    *p++ = (uint8_t)klen;
    memcpy(p, key, klen);              p += klen;
    cb_put_u16(p, (uint16_t)val_len);  p += 2;
    if (val_len) memcpy(p, val, val_len);
    w->len += need;
    return true;
}

static inline bool cb_writer_add_str(cb_writer_t *w, const char *key, const char *s) {
    return cb_writer_add(w, CB_T_STR, key, s, strlen(s));
}

/* Writes the header. Returns the total image length, or 0 on overflow. */
static inline size_t cb_writer_finish(cb_writer_t *w) {
    if (w->overflow) return 0;
    uint16_t plen = (uint16_t)(w->len - CB_HEADER_SIZE);
    cb_put_u32(w->buf + 0, CB_MAGIC);
    w->buf[4] = CB_VERSION;
    cb_put_u16(w->buf + 8, plen);
    cb_put_u32(w->buf + 12, cb_crc32(w->buf + CB_HEADER_SIZE, plen));
    return w->len;
}

/* Validates an image read back from flash. An erased sector (all 0xFF), a
 * torn write or any bit flip fails here, so a bad backup is never restored. */
static inline bool cb_image_valid(const uint8_t *img, size_t img_len, size_t *total_len) {
    if (img_len < CB_HEADER_SIZE) return false;
    if (cb_get_u32(img) != CB_MAGIC || img[4] != CB_VERSION) return false;
    uint16_t plen = cb_get_u16(img + 8);
    if ((size_t)CB_HEADER_SIZE + plen > img_len) return false;
    if (cb_crc32(img + CB_HEADER_SIZE, plen) != cb_get_u32(img + 12)) return false;
    if (total_len) *total_len = CB_HEADER_SIZE + plen;
    return true;
}

/* Only call on an image that passed cb_image_valid. */
static inline void cb_reader_init(cb_reader_t *r, const uint8_t *img) {
    r->p = img + CB_HEADER_SIZE;
    r->end = r->p + cb_get_u16(img + 8);
}

/* Returns false at the end of the payload or on a malformed record. */
static inline bool cb_reader_next(cb_reader_t *r, cb_record_t *out) {
    if (r->end - r->p < 4) return false;
    uint8_t type = r->p[0];
    uint8_t klen = r->p[1];
    if (klen == 0 || klen > CB_KEY_MAX || r->end - r->p < 2 + klen + 2) return false;
    uint16_t vlen = cb_get_u16(r->p + 2 + klen);
    if (r->end - r->p < 2 + klen + 2 + vlen) return false;
    out->type = type;
    memcpy(out->key, r->p + 2, klen);
    out->key[klen] = '\0';
    out->val = r->p + 2 + klen + 2;
    out->val_len = vlen;
    r->p += 2 + klen + 2 + vlen;
    return true;
}

/* Looks up one record by key. */
static inline bool cb_image_find(const uint8_t *img, const char *key, cb_record_t *out) {
    cb_reader_t r;
    cb_reader_init(&r, img);
    while (cb_reader_next(&r, out)) {
        if (strcmp(out->key, key) == 0) return true;
    }
    return false;
}
