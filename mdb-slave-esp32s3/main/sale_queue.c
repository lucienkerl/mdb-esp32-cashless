/*
 * sale_queue.c — NVS-backed persistent sales queue (see sale_queue.h).
 */

#include "sale_queue.h"

#include <string.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include <nvs_flash.h>
#include <nvs.h>
#include <time.h>

#define TAG "sale_queue"

// NVS namespace — separate from "vmflow" so a device-config wipe can be
// performed without discarding pending sales.
#define NS "sale_q"

// Metadata keys
#define K_HEAD      "head"      // u32: next slot to publish
#define K_TAIL      "tail"      // u32: next slot to write
#define K_OVERFLOW  "overflow"  // u32: count of dropped sales
#define K_LAST_SEQ  "last_seq"  // u32: highest sale_seq that has been RESERVED in NVS

// Per-slot key prefix. Keys are "s" + decimal index (max "s511" = 4 chars +
// NUL = 5 chars, well under the 15-char NVS limit).
#define SLOT_KEY_FMT "s%u"

// Chunk size for sale_seq reservations. We commit a new high-water mark to
// NVS every this many sales, and serve allocations from RAM in between. A
// reboot may waste up to (chunk - 1) sale_seqs as gaps in the sequence,
// which is harmless — the backend UNIQUE index does not require contiguity.
//
// Trade-off:
//   smaller chunk → more NVS commits (less flash savings)
//   larger chunk  → bigger gaps after reboots (cosmetic only)
#define SALE_SEQ_RESERVATION_CHUNK 100

// Device identity — filled from globals during publish; we do not store
// them in the queue records because they're constants per device and
// change only on re-provisioning (queue assumed empty then).
extern char my_company_id[40];
extern char my_device_id[40];
extern char my_passkey[18];

extern void xorEncodeWithPasskey(uint8_t cmd, uint16_t itemPrice,
                                 uint16_t itemNumber, uint16_t paxCounter,
                                 uint8_t *payload);
extern int mqtt_publish_safe(esp_mqtt_client_handle_t client, const char *topic,
                             const char *data, int len, int qos, int retain);
extern bool mqtt_started;

static esp_mqtt_client_handle_t s_client = NULL;
static SemaphoreHandle_t s_lock = NULL;   // protects head/tail/last_seq/in_flight
static SemaphoreHandle_t s_wake = NULL;   // drain task wakeup

static uint32_t s_head = 0;
static uint32_t s_tail = 0;
static uint32_t s_overflow = 0;
// Highest sale_seq already reserved (= persisted) in NVS. After boot this
// is taken as the conservative estimate of "highest possibly assigned",
// so next alloc always starts > any pre-reboot assignment.
static uint32_t s_seq_reserved_to = 0;
// Highest sale_seq handed out by alloc_seq so far in this boot. Increments
// in RAM for each enqueue and is flushed to NVS lazily in chunks.
static uint32_t s_last_seq = 0;
// Count of fast-path direct publishes since boot, surfaced via diagnostics
// so operators can confirm the flash-sparing optimisation is active.
static uint32_t s_fast_path_count = 0;

// msg_id of the sale currently in flight to the broker via the SLOW path
// (0 = none). Cleared on slow-path PUBACK or on MQTT disconnect.
static int s_in_flight_msg_id = 0;

// In-flight tracking for FAST-path publishes.
//
// Fast-path publish is fire-and-forget from the *caller's* perspective, but
// we keep a small RAM-only record of each (msg_id, sale_record_t) pair until
// PUBACK arrives. This gives us two essential safety properties:
//
//   1. PUBACK identification: when MQTT_EVENT_PUBLISHED fires we can
//      distinguish fast-path acks (clear the entry) from slow-path acks
//      (advance the NVS head pointer).
//
//   2. Disconnect recovery: when MQTT_EVENT_DISCONNECTED fires we DEMOTE
//      every still-tracked entry into the NVS slow-path queue. This way
//      a reconnect (or even the watchdog hard-reboot at 10min offline)
//      cannot lose a fast-path sale that was in flight at the moment of
//      the network drop. The drain task will republish from NVS after
//      reconnect; backend idempotency on (embedded_id, sale_seq) absorbs
//      any duplicates that the broker had actually received.
//
// 16 slots is well above realistic in-flight count (typically 0-2): each
// publish gets PUBACK in milliseconds when the network is healthy. If the
// array fills up that's a strong signal of network trouble — we then fall
// back to the slow path for new sales until things recover.
#define FAST_PATH_TRACK_MAX 16

typedef struct {
    sale_record_t rec;
    int           msg_id;  // 0 = slot empty
} fast_path_slot_t;

static fast_path_slot_t s_fast_tracked[FAST_PATH_TRACK_MAX];

static void load_u32(nvs_handle_t h, const char *key, uint32_t *out) {
    if (nvs_get_u32(h, key, out) != ESP_OK) *out = 0;
}

void sale_queue_init(void) {
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_wake == NULL) s_wake = xSemaphoreCreateBinary();

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) {
        ESP_LOGE(TAG, "nvs_open(%s) failed — queue will be in-memory only", NS);
        return;
    }
    load_u32(h, K_HEAD,     &s_head);
    load_u32(h, K_TAIL,     &s_tail);
    load_u32(h, K_OVERFLOW, &s_overflow);
    load_u32(h, K_LAST_SEQ, &s_seq_reserved_to);
    nvs_close(h);

    // Conservative: assume every reserved seq might have been assigned in the
    // previous boot (fast path does not persist the running counter). The first
    // alloc_seq() therefore triggers a new reservation, guaranteeing no
    // pre-reboot seq is reused — at the cost of up to (chunk - 1) wasted
    // numbers per reboot.
    s_last_seq = s_seq_reserved_to;

    uint32_t pending = s_tail - s_head;
    ESP_LOGI(TAG, "queue restored: head=%u tail=%u pending=%u overflow=%u reserved_to=%u",
             (unsigned)s_head, (unsigned)s_tail, (unsigned)pending,
             (unsigned)s_overflow, (unsigned)s_seq_reserved_to);
}

// Forward declaration — the definition lives further down alongside the
// drain task so the fast path in sale_queue_enqueue can call it.
static void build_v2_payload(const sale_record_t *rec, uint8_t *payload);

// True when the device has a usable wall clock, i.e. the vend timestamp we
// stamp into the payload is real calendar time rather than seconds-since-boot.
//
// Deliberately NOT sntp_get_sync_status(): that status is one-shot. ESP-IDF
// returns SNTP_SYNC_STATUS_COMPLETED exactly once per successful sync and
// resets itself to SNTP_SYNC_STATUS_RESET in the same call
// (esp-idf/components/lwip/apps/sntp/sntp.c). With the configured
// CONFIG_LWIP_SNTP_UPDATE_DELAY of one hour, and this being the only caller
// in the firmware, polling it per sale reported "synced" for at most ONE sale
// per hour and "unsynced" for every other sale -- on a device whose clock had
// been correct for weeks. Every one of those sales was published with
// occurred_at=0 + time_uncertain=1, which (a) replaced the real vend time with
// the server receive time and (b) fed each sale into the backend's
// time_uncertain-gated brownout duplicate suppression.
//
// The wall clock itself is the durable signal: once any source has set a
// plausible time it stays plausible, and it survives a soft restart via the
// RTC. A device that has genuinely lost its clock -- a power cut or a
// brownout, which is exactly the condition the backend's duplicate
// suppression is meant to detect -- comes back with seconds-since-boot and
// falls below the threshold.
#define CLOCK_PLAUSIBLE_AFTER 1672531200  // 2023-01-01T00:00:00Z

static bool clock_is_usable(void) {
    return time(NULL) >= (time_t)CLOCK_PLAUSIBLE_AFTER;
}

// Caller must hold s_lock. Allocates a fresh sale_seq, lazily committing a
// new reservation chunk to NVS when the current reservation is exhausted.
// Returns 0 on NVS failure so the caller can fall back to direct-publish.
static uint32_t alloc_seq_locked(void) {
    if (s_last_seq + 1 > s_seq_reserved_to) {
        uint32_t new_high = s_seq_reserved_to + SALE_SEQ_RESERVATION_CHUNK;
        nvs_handle_t h;
        if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return 0;
        bool ok = (nvs_set_u32(h, K_LAST_SEQ, new_high) == ESP_OK);
        if (ok) ok = (nvs_commit(h) == ESP_OK);
        nvs_close(h);
        if (!ok) return 0;
        s_seq_reserved_to = new_high;
    }
    return ++s_last_seq;
}

// Caller must hold s_lock. The fast path skips the NVS blob write entirely
// when we are reasonably certain the publish will reach the broker promptly:
//   - MQTT session is connected
//   - No pending sales waiting to be drained (FIFO ordering)
//   - No slow-path publish currently waiting on PUBACK (single-writer)
static bool can_fast_path_locked(void) {
    return s_client != NULL
        && mqtt_started
        && s_tail == s_head
        && s_in_flight_msg_id == 0;
}

// Caller must hold s_lock. Records a fast-path publish so its PUBACK can be
// matched and so it can be demoted to NVS on disconnect. Returns false if
// the tracking array is full — caller should fall through to the slow path
// in that case (signal of slow PUBACKs / network trouble).
static bool fast_path_track_locked(int msg_id, const sale_record_t *rec) {
    for (int i = 0; i < FAST_PATH_TRACK_MAX; i++) {
        if (s_fast_tracked[i].msg_id == 0) {
            s_fast_tracked[i].msg_id = msg_id;
            s_fast_tracked[i].rec    = *rec;
            return true;
        }
    }
    return false;
}

// Caller must hold s_lock. Returns true and clears the slot if a fast-path
// entry with this msg_id exists. Used by sale_queue_on_published to absorb
// fast-path PUBACKs without touching NVS.
static bool fast_path_ack_locked(int msg_id) {
    for (int i = 0; i < FAST_PATH_TRACK_MAX; i++) {
        if (s_fast_tracked[i].msg_id == msg_id) {
            s_fast_tracked[i].msg_id = 0;
            return true;
        }
    }
    return false;
}

// Caller must hold s_lock. Writes one record into the slow-path NVS queue
// (blob + tail commit). Returns true on success. Caller is responsible for
// overflow accounting.
static bool nvs_persist_record_locked(const sale_record_t *rec) {
    uint32_t slot = s_tail % SALE_QUEUE_CAPACITY;
    char key[8];
    snprintf(key, sizeof(key), SLOT_KEY_FMT, (unsigned)slot);

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return false;

    bool ok = true;
    if (nvs_set_blob(h, key, rec, sizeof(*rec)) != ESP_OK) ok = false;
    if (ok && nvs_set_u32(h, K_TAIL, s_tail + 1) != ESP_OK) ok = false;
    if (ok && nvs_commit(h)                      != ESP_OK) ok = false;
    nvs_close(h);

    if (!ok) return false;
    s_tail++;
    return true;
}

// Caller must hold s_lock. Demotes every still-tracked fast-path entry to
// the NVS queue. Per-entry commit so a power loss mid-demote (e.g. watchdog
// hard reboot racing with the disconnect handler) leaves earlier entries
// safely persisted. Idempotency at the backend means it's harmless if the
// broker had actually delivered some of these before the disconnect — the
// drain task republishes, backend returns 23505 duplicate, head advances.
static void fast_path_demote_all_locked(void) {
    int demoted = 0, lost = 0;
    for (int i = 0; i < FAST_PATH_TRACK_MAX; i++) {
        if (s_fast_tracked[i].msg_id == 0) continue;

        if (s_tail - s_head >= SALE_QUEUE_CAPACITY) {
            // Queue is full — record the loss but clear the tracking slot
            // so we don't keep retrying forever.
            s_overflow++;
            lost++;
        } else if (nvs_persist_record_locked(&s_fast_tracked[i].rec)) {
            demoted++;
        } else {
            ESP_LOGE(TAG, "demote: NVS write failed for seq=%u",
                     (unsigned)s_fast_tracked[i].rec.sale_seq);
            lost++;
        }
        s_fast_tracked[i].msg_id = 0;
    }

    if (demoted || lost) {
        ESP_LOGW(TAG, "disconnect: demoted %d fast-path sales to NVS (%d lost)",
                 demoted, lost);
        if (demoted) xSemaphoreGive(s_wake);
    }
}

bool sale_queue_enqueue(uint8_t cmd, uint16_t item_price, uint16_t item_number) {
    if (s_lock == NULL) {
        ESP_LOGE(TAG, "enqueue before init — dropping sale");
        return false;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);

    // MDB bus retransmit guard: the VMC resends CASH_SALE / VEND_SUCCESS
    // when the ACK byte is lost or corrupted (common during motor-induced
    // EMI). Each retransmit gets a fresh sale_seq, so the backend unique
    // index cannot catch it. Suppress identical (cmd, price, item) within
    // a short window. 5 s is safe — a real repeat purchase requires a full
    // mechanical cycle (coin-in → select → motor → dispense ≥ 10 s).
    // Returns true (not false!) so the caller does NOT fall back to the
    // unprotected v1 direct-publish path.
    {
        static uint8_t  s_dedup_cmd   = 0;
        static uint16_t s_dedup_price = 0;
        static uint16_t s_dedup_item  = 0;
        static TickType_t s_dedup_tick = 0;

        TickType_t now_tick = xTaskGetTickCount();
        if (cmd == s_dedup_cmd
            && item_price == s_dedup_price
            && item_number == s_dedup_item
            && (now_tick - s_dedup_tick) < pdMS_TO_TICKS(5000)) {
            ESP_LOGW(TAG, "dedup: suppressed retransmit cmd=0x%02x item=%u price=%u (%ums since last)",
                     cmd, (unsigned)item_number, (unsigned)item_price,
                     (unsigned)(now_tick - s_dedup_tick) * portTICK_PERIOD_MS);
            xSemaphoreGive(s_lock);
            return true;
        }
        s_dedup_cmd   = cmd;
        s_dedup_price = item_price;
        s_dedup_item  = item_number;
        s_dedup_tick  = now_tick;
    }

    uint32_t pending = s_tail - s_head;
    if (pending >= SALE_QUEUE_CAPACITY) {
        s_overflow++;
        nvs_handle_t oh;
        if (nvs_open(NS, NVS_READWRITE, &oh) == ESP_OK) {
            nvs_set_u32(oh, K_OVERFLOW, s_overflow);
            nvs_commit(oh);
            nvs_close(oh);
        }
        ESP_LOGE(TAG, "queue full (capacity=%u) — sale DROPPED (overflow=%u)",
                 (unsigned)SALE_QUEUE_CAPACITY, (unsigned)s_overflow);
        xSemaphoreGive(s_lock);
        return false;
    }

    // Clock sync: if the device has no usable wall clock we record
    // occurred_at=0 + the time_uncertain flag, and the webhook substitutes
    // its own receive time rather than rejecting the sale.
    bool time_ok = clock_is_usable();
    time_t now_sec = time_ok ? time(NULL) : 0;

    uint32_t seq = alloc_seq_locked();
    if (seq == 0) {
        ESP_LOGE(TAG, "alloc_seq failed (NVS error) — caller must fall back");
        xSemaphoreGive(s_lock);
        return false;
    }

    sale_record_t rec = {
        .cmd            = cmd,
        .item_price     = item_price,
        .item_number    = item_number,
        .occurred_at    = (uint32_t)now_sec,
        .sale_seq       = seq,
        .time_uncertain = time_ok ? 0 : 1,
    };

    // ---- FAST PATH -----------------------------------------------------
    // Broker is online and queue is idle: publish directly with no NVS blob
    // write. Idempotency is preserved via the already-persisted seq
    // reservation, so a reboot cannot reuse the same sale_seq. The publish
    // is tracked in a small RAM array so that:
    //   - PUBACK is matched and the slot freed (no NVS work)
    //   - on disconnect, the still-untracked entries are demoted to NVS so
    //     a subsequent watchdog reboot cannot lose them
    // Only the few microseconds between mqtt_publish_safe() returning and
    // fast_path_track_locked() registering the slot are unprotected — the
    // accepted loss window.
    if (can_fast_path_locked()) {
        uint8_t payload[19];
        build_v2_payload(&rec, payload);

        char topic[128];
        snprintf(topic, sizeof(topic), "/%s/%s/sale", my_company_id, my_device_id);

        int msg_id = mqtt_publish_safe(s_client, topic, (const char *)payload,
                                       sizeof(payload), 1 /*QoS*/, 0);
        if (msg_id > 0 && fast_path_track_locked(msg_id, &rec)) {
            s_fast_path_count++;
            ESP_LOGI(TAG, "fast-path seq=%u msg_id=%d time_uncertain=%u",
                     (unsigned)seq, msg_id, (unsigned)rec.time_uncertain);
            xSemaphoreGive(s_lock);
            return true;
        }
        if (msg_id > 0) {
            ESP_LOGW(TAG, "fast-path tracking full — falling through to slow path "
                          "(network healthy? %d in flight)", FAST_PATH_TRACK_MAX);
        } else {
            ESP_LOGW(TAG, "fast-path publish failed (msg_id=%d) — falling through to slow path",
                     msg_id);
        }
    }

    // ---- SLOW PATH -----------------------------------------------------
    // Queue the sale to NVS so the drain task can publish with strict
    // FIFO + PUBACK tracking. K_LAST_SEQ is NOT written here — the seq
    // was already persisted by alloc_seq_locked() via the reservation.
    uint32_t slot = s_tail % SALE_QUEUE_CAPACITY;
    if (!nvs_persist_record_locked(&rec)) {
        ESP_LOGE(TAG, "NVS write failed for seq=%u — sale NOT persisted",
                 (unsigned)seq);
        xSemaphoreGive(s_lock);
        return false;
    }

    ESP_LOGI(TAG, "slow-path enqueued seq=%u slot=%u price=%u item=%u time_uncertain=%u (pending=%u)",
             (unsigned)seq, (unsigned)slot,
             (unsigned)item_price, (unsigned)item_number,
             (unsigned)rec.time_uncertain, (unsigned)(s_tail - s_head));

    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_wake);
    return true;
}

// Loads the head record. Caller must hold s_lock. Returns false when queue empty.
static bool load_head_record(sale_record_t *out) {
    if (s_tail == s_head) return false;
    uint32_t slot = s_head % SALE_QUEUE_CAPACITY;
    char key[8];
    snprintf(key, sizeof(key), SLOT_KEY_FMT, (unsigned)slot);

    nvs_handle_t h;
    if (nvs_open(NS, NVS_READONLY, &h) != ESP_OK) return false;

    size_t len = sizeof(sale_record_t);
    esp_err_t err = nvs_get_blob(h, key, out, &len);
    nvs_close(h);

    if (err != ESP_OK || len != sizeof(sale_record_t)) {
        ESP_LOGE(TAG, "head slot %u corrupt (err=%s len=%u) — advancing past it",
                 (unsigned)slot, esp_err_to_name(err), (unsigned)len);
        return false;
    }
    return true;
}

// Builds a 19-byte v2 sale payload with idempotency fields.
//
// v2 layout (after XOR decrypt):
//   byte 0    : cmd
//   byte 1    : version = 0x02
//   bytes 2-5 : item_price (4 bytes, big-endian, scale-factor encoded)
//   bytes 6-7 : item_number (2 bytes, big-endian)
//   bytes 8-11: occurred_at (unix seconds, big-endian) — 0 if time_uncertain
//   byte 12   : flags (bit 0 = time_uncertain)
//   byte 13   : reserved
//   bytes 14-17: sale_seq (uint32, big-endian)
//   byte 18   : checksum = sum(bytes 0..17) & 0xFF
static void build_v2_payload(const sale_record_t *rec, uint8_t *payload) {
    // Delegate to the existing encoder for the scale-factor conversion and
    // the random filler: xorEncodeWithPasskey fills the unused bytes with
    // esp_fill_random() before XOR-encrypting, which prevents a replay
    // adversary from trivially distinguishing otherwise-identical sales.
    // We then decrypt, stamp the v2-specific fields (version, occurred_at,
    // flags, sale_seq), recompute the checksum, and re-encrypt with the
    // same passkey — the only way to preserve the random-filler contract
    // without reimplementing the encoder.
    xorEncodeWithPasskey(rec->cmd, rec->item_price, rec->item_number, 0, payload);

    uint8_t v2[19];
    memcpy(v2, payload, 19);

    for (int i = 0; i < 18; i++) {
        v2[i + 1] ^= (uint8_t)my_passkey[i];
    }

    v2[1]  = SALE_PAYLOAD_V2;
    v2[8]  = (uint8_t)(rec->occurred_at >> 24);
    v2[9]  = (uint8_t)(rec->occurred_at >> 16);
    v2[10] = (uint8_t)(rec->occurred_at >> 8);
    v2[11] = (uint8_t)(rec->occurred_at);
    v2[12] = rec->time_uncertain ? 0x01 : 0x00;
    v2[13] = 0x00;
    v2[14] = (uint8_t)(rec->sale_seq >> 24);
    v2[15] = (uint8_t)(rec->sale_seq >> 16);
    v2[16] = (uint8_t)(rec->sale_seq >> 8);
    v2[17] = (uint8_t)(rec->sale_seq);

    // Recompute checksum on plaintext
    uint8_t chk = 0;
    for (int i = 0; i < 18; i++) chk += v2[i];
    v2[18] = chk;

    // Re-encrypt bytes 1..17
    for (int i = 0; i < 18; i++) {
        v2[i + 1] ^= (uint8_t)my_passkey[i];
    }

    memcpy(payload, v2, 19);
}

void sale_queue_on_published(int msg_id) {
    if (msg_id == 0) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);

    // Fast-path PUBACK: just clear the RAM tracking slot. No NVS work,
    // because fast-path sales were never written to the queue.
    if (fast_path_ack_locked(msg_id)) {
        xSemaphoreGive(s_lock);
        return;
    }

    if (msg_id != s_in_flight_msg_id) {
        // Ack for some other publish (status, paxcounter, mdb-log) — ignore.
        xSemaphoreGive(s_lock);
        return;
    }

    // Slow-path PUBACK: advance head, the oldest queued sale is confirmed.
    uint32_t new_head = s_head + 1;
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u32(h, K_HEAD, new_head);
        nvs_commit(h);
        nvs_close(h);
        s_head = new_head;
    } else {
        ESP_LOGE(TAG, "PUBACK: nvs_open failed — head stays at %u (will retry on drain)",
                 (unsigned)s_head);
    }
    s_in_flight_msg_id = 0;
    xSemaphoreGive(s_lock);
    xSemaphoreGive(s_wake); // send next
}

void sale_queue_on_disconnect(void) {
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_in_flight_msg_id = 0; // drain task will re-publish on reconnect

    // Rescue any in-flight fast-path publishes whose PUBACK never made it
    // back. Without this, a watchdog hard-reboot at 10min offline would
    // wipe the ESP-IDF outbox and lose them. Backend dedup absorbs any
    // entries that the broker had actually delivered before the drop.
    fast_path_demote_all_locked();

    xSemaphoreGive(s_lock);
}

uint32_t sale_queue_pending_count(void) {
    return s_tail - s_head;
}

uint32_t sale_queue_overflow_count(void) {
    return s_overflow;
}

uint32_t sale_queue_last_seq(void) {
    return s_last_seq;
}

uint32_t sale_queue_fast_path_count(void) {
    return s_fast_path_count;
}

bool sale_queue_clock_ok(void) {
    return clock_is_usable();
}

static void sale_queue_publish_task(void *arg) {
    ESP_LOGI(TAG, "drain task started");
    for (;;) {
        // Wait up to 5s for wake; also retry periodically in case we missed a wake.
        xSemaphoreTake(s_wake, pdMS_TO_TICKS(5000));

        if (!mqtt_started) continue;

        xSemaphoreTake(s_lock, portMAX_DELAY);
        if (s_in_flight_msg_id != 0) {
            // Already waiting on a PUBACK — don't send another. QoS 1 with
            // a single-entry inflight window gives strictly ordered delivery.
            xSemaphoreGive(s_lock);
            continue;
        }
        sale_record_t rec;
        bool have = load_head_record(&rec);
        if (!have) {
            if (s_tail != s_head) {
                // corrupt slot — skip it so we don't deadlock
                uint32_t new_head = s_head + 1;
                nvs_handle_t h;
                if (nvs_open(NS, NVS_READWRITE, &h) == ESP_OK) {
                    nvs_set_u32(h, K_HEAD, new_head);
                    nvs_commit(h);
                    nvs_close(h);
                    s_head = new_head;
                }
            }
            xSemaphoreGive(s_lock);
            continue;
        }

        uint8_t payload[19];
        build_v2_payload(&rec, payload);

        char topic[128];
        snprintf(topic, sizeof(topic), "/%s/%s/sale", my_company_id, my_device_id);

        int msg_id = mqtt_publish_safe(s_client, topic, (const char *)payload,
                                       sizeof(payload), 1 /*QoS*/, 0);
        // QoS 1 publishes must return a positive msg_id; 0 is the sentinel
        // for "no in-flight", and negative values indicate publish failure.
        // In either failure case leave s_in_flight_msg_id == 0 so the next
        // wake retries this same slot.
        if (msg_id > 0) {
            s_in_flight_msg_id = msg_id;
            ESP_LOGI(TAG, "publishing seq=%u msg_id=%d (pending=%u)",
                     (unsigned)rec.sale_seq, msg_id,
                     (unsigned)(s_tail - s_head));
        } else {
            ESP_LOGW(TAG, "publish failed for seq=%u (msg_id=%d) — will retry",
                     (unsigned)rec.sale_seq, msg_id);
        }
        xSemaphoreGive(s_lock);
    }
}

void sale_queue_start(esp_mqtt_client_handle_t client) {
    s_client = client;
    xTaskCreate(sale_queue_publish_task, "sale_drain", 4096, NULL, 5, NULL);
    // Kick once in case we booted with pending entries.
    if (s_wake) xSemaphoreGive(s_wake);
}
