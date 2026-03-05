#ifndef WEBUI_SERVER_H
#define WEBUI_SERVER_H

#include <stdint.h>
#include <stdbool.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#define VMC_AP_SSID "VMC-Simulator"
#define VMC_AP_PASS "12345678"

/* --- Shared types --- */

typedef enum MACHINE_STATE {
    INACTIVE_STATE, DISABLED_STATE, ENABLED_STATE, IDLE_STATE, VEND_STATE
} machine_state_t;

struct reader_t {
    uint8_t featureLevel;
    uint16_t countryCode;
    uint16_t coinTypeRouting;
    uint16_t tubeFullStatus;
    uint8_t scaleFactor;
    uint8_t decimalPlaces;
    uint8_t responseTimeSec;
    uint8_t tubeCounts[16];
    uint8_t miscellaneous;
    uint8_t poll_fail_count;
    machine_state_t machineState;
};

typedef struct {
    uint16_t itemNumber;
    uint16_t itemPrice; // 0 = generate random price
} vend_request_t;

/* --- MDB Log --- */
#define MDB_LOG_SIZE 100

typedef struct {
    uint32_t timestamp_ms;
    char direction;
    char description[48];
} mdb_log_entry_t;

extern mdb_log_entry_t mdb_log[MDB_LOG_SIZE];
extern int mdb_log_head;
extern int mdb_log_count;

/* --- Externs from mdb-master-esp32s3.c --- */

extern struct reader_t reader0x10;

extern char reader0x10_manufacturer[4];
extern char reader0x10_serial[13];
extern char reader0x10_model[13];
extern char reader0x10_sw_version[3];

extern QueueHandle_t vend_request_queue;
extern bool reader_enabled;

/* --- Server functions --- */

void start_webui_server(void);
void stop_webui_server(void);

void start_softap(void);
void start_dns_server(void);
void stop_dns_server(void);

#endif
