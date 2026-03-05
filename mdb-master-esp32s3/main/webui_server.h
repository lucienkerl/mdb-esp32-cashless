#ifndef WEBUI_SERVER_H
#define WEBUI_SERVER_H

#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#define AP_SSID "MDB-Master"
#define AP_PASS "12345678"

#define MAX_PRODUCTS    20
#define MAX_EVENTS      50
#define MAX_EVENT_LEN   128

/* ---- Shared types ---- */

typedef enum {
    INACTIVE_STATE = 0,
    DISABLED_STATE,
    ENABLED_STATE,
    IDLE_STATE,
    VEND_STATE
} machine_state_t;

typedef struct {
    uint16_t item_number;
    uint16_t price_cents;       /* e.g. 150 = EUR 1.50 */
} vend_request_t;

typedef struct {
    uint8_t  slot;              /* 1-based item/slot number */
    char     name[32];
    uint16_t price_cents;
} product_t;

typedef struct {
    char    text[MAX_EVENT_LEN];
    int64_t timestamp_ms;       /* milliseconds since boot */
} event_entry_t;

struct reader_t {
    uint8_t  featureLevel;
    uint16_t countryCode;
    uint16_t coinTypeRouting;
    uint16_t tubeFullStatus;
    uint8_t  scaleFactor;
    uint8_t  decimalPlaces;
    uint8_t  responseTimeSec;
    uint8_t  tubeCounts[16];
    uint8_t  miscellaneous;
    uint8_t  poll_fail_count;
    machine_state_t machineState;
};

/* ---- Shared globals (defined in mdb-master-esp32s3.c) ---- */

extern product_t       products[MAX_PRODUCTS];
extern uint8_t         product_count;
extern QueueHandle_t   vend_queue;
extern struct reader_t reader0x10;

extern event_entry_t   event_log[MAX_EVENTS];
extern int             event_log_head;
extern int             event_log_count;
extern SemaphoreHandle_t event_mutex;

extern char            sta_ip_addr[16];

extern char            device_manufacturer[4];
extern char            device_serial[13];
extern char            device_model[13];
extern char            device_sw_version[3];

/* ---- Functions (webui_server.c) ---- */

void start_softap(void);
void start_rest_server(void);
void stop_rest_server(void);
void start_dns_server(void);
void stop_dns_server(void);

void load_products_from_nvs(void);
void save_products_to_nvs(void);
void set_default_products(void);

void add_event(const char *fmt, ...);

#endif
