/*
 * sale_queue.h — NVS-backed persistent sales queue
 *
 * Guarantees that no sale is lost when the device, MQTT broker, or backend
 * is offline. Each vend is persisted to NVS *before* the VMC response is
 * sent, so even a power loss between vend success and MQTT publish leaves
 * the sale recoverable on the next boot.
 *
 * Flow:
 *   1. VEND_SUCCESS handler calls sale_queue_enqueue() — synchronous NVS
 *      write, returns the assigned sale_seq.
 *   2. sale_queue_publish_task (dedicated FreeRTOS task) drains the queue
 *      in FIFO order. It builds a v2 sale payload, publishes with QoS 1,
 *      then waits for MQTT_EVENT_PUBLISHED.
 *   3. On PUBACK, sale_queue_ack() advances the head pointer in NVS.
 *   4. On reboot, pending (unacked) entries are re-published automatically.
 *      Backend idempotency (UNIQUE(embedded_id, sale_seq)) absorbs any
 *      duplicates from crash-before-ack or broker-retention replay.
 *
 * Capacity is SALE_QUEUE_CAPACITY entries; when full the sale is still
 * accepted (we never reject a vend the customer already paid for) but the
 * overflow counter is incremented and surfaced via MDB diagnostics.
 */

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <mqtt_client.h>

#define SALE_QUEUE_CAPACITY 512

// Sale payload format version (byte 1 of the 19-byte XOR-encrypted payload).
// v2 adds per-device monotonic sale_seq + time_uncertain flag so replays from
// the firmware queue or broker retention can be de-duplicated at the DB.
#define SALE_PAYLOAD_V2 0x02

typedef struct __attribute__((packed)) {
    uint8_t  cmd;             // 0x21 CASH_SALE / 0x23 CARD_SALE / 0x24 CASHLESS_SALE
    uint16_t item_price;      // Scale-factor encoded (as passed to xorEncodeWithPasskey)
    uint16_t item_number;
    uint32_t occurred_at;     // Unix seconds at vend moment (0 when time_uncertain)
    uint32_t sale_seq;        // Monotonic per device, allocated before write
    uint8_t  time_uncertain;  // 1 when SNTP had not synced at vend time
} sale_record_t;

/*
 * Initialise queue from NVS. Must be called once from app_main before any
 * enqueue/publish. Safe to call multiple times (idempotent).
 */
void sale_queue_init(void);

/*
 * Persist a sale to NVS.
 *   cmd:         one of 0x21 / 0x23 / 0x24
 *   item_price:  scale-factor encoded price
 *   item_number: slot number
 * Returns true on success, false when NVS write fails. On success the
 * record is durably stored and the drain task will pick it up on the next
 * tick. Safe to call from the MDB task: synchronous NVS commit typically
 * completes in <20 ms.
 */
bool sale_queue_enqueue(uint8_t cmd, uint16_t item_price, uint16_t item_number);

/*
 * Start the drain task. Call once after MQTT client init. The task sleeps
 * until entries are available and MQTT is connected, then publishes in
 * FIFO order and advances the head pointer on PUBACK.
 */
void sale_queue_start(esp_mqtt_client_handle_t client);

/*
 * MQTT event hook. Forward MQTT_EVENT_PUBLISHED (with msg_id) from the
 * mqtt_event_handler to here so the queue can advance on ack.
 */
void sale_queue_on_published(int msg_id);

/*
 * MQTT event hook. Called from MQTT_EVENT_DISCONNECTED so the drain task
 * stops treating in-flight sends as pending-ack.
 */
void sale_queue_on_disconnect(void);

/*
 * Number of entries currently pending in the queue (published-but-unacked
 * included).
 */
uint32_t sale_queue_pending_count(void);

/*
 * Monotonic counter of sales that were stored but could not fit in the
 * queue (capacity exhausted). Surfaced via MDB diagnostics so operators
 * know when the offline buffer is saturated.
 */
uint32_t sale_queue_overflow_count(void);

/*
 * Last assigned sale_seq, for diagnostics.
 */
uint32_t sale_queue_last_seq(void);

/*
 * Count of sales that took the zero-NVS-write fast path since boot, for
 * diagnostics. A healthy device running online should see this counter
 * growing roughly in lockstep with last_seq.
 */
uint32_t sale_queue_fast_path_count(void);

/*
 * True when the device currently has a usable wall clock, i.e. sales are
 * being stamped with real vend times instead of occurred_at=0 +
 * time_uncertain. Surfaced via MDB diagnostics: a device reporting false
 * here has never reached an NTP server since its last power cycle, so its
 * sales carry server receive times and are eligible for the backend's
 * brownout duplicate suppression.
 */
bool sale_queue_clock_ok(void);
