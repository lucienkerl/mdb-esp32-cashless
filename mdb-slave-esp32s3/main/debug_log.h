/*
 * debug_log.h — offline-safe ring buffer for relay/custom-input/1-Wire/NTC
 * debug events, mirroring sale_queue.h's NVS-cursor pattern but backed by a
 * dedicated raw flash partition ("dbglog", ~800KB) instead of per-record NVS
 * blobs — see debug_log.c for why NVS doesn't fit at this volume.
 *
 * This is diagnostic data, not business data: unlike sale_queue, entries
 * that scroll out of the ring before being published are simply lost
 * (counted in debug_log_overflow_count()), no retry-forever guarantee.
 */
#ifndef DEBUG_LOG_H
#define DEBUG_LOG_H

#include <stdint.h>
#include <mqtt_client.h>

typedef enum {
    DEBUG_LOG_RELAY   = 1,
    DEBUG_LOG_INPUT   = 2,
    DEBUG_LOG_ONEWIRE = 3,
    DEBUG_LOG_NTC     = 4,
    DEBUG_LOG_PULSE   = 5,
} debug_log_type_t;

// Call once, after nvs_flash_init() has succeeded (the ack/write cursors
// live in NVS; the bulk records live in the raw partition).
void debug_log_init(void);

// Call once, after the MQTT client exists — mirrors sale_queue_start().
void debug_log_start(esp_mqtt_client_handle_t client);

// Appends one record to the ring. Safe to call before debug_log_init()
// completes or with MQTT disconnected — silently buffered/dropped.
// value_i32 meaning is type-dependent: INPUT = seconds the previous level
// was held; ONEWIRE/NTC = milli-degrees C (23456 = 23.456 C).
void debug_log_append(debug_log_type_t type, uint8_t channel, uint8_t value_u8, int32_t value_i32);

// Wire into the MQTT event handler alongside the sale_queue equivalents.
void debug_log_on_published(int msg_id);
void debug_log_on_disconnect(void);

uint32_t debug_log_pending_count(void);
uint32_t debug_log_overflow_count(void);

#endif
