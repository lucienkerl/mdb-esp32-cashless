/*
 * VMflow.xyz
 *
 * mdb-slave-esp32s3.c - Vending machine peripheral
 *
 */

#include <esp_log.h>

#include <sdkconfig.h>
#include <driver/gpio.h>
#include <driver/uart.h>
#include <esp_wifi.h>
#include <esp_random.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/ringbuf.h>
#include <math.h>
#include <mqtt_client.h>
#include <nvs_flash.h>
#include <stdio.h>
#include <string.h>
#include <esp_sntp.h>
#include <time.h>
#include <rom/ets_sys.h>


#include <esp_adc/adc_oneshot.h>
#include <esp_adc/adc_cali.h>
#include <esp_adc/adc_cali_scheme.h>

#include "led_strip.h"

#include "nimble.h"
#include "webui_server.h"
#include "sale_queue.h"
#include "network.h"

#include "esp_system.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "modem_https.h"
#include "esp_https_ota.h"
#include "esp_ota_ops.h"
#include "esp_app_desc.h"
#include "cJSON.h"

#define TAG "mdb_cashless"

#define PIN_I2C_SDA             GPIO_NUM_10
#define PIN_I2C_SCL             GPIO_NUM_11
#define PIN_PULSE_1             GPIO_NUM_13
#define PIN_MDB_RX              GPIO_NUM_4
#define PIN_MDB_TX              GPIO_NUM_5
#define PIN_MDB_LED             GPIO_NUM_21
#define PIN_DEX_RX              GPIO_NUM_8
#define PIN_DEX_TX              GPIO_NUM_9
#define PIN_SIM7080G_RX         GPIO_NUM_18
#define PIN_SIM7080G_TX         GPIO_NUM_17
#define PIN_SIM7080G_PWR        GPIO_NUM_14
#define PIN_BUZZER_PWR          GPIO_NUM_12

#define ADC_UNIT_THERMISTOR     ADC_UNIT_1
#define ADC_CHANNEL_THERMISTOR  ADC_CHANNEL_6   // Define the ADC unit, channel, and attenuation (NTC Thermistor)

// Functions for scale factor conversion
#define TO_SCALE_FACTOR(p, scale_to, dec_to) (p / scale_to / pow(10, -(dec_to) ))               // Converts to scale factor
#define FROM_SCALE_FACTOR(p, scale_from, dec_from) (p * scale_from * pow(10, -(dec_from) ))     // Converts from scale factor

#define ACK 	0x00  // Acknowledgment / Checksum correct
#define RET 	0xAA  // Retransmit previously sent data. Only VMC can send this
#define NAK 	0xFF  // Negative acknowledgment

// Bit masks for MDB operations
#define BIT_MODE_SET 	0b100000000
#define BIT_ADD_SET   	0b011111000
#define BIT_CMD_SET   	0b000000111

enum BIT_EVENTS {
    BIT_EVT_INTERNET    = (1 << 0),
    BIT_EVT_MDB         = (1 << 1),
    BIT_EVT_PSSKEY      = (1 << 2),
    BIT_EVT_DOMAIN      = (1 << 3),
    BIT_EVT_BUZZER      = (1 << 4),
    BIT_EVT_TRIGGER     = (1 << 5),
    MASK_EVT_INSTALLED  = (BIT_EVT_PSSKEY | BIT_EVT_DOMAIN)
};

EventGroupHandle_t xLedEventGroup;

// Visible to sale_queue.c — it needs to know whether the broker is currently
// reachable before pulling a pending sale off the queue.
bool mqtt_started = false;
static bool sntp_started = false;
static bool ota_in_progress = false;
SemaphoreHandle_t mqtt_publish_mutex = NULL;
static esp_timer_handle_t mqtt_watchdog_timer = NULL;
static TickType_t mqtt_last_connected_tick = 0;
#define MQTT_WATCHDOG_INTERVAL_SEC  120    // check every 2min
#define MQTT_WATCHDOG_TIMEOUT_SEC   300    // restart MQTT client after 5min offline
#define MQTT_HARD_REBOOT_SEC        600    // hard reboot after 10min offline

char my_company_id[40];   // UUID from Supabase companies table
char my_device_id[40];    // UUID from Supabase embeddeds table
char my_passkey[18];
static char my_srv_url[128] = {0};  // Backend server URL for OTA downloads

// MDB address — initialised from Kconfig, overridden by NVS at boot
static uint8_t cashless_device_address = CONFIG_CASHLESS_DEVICE_ADDRESS;
#ifdef CONFIG_MDB_SNIFF_OTHER_CASHLESS
static uint8_t mdb_sniff_address = CONFIG_MDB_SNIFF_ADDRESS;
#endif

// Defining MDB commands as an enum
enum MDB_COMMAND_FLOW {
	RESET       = 0x00,
	SETUP       = 0x01,
	POLL        = 0x02,
	VEND        = 0x03,
	READER      = 0x04,
	EXPANSION   = 0x07
};

// Defining MDB setup flow
enum MDB_SETUP_FLOW {
	CONFIG_DATA = 0x00, MAX_MIN_PRICES = 0x01
};

// Defining MDB vending flow
enum MDB_VEND_FLOW {
	VEND_REQUEST        = 0x00,
	VEND_CANCEL         = 0x01,
	VEND_SUCCESS        = 0x02,
	VEND_FAILURE        = 0x03,
	SESSION_COMPLETE    = 0x04,
	CASH_SALE           = 0x05
};

// Defining MDB reader flow
enum MDB_READER_FLOW {
	READER_DISABLE  = 0x00,
	READER_ENABLE   = 0x01,
	READER_CANCEL   = 0x02
};

// Defining MDB expansion flow
enum MDB_EXPANSION_FLOW {
	REQUEST_ID = 0x00, DIAGNOSTICS = 0xFF
};

// Defining machine states
typedef enum MACHINE_STATE {
	INACTIVE_STATE, DISABLED_STATE, ENABLED_STATE, IDLE_STATE, VEND_STATE
} machine_state_t;

machine_state_t machine_state = INACTIVE_STATE; // Initial machine state

led_strip_handle_t led_strip;

// MDB Control flags
bool session_begin_todo = false;
bool session_cancel_todo = false;
bool session_end_todo = false;
bool vend_approved_todo = false;
bool vend_denied_todo = false;
bool cashless_reset_todo = true;
bool out_of_sequence_todo = false;

// Restart tracking: saved to NVS before esp_restart(), read at boot and published via MQTT
static const char *pending_restart_reason = NULL;  // set at boot if NVS contains a reason
static uint32_t pending_restart_uptime = 0;
static const char *pending_restart_hw = NULL;
static bool restart_info_published = false;

// Save restart reason + current uptime to NVS, then call esp_restart().
// reason must be a string literal (not freed).
//
// On cellular boards we ALSO cycle the modem power before rebooting.
// Without this, the modem stays in whatever state the previous session
// left it (PPP DATA mode + internal CNACT bearer up after the claim
// flow), and the next boot's PPP fails IPCP — recovery ladder then
// burns 3-4 minutes. modem_kick_for_host_reboot is fire-and-forget
// (~1.5 s blocking), then ESP32 reboot proceeds in parallel with the
// modem's own boot.
static void tracked_restart(const char *reason) {
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, "restart_reason", reason);
        uint32_t uptime_sec = (uint32_t)(esp_timer_get_time() / 1000000ULL);
        nvs_set_u32(h, "last_uptime", uptime_sec);
        nvs_commit(h);
        nvs_close(h);
    }
    ESP_LOGW(TAG, "Tracked restart: reason=%s", reason);

    /* Kick modem power if a modem is present so the next boot starts
     * with a cold-booted modem. modem_get_dce() returns NULL on WiFi-
     * only boards, in which case skip silently. */
    if (modem_get_dce() != NULL) {
        modem_kick_for_host_reboot();
    }

    vTaskDelay(pdMS_TO_TICKS(100));
    esp_restart();
}

static const char *reset_reason_str(esp_reset_reason_t r) {
    switch (r) {
        case ESP_RST_POWERON:   return "POWERON";
        case ESP_RST_SW:        return "SW_RESET";
        case ESP_RST_PANIC:     return "PANIC";
        case ESP_RST_INT_WDT:   return "INT_WDT";
        case ESP_RST_TASK_WDT:  return "TASK_WDT";
        case ESP_RST_WDT:       return "WDT";
        case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
        case ESP_RST_BROWNOUT:  return "BROWNOUT";
        case ESP_RST_SDIO:      return "SDIO";
        default:                return "UNKNOWN";
    }
}

// MDB diagnostics
static uint32_t mdb_poll_count = 0;
static uint32_t mdb_checksum_errors = 0;
static const char *mdb_last_cmd = "none";
static machine_state_t mdb_prev_state = INACTIVE_STATE;
static void publish_mdb_diag(void); // forward declaration

// Thread-safe MQTT publish wrapper — protects esp_mqtt_client_publish()
// which is called from multiple FreeRTOS tasks (MDB, BLE, timers, sale drain).
int mqtt_publish_safe(esp_mqtt_client_handle_t client, const char *topic,
                      const char *data, int len, int qos, int retain) {
    int msg_id = -1;
    if (mqtt_publish_mutex && xSemaphoreTake(mqtt_publish_mutex, pdMS_TO_TICKS(1000)) == pdTRUE) {
        msg_id = esp_mqtt_client_publish(client, topic, data, len, qos, retain);
        xSemaphoreGive(mqtt_publish_mutex);
    } else {
        ESP_LOGW("MQTT", "publish mutex timeout — skipping publish to %s", topic);
    }
    return msg_id;
}

static uint8_t vmc_feature_level = 1; // VMC feature level from SETUP (default Level 1)

// Spinlock for MDB bit-banging critical sections.
// Disables interrupts on Core 1 during bit sampling to prevent
// WiFi/MQTT/BLE tasks from disrupting the 9600-baud timing.
static portMUX_TYPE mdb_mux = portMUX_INITIALIZER_UNLOCKED;

static const char *machine_state_name(machine_state_t s) {
    switch (s) {
        case INACTIVE_STATE: return "INACTIVE";
        case DISABLED_STATE: return "DISABLED";
        case ENABLED_STATE:  return "ENABLED";
        case IDLE_STATE:     return "IDLE";
        case VEND_STATE:     return "VEND";
        default:             return "UNKNOWN";
    }
}

RingbufHandle_t dexRingbuf;

// MQTT client handle
esp_mqtt_client_handle_t mqttClient = NULL;

// Message queues for communication
static QueueHandle_t mdbSessionQueue = NULL;

// MQTT watchdog: forces reconnection if disconnected for too long.
// mqtt_started is only set to true by MQTT_EVENT_CONNECTED, so this
// detects both "never connected" and "lost connection" states.
// As a last resort, hard-reboots the device after extended offline.
//
// IMPORTANT: mqtt_last_connected_tick is NOT reset on the soft-reconnect
// path. The offline timer must keep counting from the actual last successful
// connect so the hard reboot threshold (MQTT_HARD_REBOOT_SEC) can trigger.
// Only MQTT_EVENT_CONNECTED resets this tick.
static void mqtt_watchdog_cb(void *arg) {
    if (!mqtt_started && mqtt_last_connected_tick > 0) {
        TickType_t offline_ticks = xTaskGetTickCount() - mqtt_last_connected_tick;
        uint32_t offline_sec = (offline_ticks * portTICK_PERIOD_MS) / 1000;

        if (offline_sec >= MQTT_HARD_REBOOT_SEC) {
            // Last resort: full reboot to recover from any corrupted state
            // (stale lwIP DNS cache, stuck MQTT client state, routing issues).
            ESP_LOGE(TAG, "MQTT watchdog: offline for %lus — HARD REBOOT", (unsigned long)offline_sec);
            tracked_restart("mqtt_watchdog");
        } else if (offline_sec >= MQTT_WATCHDOG_TIMEOUT_SEC) {
            // Force a fresh reconnect attempt. esp_mqtt_client_reconnect() is
            // the API Espressif provides for exactly this case — it tears
            // down the current transport (incl. TCP socket + DNS resolution)
            // and starts a new connect cycle. Unlike stop()+start() it is
            // safe to call mid-retry and does not leave the internal state
            // machine half-initialized.
            ESP_LOGW(TAG, "MQTT watchdog: offline for %lus — forcing reconnect", (unsigned long)offline_sec);
            esp_mqtt_client_reconnect(mqttClient);
            // DO NOT reset mqtt_last_connected_tick here — otherwise the
            // hard reboot path can never be reached while the broker stays
            // unreachable.
        }
    }
}

uint16_t read_9(uint8_t *checksum) {

	uint16_t coming_read = 0;

	// Wait start bit (idle, interruptible — no timing constraint here)
	while (gpio_get_level(PIN_MDB_RX))
		;

	// Enter critical section: disable interrupts on this core so that
	// WiFi/MQTT/BLE tasks cannot preempt the timing-sensitive bit sampling.
	// The critical section lasts ~1.1ms (11 bits at 9600 baud) which is safe
	// for the interrupt watchdog (timeout >> 1ms) and only affects Core 1.
	portENTER_CRITICAL(&mdb_mux);

	ets_delay_us(104);

	ets_delay_us(52);
	for(int x = 0; x < 9; x++){
		coming_read |= (gpio_get_level(PIN_MDB_RX) << x);
		ets_delay_us(104); // 9600bps
	}

	portEXIT_CRITICAL(&mdb_mux);

	if (checksum)
		*checksum += coming_read;

	return coming_read;
}

// Timed version of read_9: returns -1 if no start bit arrives within timeout_us.
// Used to drain remaining bytes from the bus after unrecognized commands.
int32_t read_9_timeout(uint8_t *checksum, uint32_t timeout_us) {

	uint16_t coming_read = 0;

	// Wait for start bit with timeout (idle, interruptible)
	uint32_t waited = 0;
	while (gpio_get_level(PIN_MDB_RX)) {
		ets_delay_us(10);
		waited += 10;
		if (waited >= timeout_us) return -1; // no data arrived
	}

	// Critical section for bit sampling (same as read_9)
	portENTER_CRITICAL(&mdb_mux);

	ets_delay_us(104);

	ets_delay_us(52);
	for (int x = 0; x < 9; x++) {
		coming_read |= (gpio_get_level(PIN_MDB_RX) << x);
		ets_delay_us(104);
	}

	portEXIT_CRITICAL(&mdb_mux);

	if (checksum)
		*checksum += coming_read;

	return (int32_t) coming_read;
}

void write_9(uint16_t nth9) {

	portENTER_CRITICAL(&mdb_mux);

    gpio_set_level(PIN_MDB_TX, 0);  // Start bit
    ets_delay_us(104); // 9600bps

	for (uint8_t x = 0; x < 9; x++) {

		gpio_set_level(PIN_MDB_TX, (nth9 >> x) & 1);
		ets_delay_us(104); // 9600bps
	}

    gpio_set_level(PIN_MDB_TX, 1);  // Stop bit
    ets_delay_us(104); // 9600bps

	portEXIT_CRITICAL(&mdb_mux);
}

// Function to transmit the payload via bit-banging (using MDB protocol)
// Switches TX pin to output for the entire payload, then back to high-Z.
// The outer critical section keeps interrupts disabled for the entire
// response — write_9's inner portENTER/EXIT_CRITICAL nests harmlessly.
// Without this, WiFi/MQTT interrupts firing between bytes can stretch
// inter-byte gaps beyond the VMC's tolerance, causing checksum errors
// (NAK) on longer responses like REQUEST_ID (30+ bytes ≈ 32ms).
void write_payload_9(uint8_t *mdb_payload, uint8_t length) {

	gpio_set_direction(PIN_MDB_TX, GPIO_MODE_OUTPUT);
	gpio_set_level(PIN_MDB_TX, 1);  // idle HIGH before first start bit

	uint8_t checksum = 0x00;

	portENTER_CRITICAL(&mdb_mux);

	// Calculate checksum
	for (int x = 0; x < length; x++) {

		checksum += mdb_payload[x];
		write_9(mdb_payload[x]);
	}

	// CHK* ACK*
	write_9(BIT_MODE_SET | checksum);

	portEXIT_CRITICAL(&mdb_mux);

	// Release the bus — back to high-Z so we don't interfere with other peripherals
	gpio_set_direction(PIN_MDB_TX, GPIO_MODE_INPUT);
}

void xorEncodeWithPasskey(uint8_t cmd, uint16_t itemPrice, uint16_t itemNumber, uint16_t paxCounter, uint8_t *payload);
uint8_t xorDecodeWithPasskey(uint16_t *itemPrice, uint16_t *itemNumber, uint8_t *payload);

// Drain any remaining bytes from the MDB bus after a checksum error or
// unrecognized command to prevent desynchronization. Reads until the bus
// is idle for 5ms (no more bytes) or a new address byte (mode bit) arrives.
static void mdb_drain_bus(void) {
	for (uint8_t i = 0; i < 36; i++) {
		int32_t b = read_9_timeout(NULL, 1500);
		if (b < 0) break;           // bus idle
		if (b & BIT_MODE_SET) break; // next command starting
	}
}

// Main MDB loop function
void vTaskMdbEvent(void *pvParameters) {

	ESP_LOGW(TAG, "MDB TASK: starting, cashless_addr=0x%02X (%s)",
		cashless_device_address,
		cashless_device_address == 16 ? "Cashless #1" : "Cashless #2");

	time_t session_begin_time = 0;
	time_t vend_request_time = 0;

	uint16_t fundsAvailable = 0;
	uint16_t itemPrice = 0;
	uint16_t itemNumber = 0;

	// Payload buffer and available transmission flag
	uint8_t mdb_payload[36];
	uint8_t available_tx = 0;

	// Retransmit buffer: stores the last transmitted response so that
	// RET/NAK requests from the VMC can be served without rebuilding.
	uint8_t last_tx_payload[36];
	uint8_t last_tx_len = 0;

#ifdef CONFIG_MDB_SNIFF_OTHER_CASHLESS
	// State for passively sniffed Cashless Device #2 (e.g. Nayax credit card terminal)
	uint16_t sniff_itemPrice = 0;
	uint16_t sniff_itemNumber = 0;
#endif

	for (;;) {

		// In the MDB (Multi-Drop Bus) protocol, the last byte of a command or data packet is a checksum.
		uint8_t checksum = 0x00;

		// Read from MDB and check if the mode bit is set
		uint16_t coming_read = read_9(&checksum);

		if (coming_read & BIT_MODE_SET) {

			if ((uint8_t) coming_read == ACK) {
				// VMC confirmed receipt — clear retransmit buffer
				last_tx_len = 0;
			} else if ((uint8_t) coming_read == RET && last_tx_len > 0) {
				// VMC requests retransmit of last response.
				// Only act if we actually sent something recently (last_tx_len > 0).
				// This prevents spurious retransmits triggered by other peripherals'
				// checksum bytes that happen to equal 0xAA on the shared bus.
				ets_delay_us(200);
				write_payload_9(last_tx_payload, last_tx_len);
				ESP_LOGW(TAG, "MDB RET: retransmitted %d bytes", last_tx_len);
			} else if ((uint8_t) coming_read == NAK && last_tx_len > 0) {
				// VMC received response with checksum error — retransmit.
				ets_delay_us(200);
				write_payload_9(last_tx_payload, last_tx_len);
				ESP_LOGW(TAG, "MDB NAK: retransmitted %d bytes", last_tx_len);
			} else {
				// Any other byte with mode-bit set is an address byte for
				// some device on the bus. This means the VMC has moved on
				// from our last exchange — clear the retransmit buffer so
				// that subsequent peripheral checksum bytes (which also have
				// the mode bit set) can never trigger a spurious retransmit.
				last_tx_len = 0;

				if ((coming_read & BIT_ADD_SET) == cashless_device_address) {

				// Reset transmission availability
				available_tx = 0;

				// Command decoding based on incoming data
				switch (coming_read & BIT_CMD_SET) {

				case RESET: {

                    if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

                    // Reset during VEND_STATE is interpreted as VEND_SUCCESS

					cashless_reset_todo = true;
					machine_state = INACTIVE_STATE;
					vmc_feature_level = 1;
					mdb_last_cmd = "RESET";

					// Clear all stale control flags to prevent out-of-context
					// responses after the JUST RESET reply
					session_begin_todo = false;
					session_cancel_todo = false;
					session_end_todo = false;
					vend_approved_todo = false;
					vend_denied_todo = false;
					out_of_sequence_todo = false;

					// Flush any pending credit from the queue
					uint16_t discarded;
					while (xQueueReceive(mdbSessionQueue, &discarded, 0) == pdTRUE) {}

                    xEventGroupClearBits(xLedEventGroup, BIT_EVT_MDB);
                    xEventGroupSetBits(xLedEventGroup, BIT_EVT_TRIGGER);

					ESP_LOGI( TAG, "RESET");
					break;
				}
				case SETUP: {
					switch (read_9(&checksum)) {

					case CONFIG_DATA: {
						uint8_t vmcFeatureLevel = read_9(&checksum);
						uint8_t vmcColumnsOnDisplay = read_9(&checksum);
						uint8_t vmcRowsOnDisplay = read_9(&checksum);
						uint8_t vmcDisplayInfo = read_9(&checksum);

						(void) vmcDisplayInfo;
						(void) vmcRowsOnDisplay;
						(void) vmcColumnsOnDisplay;

                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						// Only trust vmcFeatureLevel after the checksum has verified — otherwise
						// a bit-flipped byte could persistently set a wrong level until the next
						// SETUP cycle, causing the firmware to send a 10-byte Level 2/3
						// BEGIN_SESSION to a Level 1 VMC (protocol desync).
						// Store actual VMC level for logging, but always declare Level 1
						// for peripheral responses. Level 3 was introduced in c7d2bca but
						// breaks SandenVendo VMCs (and possibly others): the VMC sends
						// Level 1 REQUEST_ID format despite reporting L3, rejects our L3
						// Peripheral ID, and doesn't display credit from L3 BEGIN_SESSION.
						// Original Level 1 code (pre-c7d2bca) worked with send-credit.
						uint8_t vmc_reported_level = vmcFeatureLevel > 0 ? vmcFeatureLevel : 1;
						vmc_feature_level = 1;

						machine_state = DISABLED_STATE;
						mdb_last_cmd = "SETUP:CONFIG_DATA";

                        mdb_payload[0] = 0x01;                                  // Reader Config Data
                        mdb_payload[1] = 0x01;                                  // Reader Feature Level 1
						mdb_payload[2] = CONFIG_MDB_CURRENCY_CODE >> 8;         // Country Code High
						mdb_payload[3] = CONFIG_MDB_CURRENCY_CODE & 0xff;       // Country Code Low
						mdb_payload[4] = CONFIG_MDB_SCALE_FACTOR;               // Scale Factor
						mdb_payload[5] = CONFIG_MDB_DECIMAL_PLACES;             // Decimal Places
						mdb_payload[6] = 3;                                     // Maximum Response Time (5s)
						mdb_payload[7] = 0b00001001;                            // Miscellaneous Options
						available_tx = 8;

						// idf.py menuconfig -> "MDB Cashless Device"

						ESP_LOGI( TAG, "CONFIG_DATA (vmcLevel=%u, ourLevel=1, cols=%u, rows=%u)", vmc_reported_level, vmcColumnsOnDisplay, vmcRowsOnDisplay);
						break;
					}
					case MAX_MIN_PRICES: {

						uint16_t maxPrice = (read_9(&checksum) << 8) | read_9(&checksum);
						uint16_t minPrice = (read_9(&checksum) << 8) | read_9(&checksum);

						(void) maxPrice;
						(void) minPrice;

                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "SETUP:MAX_MIN_PRICES";
						ESP_LOGI( TAG, "MAX_MIN_PRICES");
						break;
					}
					default: {
						mdb_drain_bus();
						mdb_last_cmd = "SETUP:UNKNOWN";
						ESP_LOGW(TAG, "SETUP: unhandled subcommand, drained bus");
						break;
					}
					}

					break;
				}
				case POLL: {

				    if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

					mdb_poll_count++;

					// Log and publish state changes immediately
					if (machine_state != mdb_prev_state) {
						ESP_LOGW(TAG, "MDB STATE: %s -> %s (polls=%lu, chkErr=%lu)",
							machine_state_name(mdb_prev_state), machine_state_name(machine_state),
							mdb_poll_count, mdb_checksum_errors);
						mdb_prev_state = machine_state;
						publish_mdb_diag();
					}

					// Periodic log every 500 polls (~every 50s at typical VMC rate)
					if (mdb_poll_count % 500 == 0) {
						ESP_LOGI(TAG, "MDB DIAG: state=%s addr=0x%02X polls=%lu chkErr=%lu lastCmd=%s vmcLevel=%u",
							machine_state_name(machine_state), cashless_device_address,
							mdb_poll_count, mdb_checksum_errors, mdb_last_cmd, vmc_feature_level);
					}

					if (cashless_reset_todo) {
						// Just reset
						cashless_reset_todo = false;
						mdb_payload[0] = 0x00;
						available_tx = 1;

					} else if (machine_state == ENABLED_STATE && xQueueReceive(mdbSessionQueue, &fundsAvailable, 0)) {
						// Begin session
						session_begin_todo = false;

						machine_state = IDLE_STATE;

						mdb_payload[0] = 0x03;

						if (vmc_feature_level >= 3) {
							// Level 3: 32-bit Funds Available + Media ID + Payment Type +
							// Payment Data + User Language + User Currency Code.
							// Per MDB/ICP 4.2 section 7.4, Level 3 Begin Session:
							//   Z2-Z5  = Funds Available (32-bit scaled)
							//   Z6-Z9  = Payment Media ID (0xFFFFFFFF = unknown)
							//   Z10    = Payment Type (0x00 = normal vend, VMC default prices)
							//   Z11-12 = Payment Data (0xFFFF = not applicable for sub-type 0)
							//   Z13-14 = User Language (0xFFFF = no preference)
							//   Z15-16 = User Currency Code (0xFFFF = no preference)
							mdb_payload[1] = 0x00;                          // Funds (32-bit MSB)
							mdb_payload[2] = 0x00;
							mdb_payload[3] = fundsAvailable >> 8;
							mdb_payload[4] = fundsAvailable & 0xFF;
							mdb_payload[5] = 0xFF;                          // Media ID (unknown)
							mdb_payload[6] = 0xFF;
							mdb_payload[7] = 0xFF;
							mdb_payload[8] = 0xFF;
							mdb_payload[9] = 0x00;                          // Payment Type (normal vend)
							mdb_payload[10] = 0x00;                         // Payment Data (n/a for type 0)
							mdb_payload[11] = 0x00;
							mdb_payload[12] = 0x00;                         // User Language (no preference)
							mdb_payload[13] = 0x00;
							mdb_payload[14] = 0x00;                         // User Currency Code (no preference)
							mdb_payload[15] = 0x00;
							available_tx = 16;
						} else if (vmc_feature_level >= 2) {
							// Level 2: 16-bit Funds Available + Media ID + Payment Type + Payment Data.
							// Per MDB/ICP 4.2 section 7.4, Level 2 Begin Session:
							//   Z2-Z3  = Funds Available (16-bit scaled)
							//   Z4-Z7  = Payment Media ID (0xFFFFFFFF = unknown)
							//   Z8     = Payment Type (0x00 = normal vend, VMC default prices)
							//   Z9-Z10 = Payment Data (0xFFFF = not applicable for sub-type 0)
							mdb_payload[1] = fundsAvailable >> 8;
							mdb_payload[2] = fundsAvailable & 0xFF;
							mdb_payload[3] = 0xFF;                          // Media ID (unknown)
							mdb_payload[4] = 0xFF;
							mdb_payload[5] = 0xFF;
							mdb_payload[6] = 0xFF;
							mdb_payload[7] = 0x00;                          // Payment Type
							mdb_payload[8] = 0xFF;                          // Payment Data (n/a)
							mdb_payload[9] = 0xFF;
							available_tx = 10;
						} else {
							// Level 1: just Funds Available (16-bit)
							mdb_payload[1] = fundsAvailable >> 8;
							mdb_payload[2] = fundsAvailable & 0xFF;
							available_tx = 3;
						}

						time( &session_begin_time);

						ESP_LOGI(TAG, "BEGIN_SESSION: funds=%u level=%u bytes=%d",
							fundsAvailable, vmc_feature_level, available_tx);

					} else if (session_cancel_todo) {
						// Cancel session
						session_cancel_todo = false;

						mdb_payload[0] = 0x04;
						available_tx = 1;

					} else if (vend_approved_todo) {
						// Vend approved
						vend_approved_todo = false;

						mdb_payload[0] = 0x05;
						if (vmc_feature_level >= 3) {
							// Level 3: 32-bit Vend Amount
							mdb_payload[1] = 0x00;
							mdb_payload[2] = 0x00;
							mdb_payload[3] = itemPrice >> 8;
							mdb_payload[4] = itemPrice & 0xFF;
							available_tx = 5;
						} else {
							// Level 1/2: 16-bit Vend Amount
							mdb_payload[1] = itemPrice >> 8;
							mdb_payload[2] = itemPrice & 0xFF;
							available_tx = 3;
						}

					} else if (vend_denied_todo) {
						// Vend denied
						vend_denied_todo = false;

						mdb_payload[0] = 0x06;
						available_tx = 1;
						machine_state = IDLE_STATE;

					} else if (session_end_todo) {
						// End session
						session_end_todo = false;

						mdb_payload[0] = 0x07;
						available_tx = 1;
						machine_state = ENABLED_STATE;

					} else if (out_of_sequence_todo) {
						// Command out of sequence
						out_of_sequence_todo = false;

						mdb_payload[0] = 0x0b;
						available_tx = 1;

					} else {

						time_t now = time(NULL);

						// Vend timeout: deny if no approval/denial within 30s
						// Prevents machine from hanging in VEND_STATE (display stuck on credit,
						// bill acceptor disabled) when BLE/MQTT approval never arrives.
						if (machine_state == VEND_STATE && (now - vend_request_time) > 30) {
							ESP_LOGW(TAG, "VEND TIMEOUT: no approval after 30s, denying");
							vend_denied_todo = true;
						}

						// Session timeout: cancel idle sessions after 60s
						// (VEND_STATE is handled by the vend timeout above)
						if (machine_state >= IDLE_STATE && machine_state != VEND_STATE && (now - session_begin_time) > 60) {
							session_cancel_todo = true;
						}
					}

					break;
				}
				case VEND: {
					switch (read_9(&checksum)) {
					case VEND_REQUEST: {

						itemPrice = (read_9(&checksum) << 8) | read_9(&checksum);
						itemNumber = (read_9(&checksum) << 8) | read_9(&checksum);

                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						machine_state = VEND_STATE;
						mdb_last_cmd = "VEND_REQUEST";
						time(&vend_request_time);

                        if(fundsAvailable && (fundsAvailable != 0xffff)){

                            if (itemPrice <= fundsAvailable) {
                                vend_approved_todo = true;
                            } else {
                                vend_denied_todo = true;
                            }
                        }

						/* PIPE_BLE */
						uint8_t payload[19];
						xorEncodeWithPasskey(0x0a, itemPrice, itemNumber, 0, (uint8_t*) &payload);

                        ble_notify_send((char*) &payload, sizeof(payload));

						ESP_LOGI( TAG, "VEND_REQUEST");
						break;
					}
					case VEND_CANCEL: {
                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "VEND_CANCEL";
						vend_denied_todo = true;
						break;
					}
					case VEND_SUCCESS: {

						itemNumber = (read_9(&checksum) << 8) | read_9(&checksum);

                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "VEND_SUCCESS";

						// Guard: only publish sale if we are in VEND_STATE.
						// VMC retransmissions or bus noise can deliver duplicate
						// VEND_SUCCESS commands — without this check each one would
						// publish a separate sale to MQTT.
						if (machine_state != VEND_STATE) {
						    ESP_LOGW(TAG, "VEND_SUCCESS received outside VEND_STATE (state=%d) — skipping sale publish", machine_state);
						    // Still transition to IDLE in case the VMC expects it,
						    // but do NOT publish a duplicate sale.
						    machine_state = IDLE_STATE;
						    break;
						}

						// Guard: reject if itemPrice is 0 (should never happen in
						// normal operation since VEND_REQUEST sets it, but protects
						// against unexpected state).
						if (itemPrice == 0) {
						    ESP_LOGW(TAG, "VEND_SUCCESS ignored — itemPrice is 0");
						    machine_state = IDLE_STATE;
						    break;
						}

						machine_state = IDLE_STATE;

						/* PIPE_BLE — immediate notify to companion app */
						uint8_t payload_ble[19];
						xorEncodeWithPasskey(0x0b, itemPrice, itemNumber, 0, (uint8_t*) &payload_ble);

                        ble_notify_send((char*) &payload_ble, sizeof(payload_ble));

						/* PIPE_MQTT — persist to NVS-backed queue BEFORE responding
						 * to the VMC.  Even a crash or power-loss after this point
						 * leaves the sale durably recorded; the drain task will
						 * publish it (or re-publish after reboot) with broker QoS 1
						 * + backend idempotency protecting against duplicates.
						 *
						 * Fallback: if the queue is unavailable (NVS error, init
						 * failure, or capacity exhausted) fall back to the legacy
						 * direct-publish path so behaviour never degrades below
						 * the pre-queue firmware. */
						if (!sale_queue_enqueue(0x24, itemPrice, itemNumber)) {
							uint8_t payload_mqtt[19];
							xorEncodeWithPasskey(0x24, itemPrice, itemNumber, 0, (uint8_t*) &payload_mqtt);
							char topic_sale[128];
							snprintf(topic_sale, sizeof(topic_sale), "/%s/%s/sale", my_company_id, my_device_id);
							mqtt_publish_safe(mqttClient, topic_sale, (char*) &payload_mqtt, sizeof(payload_mqtt), 1, 0);
							ESP_LOGW(TAG, "sale_queue fallback: direct publish (v1) for VEND_SUCCESS");
						}

						ESP_LOGI( TAG, "VEND_SUCCESS price=%u item=%u", itemPrice, itemNumber);

						// Clear vend data to prevent stale values if re-entered
						itemPrice = 0;
						itemNumber = 0;

						break;
					}
					case VEND_FAILURE: {
                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "VEND_FAILURE";

						if (machine_state != VEND_STATE) {
						    ESP_LOGW(TAG, "VEND_FAILURE ignored — not in VEND_STATE (state=%d)", machine_state);
						    break;
						}

						machine_state = IDLE_STATE;

					    /* PIPE_BLE */
						uint8_t payload[19];
						xorEncodeWithPasskey(0x0c, itemPrice, itemNumber, 0, (uint8_t*) &payload);

                        ble_notify_send((char*) &payload, sizeof(payload));
						break;
					}
					case SESSION_COMPLETE: {
                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "SESSION_COMPLETE";
						session_end_todo = true;

			            /* PIPE_BLE */
						uint8_t payload[19];
						xorEncodeWithPasskey(0x0d, itemPrice, itemNumber, 0, (uint8_t*) &payload);

                        ble_notify_send((char*) &payload, sizeof(payload));

						ESP_LOGI( TAG, "SESSION_COMPLETE");
						break;
					}
					case CASH_SALE: {

						uint16_t itemPrice = (read_9(&checksum) << 8) | read_9(&checksum);
						uint16_t itemNumber = (read_9(&checksum) << 8) | read_9(&checksum);

						if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "CASH_SALE";

                        /* Persistent queue handles publish + retry — see VEND_SUCCESS */
                        if (!sale_queue_enqueue(0x21, itemPrice, itemNumber)) {
                            uint8_t payload[19];
                            xorEncodeWithPasskey(0x21, itemPrice, itemNumber, 0, (uint8_t*) &payload);
                            char topic[128];
                            snprintf(topic, sizeof(topic), "/%s/%s/sale", my_company_id, my_device_id);
                            mqtt_publish_safe(mqttClient, topic, (char*) &payload, sizeof(payload), 1, 0);
                            ESP_LOGW(TAG, "sale_queue fallback: direct publish (v1) for CASH_SALE");
                        }

                        ESP_LOGI( TAG, "CASH_SALE");
						break;
					}
					default: {
						mdb_drain_bus();
						mdb_last_cmd = "VEND:UNKNOWN";
						ESP_LOGW(TAG, "VEND: unhandled subcommand, drained bus");
						break;
					}
					}

					break;
				}
				case READER: {
					switch (read_9(&checksum)) {
					case READER_DISABLE: {
                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						machine_state = DISABLED_STATE;
						mdb_last_cmd = "READER_DISABLE";

                        xEventGroupClearBits(xLedEventGroup, BIT_EVT_MDB);
                        xEventGroupSetBits(xLedEventGroup, BIT_EVT_TRIGGER);

						break;
					}
					case READER_ENABLE: {
                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						machine_state = ENABLED_STATE;
						mdb_last_cmd = "READER_ENABLE";

                        xEventGroupSetBits(xLedEventGroup, BIT_EVT_MDB | BIT_EVT_TRIGGER);

						break;
					}
					case READER_CANCEL: {
                        if (read_9(NULL) != checksum) { mdb_checksum_errors++; mdb_drain_bus(); continue; }

						mdb_last_cmd = "READER_CANCEL";
						mdb_payload[ 0 ] = 0x08; // Canceled
						available_tx = 1;

						ESP_LOGI( TAG, "READER_CANCEL");
						break;
					}
					default: {
						mdb_drain_bus();
						mdb_last_cmd = "READER:UNKNOWN";
						ESP_LOGW(TAG, "READER: unhandled subcommand, drained bus");
						break;
					}
					}

					break;
				}
				case EXPANSION: {

					uint8_t exp_sub = read_9(&checksum);
					switch (exp_sub) {
					case REQUEST_ID: {
                        // SandenVendo rejects our Peripheral ID response regardless of
                        // Level 1 or 2+ format (retry 5x → RESET). The original firmware
                        // (pre-c7d2bca) had the same issue: the checksum read consumed a
                        // wrong byte because of Level 1/3 format mismatch, so the device
                        // never responded. The VMC gave up and moved on to
                        // OPTIONAL_FEATURE_ENABLED → READER_ENABLE, which worked.
                        // Replicate that behavior: drain without responding (NAK).
                        mdb_drain_bus();
                        mdb_last_cmd = "EXPANSION:REQUEST_ID";
                        ESP_LOGI(TAG, "REQUEST_ID: drain (VMC will skip after retries)");
                        continue;  // skip response — `continue` not `break`!
					}
					case 0x04: {
						// OPTIONAL_FEATURE_ENABLED — VMC tells us which optional features
						// it supports. Standard format: 4 bytes of feature bits + checksum.
						// Note: VMC→Peripheral checksum does NOT have mode bit set,
						// so we must read a fixed byte count, not scan for mode bit.
						for (uint8_t x = 0; x < 4; x++) read_9(&checksum);

						if (read_9(NULL) != checksum) {
							mdb_checksum_errors++;
							ESP_LOGW(TAG, "EXPANSION:OPT_FEATURE checksum FAIL");
							mdb_drain_bus();
							continue;
						}

						mdb_last_cmd = "EXPANSION:OPT_FEATURE";
						ESP_LOGI(TAG, "OPTIONAL_FEATURE_ENABLED");
						// ACK with no data (available_tx stays 0)
						break;
					}
					default: {
						// Unknown EXPANSION subcommand — drain remaining bytes until
						// bus goes idle to prevent desynchronization.
						mdb_drain_bus();
						mdb_last_cmd = "EXPANSION:UNKNOWN";
						ESP_LOGW(TAG, "EXPANSION: unhandled subcommand 0x%02X, drained bus", exp_sub);
						break;
					}
					}

					break;
				}
				}

				// Inter-frame gap: let bus settle before responding
				ets_delay_us(200);

				// Transmit the prepared payload via bit-banging
				write_payload_9((uint8_t*) &mdb_payload, available_tx);

				// Store transmitted payload for RET/NAK retransmission
				if (available_tx > 0) {
					memcpy(last_tx_payload, mdb_payload, available_tx);
					last_tx_len = available_tx;
				}

			}
#ifdef CONFIG_MDB_SNIFF_OTHER_CASHLESS
			else if ((coming_read & BIT_ADD_SET) == mdb_sniff_address) {

				// Passively sniff Cashless Device #2 traffic (read-only, never transmit)
				switch (coming_read & BIT_CMD_SET) {
				case VEND: {
					uint8_t checksum_sniff = 0x00;
					checksum_sniff += coming_read;
					switch (read_9(&checksum_sniff)) {
					case VEND_REQUEST: {
						sniff_itemPrice = (read_9(&checksum_sniff) << 8) | read_9(&checksum_sniff);
						sniff_itemNumber = (read_9(&checksum_sniff) << 8) | read_9(&checksum_sniff);
						if (read_9(NULL) != checksum_sniff) continue;
						ESP_LOGI(TAG, "SNIFF VEND_REQUEST price=%u item=%u", sniff_itemPrice, sniff_itemNumber);
						break;
					}
					case VEND_SUCCESS: {
						uint16_t sn = (read_9(&checksum_sniff) << 8) | read_9(&checksum_sniff);
						if (read_9(NULL) != checksum_sniff) continue;
						if (sn != 0xFFFF) sniff_itemNumber = sn;

						// Guard: only publish if we saw a VEND_REQUEST with a valid price.
						// The sniff path can miss VEND_REQUEST (checksum error, bus busy)
						// which leaves sniff_itemPrice at 0 — don't publish bogus sales.
						if (sniff_itemPrice == 0) {
						    ESP_LOGW(TAG, "SNIFF VEND_SUCCESS ignored — no prior VEND_REQUEST (price=0)");
						    break;
						}

						ESP_LOGI(TAG, "SNIFF CARD_SALE price=%u item=%u", sniff_itemPrice, sniff_itemNumber);

						/* Persistent queue handles publish + retry — see VEND_SUCCESS */
						if (!sale_queue_enqueue(0x23, sniff_itemPrice, sniff_itemNumber)) {
							uint8_t payload[19];
							xorEncodeWithPasskey(0x23, sniff_itemPrice, sniff_itemNumber, 0, (uint8_t*) &payload);
							char topic[128];
							snprintf(topic, sizeof(topic), "/%s/%s/sale", my_company_id, my_device_id);
							mqtt_publish_safe(mqttClient, topic, (char*) &payload, sizeof(payload), 1, 0);
							ESP_LOGW(TAG, "sale_queue fallback: direct publish (v1) for SNIFF CARD_SALE");
						}

						// Clear after enqueue to prevent stale data
						sniff_itemPrice = 0;
						sniff_itemNumber = 0;

						break;
					}
					default:
						break;
					}
					break;
				}
				default:
					break;
				}
			}
#endif
			else {
				// Not the intended address...
			}
			}
		}
	}
}

/*
 * 19-byte payload:
 * - Initially filled with random data (esp_fill_random)
 * - Fixed fields overwritten according to CMD semantics
 * - Payload XOR-obfuscated with provisioning/session key before TX
 *
 * Byte index →
 * +----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+
 * |CMD |VER |    ITEM_PRICE     |ITEM_NUMB|       TIME_SEC    |PAX_COUNT|     NOT_USED           |
 * +----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+
 *   0    1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16   17   18
 *
 * CMD (byte 0) – vmflow protocol opcode:
 *  BLE target <- client:
 *   0x00 SUBDOMAIN (device_id) | 0x01 PASSKEY (cipher_code) | 0x02 START_SESSION
 *   0x03 APPROVE_SESSION       | 0x04 CLOSE_SESSION
 *   0x06 WIFI_SSID             | 0x07 WIFI_PASSWORD
 *
 *  BLE target -> client:
 *   0x0A VEND_REQUEST | 0x0B VEND_SUCCESS | 0x0C VEND_FAILURE | 0x0D SESSION_COMPLETE
 *
 *  MQTT target <- server:
 *   0x20 CREDIT
 *
 *  MQTT target -> server:
 *   0x21 CASH_SALE | 0x22 PAX_COUNTER | 0x23 CARD_SALE | 0x24 CASHLESS_SALE
 *
 * [ random filler ] + [ structured fields per CMD ] → XOR → obfuscated payload
 */

// Decode payload from communication between BLE and MQTT
uint8_t xorDecodeWithPasskey(uint16_t *itemPrice, uint16_t *itemNumber, uint8_t *payload) {

	for(int x = 0; x < sizeof(my_passkey); x++){
		payload[x + 1] ^= my_passkey[x];
	}

	int p_len = sizeof(my_passkey) + 1;

	uint8_t chk = 0x00;
	for(int x= 0; x < p_len - 1; x++){
		chk += payload[x];
	}

    if(chk != payload[p_len - 1]){
        // Common causes: passkey in NVS differs from backend DB, or message
        // corrupted in transit. Without this log the message was silently
        // dropped and the device appeared unreachable for send-credit.
        ESP_LOGW(TAG, "xorDecode: checksum mismatch (cmd=0x%02x got=0x%02x expected=0x%02x)",
                 payload[0], payload[p_len - 1], chk);
        return 0;
    }

    int32_t timestamp = ((uint32_t) payload[8] << 24) |
						((uint32_t) payload[9] << 16) |
						((uint32_t) payload[10] << 8)  |
						((uint32_t) payload[11] << 0);

    time_t now = time(NULL);

    int32_t drift = (int32_t) now - timestamp;
    if( abs(drift) > 8 /*sec*/){
        // Common causes: SNTP hasn't synced yet after boot, clock drift,
        // or firewall blocks pool.ntp.org at the install site.
        ESP_LOGW(TAG, "xorDecode: timestamp out of window (cmd=0x%02x drift=%lds now=%lu msg=%lu)",
                 payload[0], (long) drift, (unsigned long)(uint32_t) now, (unsigned long)(uint32_t) timestamp);
        return 0;
    }

    int32_t itemPrice32 =   ((uint32_t) payload[2] << 24) |
                            ((uint32_t) payload[3] << 16) |
                            ((uint32_t) payload[4] << 8)  |
                            ((uint32_t) payload[5] << 0);

    if(itemPrice)
        *itemPrice = TO_SCALE_FACTOR( FROM_SCALE_FACTOR(itemPrice32, 1, 2), CONFIG_MDB_SCALE_FACTOR, CONFIG_MDB_DECIMAL_PLACES);

    if(itemNumber)
        *itemNumber = ((uint16_t) payload[6] << 8) | ((uint16_t) payload[7] << 0);

    return 1;
}

// Encode payload to communication between BLE and MQTT
void xorEncodeWithPasskey(uint8_t cmd, uint16_t itemPrice, uint16_t itemNumber, uint16_t paxCounter, uint8_t *payload) {

    uint32_t itemPrice32 = TO_SCALE_FACTOR( FROM_SCALE_FACTOR(itemPrice, CONFIG_MDB_SCALE_FACTOR, CONFIG_MDB_DECIMAL_PLACES), 1, 2);

	esp_fill_random(payload + 1, sizeof(my_passkey));

	time_t now = time(NULL);

    payload[0] = cmd;

	payload[1] = 0x01; 				// version v1
	payload[2] = itemPrice32 >> 24;	// itemPrice
    payload[3] = itemPrice32 >> 16;
	payload[4] = itemPrice32 >> 8;
	payload[5] = itemPrice32;
	payload[6] = itemNumber >> 8;	// itemNumber
	payload[7] = itemNumber;
	payload[8]  = now >> 24;		// time (sec)
	payload[9]  = now >> 16;
	payload[10] = now >> 8;
	payload[11] = now;
    payload[12] = paxCounter >> 8;	// paxCounter
	payload[13] = paxCounter;

	int p_len = sizeof(my_passkey) + 1;

	uint8_t chk = 0x00;
	for(int x= 0; x < p_len - 1; x++){
		chk += payload[x];
	}
	payload[p_len - 1] = chk;

	for(int x = 0; x < sizeof(my_passkey); x++){
		payload[x + 1] ^= my_passkey[x];
	}
}

char* calc_crc_16(uint16_t *pCrc, char *uData) {

	uint8_t data = *uData;

	for (uint8_t iBit = 0; iBit < 8; iBit++, data >>= 1) {

		if ((data ^ *pCrc) & 0x01) {

			*pCrc >>= 1;
			*pCrc ^= 0xA001;

		} else
			*pCrc >>= 1;
	}

	return uData;
}

void readTelemetryDEX() {

	uart_set_baudrate(UART_NUM_1, 9600);
    // uart_set_line_inverse(UART_NUM_1, UART_SIGNAL_RXD_INV | UART_SIGNAL_TXD_INV);

	// -------------------------------------- First Handshake --------------------------------------
	uint8_t data[32];

	// ENQ ->
	uart_write_bytes(UART_NUM_1, "\x05", 1);

	// DLE 0 <-
	uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
	if( data[0] != 0x10 || data[1] != '0' ) return;

	// DLE SOH ->
	uart_write_bytes(UART_NUM_1, "\x10\x01", 2);

	uint16_t crc = 0x0000;

	// Communication ID
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "1"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "2"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "3"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "4"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "5"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "6"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "7"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "8"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "9"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "0"), 1 );
	// Operation Request
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "R"), 1 );
	// Revision & Level
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "R"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "0"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "0"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "L"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "0"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "6"), 1 );

	uart_write_bytes( UART_NUM_1, "\x10", 1 );						// DLE
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x03"), 1 ); 	// ETX

	data[0] = crc % 256;
	data[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &data, 2 );

	// DLE 1 <-
	uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
	if( data[0] != 0x10 || data[1] != '1' ) return;

	// EOT ->
	uart_write_bytes(UART_NUM_1, "\x04", 1);

	// -------------------------------------- Second Handshake --------------------------------------

	// ENQ <-
	uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(100));
	if( data[0] != 0x05 ) return;

	// DLE 0 ->
	uart_write_bytes(UART_NUM_1, "\x10\x30", 2);

	// DLE SOH <-
	uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
	if( data[0] != 0x10 || data[1] != 0x01 ) return;

	// Response Code <-
	uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
	// Communication ID <-
	uart_read_bytes(UART_NUM_1, &data, 10, pdMS_TO_TICKS(100));
	// Revision & Level <-
	uart_read_bytes(UART_NUM_1, &data, 6, pdMS_TO_TICKS(100));

	// DLE ETX <-
	uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));
	if( data[0] != 0x10 || data[1] != 0x03 ) return;

	// CRC <-
	uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(100));

	// DLE 1 ->
	uart_write_bytes(UART_NUM_1, "\x10\x31", 2);

	// EOT <-
	uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(100));
	if( data[0] != 0x04 ) return;

	// -------------------------------------- Data transfer --------------------------------------

	// ENQ <-
	uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(100));
	if (data[0] != 0x05) return;

	uint8_t block = 0x00;
	for (;;) {

		data[0] = 0x10; 				// DLE
		data[1] = ('0' + (block++ & 1)); 	// '0'|'1' ->
		uart_write_bytes(UART_NUM_1, &data, 2);

		// DLE STX <-
		uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(200));
		if (data[0] != 0x10 || data[1] != 0x02) return;

		for (;;) {

			uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(200));
			if (data[0] == 0x10) { // DLE

				uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(200));

				if (data[0] == 0x17) { // ETB

					// <- CRC
					uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(200));

					break;

				} else if (data[0] == 0x03) { // ETX

					// CRC <-
					uart_read_bytes(UART_NUM_1, &data, 2, pdMS_TO_TICKS(200));

					data[0] = 0x10; 					// DLE
					data[1] = ('0' + (block++ & 0x01)); 	// '0'|'1' ->
					uart_write_bytes(UART_NUM_1, &data, 2);

					// EOT <-
					uart_read_bytes(UART_NUM_1, &data, 1, pdMS_TO_TICKS(200));

					return;
				}
			}

			xRingbufferSend(dexRingbuf, &data[0], 1, 0);
		}
	}
}

void readTelemetryDDCMP() {

	uart_set_baudrate(UART_NUM_1, 2400);
    // uart_set_line_inverse(UART_NUM_1, UART_SIGNAL_RXD_INV | UART_SIGNAL_TXD_INV);

	//-------------------------------------------------------
	uint8_t buffer_rx[1024];
	uint8_t seq_rr_ddcmp;
	uint8_t seq_xx_ddcmp = 0;
	uint32_t n_bytes_message;
	uint16_t crc = 0x0000;
	uint8_t last_package;

	uint8_t crc_[2];

	// start...
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x05"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x06"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // mbd
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 ); // sadd
	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 );

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
		return;

	if ((buffer_rx[0] != 0x05) || (buffer_rx[1] != 0x07)) {
		return;
	} // ...stack

	crc = 0x0000;

	// data message header...
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x81"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x10"), 1 ); // nn
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 ); // mm
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // rr
	++seq_xx_ddcmp;
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_xx_ddcmp), 1 ); // xx
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 ); // sadd
	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 );

	crc = 0x0000;
	// who are you...
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x77"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\xe0"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );

	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // security code
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );

	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // pass code
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );

	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 ); // date dd mm yy
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x70"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // time hh mm ss
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // u2
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 ); // u1
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x0c"), 1 ); // 0b-Maintenance 0c-Route Person

	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 );

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
		return;

	if ((buffer_rx[0] != 0x05) || (buffer_rx[1] != 0x01)) {
		return;
	} // ...ack

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
		return;

	if (buffer_rx[0] != 0x81) {
		return;
	} // ...data message header
//
	seq_rr_ddcmp = buffer_rx[4];
//
	n_bytes_message = ((buffer_rx[2] & 0x3f) * 256) + buffer_rx[1];
	n_bytes_message += 2; // crc16

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, n_bytes_message, pdMS_TO_TICKS(200)) != n_bytes_message)
		return;

//  if (buffer_rx[2] != 0x01) {
//    return;
//  } ...not rejected

	crc = 0x0000;

	// ack...
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x05"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_rr_ddcmp), 1 ); 	// rr
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 ); 					// sadd
	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 ); // Transmitiu ACK (05 01 40 01 00 01 B8 55)

	crc = 0x0000;

	// data message header...
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x81"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x09"), 1 ); 					// nn
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 ); 					// mm
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_rr_ddcmp), 1 ); 	// rr
	++seq_xx_ddcmp;
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_xx_ddcmp), 1 ); 	// xx
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 ); 					// sadd
	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 ); // Transmitiu DATA_HEADER (81 09 40 01 02 01 46 B0)

	crc = 0x0000;

	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x77"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\xE2"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x02"), 1 ); // security read list (Standard audit data is read without resetting the interim data. (Read only) )
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 ); // Transmitiu READ_DATA/Audit Collection List (77 E2 00 01 01 00 00 00 00 F0 72)

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
		return;

	if ((buffer_rx[0] != 0x05) || (buffer_rx[1] != 0x01)) {
		return;
	} // ...ack

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
		return;

	if (buffer_rx[0] != 0x81) {
		return;
	} // DATA HEADER

	seq_rr_ddcmp = buffer_rx[4];

	n_bytes_message = ((buffer_rx[2] & 0x3f) * 256) + buffer_rx[1];
	n_bytes_message += 2; // crc16

	if( uart_read_bytes(UART_NUM_1, &buffer_rx, n_bytes_message, pdMS_TO_TICKS(200)) != n_bytes_message)
		return;

	if (buffer_rx[2] != 0x01) {
		return;
	}

	crc = 0x0000;

	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x05"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_rr_ddcmp), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
	uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
	crc_[0] = crc % 256;
	crc_[1] = crc / 256;
	uart_write_bytes( UART_NUM_1, &crc_, 2 ); // Transmitiu ACK

	do {

		if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
			break;

		if (buffer_rx[0] != 0x81) {
			break;
		} // ...data header

		seq_rr_ddcmp = buffer_rx[4];
		last_package = buffer_rx[2] & 0x80;

		n_bytes_message = ((buffer_rx[2] & 0x3f) * 256) + buffer_rx[1];
		n_bytes_message += 2; // crc16

		if( uart_read_bytes(UART_NUM_1, &buffer_rx, n_bytes_message, pdMS_TO_TICKS(200)) != n_bytes_message)
			break;
		// ...data

		// Os dados recebidos são: 99 nn "audit dada" crc crc, ou seja, as informaões de audit estão da posição 2 do buffer_rx à posição n_bytes-3
		for (int x = 2; x < n_bytes_message - 2; x++)
			xRingbufferSend(dexRingbuf, &buffer_rx[x], 1, 0);

		crc = 0x0000;

		uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x05"), 1 );
		uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
		uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 );
		uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_rr_ddcmp), 1 );
		uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x00"), 1 );
		uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 );
		crc_[0] = crc % 256;
		crc_[1] = crc / 256;
		uart_write_bytes( UART_NUM_1, &crc_, 2 ); // Transmitiu ACK

		if (last_package) {

			crc = 0x0000;

			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x81"), 1 );
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x02"), 1 );					// nn
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x40"), 1 ); 					// mm
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, (char*) &seq_rr_ddcmp), 1 ); 	// rr
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x03"), 1 ); 					// xx
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x01"), 1 ); 					// sadd
			crc_[0] = crc % 256;
			crc_[1] = crc / 256;
			uart_write_bytes( UART_NUM_1, &crc_, 2 ); // Transmitiu DATA HEADER

			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x77"), 1 );
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\xFF"), 1 );
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\x67"), 1 );
			uart_write_bytes( UART_NUM_1, calc_crc_16(&crc, "\xB0"), 1 ); // Transmitiu FINIS

			if( uart_read_bytes(UART_NUM_1, &buffer_rx, 8, pdMS_TO_TICKS(200)) != 8)
				break;

			if ((buffer_rx[0] != 0x05) || (buffer_rx[1] != 0x01)) {
				break;
			} // ACK

			break;
		}

		vTaskDelay(pdMS_TO_TICKS(10)); // ticks para ms

	} while(1);
}

// One-shot FreeRTOS task for telemetry — needs its own stack because
// readTelemetryDDCMP() allocates 1 KB on the stack, which exceeds the
// esp_timer task's default ~3.5 KB.
static void telemetry_task(void *arg) {

	readTelemetryDDCMP();
	readTelemetryDEX();

	size_t dex_size;
	uint8_t *dex = (uint8_t*) xRingbufferReceive(dexRingbuf, &dex_size, 0);

	if (dex != NULL) {
		char topic[128];
		snprintf(topic, sizeof(topic), "/%s/%s/dex", my_company_id, my_device_id);

		// QoS 1: DEX snapshots feed sales reconciliation, so losing one means
		// a gap in the cross-check window. Broker session is persistent so
		// transient forwarder outages don't drop the audit.
		mqtt_publish_safe(mqttClient, topic, (char*) dex, dex_size, 1, 0);
		ESP_LOGI(TAG, "DEX telemetry published (%d bytes)", (int)dex_size);

		vRingbufferReturnItem(dexRingbuf, (void*) dex);
	} else {
		ESP_LOGW(TAG, "DEX telemetry: ring buffer empty, nothing to publish");
	}

	vTaskDelete(NULL);  // self-delete
}

// esp_timer callback — lightweight wrapper that spawns the heavy telemetry work
// in a dedicated task with sufficient stack.
static void requestTelemetryData(void *arg) {
	BaseType_t ret = xTaskCreate(telemetry_task, "dex_telem", 4096, NULL, 5, NULL);
	if (ret != pdPASS) {
		ESP_LOGE(TAG, "DEX telemetry: failed to create task");
	}
}

void vTaskBitEvent(void *pvParameters) {

    while(1){
        EventBits_t uxBits = xEventGroupWaitBits(xLedEventGroup, BIT_EVT_TRIGGER, pdTRUE, pdFALSE, portMAX_DELAY );

        if ((uxBits & MASK_EVT_INSTALLED) != MASK_EVT_INSTALLED) {
            led_strip_set_pixel(led_strip, 0, 80, 60, 0);   // Not installed := YELLOW
        } else if ((uxBits & BIT_EVT_MDB) && (uxBits & BIT_EVT_INTERNET)) {
            led_strip_set_pixel(led_strip, 0, 10, 80, 10);  // MDB & Internet := GREEN
        } else if (uxBits & BIT_EVT_MDB) {
            led_strip_set_pixel(led_strip, 0, 5, 15, 80);   // Only MDB := BLUE
        } else {
            led_strip_set_pixel(led_strip, 0, 80, 5, 5);    // Inactive/Disabled := RED
        }
        led_strip_refresh(led_strip);

        if(uxBits & BIT_EVT_BUZZER){

            gpio_set_level(PIN_BUZZER_PWR, 1);
            vTaskDelay(pdMS_TO_TICKS(1000));
            gpio_set_level(PIN_BUZZER_PWR, 0);

            xEventGroupClearBits(xLedEventGroup, BIT_EVT_BUZZER);
        }
    }
}

void ble_pax_event_handler(uint16_t devices_count){

    uint8_t payload[19];
    xorEncodeWithPasskey(0x22, 0, 0, devices_count, (uint8_t*) &payload);

    char topic[128];
    snprintf(topic, sizeof(topic), "/%s/%s/paxcounter", my_company_id, my_device_id);

    mqtt_publish_safe(mqttClient, topic, (char*) &payload, sizeof(payload), 1, 0);
}

void ble_event_handler(char *ble_payload) {

    printf("ble_event_handler %x\n", (uint8_t) ble_payload[0]);

	switch ( (uint8_t) ble_payload[0] ) {
    case 0x00: {
        nvs_handle_t handle;
		ESP_ERROR_CHECK( nvs_open("vmflow", NVS_READWRITE, &handle) );

		size_t s_len;
		if (nvs_get_str(handle, "device_id", NULL, &s_len) != ESP_OK) {

			strcpy((char*) &my_device_id, ble_payload + 1);

			ESP_ERROR_CHECK( nvs_set_str(handle, "device_id", (char*) &my_device_id) );
			ESP_ERROR_CHECK( nvs_commit(handle) );

			char myhost[64];
			snprintf(myhost, sizeof(myhost), "%s.vmflow.xyz", my_device_id);

			ble_set_device_name((char*) &myhost);

            xEventGroupSetBits(xLedEventGroup, BIT_EVT_DOMAIN | BIT_EVT_TRIGGER);

			ESP_LOGI( TAG, "HOST= %s", myhost);
		}
		nvs_close(handle);
		break;
    }
    case 0x01: {
        nvs_handle_t handle;
		ESP_ERROR_CHECK( nvs_open("vmflow", NVS_READWRITE, &handle) );

		size_t s_len;
		if (nvs_get_str(handle, "passkey", NULL, &s_len) != ESP_OK) {

			strcpy((char*) &my_passkey, ble_payload + 1);

			ESP_ERROR_CHECK( nvs_set_str(handle, "passkey", (char*) &my_passkey) );
			ESP_ERROR_CHECK( nvs_commit(handle) );

            xEventGroupSetBits(xLedEventGroup, BIT_EVT_PSSKEY | BIT_EVT_TRIGGER);

			ESP_LOGI( TAG, "PASSKEY= %s", my_passkey);
		}
		nvs_close(handle);

        break;
    }
    case 0x02: /*Starting a vending session*/
        uint16_t fundsAvailable = 0xffff;
		xQueueSend(mdbSessionQueue, &fundsAvailable, 0 /*if full, do not wait*/);
		break;
	case 0x03: /*Approve the vending session*/

        if(xorDecodeWithPasskey(NULL, NULL, (uint8_t*) ble_payload)){
            vend_approved_todo = (machine_state == VEND_STATE) ? true : false;
        }
        break;
    case 0x04: /*Close the vending session*/
        if (machine_state == VEND_STATE) {
            vend_denied_todo = true; // must deny vend before cancelling session
        } else if (machine_state >= IDLE_STATE) {
            session_cancel_todo = true;
        }
        break;
    case 0x05:
        // Not implemented
        break;
    case 0x06: {
        esp_wifi_disconnect();

		wifi_config_t wifi_config = {0};
		esp_wifi_get_config(WIFI_IF_STA, &wifi_config);

		strcpy((char*) wifi_config.sta.ssid, ble_payload + 1);
		esp_wifi_set_config(WIFI_IF_STA, &wifi_config);

	    ESP_LOGI( TAG, "SSID= %s", wifi_config.sta.ssid);
        break;
    }
    case 0x07: {
        wifi_config_t wifi_config = {0};
		esp_wifi_get_config(WIFI_IF_STA, &wifi_config);

		strcpy((char*) wifi_config.sta.password, ble_payload + 1);
		esp_wifi_set_config(WIFI_IF_STA, &wifi_config);

		esp_wifi_connect();

	    ESP_LOGI( TAG, "PASSWORD= %s", wifi_config.sta.password);
		break;
    }
	}
}

/* ---------- OTA firmware update ----------
 * Spawned as a FreeRTOS task when an OTA command is received via MQTT.
 * Downloads a firmware binary from the given URL using esp_https_ota,
 * then reboots into the new firmware.
 */
static void ota_update_task(void *arg) {
    char *url = (char *)arg;
    ESP_LOGW(TAG, "OTA: starting firmware download from %s", url);

    /* Publish OTA-in-progress status */
    char topic[128];
    snprintf(topic, sizeof(topic), "/%s/%s/status", my_company_id, my_device_id);
    mqtt_publish_safe(mqttClient, topic, "ota_updating", 0, 1, 0);

    bool use_tls = (strncmp(url, "https://", 8) == 0);

    esp_http_client_config_t http_cfg = {
        .url               = url,
        .crt_bundle_attach = use_tls ? esp_crt_bundle_attach : NULL,
        .timeout_ms        = 60000,
        .buffer_size       = 1024,
        .buffer_size_tx    = 1024,
    };

    esp_https_ota_config_t ota_cfg = {
        .http_config = &http_cfg,
    };

    esp_err_t ret = esp_https_ota(&ota_cfg);

    if (ret == ESP_OK) {
        ESP_LOGW(TAG, "OTA: firmware update successful — restarting");
        mqtt_publish_safe(mqttClient, topic, "ota_success", 0, 1, 0);
        vTaskDelay(pdMS_TO_TICKS(1000));
        free(url);
        tracked_restart("ota");
        /* not reached */
    } else {
        ESP_LOGE(TAG, "OTA: firmware update failed: %s", esp_err_to_name(ret));
        mqtt_publish_safe(mqttClient, topic, "ota_failed", 0, 1, 0);
    }

    ota_in_progress = false;
    free(url);
    vTaskDelete(NULL);
}

// Publish MDB diagnostics snapshot via MQTT.
// Called event-driven on state changes and periodically as heartbeat.
static void publish_mdb_diag(void) {
    if (!mqttClient) return;

    char topic[128];
    snprintf(topic, sizeof(topic), "/%s/%s/mdb-log", my_company_id, my_device_id);

    char msg[448];
    snprintf(msg, sizeof(msg),
        "{\"state\":\"%s\",\"addr\":\"0x%02X\",\"polls\":%lu,\"chkErr\":%lu,\"lastCmd\":\"%s\",\"vmcLevel\":%u,\"clockOk\":%s,\"saleQueue\":{\"pending\":%lu,\"overflow\":%lu,\"lastSeq\":%lu,\"fastPath\":%lu}}",
        machine_state_name(machine_state),
        cashless_device_address,
        mdb_poll_count,
        mdb_checksum_errors,
        mdb_last_cmd,
        vmc_feature_level,
        sale_queue_clock_ok() ? "true" : "false",
        (unsigned long) sale_queue_pending_count(),
        (unsigned long) sale_queue_overflow_count(),
        (unsigned long) sale_queue_last_seq(),
        (unsigned long) sale_queue_fast_path_count());

    mqtt_publish_safe(mqttClient, topic, msg, 0, 0, 0);
}

// esp_timer callback wrapper
static void mdb_diag_timer_cb(void *arg) {
    publish_mdb_diag();
}

static void mqtt_event_handler(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data) {

	esp_mqtt_event_handle_t event = event_data;
	esp_mqtt_client_handle_t mqttClient = event->client;

	switch ((esp_mqtt_event_id_t) event_id) {
	case MQTT_EVENT_CONNECTED:
		ESP_LOGW(TAG, "MQTT: connected to broker");
        mqtt_started = true;
        mqtt_last_connected_tick = xTaskGetTickCount();

    	char topic[128];
    	snprintf(topic, sizeof(topic), "/%s/%s/credit", my_company_id, my_device_id);
		ESP_LOGI(TAG, "MQTT: subscribing to '%s'", topic);
    	esp_mqtt_client_subscribe(mqttClient, topic, 1);

    	char topic_ota[128];
    	snprintf(topic_ota, sizeof(topic_ota), "/%s/%s/ota", my_company_id, my_device_id);
		ESP_LOGI(TAG, "MQTT: subscribing to '%s'", topic_ota);
    	esp_mqtt_client_subscribe(mqttClient, topic_ota, 1);

    	char topic_config[128];
    	snprintf(topic_config, sizeof(topic_config), "/%s/%s/config", my_company_id, my_device_id);
		ESP_LOGI(TAG, "MQTT: subscribing to '%s'", topic_config);
    	esp_mqtt_client_subscribe(mqttClient, topic_config, 1);

    	char topic_[128];
    	snprintf(topic_, sizeof(topic_), "/%s/%s/status", my_company_id, my_device_id);

		const esp_app_desc_t *app_desc = esp_app_get_description();
		char status_msg[256];   /* bumped from 128 to fit cellular fields */
		int n = snprintf(status_msg, sizeof(status_msg), "online|v:%s|b:%s %s %s",
		                 app_desc->version, app_desc->date, app_desc->time, BUILD_TIMEZONE);

		network_status_t ns;
		network_get_status(&ns);
		if (ns.modem_present && n > 0 && n < (int)sizeof(status_msg)) {
		    /* modem_lte_mode_t enum to short string, mirroring captive-portal helper */
		    const char *mode_str = (ns.cellular_mode == MODEM_LTE_MODE_CATM)  ? "LTE-M"  :
		                           (ns.cellular_mode == MODEM_LTE_MODE_NBIOT) ? "NB-IoT" :
		                           (ns.cellular_mode == MODEM_LTE_MODE_BOTH)  ? "Auto"   : "?";
		    snprintf(status_msg + n, sizeof(status_msg) - n,
		             "|uplink:cellular|op:%s|rssi:%d|mode:%s|ip:%s",
		             ns.cellular_operator[0] ? ns.cellular_operator : "unknown",
		             ns.cellular_rssi_dbm,
		             mode_str,
		             ns.cellular_ip[0] ? ns.cellular_ip : "0.0.0.0");
		}
		ESP_LOGI(TAG, "MQTT: publishing '%s' to '%s'", status_msg, topic_);
		esp_mqtt_client_publish(mqttClient, topic_, status_msg, 0, 1, 1);

        // Publish restart info once after first connect (if we have a reason to report)
        if (!restart_info_published && pending_restart_reason) {
            char restart_topic[128];
            snprintf(restart_topic, sizeof(restart_topic), "/%s/%s/restart", my_company_id, my_device_id);

            char restart_json[256];
            snprintf(restart_json, sizeof(restart_json),
                     "{\"reason\":\"%s\",\"uptime\":%lu,\"fw\":\"%s\",\"hw_reason\":\"%s\"}",
                     pending_restart_reason,
                     (unsigned long)pending_restart_uptime,
                     app_desc->version,
                     pending_restart_hw ? pending_restart_hw : "UNKNOWN");

            ESP_LOGI(TAG, "MQTT: publishing restart info '%s' to '%s'", restart_json, restart_topic);
            int msg_id = esp_mqtt_client_publish(mqttClient, restart_topic, restart_json, 0, 1, 0);
            if (msg_id >= 0) {
                restart_info_published = true;
            }
        }

        xEventGroupSetBits(xLedEventGroup, BIT_EVT_INTERNET | BIT_EVT_TRIGGER);

        // Start MDB diagnostics timer (30s interval)
        {
            static esp_timer_handle_t mdb_diag_timer = NULL;
            if (!mdb_diag_timer) {
                const esp_timer_create_args_t args = {
                    .callback = mdb_diag_timer_cb,
                    .name = "mdb_diag"
                };
                if (esp_timer_create(&args, &mdb_diag_timer) == ESP_OK) {
                    esp_timer_start_periodic(mdb_diag_timer, 300 * 1000000ULL); // 5min heartbeat
                    ESP_LOGI(TAG, "MDB DIAG: heartbeat timer started (5min interval)");
                }
            }
        }

		break;
	case MQTT_EVENT_DISCONNECTED:
		ESP_LOGW(TAG, "MQTT: disconnected from broker");
        mqtt_started = false;
        sale_queue_on_disconnect();
        xEventGroupClearBits(xLedEventGroup, BIT_EVT_INTERNET);
        xEventGroupSetBits(xLedEventGroup, BIT_EVT_TRIGGER);

		break;
	case MQTT_EVENT_SUBSCRIBED:
		ESP_LOGI(TAG, "MQTT: subscribed, msg_id=%d", event->msg_id);
		break;
	case MQTT_EVENT_UNSUBSCRIBED:
		ESP_LOGI(TAG, "MQTT: unsubscribed, msg_id=%d", event->msg_id);
		break;
	case MQTT_EVENT_PUBLISHED:
		ESP_LOGI(TAG, "MQTT: published, msg_id=%d", event->msg_id);
		sale_queue_on_published(event->msg_id);
		break;
	case MQTT_EVENT_DATA:

	    ESP_LOGI( TAG, "TOPIC= %.*s", event->topic_len, event->topic);
	    ESP_LOGI( TAG, "DATA_LEN= %d", event->data_len);
	    ESP_LOGI( TAG, "DATA= %.*s", event->data_len, event->data);

		size_t topic_len = event->topic_len;

		if (topic_len > 7 && strncmp(event->topic + event->topic_len - 7, "/credit", 7) == 0) {

			uint16_t newFunds;
			if(xorDecodeWithPasskey(&newFunds, NULL, (uint8_t*) event->data)){

                if (newFunds == 0) {
                    // Cancel current session (credit reset)
                    if (machine_state == VEND_STATE) {
                        // Must deny vend first before cancelling session
                        vend_denied_todo = true;
                        ESP_LOGI(TAG, "Credit cancel during VEND — denying vend first");
                    } else if (machine_state >= IDLE_STATE) {
                        session_cancel_todo = true;
                        ESP_LOGI(TAG, "Credit cancel — ending active session");
                    }
                } else {
                    // Overwrite queue (always replaces previous credit)
                    xQueueOverwrite(mdbSessionQueue, &newFunds);

                    // If a session is already active, cancel/deny it first so the
                    // new credit gets picked up after Session Complete → ENABLED
                    if (machine_state == VEND_STATE) {
                        vend_denied_todo = true;
                        ESP_LOGI(TAG, "New credit during VEND — denying vend, will restart session");
                    } else if (machine_state >= IDLE_STATE) {
                        session_cancel_todo = true;
                        ESP_LOGI(TAG, "New credit while session active — restarting session");
                    }
                }

                xEventGroupSetBits(xLedEventGroup, BIT_EVT_BUZZER | BIT_EVT_TRIGGER);
                ESP_LOGI( TAG, "Amount= %f", FROM_SCALE_FACTOR(newFunds, CONFIG_MDB_SCALE_FACTOR, CONFIG_MDB_DECIMAL_PLACES) );
			}
		}

		/* OTA firmware update — expects JSON: {"url":"https://server/path/to/firmware.bin"} */
		if (topic_len > 4 && strncmp(event->topic + event->topic_len - 4, "/ota", 4) == 0) {

		    if (ota_in_progress) {
		        ESP_LOGW(TAG, "OTA: update already in progress, ignoring");
		        break;
		    }

		    /* Null-terminate the incoming data so we can parse it as a string */
		    char *json_buf = malloc(event->data_len + 1);
		    if (!json_buf) {
		        ESP_LOGE(TAG, "OTA: malloc failed");
		        break;
		    }
		    memcpy(json_buf, event->data, event->data_len);
		    json_buf[event->data_len] = '\0';

		    cJSON *root = cJSON_Parse(json_buf);
		    free(json_buf);

		    if (!root) {
		        ESP_LOGE(TAG, "OTA: failed to parse JSON");
		        break;
		    }

		    cJSON *j_url = cJSON_GetObjectItem(root, "url");
		    if (!j_url || !cJSON_IsString(j_url) || strlen(j_url->valuestring) == 0) {
		        ESP_LOGE(TAG, "OTA: missing or empty 'url' field");
		        cJSON_Delete(root);
		        break;
		    }

		    /* Validate URL starts with the trusted server URL (prevents arbitrary downloads) */
		    if (strlen(my_srv_url) > 0 && strncmp(j_url->valuestring, my_srv_url, strlen(my_srv_url)) != 0) {
		        ESP_LOGE(TAG, "OTA: URL '%s' does not match trusted server '%s'", j_url->valuestring, my_srv_url);
		        cJSON_Delete(root);
		        break;
		    }

		    /* Copy URL for the OTA task (freed inside the task) */
		    char *ota_url = strdup(j_url->valuestring);
		    cJSON_Delete(root);

		    if (!ota_url) {
		        ESP_LOGE(TAG, "OTA: strdup failed");
		        break;
		    }

		    ESP_LOGW(TAG, "OTA: received update command, URL=%s", ota_url);
		    ota_in_progress = true;
		    xTaskCreate(ota_update_task, "ota_update", 8192, ota_url, 5, NULL);
		}

		/* Device config — expects JSON: {"mdb_address": 1} or {"mdb_address": 2} */
		if (topic_len > 7 && strncmp(event->topic + event->topic_len - 7, "/config", 7) == 0) {

		    bool needs_restart = false;

		    // Try XOR-encrypted config first (cmd 0x30=restart, 0x31=mdb_address)
		    if (event->data_len == 19) {
		        uint16_t configParam = 0;
		        uint8_t configData[19];
		        memcpy(configData, event->data, 19);
		        uint8_t cmd = configData[0];

		        if (xorDecodeWithPasskey(&configParam, NULL, configData)) {
		            switch (cmd) {
		                case 0x30: // Restart
		                    ESP_LOGW(TAG, "CONFIG: authenticated restart requested");
		                    needs_restart = true;
		                    break;
		                case 0x31: // Set MDB address
		                    if (configParam == 1 || configParam == 2) {
		                        nvs_handle_t h;
		                        if (nvs_open("vmflow", NVS_READWRITE, &h) == ESP_OK) {
		                            nvs_set_u8(h, "mdb_addr", (uint8_t) configParam);
		                            nvs_commit(h);
		                            nvs_close(h);
		                            ESP_LOGW(TAG, "CONFIG: mdb_address set to %u, restart required", configParam);
		                            needs_restart = true;
		                        }
		                    } else {
		                        ESP_LOGE(TAG, "CONFIG: invalid mdb_address %u (must be 1 or 2)", configParam);
		                    }
		                    break;
		                case 0x32: // MDB soft reset — re-announce to VMC
		                    ESP_LOGW(TAG, "CONFIG: MDB soft reset requested");
		                    // Clear all pending flags and queue (same as hardware RESET handler)
		                    session_begin_todo = false;
		                    session_cancel_todo = false;
		                    session_end_todo = false;
		                    vend_approved_todo = false;
		                    vend_denied_todo = false;
		                    out_of_sequence_todo = false;
		                    {
		                        uint16_t discard;
		                        while (xQueueReceive(mdbSessionQueue, &discard, 0) == pdTRUE) {}
		                    }
		                    // Signal "Just Reset" on next POLL — VMC will re-run SETUP sequence
		                    machine_state = INACTIVE_STATE;
		                    vmc_feature_level = 1;
		                    cashless_reset_todo = true;
		                    publish_mdb_diag();
		                    break;
		                default:
		                    ESP_LOGW(TAG, "CONFIG: unknown encrypted cmd 0x%02X", cmd);
		                    break;
		            }
		        } else {
		            ESP_LOGW(TAG, "CONFIG: XOR decode failed (bad checksum or timestamp)");
		        }
		    } else {
		        ESP_LOGW(TAG, "CONFIG: unexpected payload length %d (expected 19)", event->data_len);
		    }

		    if (needs_restart) {
		        ESP_LOGW(TAG, "CONFIG: restarting...");
		        tracked_restart("config");
		    }
		}

		break;
	case MQTT_EVENT_ERROR:
		ESP_LOGE(TAG, "MQTT: error event");
		if (event->error_handle->error_type == MQTT_ERROR_TYPE_TCP_TRANSPORT) {
		    ESP_LOGE(TAG, "MQTT: transport error: esp_tls_last_esp_err=0x%x, tls_stack_err=0x%x, sock_errno=%d (%s)",
		             event->error_handle->esp_tls_last_esp_err,
		             event->error_handle->esp_tls_stack_err,
		             event->error_handle->esp_transport_sock_errno,
		             strerror(event->error_handle->esp_transport_sock_errno));
		} else if (event->error_handle->error_type == MQTT_ERROR_TYPE_CONNECTION_REFUSED) {
		    ESP_LOGE(TAG, "MQTT: connection refused, reason=0x%x", event->error_handle->connect_return_code);
		}
		break;
	default:
	    ESP_LOGI( TAG, "Other event id: %d", event->event_id);
		break;
	}
}

/* ---------- Provisioning claim ----------
 * Called as a FreeRTOS task after the device obtains an IP address and a
 * prov_code is found in NVS.  POSTs to the claim-device edge function,
 * persists the returned subdomain + passkey, erases the one-time code, then
 * reboots so the regular startup path takes over.
 */
/* In-task retry policy.
 *
 * Used to be: on any failure, sleep 10s and esp_restart(). That made
 * sense when the only reason to fail was a transient network blip on
 * WiFi STA — reboot, re-DHCP, retry. On cellular it's destructive: a
 * persistent failure (typo'd prov_code, server down, expired code)
 * turns into an endless reboot loop where the user can never get back
 * to the captive portal long enough to fix the input.
 *
 * New behaviour: try the HTTPS POST up to PROV_MAX_ATTEMPTS times with
 * a fixed backoff. On success → restart (cleanest way to apply the
 * new credentials). On persistent failure → log + exit. The captive
 * portal stays up. The user can resubmit /api/v1/claim with corrected
 * input, which spawns a fresh task. */
/* Retry budget — sized for the "cold cellular" startup pattern.
 *
 * Field measurements on Telekom IoT (sensor.net) showed that a fresh
 * cellular session needs several minutes to reach full performance:
 * the first TLS handshake to a Cloudflare-fronted endpoint routinely
 * exceeds CF's 15 s edge timeout, but ~5 minutes later the *same*
 * handshake completes in <8 s. Reasons live at the carrier side
 * (cell selection optimisation, PDP context realisation, NAT entry
 * caching) — we can't speed them up, only wait through them.
 *
 * Backoff schedule (ms): 5 s, 15 s, 30 s, 60 s, 60 s, 60 s, 60 s
 * Total: ~5 minutes of retries before giving up. Matches the
 * empirically observed "warm-up" window. After exhaustion the AP
 * stays online and the user can retry via captive portal. */
#define PROV_MAX_ATTEMPTS  7
static const int PROV_RETRY_DELAYS_S[PROV_MAX_ATTEMPTS - 1] = {
    5, 15, 30, 60, 60, 60
};

/* Single-flight guard so concurrent /api/v1/claim submits + boot-time
 * re-spawn don't run two tasks against the same NVS state. */
static volatile bool s_prov_claim_running = false;

/* (The cellular keep-warm task that lived here was a diagnostic for
 * the PPP-based claim path. It probed 1.1.1.1:53 every 1 s during a
 * claim attempt, hoping to keep the LTE-M radio in RRC-CONNECTED.
 * Field log 2026-04-29 showed it had no measurable effect — 90 % of
 * its own probes failed with the same loss pattern as the HTTPS
 * connection — confirming the bug was below lwIP/PPP. The claim flow
 * was subsequently moved to the modem-internal HTTPS path, which
 * doesn't go through lwIP at all. The keep-warm task is no longer
 * needed and was removed in the same commit that wired in
 * modem_https_post_json.) */

void provision_claim_task(void *arg) {
    if (s_prov_claim_running) {
        ESP_LOGW(TAG, "PROV: task already running — skipping duplicate spawn");
        vTaskDelete(NULL);
        return;
    }
    s_prov_claim_running = true;

    char prov_code[32] = {0};
    char srv_url[128]  = {0};

    nvs_handle_t handle;
    if (nvs_open("vmflow", NVS_READWRITE, &handle) != ESP_OK) {
        ESP_LOGE(TAG, "PROV: NVS open failed");
        s_prov_claim_running = false;
        vTaskDelete(NULL);
        return;
    }

    size_t len = sizeof(prov_code);
    if (nvs_get_str(handle, "prov_code", prov_code, &len) != ESP_OK || strlen(prov_code) == 0) {
        ESP_LOGI(TAG, "PROV: no provisioning code in NVS");
        nvs_close(handle);
        s_prov_claim_running = false;
        vTaskDelete(NULL);
        return;
    }

    len = sizeof(srv_url);
    nvs_get_str(handle, "srv_url", srv_url, &len);
    nvs_close(handle);

    if (strlen(srv_url) == 0) {
        ESP_LOGE(TAG, "PROV: no server URL in NVS");
        s_prov_claim_running = false;
        vTaskDelete(NULL);
        return;
    }

    /* MAC address. On cellular boards STA isn't started, but esp_wifi
     * is initialised for AP — esp_wifi_get_mac(STA) still works because
     * the STA MAC is derived from the same efuse base address. */
    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    char mac_str[18];
    snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    char body[128];
    snprintf(body, sizeof(body),
             "{\"short_code\":\"%s\",\"mac_address\":\"%s\"}", prov_code, mac_str);

    /* Branch by uplink type. The cellular path uses the modem's internal
     * AT+SH* HTTPS stack (bypasses PPP entirely — see field-debug notes
     * below). The WiFi path uses esp_http_client over the active STA
     * connection, which is the simpler and historically-proven route. */
    bool use_cellular = modem_is_present();

    if (!use_cellular) {
        /* === WiFi / esp_http_client claim path ========================
         * Single-attempt POST; on success (HTTP 200 + valid JSON) we
         * save NVS and tracked_restart. On failure we log + bail —
         * captive portal stays reachable on the SoftAP side and the
         * user can resubmit via /api/v1/claim, which spawns another
         * provision_claim_task. */
        ESP_LOGI(TAG, "PROV: claim via WiFi/esp_http_client (no modem)");
        ESP_LOGI(TAG, "PROV: srv_url=%s body=%s", srv_url, body);

        char claim_url[192];
        snprintf(claim_url, sizeof(claim_url), "%s/functions/v1/claim-device", srv_url);

        bool use_tls = (strncmp(claim_url, "https://", 8) == 0);
        esp_http_client_config_t http_cfg = {
            .url               = claim_url,
            .crt_bundle_attach = use_tls ? esp_crt_bundle_attach : NULL,
            .method            = HTTP_METHOD_POST,
            .timeout_ms        = 30000,
            .buffer_size       = 1024,
            .buffer_size_tx    = 512,
        };
        esp_http_client_handle_t client = esp_http_client_init(&http_cfg);
        if (!client) {
            ESP_LOGE(TAG, "PROV: esp_http_client_init failed");
            s_prov_claim_running = false;
            vTaskDelete(NULL);
            return;
        }

        esp_http_client_set_header(client, "Content-Type", "application/json");
        esp_http_client_set_post_field(client, body, strlen(body));

        char resp_buf[1024] = {0};
        size_t resp_len = 0;
        int http_status = 0;

        esp_err_t err = esp_http_client_open(client, strlen(body));
        if (err == ESP_OK) {
            int written = esp_http_client_write(client, body, strlen(body));
            if (written < 0) {
                err = ESP_FAIL;
            } else {
                int header_len = esp_http_client_fetch_headers(client);
                if (header_len < 0) {
                    err = ESP_FAIL;
                } else {
                    http_status = esp_http_client_get_status_code(client);
                    int read_len = esp_http_client_read_response(client, resp_buf,
                                                                  sizeof(resp_buf) - 1);
                    if (read_len < 0) read_len = 0;
                    resp_buf[read_len] = '\0';
                    resp_len = (size_t)read_len;
                }
            }
        }
        esp_http_client_close(client);
        esp_http_client_cleanup(client);

        if (err != ESP_OK) {
            ESP_LOGE(TAG, "PROV: WiFi claim transport error: %s", esp_err_to_name(err));
            s_prov_claim_running = false;
            vTaskDelete(NULL);
            return;
        }

        ESP_LOGI(TAG, "PROV: WiFi HTTP %d (%zu B body): %.200s",
                 http_status, resp_len, resp_buf);

        if (http_status == 200) {
            cJSON *root = cJSON_Parse(resp_buf);
            if (root) {
                cJSON *j_company = cJSON_GetObjectItem(root, "company_id");
                cJSON *j_device  = cJSON_GetObjectItem(root, "device_id");
                cJSON *j_pass    = cJSON_GetObjectItem(root, "passkey");

                if (j_company && cJSON_IsString(j_company) &&
                    j_device  && cJSON_IsString(j_device) &&
                    j_pass    && cJSON_IsString(j_pass)) {

                    nvs_handle_t h;
                    if (nvs_open("vmflow", NVS_READWRITE, &h) == ESP_OK) {
                        nvs_set_str(h, "company_id", j_company->valuestring);
                        nvs_set_str(h, "device_id",  j_device->valuestring);
                        nvs_set_str(h, "passkey",    j_pass->valuestring);
                        cJSON *j_mqtt = cJSON_GetObjectItem(root, "mqtt_host");
                        if (j_mqtt && cJSON_IsString(j_mqtt) && strlen(j_mqtt->valuestring) > 0) {
                            nvs_set_str(h, "mqtt_host", j_mqtt->valuestring);
                        }
                        cJSON *j_mqtt_port = cJSON_GetObjectItem(root, "mqtt_port");
                        if (j_mqtt_port && cJSON_IsString(j_mqtt_port) && strlen(j_mqtt_port->valuestring) > 0) {
                            nvs_set_str(h, "mqtt_port", j_mqtt_port->valuestring);
                        }
                        cJSON *j_softap = cJSON_GetObjectItem(root, "softap_password");
                        if (j_softap && cJSON_IsString(j_softap) && strlen(j_softap->valuestring) >= 8) {
                            nvs_set_str(h, "softap_pwd", j_softap->valuestring);
                            ESP_LOGI(TAG, "PROV: stored backend-assigned SoftAP password");
                        }
                        nvs_erase_key(h, "prov_code");
                        nvs_commit(h);
                        nvs_close(h);
                    }

                    ESP_LOGI(TAG, "PROV: claimed (WiFi), company=%s device=%s — restarting",
                             j_company->valuestring, j_device->valuestring);
                    cJSON_Delete(root);
                    s_prov_claim_running = false;
                    tracked_restart("provision");
                    /* not reached */
                }
                cJSON_Delete(root);
                ESP_LOGE(TAG, "PROV: HTTP 200 but missing required fields — giving up");
            } else {
                ESP_LOGE(TAG, "PROV: HTTP 200 but invalid JSON — giving up");
            }
        } else {
            ESP_LOGW(TAG, "PROV: server returned HTTP %d — not retrying", http_status);
        }

        s_prov_claim_running = false;
        vTaskDelete(NULL);
        return;
    }

    /* === Modem-internal HTTPS claim path =============================
     *
     * Field test 2026-04-29: the same 1NCE SIM works cleanly in a
     * separate LTE router (which uses the modem's offloaded TCP/IP
     * stack), while our PPP+lwIP+mbedtls path on this SIM7080G stalls
     * TLS handshakes after the server certificate. Diagnostic narrows
     * to a defect in the host-side stack (PPP framing, UART buffer
     * pressure, esp_modem 1.4.0 + lwIP edge case, or some combination
     * thereof) — NOT the carrier and NOT the modem firmware itself.
     *
     * Switching the claim flow to the modem's internal HTTPS engine
     * via AT+SHCONN/SHREQ/SHREAD bypasses our entire host TCP/IP path.
     * The modem opens TCP, performs the TLS handshake, sends the
     * request, and reads the response — we only see the final HTTP
     * status + body via AT. This is the same path every consumer
     * cellular router uses.
     *
     * Steady-state MQTT continues over PPP after the claim succeeds
     * and the device reboots. Small-payload MQTT doesn't trigger the
     * failure mode (no 3 KB cert burst, no long-lived TLS handshake),
     * so PPP is fine for it.
     *
     * Caller flow:
     *   1. PPP is currently UP (we got here on UPLINK_UP)
     *   2. Take modem_op_lock so concurrent recovery paths don't
     *      interfere with our internal-stack operations
     *   3. Tear down PPP (modem_disconnect → COMMAND mode)
     *   4. Loop modem_https_post_json attempts with the same backoff
     *      schedule as the previous PPP path
     *   5. On 200 + valid JSON: save NVS, tracked_restart (PPP comes
     *      back fresh after reboot)
     *   6. On exhaustion: re-establish PPP via modem_connect so
     *      captive-portal /api/v1/claim retry stays viable */

    ESP_LOGI(TAG, "PROV: claim via modem-internal HTTPS (bypassing PPP)");
    ESP_LOGI(TAG, "PROV: srv_url=%s body=%s", srv_url, body);

    /* Need the APN to (re)configure the internal bearer. modem_nvs_load
     * was populated during the captive-portal cellular_configure, so
     * this should always succeed at this point in the flow. */
    char apn_buf[MODEM_APN_MAX] = {0};
    char pin_buf[MODEM_PIN_MAX] = {0};
    modem_lte_mode_t lte_mode_unused;
    if (modem_nvs_load(apn_buf, sizeof(apn_buf), pin_buf, sizeof(pin_buf),
                       &lte_mode_unused) != ESP_OK || apn_buf[0] == '\0') {
        ESP_LOGE(TAG, "PROV: no APN in NVS — cannot run modem-internal HTTPS");
        s_prov_claim_running = false;
        vTaskDelete(NULL);
        return;
    }

    /* Serialise against parallel recovery paths and FULL-teardown PPP
     * for the AT-mode HTTPS window.
     *
     * Why full teardown (~32 s) instead of modem_pause (~1 s): the
     * SIM7080G internal TLS stack (SHCONN) requires the PDP context
     * to be unbound from PPP. modem_pause keeps the PDP bound to the
     * suspended PPP netif, so CNACT=0,1 establishes a parallel
     * binding that confuses the data plane — SHCONN then returns
     * garbage (HDLC frames leak into the AT response stream:
     * "AT+SHCONN → ESP_FAIL, resp=~!E"). Full teardown via set_mode
     * (COMMAND) releases the PDP context, allowing CNACT to take it
     * over cleanly. We pay the 30 s teardown wait once per claim. */
    modem_op_lock();
    ESP_LOGI(TAG, "PROV: tearing PPP down for AT-mode HTTPS");
    modem_disconnect();
    vTaskDelay(pdMS_TO_TICKS(2000));   /* settle */

    bool gave_up_permanently = false;

    for (int attempt = 1; attempt <= PROV_MAX_ATTEMPTS; attempt++) {
        char   resp_buf[1024] = {0};
        size_t resp_len       = 0;
        int    http_status    = 0;

        ESP_LOGI(TAG, "PROV: attempt %d/%d via modem-internal HTTPS",
                 attempt, PROV_MAX_ATTEMPTS);

        esp_err_t err = modem_https_post_json(srv_url,
                                               "/functions/v1/claim-device",
                                               apn_buf,
                                               body, strlen(body),
                                               resp_buf, sizeof(resp_buf),
                                               &resp_len, &http_status,
                                               90000);

        if (err != ESP_OK) {
            ESP_LOGW(TAG, "PROV: attempt %d/%d transport error: %s",
                     attempt, PROV_MAX_ATTEMPTS, esp_err_to_name(err));
        } else {
            ESP_LOGI(TAG, "PROV: attempt %d/%d HTTP %d (%zu B body): %.200s",
                     attempt, PROV_MAX_ATTEMPTS, http_status, resp_len, resp_buf);

            if (http_status == 200) {
                cJSON *root = cJSON_Parse(resp_buf);
                if (root) {
                    cJSON *j_company = cJSON_GetObjectItem(root, "company_id");
                    cJSON *j_device  = cJSON_GetObjectItem(root, "device_id");
                    cJSON *j_pass    = cJSON_GetObjectItem(root, "passkey");

                    if (j_company && cJSON_IsString(j_company) &&
                        j_device  && cJSON_IsString(j_device) &&
                        j_pass    && cJSON_IsString(j_pass)) {

                        nvs_handle_t h;
                        if (nvs_open("vmflow", NVS_READWRITE, &h) == ESP_OK) {
                            nvs_set_str(h, "company_id", j_company->valuestring);
                            nvs_set_str(h, "device_id",  j_device->valuestring);
                            nvs_set_str(h, "passkey",    j_pass->valuestring);
                            cJSON *j_mqtt = cJSON_GetObjectItem(root, "mqtt_host");
                            if (j_mqtt && cJSON_IsString(j_mqtt) && strlen(j_mqtt->valuestring) > 0) {
                                nvs_set_str(h, "mqtt_host", j_mqtt->valuestring);
                            }
                            cJSON *j_mqtt_port = cJSON_GetObjectItem(root, "mqtt_port");
                            if (j_mqtt_port && cJSON_IsString(j_mqtt_port) && strlen(j_mqtt_port->valuestring) > 0) {
                                nvs_set_str(h, "mqtt_port", j_mqtt_port->valuestring);
                            }
                            cJSON *j_softap = cJSON_GetObjectItem(root, "softap_password");
                            if (j_softap && cJSON_IsString(j_softap) && strlen(j_softap->valuestring) >= 8) {
                                nvs_set_str(h, "softap_pwd", j_softap->valuestring);
                                ESP_LOGI(TAG, "PROV: stored backend-assigned SoftAP password");
                            }
                            nvs_erase_key(h, "prov_code");
                            nvs_commit(h);
                            nvs_close(h);
                        }

                        ESP_LOGI(TAG, "PROV: claimed, company=%s device=%s — restarting",
                                 j_company->valuestring, j_device->valuestring);
                        cJSON_Delete(root);
                        s_prov_claim_running = false;
                        modem_op_unlock();
                        tracked_restart("provision");
                        /* not reached */
                    }
                    cJSON_Delete(root);
                }
                ESP_LOGE(TAG, "PROV: HTTP 200 but response missing required fields — giving up");
                gave_up_permanently = true;
                break;
            }

            if (http_status >= 400 && http_status < 500) {
                ESP_LOGW(TAG, "PROV: server rejected (HTTP %d) — not retrying", http_status);
                gave_up_permanently = true;
                break;
            }
            /* 5xx or 0 → fall through to backoff + retry. */
        }

        /* Backoff between retries. */
        if (attempt < PROV_MAX_ATTEMPTS) {
            int delay_s = PROV_RETRY_DELAYS_S[attempt - 1];
            ESP_LOGI(TAG, "PROV: retrying in %d s (attempt %d/%d)...",
                     delay_s, attempt + 1, PROV_MAX_ATTEMPTS);
            vTaskDelay(pdMS_TO_TICKS(delay_s * 1000));
        }
    }

    /* All attempts exhausted (or terminal 4xx/garbage). Restart PPP so
     * the device returns to a normal cellular state — captive portal
     * stays reachable on the SoftAP side, and the user can either
     * factory-reset or POST /api/v1/claim again with a corrected code,
     * which spawns a fresh provision_claim_task. */
    if (gave_up_permanently) {
        ESP_LOGE(TAG, "PROV: terminal failure (%s) — restoring PPP",
                 "4xx or invalid JSON");
    } else {
        ESP_LOGE(TAG, "PROV: %d attempts exhausted — restoring PPP",
                 PROV_MAX_ATTEMPTS);
    }
    ESP_LOGI(TAG, "PROV: re-establishing PPP via modem_connect");
    modem_connect();   /* best-effort; if it fails, watchdog/recovery handles it */
    modem_op_unlock();
    s_prov_claim_running = false;
    vTaskDelete(NULL);
}

/* ============================================================================
 * SoftAP password sync task — runs once per boot for already-claimed devices
 * that don't yet have softap_pwd in NVS. Posts an HMAC-authenticated request
 * to /functions/v1/sync-softap-password, writes the returned password to NVS,
 * and reloads the SoftAP config in place.
 * ============================================================================ */

#include "mbedtls/md.h"

static bool s_softap_sync_running = false;
static bool s_softap_sync_done    = false;

#define SOFTAP_SYNC_MAX_ATTEMPTS  3
static const int SOFTAP_SYNC_RETRY_DELAYS_S[] = { 5, 30 };

static void compute_softap_sync_signature(const char *passkey,
                                          const char *device_id,
                                          const char *mac_str,
                                          uint32_t timestamp,
                                          char *out_hex,
                                          size_t out_hex_len)
{
    char message[160];
    snprintf(message, sizeof(message), "%s|%s|%lu",
             device_id, mac_str, (unsigned long)timestamp);

    uint8_t digest[32];
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(md,
                    (const uint8_t *)passkey, strlen(passkey),
                    (const uint8_t *)message, strlen(message),
                    digest);

    if (out_hex_len < 65) { out_hex[0] = '\0'; return; }
    static const char HEX[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out_hex[i * 2]     = HEX[digest[i] >> 4];
        out_hex[i * 2 + 1] = HEX[digest[i] & 0x0F];
    }
    out_hex[64] = '\0';
}

void softap_sync_task(void *arg) {
    if (s_softap_sync_running || s_softap_sync_done) {
        ESP_LOGI(TAG, "SOFTAP SYNC: already running or done, skipping");
        vTaskDelete(NULL);
        return;
    }
    s_softap_sync_running = true;

    /* Read NVS prerequisites. Bail if anything missing — the device is in
     * an in-between state we don't try to repair from here. */
    char device_id[64] = {0};
    char passkey[32]   = {0};
    char srv_url[128]  = {0};
    char softap_pwd_existing[16] = {0};

    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGW(TAG, "SOFTAP SYNC: NVS open failed");
        goto done;
    }
    size_t l;
    l = sizeof(device_id);            nvs_get_str(h, "device_id", device_id, &l);
    l = sizeof(passkey);              nvs_get_str(h, "passkey",   passkey,   &l);
    l = sizeof(srv_url);              nvs_get_str(h, "srv_url",   srv_url,   &l);
    l = sizeof(softap_pwd_existing);  nvs_get_str(h, "softap_pwd", softap_pwd_existing, &l);
    nvs_close(h);

    if (strlen(device_id) == 0 || strlen(passkey) == 0 || strlen(srv_url) == 0) {
        ESP_LOGI(TAG, "SOFTAP SYNC: device not claimed yet, skipping");
        goto done;
    }
    if (strlen(softap_pwd_existing) >= 8) {
        ESP_LOGI(TAG, "SOFTAP SYNC: softap_pwd already set, skipping");
        goto done;
    }

    /* Wait briefly for SNTP-synced time. The signature timestamp must be
     * within ±60 s of server time, so a 1970 clock will fail. SNTP usually
     * completes within a few seconds of WiFi/cellular bring-up. */
    for (int i = 0; i < 30; i++) {
        time_t now_t = time(NULL);
        if (now_t > 1700000000) break;
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    time_t now_t = time(NULL);
    if (now_t <= 1700000000) {
        ESP_LOGW(TAG, "SOFTAP SYNC: time not synced after 30 s, bailing");
        goto done;
    }

    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    char mac_str[18];
    snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    char sig[65];
    compute_softap_sync_signature(passkey, device_id, mac_str, (uint32_t)now_t,
                                  sig, sizeof(sig));

    char body[384];
    snprintf(body, sizeof(body),
             "{\"device_id\":\"%s\",\"mac_address\":\"%s\",\"timestamp\":%lu,\"signature\":\"%s\"}",
             device_id, mac_str, (unsigned long)now_t, sig);

    char url[192];
    snprintf(url, sizeof(url), "%s/functions/v1/sync-softap-password", srv_url);

    for (int attempt = 1; attempt <= SOFTAP_SYNC_MAX_ATTEMPTS; attempt++) {
        char resp[256] = {0};
        size_t resp_len = 0;
        int http_status = 0;
        esp_err_t err = ESP_FAIL;

        esp_http_client_config_t cfg = {
            .url               = url,
            .crt_bundle_attach = (strncmp(url, "https://", 8) == 0) ? esp_crt_bundle_attach : NULL,
            .method            = HTTP_METHOD_POST,
            .timeout_ms        = 30000,
        };
        esp_http_client_handle_t cli = esp_http_client_init(&cfg);
        if (cli) {
            esp_http_client_set_header(cli, "Content-Type", "application/json");
            esp_http_client_set_post_field(cli, body, strlen(body));
            err = esp_http_client_open(cli, strlen(body));
            if (err == ESP_OK && esp_http_client_write(cli, body, strlen(body)) >= 0) {
                if (esp_http_client_fetch_headers(cli) >= 0) {
                    http_status = esp_http_client_get_status_code(cli);
                    int rl = esp_http_client_read_response(cli, resp, sizeof(resp) - 1);
                    if (rl < 0) rl = 0;
                    resp[rl] = '\0';
                    resp_len = rl;
                }
            }
            esp_http_client_close(cli);
            esp_http_client_cleanup(cli);
        }

        ESP_LOGI(TAG, "SOFTAP SYNC: attempt %d HTTP %d (%zu B)", attempt, http_status, resp_len);

        if (http_status == 200) {
            cJSON *root = cJSON_Parse(resp);
            cJSON *j_pwd = root ? cJSON_GetObjectItem(root, "softap_password") : NULL;
            if (j_pwd && cJSON_IsString(j_pwd) && strlen(j_pwd->valuestring) >= 8) {
                nvs_handle_t hw;
                if (nvs_open("vmflow", NVS_READWRITE, &hw) == ESP_OK) {
                    nvs_set_str(hw, "softap_pwd", j_pwd->valuestring);
                    nvs_commit(hw);
                    nvs_close(hw);
                }
                ESP_LOGW(TAG, "SOFTAP SYNC: applied backend-assigned password — reloading AP");
                start_softap();   /* re-applies wifi_config, deauths existing clients */
                cJSON_Delete(root);
                goto done;
            }
            if (root) cJSON_Delete(root);
            ESP_LOGE(TAG, "SOFTAP SYNC: HTTP 200 but no usable softap_password — giving up");
            break;
        }
        if (http_status >= 400 && http_status < 500) {
            ESP_LOGW(TAG, "SOFTAP SYNC: server rejected %d — giving up", http_status);
            break;
        }

        if (attempt < SOFTAP_SYNC_MAX_ATTEMPTS) {
            int delay_s = SOFTAP_SYNC_RETRY_DELAYS_S[attempt - 1];
            ESP_LOGI(TAG, "SOFTAP SYNC: retrying in %d s", delay_s);
            vTaskDelay(pdMS_TO_TICKS(delay_s * 1000));
        }
    }

done:
    s_softap_sync_done    = true;
    s_softap_sync_running = false;
    vTaskDelete(NULL);
}

/*
 * Network manager event consumer. The network_init / handler in
 * network.c owns WIFI_EVENT and IP_EVENT directly; this callback is
 * the seam where uplink-up/down translates into MQTT + SNTP + watchdog
 * lifecycle. Keep it brief — runs in the network task context.
 */
static void network_event_cb(network_event_t event, void *user_data) {
    (void)user_data;
    switch (event) {
        case NETWORK_EVENT_UPLINK_UP:
            ESP_LOGI(TAG, "uplink up — starting MQTT + provisioning if needed");

            /* If a provisioning code is in NVS and we don't have a passkey
             * yet, this is the first-boot claim flow. Spawn the claim task;
             * MQTT starts after the claim succeeds + restart. */
            {
                nvs_handle_t h;
                if (nvs_open("vmflow", NVS_READONLY, &h) == ESP_OK) {
                    char prov_code[16] = {0};
                    size_t s = sizeof(prov_code);
                    bool has_prov = (nvs_get_str(h, "prov_code", prov_code, &s) == ESP_OK
                                      && strlen(prov_code) > 0);
                    nvs_close(h);
                    if (has_prov && strlen(my_passkey) == 0) {
                        ESP_LOGI(TAG, "spawning provision_claim_task");
                        xTaskCreate(provision_claim_task, "prov_claim", 16384, NULL, 5, NULL);
                        return;
                    }
                }
            }

            /* Steady-state: kick MQTT + SNTP + watchdog (same logic the
             * old IP_EVENT_STA_GOT_IP branch ran).
             *
             * MQTT requires a claimed device — without company_id /
             * device_id / passkey, payload XOR encryption can't work
             * and the topic prefix is empty. Starting the client anyway
             * just spins on getaddrinfo() against the default broker
             * URL and pollutes logs. Hold MQTT until the captive portal
             * (or an existing claim in NVS) has provided all three. */
            bool claimed = (strlen(my_company_id) > 0 &&
                            strlen(my_device_id)  > 0 &&
                            strlen(my_passkey)    > 0);
            if (!claimed) {
                ESP_LOGW(TAG, "uplink up but device unclaimed — MQTT held off "
                              "(company='%s' device='%s' passkey_len=%u)",
                         my_company_id, my_device_id, (unsigned)strlen(my_passkey));
                break;
            }

            /* Auto-migration: if this is an already-claimed device that
             * doesn't yet have a backend-assigned SoftAP password (NVS
             * key softap_pwd missing), fetch one via the sync endpoint.
             * The task self-checks NVS and early-exits when the password
             * is already set, so spawning unconditionally is safe. */
            if (!s_softap_sync_done) {
                xTaskCreate(softap_sync_task, "softap_sync", 8192, NULL, 4, NULL);
            }

            if (!sntp_started) {
                esp_sntp_setoperatingmode(ESP_SNTP_OPMODE_POLL);
                esp_sntp_setservername(0, "pool.ntp.org");
                esp_sntp_init();
                sntp_started = true;
            }

            /* mqtt_started=true means we already kicked the client at
             * least once. esp_mqtt_client_reconnect() forces an
             * immediate reconnect attempt instead of waiting for the
             * client's internal reconnect timer (which can be 5-30s);
             * this is what we want when uplink just came back. */
            if (mqttClient) {
                if (!mqtt_started) {
                    ESP_LOGW(TAG, "MQTT: starting client (company='%s' device='%s', client=%p)",
                             my_company_id, my_device_id, mqttClient);
                    esp_mqtt_client_start(mqttClient);
                    mqtt_last_connected_tick = xTaskGetTickCount();
                } else {
                    ESP_LOGW(TAG, "MQTT: uplink restored, forcing reconnect");
                    esp_mqtt_client_reconnect(mqttClient);
                }
            }

            if (mqtt_watchdog_timer == NULL) {
                const esp_timer_create_args_t wdt_args = {
                    .callback = mqtt_watchdog_cb,
                    .name = "mqtt_watchdog"
                };
                if (esp_timer_create(&wdt_args, &mqtt_watchdog_timer) == ESP_OK) {
                    esp_timer_start_periodic(mqtt_watchdog_timer, MQTT_WATCHDOG_INTERVAL_SEC * 1000000ULL);
                    ESP_LOGI(TAG, "MQTT watchdog timer started (every %ds, timeout %ds)",
                             MQTT_WATCHDOG_INTERVAL_SEC, MQTT_WATCHDOG_TIMEOUT_SEC);
                }
            }
            break;

        case NETWORK_EVENT_UPLINK_DOWN:
            /* Tell MQTT to disconnect so it doesn't sit on a dead socket
             * waiting for getaddrinfo / TCP timeouts. The client will be
             * forced back online via esp_mqtt_client_reconnect() in the
             * UPLINK_UP branch above when PPP recovers. Without this,
             * the client kept the original socket alive across the PPP
             * gap — sometimes resulting in 5+ minute delays before MQTT
             * detected the dead link via its internal keepalive. */
            ESP_LOGW(TAG, "uplink down — disconnecting MQTT client");
            if (mqttClient && mqtt_started) {
                esp_mqtt_client_disconnect(mqttClient);
            }
            break;

        case NETWORK_EVENT_SOFTAP_STARTED:
        case NETWORK_EVENT_SOFTAP_STOPPED:
            break;
    }
}

void request_pax_counter(void *arg) {
    ble_scan_start(PAX_SCAN_DURATION_SEC);
}

#define PIN_BOOT_BTN        GPIO_NUM_0
#define FACTORY_RESET_MS    5000  // hold for 5 seconds to trigger reset

static void factory_reset_task(void *arg) {
    gpio_config_t btn_cfg = {
        .pin_bit_mask = (1ULL << PIN_BOOT_BTN),
        .mode         = GPIO_MODE_INPUT,
        .pull_up_en   = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    gpio_config(&btn_cfg);

    while (1) {
        // Wait for button press (active low)
        if (gpio_get_level(PIN_BOOT_BTN) == 0) {
            TickType_t press_start = xTaskGetTickCount();

            // Wait while held
            while (gpio_get_level(PIN_BOOT_BTN) == 0) {
                TickType_t held_ms = (xTaskGetTickCount() - press_start) * portTICK_PERIOD_MS;
                if (held_ms >= FACTORY_RESET_MS) {
                    ESP_LOGW(TAG, "FACTORY RESET: button held %lu ms — erasing NVS and restarting", held_ms);
                    nvs_flash_erase();
                    esp_wifi_restore();
                    vTaskDelay(pdMS_TO_TICKS(200));
                    esp_restart();
                }
                vTaskDelay(pdMS_TO_TICKS(50));
            }
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void app_main(void) {

    /* Silence the chatty IDF subsystems that drown out our own logs.
     * These tags were emitting D-level lines several times per second
     * (every captive-portal poll, every NVS read, every PPP packet).
     * We keep ESP_LOG_WARN as the floor — actual problems still surface,
     * but the line-by-line parse trace is gone. */
    esp_log_level_set("httpd",          ESP_LOG_WARN);
    esp_log_level_set("httpd_parse",    ESP_LOG_WARN);
    esp_log_level_set("httpd_txrx",     ESP_LOG_WARN);
    esp_log_level_set("httpd_uri",      ESP_LOG_WARN);
    esp_log_level_set("httpd_sess",     ESP_LOG_WARN);
    esp_log_level_set("esp_netif_lwip", ESP_LOG_WARN);
    esp_log_level_set("esp_netif_handlers", ESP_LOG_WARN);
    esp_log_level_set("nvs",            ESP_LOG_WARN);
    esp_log_level_set("event",          ESP_LOG_WARN);
    esp_log_level_set("command_lib",    ESP_LOG_WARN);
    esp_log_level_set("intr_alloc",     ESP_LOG_WARN);
    esp_log_level_set("gdma",           ESP_LOG_WARN);
    esp_log_level_set("esp-modem",      ESP_LOG_INFO);
    esp_log_level_set("wifi",           ESP_LOG_WARN);

    gpio_set_direction(PIN_MDB_RX, GPIO_MODE_INPUT);
	gpio_set_direction(PIN_MDB_TX, GPIO_MODE_INPUT);  // idle: high-Z (tri-state)

	/* GPIO 12 = PIN_BUZZER_PWR on the production PCB (drives a buzzer).
	 * On the LilyGo T-SIM7080G-S3 the modem power isn't on a GPIO at
	 * all — it's on the AXP2101 PMU's DC3 channel addressed via I2C
	 * (see modem.c::modem_enable_pmu_rails). So we can keep the
	 * original LOW init here without affecting cellular bring-up. */
	gpio_set_direction(PIN_BUZZER_PWR, GPIO_MODE_OUTPUT);
	gpio_set_level(PIN_BUZZER_PWR, 0);

	//---------------- Strip LED configuration -----------------//
	//----------------------------------------------------------//
    xLedEventGroup = xEventGroupCreate();

    led_strip_config_t strip_config = {
        .strip_gpio_num = PIN_MDB_LED,
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

	//--------------- ADC Init (NTC thermistor) ----------------//
	//----------------------------------------------------------//
    adc_oneshot_unit_handle_t adc_handle;
    adc_oneshot_unit_init_cfg_t init_config = { .unit_id = ADC_UNIT_THERMISTOR, };
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&init_config, &adc_handle));

    adc_oneshot_chan_cfg_t config = { .atten = ADC_ATTEN_DB_12, .bitwidth = ADC_BITWIDTH_DEFAULT, };
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc_handle, ADC_CHANNEL_THERMISTOR, &config));

    int adc_raw_value;

    ESP_ERROR_CHECK(adc_oneshot_read(adc_handle, ADC_CHANNEL_THERMISTOR, &adc_raw_value));
    ESP_LOGI(TAG, "ADC Raw Data: %d", adc_raw_value);

	//---------------- UART1 - EVA DTS DEX/DDCMP ---------------//
	//----------------------------------------------------------//
	uart_config_t uart_config_1 = {
			.baud_rate = 9600,
			.data_bits = UART_DATA_8_BITS,
			.parity = UART_PARITY_DISABLE,
			.stop_bits = UART_STOP_BITS_1,
			.flow_ctrl = UART_HW_FLOWCTRL_DISABLE };

	uart_param_config(UART_NUM_1, &uart_config_1);
	uart_set_pin( UART_NUM_1, PIN_DEX_TX, PIN_DEX_RX, -1, -1);
	uart_driver_install(UART_NUM_1, 256, 256, 0, NULL, 0);

    // ---
    dexRingbuf = xRingbufferCreate(8 * 1024 /*8Kb*/, RINGBUF_TYPE_BYTEBUF);

    // DEX audit polled hourly. The backend compares consecutive snapshots
    // against `sales` counts to detect any vend that escaped the MQTT
    // pipeline (see dex_reconcile_gaps migration). 12h was too coarse to
    // catch short outages; 1h trades flash + UART time for meaningful
    // reconciliation resolution.
    const double INTERVAL_1H_US = 60ULL * 60 * 1000000; // 1h in microseconds

	const esp_timer_create_args_t periodic_timer_args = {
		.callback = &requestTelemetryData,
		.name = "task_dex_1h"
	};

	esp_timer_handle_t periodic_timer;
	esp_timer_create(&periodic_timer_args, &periodic_timer);
	esp_timer_start_periodic(periodic_timer, INTERVAL_1H_US);

	//-------------------- NETWORK STACK -----------------------//
	//----------------------------------------------------------//
	esp_err_t nvs_err = nvs_flash_init();
	if (nvs_err == ESP_ERR_NVS_NO_FREE_PAGES || nvs_err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
	    ESP_LOGW(TAG, "NVS partition invalid (%s), erasing and re-initialising", esp_err_to_name(nvs_err));
	    nvs_flash_erase();
	    nvs_err = nvs_flash_init();
	}
	if (nvs_err != ESP_OK) {
	    ESP_LOGE(TAG, "NVS init failed: %s", esp_err_to_name(nvs_err));
	} else {
	    ESP_LOGI(TAG, "NVS initialised OK");
	}
	//
	esp_netif_init();
	esp_event_loop_create_default();

	/* Network manager owns WiFi events, SoftAP lifecycle, modem probe,
	 * and the boot-time cellular vs WiFi branch. The callback below
	 * receives UPLINK_UP/DOWN and is the seam where MQTT + SNTP +
	 * watchdog get started/stopped. */
	network_register_callback(network_event_cb, NULL);

	//---------- NVS device config (before WiFi starts) -------//
	//----------------------------------------------------------//
	char myhost[96];
	strcpy(myhost, "0.vmflow.xyz"); // Default value

    nvs_handle_t handle;
	if (nvs_open("vmflow", NVS_READONLY, &handle) == ESP_OK) {

	    size_t s_len = 0;
	    if (nvs_get_str(handle, "passkey", NULL, &s_len) == ESP_OK) {
            nvs_get_str(handle, "passkey", my_passkey, &s_len);

            s_len = 0;
            if (nvs_get_str(handle, "company_id", NULL, &s_len) == ESP_OK) {
                nvs_get_str(handle, "company_id", my_company_id, &s_len);

                s_len = 0;
                if (nvs_get_str(handle, "device_id", NULL, &s_len) == ESP_OK) {
                    nvs_get_str(handle, "device_id", my_device_id, &s_len);

                    snprintf(myhost, sizeof(myhost), "%s.vmflow.xyz", my_device_id);

                    xEventGroupSetBits(xLedEventGroup, BIT_EVT_PSSKEY | BIT_EVT_DOMAIN | BIT_EVT_TRIGGER);
                }
            }
        }

        /* Read srv_url for OTA download validation */
        s_len = sizeof(my_srv_url);
        if (nvs_get_str(handle, "srv_url", my_srv_url, &s_len) == ESP_OK) {
            ESP_LOGI(TAG, "NVS: srv_url = %s", my_srv_url);
        }

        /* Read MDB device address from NVS (1 = 0x10, 2 = 0x60); fall back to Kconfig default */
        {
            uint8_t nvs_mdb_addr = 0;
            if (nvs_get_u8(handle, "mdb_addr", &nvs_mdb_addr) == ESP_OK) {
                if (nvs_mdb_addr == 1) {
                    cashless_device_address = 16;   /* 0x10 */
#ifdef CONFIG_MDB_SNIFF_OTHER_CASHLESS
                    mdb_sniff_address = 96;         /* 0x60 */
#endif
                } else if (nvs_mdb_addr == 2) {
                    cashless_device_address = 96;   /* 0x60 */
#ifdef CONFIG_MDB_SNIFF_OTHER_CASHLESS
                    mdb_sniff_address = 16;         /* 0x10 */
#endif
                }
                ESP_LOGI(TAG, "NVS: mdb_addr = %u (cashless=0x%02X, sniff=0x%02X)",
                         nvs_mdb_addr, cashless_device_address,
#ifdef CONFIG_MDB_SNIFF_OTHER_CASHLESS
                         mdb_sniff_address
#else
                         0
#endif
                );
            }
        }

		nvs_close(handle);
	}

	/* Log firmware version at boot */
	{
	    const esp_app_desc_t *app_desc = esp_app_get_description();
	    ESP_LOGW(TAG, "Firmware version: %s (compiled %s %s)", app_desc->version, app_desc->date, app_desc->time);
	}

	/* Read restart reason from NVS (set by tracked_restart() before last reboot) */
	{
	    esp_reset_reason_t hw_reason = esp_reset_reason();
	    pending_restart_hw = reset_reason_str(hw_reason);
	    ESP_LOGI(TAG, "HW reset reason: %s", pending_restart_hw);

	    nvs_handle_t rh;
	    if (nvs_open("vmflow", NVS_READWRITE, &rh) == ESP_OK) {
	        static char nvs_reason[32] = {0};
	        size_t rlen = sizeof(nvs_reason);
	        if (nvs_get_str(rh, "restart_reason", nvs_reason, &rlen) == ESP_OK && strlen(nvs_reason) > 0) {
	            pending_restart_reason = nvs_reason;
	            nvs_get_u32(rh, "last_uptime", &pending_restart_uptime);
	            // Erase so we don't re-report on next boot
	            nvs_erase_key(rh, "restart_reason");
	            nvs_erase_key(rh, "last_uptime");
	            nvs_commit(rh);
	            ESP_LOGI(TAG, "Restart reason: %s (uptime=%lus)", pending_restart_reason, (unsigned long)pending_restart_uptime);
	        } else {
	            // No software reason — derive from hardware reason
	            switch (hw_reason) {
	                case ESP_RST_POWERON:  pending_restart_reason = "power_on"; break;
	                case ESP_RST_PANIC:    pending_restart_reason = "panic"; break;
	                case ESP_RST_INT_WDT:
	                case ESP_RST_TASK_WDT:
	                case ESP_RST_WDT:      pending_restart_reason = "watchdog"; break;
	                case ESP_RST_BROWNOUT: pending_restart_reason = "brownout"; break;
	                default:               pending_restart_reason = NULL; break;  // SW_RESET without NVS reason = factory reset or unknown, don't report
	            }
	            if (pending_restart_reason) {
	                ESP_LOGI(TAG, "Restart reason (hw-derived): %s", pending_restart_reason);
	            }
	        }
	        nvs_close(rh);
	    }
	}

    //-------------------------- MQTT --------------------------//
	//----------------------------------------------------------//
	char lwt_topic[128];
	snprintf(lwt_topic, sizeof(lwt_topic), "/%s/%s/status", my_company_id, my_device_id);

	// Read MQTT settings from NVS (set via webui or claim-device), fall back to defaults
	char mqtt_uri[160] = "mqtt://mqtt.vmflow.xyz";
	char mqtt_user[64] = "vmflow";
	char mqtt_pass[64] = "vmflow";
	{
	    nvs_handle_t h;
	    if (nvs_open("vmflow", NVS_READONLY, &h) == ESP_OK) {
	        char mqtt_host[128] = {0};
	        size_t mlen = sizeof(mqtt_host);
	        if (nvs_get_str(h, "mqtt_host", mqtt_host, &mlen) == ESP_OK && strlen(mqtt_host) > 0) {
	            char mqtt_port_str[8] = {0};
	            size_t plen = sizeof(mqtt_port_str);
	            if (nvs_get_str(h, "mqtt_port", mqtt_port_str, &plen) == ESP_OK && strlen(mqtt_port_str) > 0) {
	                snprintf(mqtt_uri, sizeof(mqtt_uri), "mqtt://%s:%s", mqtt_host, mqtt_port_str);
	            } else {
	                snprintf(mqtt_uri, sizeof(mqtt_uri), "mqtt://%s", mqtt_host);
	            }
	        } else {
	            // No mqtt_host set — check if port override applies to default host
	            char mqtt_port_str[8] = {0};
	            size_t plen = sizeof(mqtt_port_str);
	            if (nvs_get_str(h, "mqtt_port", mqtt_port_str, &plen) == ESP_OK && strlen(mqtt_port_str) > 0) {
	                snprintf(mqtt_uri, sizeof(mqtt_uri), "mqtt://mqtt.vmflow.xyz:%s", mqtt_port_str);
	            }
	        }

	        size_t ulen = sizeof(mqtt_user);
	        nvs_get_str(h, "mqtt_user", mqtt_user, &ulen);

	        size_t pwlen = sizeof(mqtt_pass);
	        nvs_get_str(h, "mqtt_pass", mqtt_pass, &pwlen);

	        nvs_close(h);
	    }
	}
	ESP_LOGI(TAG, "MQTT broker: %s (user=%s)", mqtt_uri, mqtt_user);

	/* Cellular link is more latent than WiFi — bump keepalive (saves
	 * data quota) and timeouts (LTE-M latency). The watchdog still fires
	 * after MQTT_WATCHDOG_TIMEOUT_SEC if the broker is unreachable, so
	 * the longer keepalive only delays detection by ~2 minutes.
	 *
	 * Known limitation: at this point in app_main, network_init() has not
	 * yet been called (it runs after esp_mqtt_client_init below), so
	 * `modem_present` is still false and on_cellular evaluates to false
	 * even on cellular boards. Cellular boards therefore boot with the
	 * WiFi-tuned values on the first MQTT connect. The branch is kept
	 * because (a) it documents intent, and (b) any future refactor that
	 * moves network_init() earlier will pick up the cellular tuning
	 * automatically without code changes. Re-init'ing the MQTT client
	 * after NETWORK_EVENT_UPLINK_UP would give true cellular tuning on
	 * first boot, but is out of scope for P4. */
	network_status_t net_st;
	network_get_status(&net_st);
	bool on_cellular         = net_st.modem_present;
	int  mqtt_keepalive       = on_cellular ? 180   : 60;
	int  mqtt_network_timeout = on_cellular ? 30000 : 10000;
	int  mqtt_reconnect       = on_cellular ? 20000 : 5000;
	ESP_LOGI(TAG, "MQTT tuning: keepalive=%ds netto=%dms recto=%dms (cellular=%d)",
	         mqtt_keepalive, mqtt_network_timeout, mqtt_reconnect, on_cellular);

	const esp_mqtt_client_config_t mqttCfg = {
		.broker.address.uri = mqtt_uri,
        .credentials = {
            /* MQTT connection uses username/password authentication ONLY for broker ACL control.
             * Transport is intentionally non-TLS to reduce overhead on constrained devices.
             *
             * Security model:
             * - MQTT credentials are considered public / non-secret.
             * - Broker acts as a routing layer, not a security boundary.
             * - Broker ACLs limit publish/subscribe scope, reducing traffic amplification
             *   and preserving essential network operation in case of credential exposure.
             * - All application payloads are protected using a per-device XOR-based cipher,
             *   with a secret provisioned at installation time.
             * - Payload signing/obfuscation ensures basic integrity validation and
             *   prevents trivial message injection without knowledge of the device secret.
             */
            .username = mqtt_user,
            .authentication.password = mqtt_pass
        },
		.session.last_will.topic = lwt_topic, // LWT (Last Will and Testament)...
		.session.last_will.msg = "offline",
		.session.last_will.qos = 1,
		.session.last_will.retain = 1,
		/* MQTT-level keepalive: client sends PINGREQ every keepalive seconds;
		 * if the broker fails to answer with PINGRESP within ~1.5x keepalive
		 * the client closes the socket and fires MQTT_EVENT_DISCONNECTED,
		 * which the watchdog (mqtt_watchdog_cb) then picks up.
		 *
		 * We set this explicitly instead of relying on the ESP-IDF default
		 * (120s) so the dead-connection detection window is bounded and
		 * doesn't shift silently between IDF versions. Cellular bumps it to
		 * 180s to reduce data-plan PINGREQ traffic. */
		.session.keepalive = mqtt_keepalive,
		.session.disable_keepalive = false,
		/* Tighter network timeouts so a half-open TCP connection or a
		 * stalled DNS lookup fails fast and the watchdog can react.
		 * Cellular relaxes both because LTE-M / NB-IoT round-trips can
		 * legitimately take 5-10s. */
		.network.timeout_ms = mqtt_network_timeout,
		.network.reconnect_timeout_ms = mqtt_reconnect,
	};

	mqtt_publish_mutex = xSemaphoreCreateMutex();
	mqttClient = esp_mqtt_client_init(&mqttCfg);
	esp_mqtt_client_register_event(mqttClient, ESP_EVENT_ANY_ID, mqtt_event_handler, NULL);

	/* Offline-safe sales queue: restore pending entries from NVS and start
	 * the drain task. Must happen after mqttClient is created but before
	 * MDB event loop runs, so enqueued sales are tracked from the first
	 * vend. */
	sale_queue_init();
	sale_queue_start(mqttClient);

	//--------------- Factory reset (BOOT button) --------------//
	//----------------------------------------------------------//
	/* Spawned BEFORE network_init() so the 5-second-hold detection
	 * works while modem_probe is blocking the main task. modem_probe
	 * is synchronous and can take 5-30 s (warm-COMMAND fail → PPP
	 * escape → optional cold-boot poll on cellular boards). Earlier
	 * this task was created AFTER network_init returned, so any
	 * BOOT-button hold during the probe window was silently ignored —
	 * users had to retry the hold after the device finished booting,
	 * which is the opposite of how a recovery button should feel.
	 *
	 * The task itself is a poll loop (no interrupts) so it's safe to
	 * run concurrently with anything else. GPIO 0 isn't touched
	 * elsewhere in our code; the BOOT-pin pull-up is enabled here. */
	xTaskCreate(factory_reset_task, "factory_rst", 4096, NULL, 5, NULL);

	//-- Start network now that MQTT client is ready for events --//
	//-----------------------------------------------------------//
	/* network_init() probes the modem, takes the WiFi-vs-cellular
	 * branch, sets up esp_netif + esp_wifi_init + handler registration,
	 * and calls esp_wifi_start(). Once IP_EVENT_STA_GOT_IP fires, the
	 * UPLINK_UP callback above starts MQTT/SNTP/watchdog. */
	network_init();

	//------------------------ BLUETOOTH -----------------------//
	//----------------------------------------------------------//
	ble_init(myhost, ble_event_handler, ble_pax_event_handler);

	const esp_timer_create_args_t periodic_pax_timer_args = {
		.callback = &request_pax_counter,
		.name = "task_paxcounter"
	};

	esp_timer_handle_t periodic_pax_timer;
	esp_timer_create(&periodic_pax_timer_args, &periodic_pax_timer);
	esp_timer_start_periodic(periodic_pax_timer, PAX_SCAN_INTERVAL_US);

    //------------------------ MAIN TASKS ----------------------//
	//----------------------------------------------------------//
	mdbSessionQueue = xQueueCreate(1 /*queue-length*/, sizeof(uint16_t));
	xTaskCreatePinnedToCore(vTaskMdbEvent, "TaskMdbEvent", 4096, NULL, 1, NULL, 1);

    xTaskCreatePinnedToCore(vTaskBitEvent, "TaskBitEvent", 2048, NULL, 1, NULL, 0);
    xEventGroupSetBits(xLedEventGroup, BIT_EVT_TRIGGER);
}
