/*
 * VMflow.xyz
 *
 * mdb-master-esp32s3.c - Vending machine controller (VMC Simulator)
 *
 */

#include <esp_log.h>

#include <string.h>
#include <stdio.h>
#include <stdarg.h>
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
#include <esp_event.h>
#include <esp_netif.h>
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

struct reader_t reader0x08 = { .machineState = INACTIVE_STATE };
struct reader_t reader0x10 = { .machineState = INACTIVE_STATE };
struct reader_t reader0x60 = { .machineState = INACTIVE_STATE };

// Expansion ID info for WebUI display
char reader0x10_manufacturer[4] = "";
char reader0x10_serial[13] = "";
char reader0x10_model[13] = "";
char reader0x10_sw_version[3] = "";

/* PA102 - Product Price
 * PA201 - Number of Products Vended Since Initialisation
 * */
typedef struct {
    float pa102;
    uint16_t pa201;
} coil_t;

coil_t coils[1] = {
    {.pa102 = 1.25f, .pa201 = 0}
};

/* --- Vend request queue (shared between button ISR and WebUI) --- */
QueueHandle_t vend_request_queue = NULL;
bool reader_enabled = true; // WebUI can toggle this

/* --- MDB Log Ringbuffer --- */
mdb_log_entry_t mdb_log[MDB_LOG_SIZE];
int mdb_log_head = 0;
int mdb_log_count = 0;

void mdb_log_add(char dir, const char *fmt, ...) {
    mdb_log_entry_t *e = &mdb_log[mdb_log_head];
    e->timestamp_ms = (uint32_t)(esp_timer_get_time() / 1000);
    e->direction = dir;
    va_list args;
    va_start(args, fmt);
    vsnprintf(e->description, sizeof(e->description), fmt, args);
    va_end(args);
    mdb_log_head = (mdb_log_head + 1) % MDB_LOG_SIZE;
    if (mdb_log_count < MDB_LOG_SIZE) mdb_log_count++;
}

/* --- WiFi --- */
#define WIFI_MAX_RETRY 5
static int wifi_retry_num = 0;

static volatile int64_t last_button_time = 0;

static void IRAM_ATTR button0_isr_handler(void* arg) {

	int64_t now = esp_timer_get_time();

	if (now - last_button_time > 500000) { // 500ms debounce
        vend_request_t req = { .itemNumber = (esp_random() % 10) + 1, .itemPrice = 0 };
        xQueueSendFromISR(vend_request_queue, &req, NULL);
        last_button_time = now;
    }
}

void write_9(uint16_t nth9) {
    uint8_t ones = __builtin_popcount((uint8_t) nth9);

    uart_wait_tx_done(UART_NUM_2, pdMS_TO_TICKS(250));

    if ((nth9 >> 8) & 1) {
        uart_set_parity(UART_NUM_2, ones % 2 ? UART_PARITY_EVEN : UART_PARITY_ODD);
    } else {
        uart_set_parity(UART_NUM_2, ones % 2 ? UART_PARITY_ODD : UART_PARITY_EVEN);
    }

    uart_write_bytes(UART_NUM_2, (uint8_t*) &nth9, 1);
}

void write_payload_9(uint8_t *mdb_payload_tx, uint8_t mdb_length) {

	uint8_t checksum = 0;

	write_9((checksum = mdb_payload_tx[0]) | BIT_MODE_SET);
	for (uint8_t x = 1; x < mdb_length; x++) {
		write_9(mdb_payload_tx[x]);

		checksum += mdb_payload_tx[x];
	}

	write_9(checksum);

	// Wait for TX to complete, then consume echo bytes caused by
	// crosstalk between adjacent GPIO4 (RX) and GPIO5 (TX) pins.
	// Echo bytes arrive synchronously with TX, so they're all in the
	// RX buffer by now. Use 0 timeout to avoid consuming the slave's response.
	uart_wait_tx_done(UART_NUM_2, pdMS_TO_TICKS(250));
	uint8_t echo_discard[36];
	uart_read_bytes(UART_NUM_2, echo_discard, mdb_length + 1, 0);
}

void send_ack(void) {
	write_9(ACK | BIT_MODE_SET);
	uart_wait_tx_done(UART_NUM_2, pdMS_TO_TICKS(250));
	uint8_t echo;
	uart_read_bytes(UART_NUM_2, &echo, 1, 0);
}

void mdb_vmc_loop(void *pvParameters) {

	vend_request_t currentVend = {0};

	uint8_t mdb_payload_tx[36];
	uint8_t mdb_payload_rx[36];

    size_t len;

	for (;;) {

	    uart_flush(UART_NUM_2);

		// 0x10 Cashless Device #1
		if (reader0x10.machineState == INACTIVE_STATE) {

			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (RESET & BIT_CMD_SET);
			write_payload_9(mdb_payload_tx, 1);
			mdb_log_add('T', "RESET");

            len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*

            if(len == 1){
                mdb_log_add('R', "ACK (0x%02X)", mdb_payload_rx[0]);

                mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (POLL & BIT_CMD_SET);
                write_payload_9(mdb_payload_tx, 1);
                mdb_log_add('T', "POLL");

                len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 2, pdMS_TO_TICKS(30)); // CHK*
                if (len != 2) { ESP_LOGW(TAG, "POLL response timeout in INACTIVE (got %d)", len); continue; }
                ESP_LOGI(TAG, "POLL response: 0x%02X 0x%02X", mdb_payload_rx[0], mdb_payload_rx[1]);

                send_ack();

                if (mdb_payload_rx[0] == 0x00 /*Just Reset*/) {
                    mdb_log_add('R', "Just Reset");

                    mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (SETUP & BIT_CMD_SET);
                    mdb_payload_tx[1] = 0x00; 			// Config Data
                    mdb_payload_tx[2] = 1; 			    // VMC Feature Level
                    mdb_payload_tx[3] = 0; 			    // Columns on Display
                    mdb_payload_tx[4] = 0; 			    // Rows on Display
                    mdb_payload_tx[5] = 0b00000001; 	// Display Information

                    write_payload_9(mdb_payload_tx, 6);
                    mdb_log_add('T', "SETUP Config");

                    len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 9, pdMS_TO_TICKS(200)); // CHK*
                    if (len != 9) {
                        ESP_LOGW(TAG, "SETUP Config response timeout (got %d)", len);
                        if (len > 0) {
                            char dbg[64]; int pos = 0;
                            for (int i = 0; i < len && pos < 60; i++) pos += snprintf(dbg+pos, 64-pos, "%02X ", mdb_payload_rx[i]);
                            ESP_LOGW(TAG, "SETUP Config bytes: %s", dbg);
                        }
                        continue;
                    }

                    send_ack();

                    reader0x10.featureLevel = mdb_payload_rx[1];
                    reader0x10.countryCode = (mdb_payload_rx[2] << 8) | mdb_payload_rx[3];
                    reader0x10.scaleFactor = mdb_payload_rx[4];
                    reader0x10.decimalPlaces = mdb_payload_rx[5];
                    reader0x10.responseTimeSec = mdb_payload_rx[6];
                    reader0x10.miscellaneous = mdb_payload_rx[7];

                    mdb_log_add('R', "Config: FL%d SC%d DP%d", reader0x10.featureLevel, reader0x10.scaleFactor, reader0x10.decimalPlaces);

                    reader0x10.machineState = DISABLED_STATE;

                    ESP_LOGI( TAG, "Reader Config");
                }
            }

		} else if (reader0x10.machineState == DISABLED_STATE) {

            coil_t coilMaxPrice = coils[0];
            coil_t coilMinPrice = coils[0];

            uint8_t count = sizeof(coils) / sizeof(coils[0]);
            for (uint8_t c = 0; c < count; c++) {

                if (coils[c].pa102 > coilMaxPrice.pa102)
                    coilMaxPrice = coils[c];

                if (coils[c].pa102 < coilMinPrice.pa102)
                    coilMinPrice = coils[c];
            }

			uint16_t scaledMaxPrice = TO_SCALE_FACTOR(coilMaxPrice.pa102, reader0x10.scaleFactor, reader0x10.decimalPlaces);
			uint16_t scaledMinPrice = TO_SCALE_FACTOR(coilMinPrice.pa102, reader0x10.scaleFactor, reader0x10.decimalPlaces);

			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (SETUP & BIT_CMD_SET);
			mdb_payload_tx[1] = 0x01; // Max|Min Prices
			mdb_payload_tx[2] = scaledMaxPrice >> 8;
			mdb_payload_tx[3] = scaledMaxPrice;
			mdb_payload_tx[4] = scaledMinPrice >> 8;
			mdb_payload_tx[5] = scaledMinPrice;

			write_payload_9(mdb_payload_tx, 6);
			mdb_log_add('T', "SETUP Max/Min %d/%d", scaledMaxPrice, scaledMinPrice);

			len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
            if (len != 1) { ESP_LOGW(TAG, "Max/Min Prices ACK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

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
			mdb_log_add('T', "EXPANSION Request ID");

            len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 31, pdMS_TO_TICKS(500)); // CHK*
            if (len != 31) { ESP_LOGW(TAG, "Expansion ID response timeout (got %d)", len); reader0x10.machineState = INACTIVE_STATE; continue; }

			send_ack();

            ESP_LOGI( TAG, "Manufacture code: %.*s", 3, &mdb_payload_rx[1]);
            ESP_LOGI( TAG, "Serial number: %.*s", 12, &mdb_payload_rx[4]);
            ESP_LOGI( TAG, "Model number: %.*s", 12, &mdb_payload_rx[16]);
            ESP_LOGI( TAG, "Software version: %.*s", 2, &mdb_payload_rx[28]);

            mdb_log_add('R', "ID: %.3s SN:%.12s", &mdb_payload_rx[1], &mdb_payload_rx[4]);

			// Store expansion ID info for WebUI
			memcpy(reader0x10_manufacturer, &mdb_payload_rx[1], 3);
			reader0x10_manufacturer[3] = '\0';
			memcpy(reader0x10_serial, &mdb_payload_rx[4], 12);
			reader0x10_serial[12] = '\0';
			memcpy(reader0x10_model, &mdb_payload_rx[16], 12);
			reader0x10_model[12] = '\0';
			memcpy(reader0x10_sw_version, &mdb_payload_rx[28], 2);
			reader0x10_sw_version[2] = '\0';

			ESP_LOGI( TAG, "Reader Enable");

            mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (READER & BIT_CMD_SET);
            mdb_payload_tx[1] = 0x01; // Reader Enable

            write_payload_9(mdb_payload_tx, 2);
            mdb_log_add('T', "READER Enable");

            len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
            if (len != 1) { ESP_LOGW(TAG, "Reader Enable ACK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

            reader0x10.machineState = ENABLED_STATE;
            reader_enabled = true;

		} else {

			// Check if WebUI requested Reader Disable/Enable toggle
			if (reader_enabled && (reader0x10.machineState == ENABLED_STATE || reader0x10.machineState == IDLE_STATE)) {
				// Reader is enabled, check for disable request — handled below after POLL
			} else if (!reader_enabled && reader0x10.machineState != INACTIVE_STATE && reader0x10.machineState != DISABLED_STATE) {
				// WebUI requested disable
				mdb_payload_tx[0] = (0x10 & BIT_ADD_SET) | (READER & BIT_CMD_SET);
				mdb_payload_tx[1] = 0x00; // Reader Disable
				write_payload_9(mdb_payload_tx, 2);
				mdb_log_add('T', "READER Disable");

				len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30));
				if (len != 1) { ESP_LOGW(TAG, "Reader Disable ACK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

				reader0x10.machineState = DISABLED_STATE;
				mdb_log_add('R', "ACK (Reader Disabled)");
				continue;
			}

			mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (POLL & BIT_CMD_SET);
			write_payload_9(mdb_payload_tx, 1);

            len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30));
            if( len == 1){
                reader0x10.poll_fail_count = 0;

                // Handle Just Reset in main poll (0x00 is 2 bytes: data + CHK)
                if (mdb_payload_rx[0] == 0x00 /*Just Reset*/) {
                    len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 1, pdMS_TO_TICKS(30)); // CHK
                    send_ack();
                    ESP_LOGW(TAG, "Just Reset during active state");
                    mdb_log_add('R', "Just Reset (unexpected)");
                    reader0x10.machineState = INACTIVE_STATE;

                } else if (mdb_payload_rx[0] == 0x07 /*End Session*/ ) {

					len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 1, pdMS_TO_TICKS(30)); // CHK*
					if (len != 2) { ESP_LOGW(TAG, "End Session CHK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

                    send_ack();
                    mdb_log_add('R', "End Session");

					reader0x10.machineState = ENABLED_STATE;

				} else if (mdb_payload_rx[0] == 0x06 /*Vend Denied*/ ) {
					ESP_LOGI( TAG, "Vend Denied");

				    len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 1, pdMS_TO_TICKS(30)); // CHK*
					if (len != 2) { ESP_LOGW(TAG, "Vend Denied CHK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

					send_ack();
					mdb_log_add('R', "Vend Denied");

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x04; // Session Complete

					write_payload_9(mdb_payload_tx, 2);
					mdb_log_add('T', "Session Complete");

                    len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
                    if (len != 1) { ESP_LOGW(TAG, "Session Complete ACK timeout (Vend Denied)"); reader0x10.machineState = INACTIVE_STATE; continue; }

					reader0x10.machineState = IDLE_STATE;

				} else if (mdb_payload_rx[0] == 0x05 /*Vend Approved*/) {
					ESP_LOGI( TAG, "Vend Approved");

                    len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 3, pdMS_TO_TICKS(30)); // CHK*
					if (len != 4) { ESP_LOGW(TAG, "Vend Approved payload timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

					send_ack();

					uint16_t vendAmount = (mdb_payload_rx[1] << 8) | mdb_payload_rx[2];
					mdb_log_add('R', "Vend Approved amt=%d", vendAmount);

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x02; // Vend Success
					mdb_payload_tx[2] = currentVend.itemNumber >> 8;
					mdb_payload_tx[3] = currentVend.itemNumber;

					write_payload_9(mdb_payload_tx, 4);
					mdb_log_add('T', "Vend Success item=%d", currentVend.itemNumber);

                    len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
                    if (len != 1) { ESP_LOGW(TAG, "Vend Success ACK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

					reader0x10.machineState = IDLE_STATE;

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x04; // Session Complete

					write_payload_9(mdb_payload_tx, 2);
					mdb_log_add('T', "Session Complete");

                    len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
                    if (len != 1) { ESP_LOGW(TAG, "Session Complete ACK timeout (Vend Approved)"); reader0x10.machineState = INACTIVE_STATE; continue; }

				} else if (mdb_payload_rx[0] == 0x04 /*Session Cancel Request*/ ) {

					len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 1, pdMS_TO_TICKS(30)); // CHK*
					if (len != 2) { ESP_LOGW(TAG, "Session Cancel CHK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

					send_ack();
					mdb_log_add('R', "Session Cancel Request");

					mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
					mdb_payload_tx[1] = 0x04; // Session Complete

					write_payload_9(mdb_payload_tx, 2);
					mdb_log_add('T', "Session Complete");

                    len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
                    if (len != 1) { ESP_LOGW(TAG, "Session Complete ACK timeout (Cancel)"); reader0x10.machineState = INACTIVE_STATE; continue; }

				} else if (mdb_payload_rx[0] == 0x03 /*Begin Session*/ ) {

					ESP_LOGI( TAG, "Begin Session");

                    len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 3, pdMS_TO_TICKS(30)); // CHK*
					if (len != 4) { ESP_LOGW(TAG, "Begin Session payload timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

					send_ack();

					uint16_t fundsAvailable = (mdb_payload_rx[1] << 8) | mdb_payload_rx[2];
                    (void) fundsAvailable;
                    mdb_log_add('R', "Begin Session funds=%d", fundsAvailable);

					reader0x10.machineState = IDLE_STATE;

				} else if (mdb_payload_rx[0] == 0x0b /*Command Out of Sequence*/) {
					ESP_LOGI( TAG, "Command Out of Sequence");

                    len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 1, pdMS_TO_TICKS(30)); // CHK*
					if (len != 2) { ESP_LOGW(TAG, "Cmd Out of Sequence CHK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

                    send_ack();
                    mdb_log_add('R', "Cmd Out of Sequence");

					reader0x10.machineState = INACTIVE_STATE;

				} else if (mdb_payload_rx[0] == 0x0a /*Malfunction/Error*/) {
					ESP_LOGW(TAG, "Malfunction/Error from slave");

					len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 2, pdMS_TO_TICKS(30)); // error code + CHK
					if (len >= 2) {
						send_ack();
						mdb_log_add('R', "Malfunction err=0x%02X", mdb_payload_rx[1]);
					}

				} else if (mdb_payload_rx[0] == 0x08 /*Cancelled*/) {
					ESP_LOGI(TAG, "Cancelled response");

					len += uart_read_bytes(UART_NUM_2, mdb_payload_rx + len, 1, pdMS_TO_TICKS(30)); // CHK
					if (len == 2) send_ack();
					mdb_log_add('R', "Cancelled");

				} else if (xQueueReceive(vend_request_queue, &currentVend, 0)) {

					uint16_t itemPrice;
					if (currentVend.itemPrice == 0) {
						// Random price: whole part 1–5, decimal .1–.9
						float randomPrice = (float)((esp_random() % 5) + 1) + (float)((esp_random() % 9) + 1) / 10.0f;
						itemPrice = TO_SCALE_FACTOR(randomPrice, reader0x10.scaleFactor, reader0x10.decimalPlaces);
					} else {
						itemPrice = currentVend.itemPrice;
					}

					if (reader0x10.machineState == IDLE_STATE) {
						ESP_LOGI( TAG, "Vend request");

						mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/ & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
						mdb_payload_tx[1] = 0x00; // Vend Request
						mdb_payload_tx[2] = itemPrice >> 8;
						mdb_payload_tx[3] = itemPrice;
						mdb_payload_tx[4] = currentVend.itemNumber >> 8;
						mdb_payload_tx[5] = currentVend.itemNumber;

						write_payload_9(mdb_payload_tx, 6);
						mdb_log_add('T', "Vend Request item=%d price=%d", currentVend.itemNumber, itemPrice);

						len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
					    if (len != 1) { ESP_LOGW(TAG, "Vend Request ACK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }

						reader0x10.machineState = VEND_STATE;

					} else if (reader0x10.machineState == ENABLED_STATE) {
						ESP_LOGI( TAG, "Cash sale");

						mdb_payload_tx[0] = (0x10 /*Cashless Device #1*/  & BIT_ADD_SET) | (VEND & BIT_CMD_SET);
						mdb_payload_tx[1] = 0x05; // Cash Sale
						mdb_payload_tx[2] = itemPrice >> 8;
						mdb_payload_tx[3] = itemPrice;

						mdb_payload_tx[4] = currentVend.itemNumber >> 8;
						mdb_payload_tx[5] = currentVend.itemNumber;

						write_payload_9(mdb_payload_tx, 6);
						mdb_log_add('T', "Cash Sale item=%d price=%d", currentVend.itemNumber, itemPrice);

						len = uart_read_bytes(UART_NUM_2, mdb_payload_rx, 1, pdMS_TO_TICKS(30)); // ACK*
					    if (len != 1) { ESP_LOGW(TAG, "Cash Sale ACK timeout"); reader0x10.machineState = INACTIVE_STATE; continue; }
					}
				}

            } else {
                if(++reader0x10.poll_fail_count >= 3) reader0x10.machineState = INACTIVE_STATE;
            }
		}

		/*
        uart_flush(UART_NUM_2);

		// 0x08 Changer
		if (reader0x08.machineState == INACTIVE_STATE) {

			mdb_payload_tx[0] = 0x08 *//*Changer*//* | 0x00 *//*RESET*//*;
			write_payload_9((uint8_t*) &mdb_payload_tx, 1);

			vTaskDelay(pdMS_TO_TICKS(250));
			xQueueReceive(payload_receive_queue, &mdb_payload_rx, 500 / portTICK_PERIOD_MS); // ACK

			mdb_payload_tx[0] = (0x08 *//*Changer*//* & BIT_ADD_SET) | (0x03 *//*POOL*//* & BIT_CMD_SET);
			write_payload_9((uint8_t*) &mdb_payload_tx, 1);

			vTaskDelay(pdMS_TO_TICKS(250));
			if (xQueueReceive(payload_receive_queue, &mdb_payload_rx, pdMS_TO_TICKS(250))) {

				if (mdb_payload_rx[0] == 0x00 *//*Just Reset*//*) {

					ESP_LOGI( TAG, "Changer - Just Reset");

					reader0x08.machineState = DISABLED_STATE;
				}
			}
		} else if (reader0x08.machineState == DISABLED_STATE) {

			mdb_payload_tx[0] = (0x08 *//*Changer*//* & BIT_ADD_SET) | (0x01 *//*SETUP*//* & BIT_CMD_SET);
			write_payload_9((uint8_t*) &mdb_payload_tx, 1);

			vTaskDelay(pdMS_TO_TICKS(250));
			if (xQueueReceive(payload_receive_queue, &mdb_payload_rx, pdMS_TO_TICKS(250))) {
				// Changer Setup Response

				reader0x08.featureLevel = mdb_payload_rx[0];
				reader0x08.countryCode = (mdb_payload_rx[1] << 8) | mdb_payload_rx[2];
				reader0x08.scaleFactor = mdb_payload_rx[3];
				reader0x08.decimalPlaces = mdb_payload_rx[4];
				reader0x08.coinTypeRouting = (mdb_payload_rx[5] << 8) | mdb_payload_rx[6];

				send_ack();

				// Send TUBE STATUS
				mdb_payload_tx[0] = (0x08 *//*Changer*//* & BIT_ADD_SET) | (0x02 *//*TUBE STATUS*//* & BIT_CMD_SET);
				write_payload_9((uint8_t*) &mdb_payload_tx, 1);

				vTaskDelay(pdMS_TO_TICKS(250));
				if (xQueueReceive(payload_receive_queue, &mdb_payload_rx, pdMS_TO_TICKS(250))) {
					// Tube status response

					reader0x08.tubeFullStatus = (mdb_payload_rx[0] << 8) | mdb_payload_rx[1];

					// Tube counts (16 tubes)
					for(uint8_t i = 0; i < 16; i++) {
						reader0x08.tubeCounts[i] = mdb_payload_rx[2 + i];
					}

					ESP_LOGI(TAG, "Changer Tube Status received");

					send_ack();

					reader0x08.machineState = ENABLED_STATE;
				}
			}
		} else {
			// ENABLED_STATE or other states - POLL

			mdb_payload_tx[0] = (0x08 *//*Changer*//* & BIT_ADD_SET) | (0x03 *//*POLL*//* & BIT_CMD_SET);
			write_payload_9((uint8_t*) &mdb_payload_tx, 1);

			vTaskDelay(pdMS_TO_TICKS(250));
			if (xQueueReceive(payload_receive_queue, &mdb_payload_rx, pdMS_TO_TICKS(250))) {
				reader0x08.poll_fail_count = 0;

			} else {

				if (++reader0x08.poll_fail_count >= 3) {
					ESP_LOGW(TAG, "Changer: Poll timeout - resetting");
					reader0x08.machineState = INACTIVE_STATE;
				}
			}
		}*/

		uart_flush(UART_NUM_2);

		// 0x60 Cashless Device #2
		if (reader0x60.machineState == INACTIVE_STATE) {

			mdb_payload_tx[0] = (0x60 /*Cashless Device #2*/ & BIT_ADD_SET) | (RESET & BIT_CMD_SET);
			write_payload_9(mdb_payload_tx, 1);

            uart_read_bytes(UART_NUM_2, mdb_payload_rx, sizeof(mdb_payload_rx), pdMS_TO_TICKS(30)); // ACK*
			/*TODO*/

            write_9(NAK | BIT_MODE_SET);
		}
	}
}

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
		for (uint8_t c = 0; c < sizeof(coils)/sizeof(coils[0]); c++) {

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

/* --- WiFi Event Handler --- */
static void wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data) {

    if (event_base == WIFI_EVENT)
        switch (event_id) {
        case WIFI_EVENT_STA_START: {
            wifi_retry_num = 0;
            ESP_LOGI(TAG, "WIFI STA started");

            wifi_config_t sta_cfg = {0};
            esp_wifi_get_config(WIFI_IF_STA, &sta_cfg);
            ESP_LOGI(TAG, "Saved SSID: \"%s\"", (char *)sta_cfg.sta.ssid);

            if (strlen((char *)sta_cfg.sta.ssid) == 0) {
                ESP_LOGI(TAG, "No saved WiFi credentials — starting SoftAP");
                start_softap();
                start_dns_server();
                start_webui_server();
            } else {
                esp_err_t conn_err = esp_wifi_connect();
                ESP_LOGI(TAG, "esp_wifi_connect() → %s", esp_err_to_name(conn_err));
                if (conn_err != ESP_OK) {
                    ESP_LOGW(TAG, "Connect failed immediately — starting SoftAP");
                    start_softap();
                    start_dns_server();
                    start_webui_server();
                }
            }
            break;
        }
        case WIFI_EVENT_AP_START:
            ESP_LOGI(TAG, "WIFI AP started — SSID \"" VMC_AP_SSID "\"");
            break;
        case WIFI_EVENT_AP_STACONNECTED:
            ESP_LOGI(TAG, "Client connected to SoftAP");
            break;
        case WIFI_EVENT_STA_CONNECTED:
            break;
        case WIFI_EVENT_STA_DISCONNECTED:
            if (wifi_retry_num++ < WIFI_MAX_RETRY) {
                esp_wifi_connect();
            } else {
                start_softap();
                start_dns_server();
                start_webui_server();
            }
            break;
        }

    if (event_base == IP_EVENT)
        switch (event_id) {
        case IP_EVENT_STA_GOT_IP: {
            ip_event_got_ip_t *event_ip = (ip_event_got_ip_t *)event_data;
            ESP_LOGW(TAG, "GOT IP: " IPSTR, IP2STR(&event_ip->ip_info.ip));

            wifi_retry_num = 0;

            stop_dns_server();

            // Switch to STA-only mode
            esp_wifi_set_mode(WIFI_MODE_STA);

            // Start WebUI server (accessible on STA IP)
            start_webui_server();
            break;
        }
        }
}

void app_main(void) {

    //--------------- NVS ---------------//
    esp_err_t nvs_err = nvs_flash_init();
    if (nvs_err == ESP_ERR_NVS_NO_FREE_PAGES || nvs_err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_err = nvs_flash_init();
    }
    ESP_LOGI(TAG, "NVS init: %s", esp_err_to_name(nvs_err));

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
        .resolution_hz = 10 * 1000 * 1000, // 10 MHz → good precision
        .mem_block_symbols = 64,
    };

    ESP_ERROR_CHECK(led_strip_new_rmt_device(&strip_config, &rmt_config, &led_strip));

    //--------------- WiFi ---------------//
    esp_netif_init();
    esp_event_loop_create_default();
    esp_netif_create_default_wifi_sta();
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);

    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID, wifi_event_handler, NULL, NULL);

    // Apply Kconfig WiFi credentials if set
    #ifdef CONFIG_WIFI_SSID
    if (strlen(CONFIG_WIFI_SSID) > 0) {
        wifi_config_t sta_config = {0};
        strncpy((char *)sta_config.sta.ssid, CONFIG_WIFI_SSID, sizeof(sta_config.sta.ssid) - 1);
        #ifdef CONFIG_WIFI_PASSWORD
        strncpy((char *)sta_config.sta.password, CONFIG_WIFI_PASSWORD, sizeof(sta_config.sta.password) - 1);
        #endif
        esp_wifi_set_config(WIFI_IF_STA, &sta_config);
    }
    #endif

    esp_wifi_set_mode(WIFI_MODE_APSTA);
    esp_wifi_start();

    //--------------- MDB ---------------//
	uart_config_t uart_config_2 = {
        .baud_rate = 9600,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_EVEN,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE };

	uart_param_config(UART_NUM_2, &uart_config_2);
	uart_set_pin( UART_NUM_2, pin_mdb_tx, pin_mdb_rx, -1, -1);
	uart_driver_install(UART_NUM_2, 256, 256, 0, (void*) 0, 0);

	//
	vend_request_queue = xQueueCreate(1 /*queue-length*/, sizeof(vend_request_t));

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
	xTaskCreate(mdb_vmc_loop, "vmc_loop", 6765, (void*) 0, 1, (void*) 0);

	xTaskCreate(eva_dts_loop, "dex_loop", 6765, (void*) 0, 1, (void*) 0);
}