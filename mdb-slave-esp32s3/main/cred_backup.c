/*
 * cred_backup.c — see cred_backup.h.
 */

#include "cred_backup.h"
#include "cred_backup_format.h"

#include <stdlib.h>
#include <string.h>
#include <esp_log.h>
#include <esp_partition.h>
#include <esp_wifi.h>
#include <nvs.h>
#include <nvs_flash.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include "sdkconfig.h"

#if CONFIG_ESP_PHY_INIT_DATA_IN_PARTITION
#error "cred_backup stores its image in the phy_init partition, which PHY_INIT_DATA_IN_PARTITION would then use. Move the backup elsewhere before enabling it."
#endif

#define TAG "cred_backup"
#define NS  "vmflow"

#define KEY_WIFI_SSID "#wifi_ssid"
#define KEY_WIFI_PASS "#wifi_pass"

#define MAX_KEYS      64
#define MAX_VALUE_LEN 512

/* Keys that describe one boot or one claim attempt, not the device's
 * identity. Restoring them would replay a stale restart reason or re-run a
 * claim with a code that was already used. */
static const char *const k_skip_keys[] = {
    "prov_code", "restart_reason", "last_uptime",
};

static const esp_partition_t *s_part = NULL;
static uint8_t *s_img = NULL;        /* valid image as stored, or NULL */
static size_t   s_img_len = 0;
static volatile bool s_sync_running = false;

static bool skip_key(const char *key) {
    for (size_t i = 0; i < sizeof(k_skip_keys) / sizeof(k_skip_keys[0]); i++) {
        if (strcmp(key, k_skip_keys[i]) == 0) return true;
    }
    return false;
}

static bool image_has_identity(const uint8_t *img) {
    cb_record_t r;
    static const char *const ids[] = { "company_id", "device_id", "passkey" };
    for (size_t i = 0; i < 3; i++) {
        if (!cb_image_find(img, ids[i], &r) || r.type != CB_T_STR || r.val_len == 0) return false;
    }
    return true;
}

static void cache_image(const uint8_t *img, size_t len) {
    free(s_img);
    s_img = NULL;
    s_img_len = 0;
    if (!img || len == 0) return;
    s_img = malloc(len);
    if (!s_img) return;
    memcpy(s_img, img, len);
    s_img_len = len;
}

void cred_backup_init(void) {
    s_part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_PHY, NULL);
    if (!s_part) {
        ESP_LOGE(TAG, "no phy_init partition — credentials backup disabled");
        return;
    }
    if (s_part->size < CB_MAX_SIZE) {
        ESP_LOGE(TAG, "phy_init partition too small (%u bytes) — backup disabled", (unsigned)s_part->size);
        s_part = NULL;
        return;
    }

    uint8_t *buf = malloc(CB_MAX_SIZE);
    if (!buf) return;
    size_t len = 0;
    if (esp_partition_read(s_part, 0, buf, CB_MAX_SIZE) == ESP_OK &&
        cb_image_valid(buf, CB_MAX_SIZE, &len)) {
        cache_image(buf, len);
        ESP_LOGI(TAG, "backup present (%u bytes, %s)", (unsigned)len,
                 image_has_identity(buf) ? "claimed device" : "no identity");
    } else {
        ESP_LOGI(TAG, "no valid backup stored yet");
    }
    free(buf);
}

bool cred_backup_available(void) {
    return s_img && image_has_identity(s_img);
}

int cred_backup_restore_nvs(void) {
    if (!cred_backup_available()) return 0;

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGE(TAG, "restore: nvs_open failed");
        return 0;
    }

    int restored = 0;
    cb_reader_t rd;
    cb_record_t r;
    cb_reader_init(&rd, s_img);
    while (cb_reader_next(&rd, &r)) {
        if (r.key[0] == '#' || skip_key(r.key)) continue;

        nvs_type_t existing;
        if (nvs_find_key(h, r.key, &existing) == ESP_OK) continue;   /* never overwrite */

        esp_err_t err = ESP_ERR_INVALID_ARG;
        uint64_t v = 0;
        if (r.type >= CB_T_U8 && r.type <= CB_T_I64) {
            if (r.val_len > sizeof(v)) continue;
            memcpy(&v, r.val, r.val_len);   /* little endian on both sides */
        }
        switch (r.type) {
        case CB_T_U8:  err = nvs_set_u8 (h, r.key, (uint8_t)v);  break;
        case CB_T_I8:  err = nvs_set_i8 (h, r.key, (int8_t)v);   break;
        case CB_T_U16: err = nvs_set_u16(h, r.key, (uint16_t)v); break;
        case CB_T_I16: err = nvs_set_i16(h, r.key, (int16_t)v);  break;
        case CB_T_U32: err = nvs_set_u32(h, r.key, (uint32_t)v); break;
        case CB_T_I32: err = nvs_set_i32(h, r.key, (int32_t)v);  break;
        case CB_T_U64: err = nvs_set_u64(h, r.key, v);           break;
        case CB_T_I64: err = nvs_set_i64(h, r.key, (int64_t)v);  break;
        case CB_T_STR: {
            char *s = malloc(r.val_len + 1);
            if (!s) break;
            memcpy(s, r.val, r.val_len);
            s[r.val_len] = '\0';
            err = nvs_set_str(h, r.key, s);
            free(s);
            break;
        }
        case CB_T_BLOB: err = nvs_set_blob(h, r.key, r.val, r.val_len); break;
        default: break;
        }
        if (err == ESP_OK) {
            restored++;
            ESP_LOGW(TAG, "restored NVS key \"%s\"", r.key);
        } else {
            ESP_LOGE(TAG, "restore of \"%s\" failed: %s", r.key, esp_err_to_name(err));
        }
    }
    if (restored) nvs_commit(h);
    nvs_close(h);
    return restored;
}

bool cred_backup_restore_wifi_if_empty(void) {
    if (!cred_backup_available()) return false;

    wifi_config_t cfg = {0};
    if (esp_wifi_get_config(WIFI_IF_STA, &cfg) != ESP_OK) return false;
    if (cfg.sta.ssid[0] != '\0') return false;

    cb_record_t ssid, pass;
    if (!cb_image_find(s_img, KEY_WIFI_SSID, &ssid) || ssid.val_len == 0 ||
        ssid.val_len > sizeof(cfg.sta.ssid)) {
        return false;
    }
    memcpy(cfg.sta.ssid, ssid.val, ssid.val_len);
    if (cb_image_find(s_img, KEY_WIFI_PASS, &pass) && pass.val_len < sizeof(cfg.sta.password)) {
        memcpy(cfg.sta.password, pass.val, pass.val_len);
    }
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &cfg);
    ESP_LOGW(TAG, "WiFi STA config was empty — restored SSID from backup (%s)", esp_err_to_name(err));
    return err == ESP_OK;
}

/* ---- snapshot ---- */

typedef struct {
    char       key[NVS_KEY_NAME_MAX_SIZE];
    nvs_type_t type;
} key_entry_t;

static int key_cmp(const void *a, const void *b) {
    return strcmp(((const key_entry_t *)a)->key, ((const key_entry_t *)b)->key);
}

/* Builds the image for the current state into buf. Returns its length, or
 * 0 when the device is not claimed or the snapshot failed. */
static size_t build_image(uint8_t *buf, size_t cap) {
    key_entry_t *keys = calloc(MAX_KEYS, sizeof(key_entry_t));
    uint8_t *val = malloc(MAX_VALUE_LEN);
    if (!keys || !val) { free(keys); free(val); return 0; }

    /* Collect, then sort by key, so the image is byte-identical as long as
     * the content is — NVS iteration order follows the flash layout and
     * moves around on every page compaction. */
    int n = 0;
    nvs_iterator_t it = NULL;
    esp_err_t res = nvs_entry_find(NVS_DEFAULT_PART_NAME, NS, NVS_TYPE_ANY, &it);
    while (res == ESP_OK && n < MAX_KEYS) {
        nvs_entry_info_t info;
        nvs_entry_info(it, &info);
        if (!skip_key(info.key)) {
            strncpy(keys[n].key, info.key, sizeof(keys[n].key) - 1);
            keys[n].type = info.type;
            n++;
        }
        res = nvs_entry_next(&it);
    }
    nvs_release_iterator(it);
    qsort(keys, n, sizeof(key_entry_t), key_cmp);

    cb_writer_t w;
    cb_writer_init(&w, buf, cap);

    nvs_handle_t h;
    bool opened = (n > 0 && nvs_open(NS, NVS_READONLY, &h) == ESP_OK);
    for (int i = 0; opened && i < n; i++) {
        const char *k = keys[i].key;
        size_t len = MAX_VALUE_LEN;
        esp_err_t err = ESP_FAIL;
        uint8_t t = 0;
        size_t vlen = 0;
        switch (keys[i].type) {
        case NVS_TYPE_U8:  t = CB_T_U8;  vlen = 1; err = nvs_get_u8 (h, k, (uint8_t *)val);  break;
        case NVS_TYPE_I8:  t = CB_T_I8;  vlen = 1; err = nvs_get_i8 (h, k, (int8_t *)val);   break;
        case NVS_TYPE_U16: t = CB_T_U16; vlen = 2; err = nvs_get_u16(h, k, (uint16_t *)val); break;
        case NVS_TYPE_I16: t = CB_T_I16; vlen = 2; err = nvs_get_i16(h, k, (int16_t *)val);  break;
        case NVS_TYPE_U32: t = CB_T_U32; vlen = 4; err = nvs_get_u32(h, k, (uint32_t *)val); break;
        case NVS_TYPE_I32: t = CB_T_I32; vlen = 4; err = nvs_get_i32(h, k, (int32_t *)val);  break;
        case NVS_TYPE_U64: t = CB_T_U64; vlen = 8; err = nvs_get_u64(h, k, (uint64_t *)val); break;
        case NVS_TYPE_I64: t = CB_T_I64; vlen = 8; err = nvs_get_i64(h, k, (int64_t *)val);  break;
        case NVS_TYPE_STR:
            t = CB_T_STR;
            err = nvs_get_str(h, k, (char *)val, &len);
            vlen = (err == ESP_OK) ? strlen((char *)val) : 0;
            break;
        case NVS_TYPE_BLOB:
            t = CB_T_BLOB;
            err = nvs_get_blob(h, k, val, &len);
            vlen = len;
            break;
        default:
            break;
        }
        if (err == ESP_OK) cb_writer_add(&w, t, k, val, vlen);
        else ESP_LOGW(TAG, "snapshot: skipping \"%s\" (%s)", k, esp_err_to_name(err));
    }
    if (opened) nvs_close(h);
    free(keys);
    free(val);

    wifi_config_t cfg = {0};
    if (esp_wifi_get_config(WIFI_IF_STA, &cfg) == ESP_OK && cfg.sta.ssid[0] != '\0') {
        cb_writer_add(&w, CB_T_STR, KEY_WIFI_SSID, cfg.sta.ssid,
                      strnlen((char *)cfg.sta.ssid, sizeof(cfg.sta.ssid)));
        cb_writer_add(&w, CB_T_STR, KEY_WIFI_PASS, cfg.sta.password,
                      strnlen((char *)cfg.sta.password, sizeof(cfg.sta.password)));
    }

    size_t total = cb_writer_finish(&w);
    if (total == 0) {
        ESP_LOGE(TAG, "snapshot does not fit into %u bytes — backup not updated", (unsigned)cap);
        return 0;
    }
    if (!image_has_identity(buf)) return 0;   /* nothing worth protecting yet */
    return total;
}

static void sync_task(void *arg) {
    (void)arg;
    uint8_t *img = malloc(CB_MAX_SIZE);
    size_t len = img ? build_image(img, CB_MAX_SIZE) : 0;

    if (len > 0 && s_img && s_img_len == len && memcmp(s_img, img, len) == 0) {
        ESP_LOGD(TAG, "backup up to date");
    } else if (len > 0) {
        /* Pad to a 4-byte multiple with the erased-flash value. */
        size_t wlen = (len + 3) & ~(size_t)3;
        memset(img + len, 0xFF, wlen - len);
        esp_err_t err = esp_partition_erase_range(s_part, 0, CB_MAX_SIZE);
        if (err == ESP_OK) err = esp_partition_write(s_part, 0, img, wlen);
        if (err == ESP_OK) {
            cache_image(img, len);
            ESP_LOGI(TAG, "backup updated (%u bytes)", (unsigned)len);
        } else {
            ESP_LOGE(TAG, "backup write failed: %s", esp_err_to_name(err));
            cache_image(NULL, 0);
        }
    }
    free(img);
    s_sync_running = false;
    vTaskDelete(NULL);
}

void cred_backup_sync_async(void) {
    if (!s_part || s_sync_running) return;
    s_sync_running = true;
    if (xTaskCreate(sync_task, "cred_bkp", 4096, NULL, 3, NULL) != pdPASS) {
        s_sync_running = false;
    }
}

void cred_backup_erase(void) {
    if (!s_part) {
        /* Factory reset may run before init on an odd path; look it up. */
        s_part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_PHY, NULL);
        if (!s_part) return;
    }
    esp_err_t err = esp_partition_erase_range(s_part, 0, CB_MAX_SIZE);
    ESP_LOGW(TAG, "backup erased (%s)", esp_err_to_name(err));
    cache_image(NULL, 0);
}
