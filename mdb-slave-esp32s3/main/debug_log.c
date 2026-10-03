/*
 * debug_log.c — see debug_log.h.
 *
 * Why a raw partition instead of NVS (unlike sale_queue.c): NVS stores each
 * record as a separate key in 4KB pages with per-entry metadata, and
 * reclaiming space requires copying live entries out of a page before
 * erasing it. That's fine for sale_queue's few-hundred-slot queue, but at
 * ~800KB / tens of thousands of small records the page-relocation cost and
 * NVS's own bookkeeping overhead stop being worth it. A dedicated partition
 * written as a plain ring (fixed 16-byte records, erase-before-write only
 * at 4KB sector boundaries) is simpler and cheaper at this size. The two
 * position counters (write/ack) are still tiny and infrequent enough that
 * NVS remains the right place for *them* — same role as sale_queue's
 * K_HEAD/K_TAIL.
 */

#include "debug_log.h"

#include <string.h>
#include <math.h>
#include <time.h>
#include <esp_log.h>
#include <esp_partition.h>
#include <nvs_flash.h>
#include <nvs.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>

#define TAG "debug_log"

#define NS "dbg_log_q"
#define K_WRITE "write"   // u32: total records ever appended (monotonic, not wrapped)
#define K_ACK   "ack"     // u32: total records ever published+acked (monotonic, not wrapped)
#define K_OVERFLOW "overflow"

#define PARTITION_LABEL "dbglog"
#define RECORD_SIZE 16
#define SECTOR_SIZE 4096
#define RECORDS_PER_SECTOR (SECTOR_SIZE / RECORD_SIZE)

typedef struct __attribute__((packed)) {
    uint32_t timestamp;
    uint8_t  type;
    uint8_t  channel;
    uint8_t  value_u8;
    uint8_t  reserved;
    int32_t  value_i32;
    uint32_t reserved2;
} debug_record_t;

_Static_assert(sizeof(debug_record_t) == RECORD_SIZE, "debug_record_t must be exactly RECORD_SIZE bytes");

extern char my_company_id[40];
extern char my_device_id[40];
extern int mqtt_publish_safe(esp_mqtt_client_handle_t client, const char *topic,
                             const char *data, int len, int qos, int retain);
extern bool mqtt_started;

static const esp_partition_t *s_partition = NULL;
static uint32_t s_capacity = 0; // slots

static esp_mqtt_client_handle_t s_client = NULL;
static SemaphoreHandle_t s_lock = NULL;
static SemaphoreHandle_t s_wake = NULL;

static uint32_t s_write_count = 0;
static uint32_t s_ack_count = 0;
static uint32_t s_overflow = 0;
static int s_in_flight_msg_id = 0;
static bool s_ready = false;

static void load_u32(nvs_handle_t h, const char *key, uint32_t *out) {
    if (nvs_get_u32(h, key, out) != ESP_OK) *out = 0;
}

void debug_log_init(void) {
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_wake == NULL) s_wake = xSemaphoreCreateBinary();

    s_partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, 0x40, PARTITION_LABEL);
    if (!s_partition) {
        ESP_LOGE(TAG, "partition '%s' not found — debug log disabled", PARTITION_LABEL);
        return;
    }
    s_capacity = s_partition->size / RECORD_SIZE;

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open(%s) failed — debug log disabled", NS);
        return;
    }
    load_u32(h, K_WRITE, &s_write_count);
    load_u32(h, K_ACK, &s_ack_count);
    load_u32(h, K_OVERFLOW, &s_overflow);
    nvs_close(h);

    s_ready = true;
    ESP_LOGI(TAG, "ring restored: capacity=%u write=%u ack=%u overflow=%u",
             (unsigned)s_capacity, (unsigned)s_write_count, (unsigned)s_ack_count,
             (unsigned)s_overflow);
}

void debug_log_append(debug_log_type_t type, uint8_t channel, uint8_t value_u8, int32_t value_i32) {
    if (!s_ready) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);

    uint32_t slot = s_write_count % s_capacity;
    size_t offset = (size_t)slot * RECORD_SIZE;

    // Erase the 4KB sector before its first write this lap. Cheap: at
    // capacity=51200 (800KB / 16B) this fires once per 256 writes, so each
    // of the 200 sectors is erased roughly once per full ring lap.
    if (slot % RECORDS_PER_SECTOR == 0) {
        size_t sector_offset = offset - (offset % SECTOR_SIZE);
        esp_err_t err = esp_partition_erase_range(s_partition, sector_offset, SECTOR_SIZE);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "sector erase failed at 0x%x: %s", (unsigned)sector_offset, esp_err_to_name(err));
            xSemaphoreGive(s_lock);
            return;
        }
    }

    debug_record_t rec = {
        .timestamp = (uint32_t)time(NULL),
        .type = (uint8_t)type,
        .channel = channel,
        .value_u8 = value_u8,
        .reserved = 0,
        .value_i32 = value_i32,
        .reserved2 = 0,
    };

    esp_err_t err = esp_partition_write(s_partition, offset, &rec, RECORD_SIZE);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "write failed at slot %u: %s", (unsigned)slot, esp_err_to_name(err));
        xSemaphoreGive(s_lock);
        return;
    }

    s_write_count++;

    // If the ring has lapped past still-unacked entries, drop the oldest
    // ones that were just overwritten rather than let the drain task read
    // stale/overwritten data.
    if (s_write_count - s_ack_count > s_capacity) {
        uint32_t dropped = (s_write_count - s_ack_count) - s_capacity;
        s_ack_count += dropped;
        s_overflow += dropped;
    }

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u32(h, K_WRITE, s_write_count);
        nvs_set_u32(h, K_ACK, s_ack_count);
        if (s_overflow) nvs_set_u32(h, K_OVERFLOW, s_overflow);
        nvs_commit(h);
        nvs_close(h);
    }

    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_wake);
}

static bool load_record(uint32_t seq, debug_record_t *out) {
    uint32_t slot = seq % s_capacity;
    size_t offset = (size_t)slot * RECORD_SIZE;
    return esp_partition_read(s_partition, offset, out, RECORD_SIZE) == ESP_OK;
}

static const char *type_name(uint8_t type) {
    switch (type) {
        case DEBUG_LOG_RELAY:   return "relay";
        case DEBUG_LOG_INPUT:   return "input";
        case DEBUG_LOG_ONEWIRE: return "onewire";
        case DEBUG_LOG_NTC:     return "ntc";
        case DEBUG_LOG_PULSE:   return "pulse";
        default:                return "unknown";
    }
}

void debug_log_on_published(int msg_id) {
    if (msg_id == 0 || msg_id != s_in_flight_msg_id) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);

    s_ack_count++;
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u32(h, K_ACK, s_ack_count);
        nvs_commit(h);
        nvs_close(h);
    }
    s_in_flight_msg_id = 0;

    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_wake);
}

void debug_log_on_disconnect(void) {
    // No fast path to demote here (unlike sale_queue) — every append
    // already lands in the partition first, so a disconnect just means
    // the in-flight publish needs retrying, not rescuing from RAM.
    s_in_flight_msg_id = 0;
}

uint32_t debug_log_pending_count(void) {
    return s_write_count - s_ack_count;
}

uint32_t debug_log_overflow_count(void) {
    return s_overflow;
}

static void debug_log_drain_task(void *arg) {
    ESP_LOGI(TAG, "drain task started");
    for (;;) {
        xSemaphoreTake(s_wake, pdMS_TO_TICKS(5000));
        if (!s_ready || !mqtt_started) continue;

        xSemaphoreTake(s_lock, portMAX_DELAY);
        if (s_in_flight_msg_id != 0) {
            xSemaphoreGive(s_lock);
            continue;
        }
        if (s_ack_count >= s_write_count) {
            xSemaphoreGive(s_lock);
            continue;
        }

        debug_record_t rec;
        if (!load_record(s_ack_count, &rec)) {
            ESP_LOGW(TAG, "record %u unreadable — skipping", (unsigned)s_ack_count);
            s_ack_count++;
            xSemaphoreGive(s_lock);
            continue;
        }

        char topic[128];
        snprintf(topic, sizeof(topic), "/%s/%s/mdb-log", my_company_id, my_device_id);

        char msg[160];
        snprintf(msg, sizeof(msg),
            "{\"type\":\"%s\",\"ch\":%u,\"v\":%u,\"x\":%ld,\"ts\":%lu}",
            type_name(rec.type), rec.channel, rec.value_u8, (long)rec.value_i32,
            (unsigned long)rec.timestamp);

        int msg_id = mqtt_publish_safe(s_client, topic, msg, 0, 1, 0);
        if (msg_id > 0) {
            s_in_flight_msg_id = msg_id;
        } else {
            ESP_LOGW(TAG, "publish failed for record %u (msg_id=%d) — will retry",
                     (unsigned)s_ack_count, msg_id);
        }
        xSemaphoreGive(s_lock);
    }
}

void debug_log_start(esp_mqtt_client_handle_t client) {
    s_client = client;
    if (!s_ready) return;
    xTaskCreate(debug_log_drain_task, "dbglog_drain", 4096, NULL, 5, NULL);
    if (s_wake) xSemaphoreGive(s_wake);
}
