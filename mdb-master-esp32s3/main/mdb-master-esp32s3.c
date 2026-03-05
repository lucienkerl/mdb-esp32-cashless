/*
 * VMflow.xyz
 *
 * mdb-master-esp32s3.c - Vending machine controller with Web UI
 *
 */

#include <esp_log.h>
#include <string.h>
#include <stdio.h>
#include <float.h>
#include <math.h>
#include <driver/gpio.h>
#include <driver/uart.h>
#include <rom/ets_sys.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_random.h>
#include <esp_wifi.h>
#include <esp_netif.h>
#include <esp_event.h>
#include <nvs_flash.h>

#include "led_strip.h"
#include "webui_server.h"

#define TAG "mdb_vmc"

#define pin_dex_rx  	GPIO_NUM_18
#define pin_dex_tx      GPIO_NUM_17
#define pin_mdb_rx  	GPIO_NUM_4  // Pin to receive data from MDB
#define pin_mdb_tx  	GPIO_NUM_5  // Pin to transmit data to MDB
#define pin_mdb_led 	GPIO_NUM_48 // LED to indicate MDB state

// Functions for scale factor conversion
#define TO_SCALE_FACTOR(p, scale_to, dec_to) (p / scale_to / pow(10, -(dec_to) ))               // Converts to scale factor
#define FROM_SCALE_FACTOR(p, scale_from, dec_from) (p * scale_from * pow(10, -(dec_from) ))     // Converts from scale factor

#define ACK 	0x00  // Acknowledgment / Checksum correct;
#define RET 	0xAA  // Retransmit the previously sent data. Only the VMC can transmit this byte;
#define NAK 	0xFF  // Negative acknowledge.

#define BIT_MODE_SET 	0b100000000
#define BIT_ADD_SET   	0b011111000
#define BIT_CMD_SET   	0b000000111

enum MDB_COMMAND {
	RESET = 0x00,
	SETUP = 0x01,
	POLL = 0x02,
	VEND = 0x03,
	READER = 0x04,
	EXPANSION = 0x07
};

#define WIFI_MAX_RETRY 5

/* ================================================================
 *  Shared globals (declared extern in webui_server.h)
 * ================================================================ */

struct reader_t reader0x08 = { .machineState = INACTIVE_STATE };
struct reader_t reader0x10 = { .machineState = INACTIVE_STATE };
struct reader_t reader0x60 = { .machineState = INACTIVE_STATE };

product_t        products[MAX_PRODUCTS];
uint8_t          product_count = 0;

QueueHandle_t    vend_queue = NULL;

event_entry_t    event_log[MAX_EVENTS];
int              event_log_head  = 0;
int              event_log_count = 0;
SemaphoreHandle_t event_mutex   = NULL;

char             sta_ip_addr[16]        = "";
char             device_manufacturer[4] = "";
char             device_serial[13]      = "";
char             device_model[13]       = "";
char             device_sw_version[3]   = "";

/* PA102 - Product Price
 * PA201 - Number of Products Vended Since Initialisation
 * */
typedef struct {
    float pa102;
    uint16_t pa201;
} coil_t;

/* ================================================================
 *  Button ISR
 * ================================================================ */

static volatile int64_t last_button_time = 0;

static void IRAM_ATTR button0_isr_handler(void* arg) {

	int64_t now = esp_timer_get_time();

	if (now - last_button_time > 500000) { // 500ms debounce
        vend_request_t req = {
            .item_number = (esp_random() % 10) + 1,
            .price_cents = (uint16_t)(((esp_random() % 5) + 1) * 100 + ((esp_random() % 9) + 1) * 10),
        };
        xQueueSendFromISR(vend_queue, &req, NULL);
        last_button_time = now;
    }
}

/* ================================================================
 *  MDB 9-bit bit-bang helpers
 *
 *  TX: bit-bang via GPIO (proven to work with slave's bit-bang RX)
 *  RX: UART2 hardware with EVEN parity, driver API (uart_read_bytes).
 *      The driver's ISR moves bytes from the HW FIFO into a software
 *      ring buffer.  We read from that buffer — never poll the HW FIFO
 *      directly.
 * ================================================================ */

/* Drain all stale bytes from UART2 (HW FIFO + driver ring buffer). */
static void flush_mdb_rx(void) {
    uart_flush_input(UART_NUM_2);
}

void write_9(uint16_t nth9) {
    gpio_set_level(pin_mdb_tx, 0);  // Start bit
    ets_delay_us(104);

    for (uint8_t x = 0; x < 9; x++) {
        gpio_set_level(pin_mdb_tx, (nth9 >> x) & 1);
        ets_delay_us(104);
    }

    gpio_set_level(pin_mdb_tx, 1);  // Stop bit
    ets_delay_us(104);
}

void write_payload_9(uint8_t *mdb_payload_tx, uint8_t mdb_length) {

    /* Flush any leftover RX bytes before sending a new command.
     * The slave's write_payload_9 always sends first_byte + checksum,
     * so an "ACK" is actually 2 frames — the extra one would corrupt
     * the next read if not flushed. */
    flush_mdb_rx();

	uint8_t checksum = 0;

	write_9((checksum = mdb_payload_tx[0]) | BIT_MODE_SET);
	for (uint8_t x = 1; x < mdb_length; x++) {
		write_9(mdb_payload_tx[x]);

		checksum += mdb_payload_tx[x];
	}

	write_9(checksum);

	/* NO post-TX drain — let the caller read everything (crosstalk +
	 * slave response) and we'll figure out what's what from the raw data.
	 * This diagnostic approach avoids any drain-timing issues. */
}

/* Read up to max_len bytes from UART2 via the driver's software ring buffer.
 * Uses uart_read_bytes (1 byte at a time) with a shrinking inter-byte
 * timeout: first byte gets the full timeout_ms, subsequent bytes get 5 ms
 * (MDB bytes arrive ~1.1 ms apart; 5 ms gap means the slave is done).
 * Logs arrival timestamps for each byte (relative to read start). */
static size_t read_mdb_bytes(uint8_t *buf, size_t max_len, uint32_t timeout_ms) {
    size_t count = 0;
    int64_t start = esp_timer_get_time();
    int64_t ts[8];  /* arrival timestamps (µs relative to start) */

    /* First byte: full timeout */
    TickType_t ticks = pdMS_TO_TICKS(timeout_ms);
    if (ticks == 0) ticks = 1;  /* at least 1 tick */

    while (count < max_len) {
        int got = uart_read_bytes(UART_NUM_2, &buf[count], 1, ticks);
        if (got <= 0) break;  /* timeout — no more bytes */

        if (count < 8) ts[count] = esp_timer_get_time() - start;
        count++;

        /* After first byte, shorten to 5 ms inter-byte timeout.
         * MDB bytes come back-to-back (~1.1 ms apart). */
        ticks = pdMS_TO_TICKS(5);
        if (ticks == 0) ticks = 1;
    }

    /* Log after read completes so logging doesn't steal RX time */
    for (size_t i = 0; i < count && i < 8; i++) {
        ESP_LOGI(TAG, "  RX[%d]=0x%02X  +%lld us", (int)i, buf[i], (long long)ts[i]);
    }
    return count;
}

/* ================================================================
 *  Main MDB VMC loop
 * ================================================================ */

void mdb_vmc_loop(void *pvParameters) {

	vend_request_t vend_req = {0};

	uint8_t mdb_payload_tx[36];
	uint8_t mdb_payload_rx[36];

    size_t len;

	for (;;) {

	    vTaskDelay(pdMS_TO_TICKS(5)); // Inter-command gap

		// 0x10 Cashless Device #1
		if (reader0x10.machineState == INACTIVE_STATE) {

			/* Pace RESET attempts — don't flood the bus */
			vTaskDelay(pdMS_TO_TICKS(500));

			/* --- DIAGNOSTIC: read everything raw (crosstalk + slave) --- */
			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (RESET & BIT_CMD_SET);
			write_payload_9(mdb_payload_tx, 1);

            len = read_mdb_bytes(mdb_payload_rx, 8, 30); // raw: crosstalk + ACK
            ESP_LOGI(TAG, "RESET raw: %d bytes", len);

            /* Send POLL regardless of RESET result */
            mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (POLL & BIT_CMD_SET);
            write_payload_9(mdb_payload_tx, 1);

            len = read_mdb_bytes(mdb_payload_rx, 8, 30); // raw: crosstalk + response
            ESP_LOGI(TAG, "POLL raw: %d bytes", len);

            /* For now, find "Just Reset" (0x00) anywhere in the buffer */
            int just_reset = 0;
            for (size_t i = 0; i < len; i++) {
                if (mdb_payload_rx[i] == 0x00) { just_reset = 1; break; }
            }
            if (len >= 1 && just_reset) {
                write_9(ACK | BIT_MODE_SET);
                vTaskDelay(pdMS_TO_TICKS(5));

                /* Treat as success — skip old checks */
                len = 2; mdb_payload_rx[0] = 0x00; mdb_payload_rx[1] = 0x00;
            } else {
                ESP_LOGW(TAG, "POLL: no 'Just Reset' found");
                continue;
            }
            if (1) { /* always true — enter the Just Reset handler */

                ESP_LOGI(TAG, "POLL response: 0x%02X 0x%02X", mdb_payload_rx[0], mdb_payload_rx[1]);
                write_9(ACK | BIT_MODE_SET);
                vTaskDelay(pdMS_TO_TICKS(5)); // Give bit-bang slave time to return to listening

                if (mdb_payload_rx[0] == 0x00 /*Just Reset*/) {

                    mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (SETUP & BIT_CMD_SET);
                    mdb_payload_tx[1] = 0x00; 			// Config Data
                    mdb_payload_tx[2] = 1; 			    // VMC Feature Level
                    mdb_payload_tx[3] = 0; 			    // Columns on Display
                    mdb_payload_tx[4] = 0; 			    // Rows on Display
                    mdb_payload_tx[5] = 0b00000001; 	// Display Information

                    write_payload_9(mdb_payload_tx, 6);

                    len = read_mdb_bytes(mdb_payload_rx, 9, 40); // CHK*
                    if (len != 9) {
                        ESP_LOGW(TAG, "SETUP Config: expected 9 bytes, got %d", len);
                        continue;
                    }

                    ESP_LOGI(TAG, "SETUP Config response OK (9 bytes)");
                    write_9(ACK | BIT_MODE_SET);
                    vTaskDelay(pdMS_TO_TICKS(5)); // Give bit-bang slave time to return to listening

                    reader0x10.featureLevel = mdb_payload_rx[1];
                    reader0x10.countryCode = (mdb_payload_rx[2] << 8) | mdb_payload_rx[3];
                    reader0x10.scaleFactor = mdb_payload_rx[4];
                    reader0x10.decimalPlaces = mdb_payload_rx[5];
                    reader0x10.responseTimeSec = mdb_payload_rx[6];
                    reader0x10.miscellaneous = mdb_payload_rx[7];

                    reader0x10.machineState = DISABLED_STATE;

                    add_event("Device detected - setup received (scale=%d, dec=%d)",
                              reader0x10.scaleFactor, reader0x10.decimalPlaces);
                } else {
                    ESP_LOGW(TAG, "POLL response not 'Just Reset': 0x%02X", mdb_payload_rx[0]);
                }
            } else {
                ESP_LOGW(TAG, "RESET: no ACK (got %d bytes)", len);
            }

		} else if (reader0x10.machineState == DISABLED_STATE) {

            /* Compute max/min prices from product list */
            uint16_t maxPrice = 0, minPrice = UINT16_MAX;
            for (int i = 0; i < product_count; i++) {
                if (products[i].price_cents > maxPrice) maxPrice = products[i].price_cents;
                if (products[i].price_cents < minPrice) minPrice = products[i].price_cents;
            }
            if (product_count == 0) { maxPrice = 500; minPrice = 50; }

            float fMax = maxPrice / 100.0f;
            float fMin = minPrice / 100.0f;

			uint16_t scaledMaxPrice = TO_SCALE_FACTOR(fMax, reader0x10.scaleFactor, reader0x10.decimalPlaces);
			uint16_t scaledMinPrice = TO_SCALE_FACTOR(fMin, reader0x10.scaleFactor, reader0x10.decimalPlaces);

			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (SETUP & BIT_CMD_SET);
			mdb_payload_tx[1] = 0x01; // Max|Min Prices
			mdb_payload_tx[2] = scaledMaxPrice >> 8;
			mdb_payload_tx[3] = scaledMaxPrice;
			mdb_payload_tx[4] = scaledMinPrice >> 8;
			mdb_payload_tx[5] = scaledMinPrice;

			write_payload_9(mdb_payload_tx, 6);

			len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
            if (len != 1) {
                ESP_LOGW(TAG, "SETUP Max/Min: no ACK (got %d bytes)", len);
                reader0x10.machineState = INACTIVE_STATE; continue;
            }

            ESP_LOGI(TAG, "SETUP Max/Min ACK received");
			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (EXPANSION & BIT_CMD_SET);
			mdb_payload_tx[1] = 0x00; // Request ID

			mdb_payload_tx[2] = 'V'; // Manufacturer code
			mdb_payload_tx[3] = 'M';
			mdb_payload_tx[4] = 'F';

			mdb_payload_tx[5] = ' '; // Serial Number
			mdb_payload_tx[6] = ' ';
			mdb_payload_tx[7] = ' ';
			mdb_payload_tx[8] = ' ';
			mdb_payload_tx[9] = ' ';
			mdb_payload_tx[10] = ' ';
			mdb_payload_tx[11] = ' ';
			mdb_payload_tx[12] = ' ';
			mdb_payload_tx[13] = ' ';
			mdb_payload_tx[14] = ' ';
			mdb_payload_tx[15] = ' ';
			mdb_payload_tx[16] = ' ';

			mdb_payload_tx[17] = ' '; // Model Number
			mdb_payload_tx[18] = ' ';
			mdb_payload_tx[19] = ' ';
			mdb_payload_tx[20] = ' ';
			mdb_payload_tx[21] = ' ';
			mdb_payload_tx[22] = ' ';
			mdb_payload_tx[23] = ' ';
			mdb_payload_tx[24] = ' ';
			mdb_payload_tx[25] = ' ';
			mdb_payload_tx[26] = ' ';
			mdb_payload_tx[27] = ' ';
			mdb_payload_tx[28] = ' ';

			mdb_payload_tx[29] = '0'; // Software Version
			mdb_payload_tx[30] = '1';

			write_payload_9(mdb_payload_tx, 31);

            len = read_mdb_bytes(mdb_payload_rx, 31, 125); // CHK*
            if (len != 31) {
                ESP_LOGW(TAG, "EXPANSION Request ID: expected 31 bytes, got %d", len);
                reader0x10.machineState = INACTIVE_STATE; continue;
            }

            ESP_LOGI(TAG, "EXPANSION response OK (31 bytes)");
			write_9(ACK | BIT_MODE_SET);
            vTaskDelay(pdMS_TO_TICKS(5)); // Give bit-bang slave time to return to listening

            /* Store device info for web UI */
            snprintf(device_manufacturer, sizeof(device_manufacturer), "%.*s", 3, &mdb_payload_rx[1]);
            snprintf(device_serial, sizeof(device_serial), "%.*s", 12, &mdb_payload_rx[4]);
            snprintf(device_model, sizeof(device_model), "%.*s", 12, &mdb_payload_rx[16]);
            snprintf(device_sw_version, sizeof(device_sw_version), "%.*s", 2, &mdb_payload_rx[28]);

            ESP_LOGI( TAG, "Manufacture code: %s", device_manufacturer);
            ESP_LOGI( TAG, "Serial number: %s", device_serial);
            ESP_LOGI( TAG, "Model number: %s", device_model);
            ESP_LOGI( TAG, "Software version: %s", device_sw_version);

            mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (READER & BIT_CMD_SET);
            mdb_payload_tx[1] = 0x01; // Reader Enable

            write_payload_9(mdb_payload_tx, 2);

            len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
            if (len != 1) {
                ESP_LOGW(TAG, "READER ENABLE: no ACK (got %d bytes)", len);
                reader0x10.machineState = INACTIVE_STATE; continue;
            }

            ESP_LOGI(TAG, "READER ENABLE ACK received - handshake complete");
            reader0x10.machineState = ENABLED_STATE;

            add_event("Reader enabled (mfg=%s, serial=%s)", device_manufacturer, device_serial);

		} else {

			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (POLL & BIT_CMD_SET);
			write_payload_9(mdb_payload_tx, 1);

            len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ...
            if( len == 1){
                reader0x10.poll_fail_count = 0;

                if (mdb_payload_rx[0] == 0x07 /*End Session*/ ) {

					len += read_mdb_bytes(mdb_payload_rx + len, 1, 30); // CHK*
					if (len != 2) { reader0x10.machineState = INACTIVE_STATE; continue; }

                    write_9(ACK | BIT_MODE_SET);

					reader0x10.machineState = ENABLED_STATE;

                    add_event("Session ended");

				} else if (mdb_payload_rx[0] == 0x06 /*Vend Denied*/ ) {

				    len += read_mdb_bytes(mdb_payload_rx + len, 1, 30); // CHK*
					if (len != 2) { reader0x10.machineState = INACTIVE_STATE; continue; }

					write_9(ACK | BIT_MODE_SET);

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x04; // Session Complete

					write_payload_9(mdb_payload_tx, 2);

                    len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
                    if (len != 1) { reader0x10.machineState = INACTIVE_STATE; continue; }

					reader0x10.machineState = IDLE_STATE;

                    add_event("VEND DENIED - slot %d", vend_req.item_number);

				} else if (mdb_payload_rx[0] == 0x05 /*Vend Approved*/) {

                    len += read_mdb_bytes(mdb_payload_rx + len, 3, 30); // CHK*
					if (len != 4) { reader0x10.machineState = INACTIVE_STATE; continue; }

					write_9(ACK | BIT_MODE_SET);

					uint16_t vendAmount = (mdb_payload_rx[1] << 8) | mdb_payload_rx[2];

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x02; // Vend Success
					mdb_payload_tx[2] = vend_req.item_number >> 8;
					mdb_payload_tx[3] = vend_req.item_number;

					write_payload_9(mdb_payload_tx, 4);

                    len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
                    if (len != 1) { reader0x10.machineState = INACTIVE_STATE; continue; }

					reader0x10.machineState = IDLE_STATE;

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x04; // Session Complete

					write_payload_9(mdb_payload_tx, 2);

                    len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
                    if (len != 1) { reader0x10.machineState = INACTIVE_STATE; continue; }

                    float approvedPrice = FROM_SCALE_FACTOR(vendAmount, reader0x10.scaleFactor, reader0x10.decimalPlaces);
                    add_event("VEND APPROVED - slot %d, EUR %.2f", vend_req.item_number, approvedPrice);

				} else if (mdb_payload_rx[0] == 0x04 /*Session Cancel Request*/ ) {

					len += read_mdb_bytes(mdb_payload_rx + len, 1, 30); // CHK*
					if (len != 2) { reader0x10.machineState = INACTIVE_STATE; continue; }

					write_9(ACK | BIT_MODE_SET);

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x04; // Session Complete

					write_payload_9(mdb_payload_tx, 2);

                    len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
                    if (len != 1) { reader0x10.machineState = INACTIVE_STATE; continue; }

                    add_event("Session cancelled by device");

				} else if (mdb_payload_rx[0] == 0x03 /*Begin Session*/ ) {

                    len += read_mdb_bytes(mdb_payload_rx + len, 3, 30); // CHK*
					if (len != 4) { reader0x10.machineState = INACTIVE_STATE; continue; }

					write_9(ACK | BIT_MODE_SET);

					uint16_t fundsAvailable = (mdb_payload_rx[1] << 8) | mdb_payload_rx[2];
                    float funds = FROM_SCALE_FACTOR(fundsAvailable, reader0x10.scaleFactor, reader0x10.decimalPlaces);

					reader0x10.machineState = IDLE_STATE;

                    add_event("Session started (funds: EUR %.2f)", funds);

				} else if (mdb_payload_rx[0] == 0x0b /*Command Out of Sequence*/) {

                    len += read_mdb_bytes(mdb_payload_rx + len, 1, 30); // CHK*
					if (len != 2) { reader0x10.machineState = INACTIVE_STATE; continue; }

                    write_9(ACK | BIT_MODE_SET);

					reader0x10.machineState = INACTIVE_STATE;

                    add_event("Command out of sequence - resetting");

				} else if (xQueueReceive(vend_queue, &vend_req, 0)) {

					float price = vend_req.price_cents / 100.0f;
					uint16_t itemPrice = TO_SCALE_FACTOR(price, reader0x10.scaleFactor, reader0x10.decimalPlaces);

					if (reader0x10.machineState == IDLE_STATE) {
						ESP_LOGI( TAG, "Vend request");

						mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
						mdb_payload_tx[1] = 0x00; // Vend Request
						mdb_payload_tx[2] = itemPrice >> 8;
						mdb_payload_tx[3] = itemPrice;
						mdb_payload_tx[4] = vend_req.item_number >> 8;
						mdb_payload_tx[5] = vend_req.item_number;

						write_payload_9(mdb_payload_tx, 6);

						len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
					    if (len != 1) { reader0x10.machineState = INACTIVE_STATE; continue; }

						reader0x10.machineState = VEND_STATE;

                        add_event("Vend request sent: slot %d, EUR %.2f", vend_req.item_number, price);

					} else if (reader0x10.machineState == ENABLED_STATE) {
						ESP_LOGI( TAG, "Cash sale");

						mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/  & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
						mdb_payload_tx[1] = 0x05; // Cash Sale
						mdb_payload_tx[2] = itemPrice >> 8;
						mdb_payload_tx[3] = itemPrice;

						mdb_payload_tx[4] = vend_req.item_number >> 8;
						mdb_payload_tx[5] = vend_req.item_number;

						write_payload_9(mdb_payload_tx, 6);

						len = read_mdb_bytes(mdb_payload_rx, 1, 30); // ACK*
					    if (len != 1) { reader0x10.machineState = INACTIVE_STATE; continue; }

                        add_event("Cash sale sent: slot %d, EUR %.2f", vend_req.item_number, price);
					}
				}

            } else {
                if(++reader0x10.poll_fail_count >= 3) {
                    reader0x10.machineState = INACTIVE_STATE;
                    add_event("Poll timeout - device reset");
                }
            }
		}

		/* 0x60 Cashless Device #2 — disabled: its write_payload_9 flush
		 * and 30 ms read were consuming 0x10 slave responses from the
		 * shared UART2 FIFO, causing "no ACK" failures.
		 * TODO: re-enable when a second cashless device is needed. */
		// if (reader0x60.machineState == INACTIVE_STATE) {
		// 	mdb_payload_tx[0] = (0x60 & BIT_ADD_SET) | (RESET & BIT_CMD_SET);
		// 	write_payload_9(mdb_payload_tx, 1);
		// 	read_mdb_bytes(mdb_payload_rx, sizeof(mdb_payload_rx), 30);
		// 	write_9(NAK | BIT_MODE_SET);
		// }
	}
}

/* ================================================================
 *  EVA-DTS (telemetry) loop
 * ================================================================ */

void eva_dts_loop(void *pvParameters) {

	// Initialize UART1 driver and configure TX/RX pins
	uart_config_t uart_config_1 = {
			.baud_rate = 9600,
			.data_bits = UART_DATA_8_BITS,
			.parity = UART_PARITY_DISABLE,
			.stop_bits = UART_STOP_BITS_1,
			.flow_ctrl = UART_HW_FLOWCTRL_DISABLE };

	uart_param_config(UART_NUM_1, &uart_config_1);
	uart_set_pin( UART_NUM_1, pin_dex_tx, pin_dex_rx, -1, -1);
	uart_driver_install(UART_NUM_1, 256, 256, 0, (void*) 0, 0);

	/* Build coil array from products for DEX data */
	coil_t coils[MAX_PRODUCTS];
	int coil_count = product_count > 0 ? product_count : 1;
	for (int i = 0; i < coil_count && i < MAX_PRODUCTS; i++) {
		coils[i].pa102 = products[i].price_cents / 100.0f;
		coils[i].pa201 = 0;
	}
	if (product_count == 0) {
		coils[0].pa102 = 1.25f;
		coils[0].pa201 = 0;
		coil_count = 1;
	}

	//
	uint8_t data[32];

	while (1) {

		// ENQ <-
		uart_read_bytes(UART_NUM_1, &data, 1, portMAX_DELAY);
		if (data[0] != 0x05)
			continue;

		// -------------------------------------- First Handshake --------------------------------------

		// DLE 0 ->
		uart_write_bytes(UART_NUM_1, "\x10\x30", 2);

		// DLE SOH <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
		if (data[0] != 0x10 || data[1] != 0x01)
			continue;

		// Communication ID <-
		uart_read_bytes(UART_NUM_1, &data, 10, pdMS_TO_TICKS(100));

		// Operation Request <-
		uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(100));

		// Revision & Level <-
		uart_read_bytes(UART_NUM_1, &data, 6, pdMS_TO_TICKS(100));

		// DLE ETX <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
		if (data[0] != 0x10 || data[1] != 0x03)
			continue;

		// CRC-16 <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));

		// DLE 1 ->
		uart_write_bytes(UART_NUM_1, "\x10\x31", 2);

		// EOT <-
		uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(100));
		if (data[0] != 0x04)
			continue;

		// -------------------------------------- Second Handshake --------------------------------------

		// ENQ ->
		uart_write_bytes(UART_NUM_1, "\x05", 1);

		// DLE 0 <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
		if (data[0] != 0x10 || data[1] != '0')
			continue;

		// DLE SOH ->
		uart_write_bytes(UART_NUM_1, "\x10\x01", 2);

		// Response Code ->
		uart_write_bytes(UART_NUM_1, "00", 2);
		// Communication ID ->
		uart_write_bytes(UART_NUM_1, "1234567890", 10);
		// Revision & Level ->
		uart_write_bytes(UART_NUM_1, "R00L06", 6);

		// DLE ETX ->
		uart_write_bytes(UART_NUM_1, "\x10\x03", 2);
		// CRC-16 ->
		uart_write_bytes(UART_NUM_1, "\xFF\xFF", 2);

		// DLE 1 <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
		if (data[0] != 0x10 || data[1] != '1')
			continue;

		// EOT ->
		uart_write_bytes(UART_NUM_1, "\x04", 1);

		// -------------------------------------- Data transfer --------------------------------------

		// ENQ ->
		uart_write_bytes(UART_NUM_1, "\x05", 1);

		uint8_t block = 0x00;
		for (uint8_t c = 0; c < coil_count; c++) {

			// DLE 0|1 <-
			uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(200));
			if (data[0] != 0x10 || data[1] != ('0' + (block++ & 0x01)) )
				break;

			// DLE STX ->
			uart_write_bytes(UART_NUM_1, "\x10\x02", 2);

			char pa1[100];
			sprintf(pa1, "PA1*%d*%d****\x0D\x0A", c, (uint16_t) TO_SCALE_FACTOR(coils[c].pa102, 1, 2) );

			uart_write_bytes(UART_NUM_1, &pa1, strlen(pa1));

			char pa2[100];
			sprintf(pa2, "PA2*%d*0*0*0\x0D\x0A", coils[c].pa201);

			uart_write_bytes(UART_NUM_1, &pa2, strlen(pa2));

			// DLE ETB ->
			uart_write_bytes(UART_NUM_1, "\x10\x17", 2);
			// CRC-16
			uart_write_bytes(UART_NUM_1, "\xff\xff", 2);
		}

		// DLE 0|1 <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(200));
		if (data[0] != 0x10 || data[1] != ('0' + (block++ & 0x01)) )
			break;

		// DLE STX ->
		uart_write_bytes(UART_NUM_1, "\x10\x02", 2);

		char *ea3 = "EA3**000101*000080**000101*000080***490*490\x0D\x0A";
		uart_write_bytes(UART_NUM_1, ea3, strlen(ea3));

		char *g85 = "G85*1BB8\x0D\x0A";
		uart_write_bytes(UART_NUM_1, g85, strlen(g85));

		char *se = "SE*280*0001\x0D\x0A";
		uart_write_bytes(UART_NUM_1, se, strlen(se));

		char *dxe = "DXE*1*1\x0D\x0A";
		uart_write_bytes(UART_NUM_1, dxe, strlen(dxe));

		// DLE ETX ->
		uart_write_bytes(UART_NUM_1, "\x10\x03", 2);
		// CRC-16
		uart_write_bytes(UART_NUM_1, "\xff\xff", 2);

		// DLE 0|1 <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(200));
		if (data[0] != 0x10 || data[1] != ('0' + (block++ & 0x01)) )
			break;

		// EOT ->
		uart_write_bytes(UART_NUM_1, "\x04", 1);
	}
}

/* ================================================================
 *  WiFi event handler
 * ================================================================ */

static int wifi_retry_count = 0;

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT) {
        switch (event_id) {
        case WIFI_EVENT_STA_START: {
            wifi_config_t cfg = {0};
            esp_wifi_get_config(WIFI_IF_STA, &cfg);
            if (strlen((char *)cfg.sta.ssid) > 0) {
                ESP_LOGI(TAG, "Connecting to %s ...", cfg.sta.ssid);
                esp_wifi_connect();
            }
            break;
        }
        case WIFI_EVENT_STA_DISCONNECTED:
            sta_ip_addr[0] = '\0';
            if (++wifi_retry_count <= WIFI_MAX_RETRY) {
                ESP_LOGI(TAG, "WiFi disconnected, retry %d/%d", wifi_retry_count, WIFI_MAX_RETRY);
                esp_wifi_connect();
            } else {
                ESP_LOGW(TAG, "WiFi retry limit reached");
                add_event("WiFi disconnected (retries exhausted)");
            }
            break;
        case WIFI_EVENT_AP_STACONNECTED: {
            wifi_event_ap_staconnected_t *ev = (wifi_event_ap_staconnected_t *)event_data;
            ESP_LOGI(TAG, "Station connected to AP (AID=%d)", ev->aid);
            break;
        }
        default:
            break;
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *ev = (ip_event_got_ip_t *)event_data;
        snprintf(sta_ip_addr, sizeof(sta_ip_addr), IPSTR, IP2STR(&ev->ip_info.ip));
        ESP_LOGI(TAG, "Got IP: %s", sta_ip_addr);
        wifi_retry_count = 0;
        add_event("WiFi connected, IP: %s", sta_ip_addr);
    }
}

/* ================================================================
 *  WiFi initialization (STA+AP)
 * ================================================================ */

static void wifi_init(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               &wifi_event_handler, NULL));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_APSTA));

    /* Configure AP */
    start_softap();

    /* Start WiFi — STA will auto-connect if credentials are saved */
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "WiFi APSTA started (AP SSID: %s)", AP_SSID);
}

/* ================================================================
 *  app_main
 * ================================================================ */

void app_main(void) {

    /* ---- NVS ---- */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    /* ---- Event log mutex ---- */
    event_mutex = xSemaphoreCreateMutex();

    /* ---- Load products from NVS ---- */
    load_products_from_nvs();
    add_event("Boot - %d products loaded", product_count);

    /* ---- WiFi + HTTP ---- */
    wifi_init();
    start_dns_server();
    start_rest_server();

    //--------------- Strip LED configuration ---------------//
    led_strip_handle_t led_strip;
    led_strip_config_t strip_config = {
        .strip_gpio_num = pin_mdb_led,
        .max_leds = 1,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
        .led_model = LED_MODEL_WS2812,
        .flags.invert_out = false,
    };

    led_strip_rmt_config_t rmt_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10 * 1000 * 1000, // 10 MHz
        .mem_block_symbols = 64,
    };

    ESP_ERROR_CHECK(led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip));

    //--------------- MDB ---------------//
    // TX: bit-bang via GPIO (matches slave's bit-bang approach)
    gpio_config_t mdb_tx_conf = {
        .pin_bit_mask = (1ULL << pin_mdb_tx),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE };
    gpio_config(&mdb_tx_conf);
    gpio_set_level(pin_mdb_tx, 1);  // Idle HIGH

    // RX: UART2 hardware with EVEN parity.
    // MDB 9-bit frame = start + 8 data + mode + stop = 11 bits.
    // UART EVEN parity frame = start + 8 data + parity + stop = 11 bits.
    // → Perfect match: parity bit position = MDB mode bit,
    //   actual stop bit (always 1) stays at UART stop position.
    // Mode=0 and mode=1 bytes both land in the ring buffer (parity errors
    // are just flags — they don't prevent the byte from being stored).
    // Driver ISR runs normally: it moves bytes from HW FIFO → software
    // ring buffer.  We read via uart_read_bytes (never poll HW FIFO).
	uart_config_t uart_config_2 = {
        .baud_rate = 9600,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_EVEN,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE };

	uart_param_config(UART_NUM_2, &uart_config_2);
	uart_set_pin( UART_NUM_2, UART_PIN_NO_CHANGE, pin_mdb_rx, -1, -1);
	uart_driver_install(UART_NUM_2, 256, 256, 0, (void*) 0, 0);
	flush_mdb_rx();

	//
	vend_queue = xQueueCreate(1 /*queue-length*/, sizeof(vend_request_t));

	gpio_config_t io_conf = {
			.intr_type = GPIO_INTR_NEGEDGE,
			.mode = GPIO_MODE_INPUT,
			.pin_bit_mask = (1ULL << GPIO_NUM_0),
			.pull_up_en = GPIO_PULLUP_ENABLE,
			.pull_down_en = GPIO_PULLDOWN_DISABLE, };

	gpio_config(&io_conf);

	gpio_install_isr_service(0 /*default*/);
	gpio_isr_handler_add(GPIO_NUM_0, button0_isr_handler, (void*) 0);

	//
	xTaskCreatePinnedToCore(mdb_vmc_loop, "vmc_loop", 6765, (void*) 0, 5, (void*) 0, 1);

	xTaskCreate(eva_dts_loop, "dex_loop", 6765, (void*) 0, 1, (void*) 0);
}
