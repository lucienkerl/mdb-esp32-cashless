/*
 * VMflow.xyz
 *
 * modem.c — SIM7080G driver implementation
 */

#include "modem.h"

#include <string.h>
#include <esp_log.h>
#include <esp_err.h>
#include <nvs.h>

#include <esp_modem_api.h>
#include <esp_netif_ppp.h>
#include <esp_netif.h>
#include <driver/gpio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>

#define TAG "modem"

#define NVS_NAMESPACE   "vmflow"
#define NVS_KEY_APN     "apn"
#define NVS_KEY_PIN     "sim_pin"
#define NVS_KEY_MODE    "lte_mode"

/* Leonardo's custom mdb-slave-esp32s3-sim7080g PCB, confirmed against the
 * KiCad schematic (kicad/mdb-slave-esp32s3-sim7080g/) 2026-09-14: GPIO17
 * -> R3 -> U2 pin2 (UART1_RXD), GPIO18 -> R2 -> U2 pin1 (UART1_TXD), GPIO14
 * -> R6 -> Q2 (inverting transistor) -> U2 pin39 (PWRKEY).
 *
 * A short-lived LilyGo T-SIM7080G-S3 devboard used GPIO 4/5/41 instead
 * (no longer in use — production is Leonardo's PCB). Those pins also
 * aliased PIN_MDB_RX/PIN_MDB_TX, which doesn't apply here either since
 * this board has its own MDB UART pins separate from the modem's. */
#define MODEM_PIN_RX    GPIO_NUM_18   /* SIM7080G TX → ESP RX */
#define MODEM_PIN_TX    GPIO_NUM_17   /* ESP TX → SIM7080G RX */
#define MODEM_PIN_PWR   GPIO_NUM_14   /* PWRKEY via inverting transistor Q2 */
#define MODEM_UART_PORT UART_NUM_2
#define MODEM_BAUD      115200

/* PWRKEY polarity: true if the board uses an inverting transistor between
 * the ESP GPIO and the SIM7080G PWRKEY pin (GPIO high → transistor
 * conducts → PWRKEY low = "press"). false if wired direct.
 *
 * Leonardo's PCB drives PWRKEY through Q2, wired the same way as the
 * LilyGo reference design this constant was originally verified against:
 * ESP idles LOW, drives HIGH for the press duration to assert PWRKEY low,
 * then back. Hence INVERTED = 1. */
#define MODEM_PWRKEY_INVERTED 1

static esp_modem_dce_t  *s_dce  = NULL;
static esp_netif_t      *s_netif = NULL;
static bool              s_probed_present = false;

/* Track which esp_modem_set_mode we last issued — set after a successful
 * DATA transition, cleared by every primitive that re-enters COMMAND or
 * power-cycles the modem. The watchdog uses this flag (NOT
 * esp_netif_get_ip_info) to gate AT-pings: lwIP can clear the netif's
 * IP after LCP-echo timeout but before IP_EVENT_PPP_LOST_IP fires,
 * which created a window where the watchdog AT-pinged a still-up PPP
 * link (bytes interpreted as PPP frames, response never came back),
 * timed out 3x in 90s, and triggered a false hard-reset while the
 * Layer-1 PPP reconnect path was still about to start. */
static volatile bool     s_in_data_mode = false;

/* Recovery-path serialisation mutex — see modem.h for the full saga. */
static SemaphoreHandle_t s_modem_op_mtx = NULL;

void modem_op_lock(void) {
    /* Lazy init so the first caller wins regardless of task creation
     * order. xSemaphoreCreateRecursiveMutex is allocation-safe before
     * the scheduler starts (FreeRTOS allocates from the static heap),
     * but we only ever call this from running tasks. */
    if (!s_modem_op_mtx) {
        s_modem_op_mtx = xSemaphoreCreateRecursiveMutex();
    }
    if (s_modem_op_mtx) {
        /* 5 minute ceiling — generous enough for the worst-case
         * recovery ladder traversal (~3-4 min) but bounded so a stuck
         * holder eventually fails-loud rather than wedging forever. */
        if (xSemaphoreTakeRecursive(s_modem_op_mtx, pdMS_TO_TICKS(300000)) != pdTRUE) {
            ESP_LOGE(TAG, "modem_op_lock: 5min timeout — holder is wedged");
        }
    }
}

void modem_op_unlock(void) {
    if (s_modem_op_mtx) xSemaphoreGiveRecursive(s_modem_op_mtx);
}

/* Status cache.
 *
 * The captive portal polls /api/v1/system/info every ~2s, which calls
 * network_get_status → modem_status. The original implementation issued
 * three AT commands (AT+CSQ, AT+CEREG?, AT+COPS?) on every read with
 * 2s timeouts each. While cellular_bring_up_task was hammering AT+CFUN=1
 * (now 30s) and AT+CEREG? in a 2s polling loop, those three reads
 * queued behind it for tens of seconds — making the wizard look frozen.
 *
 * Fix: maintain a snapshot updated only from contexts that already own
 * the DCE (modem_wait_registered + post-registration finalisation), and
 * have modem_status() return it without issuing any AT. The mutex
 * guards readers that don't run on the bring-up task. */
static struct {
    SemaphoreHandle_t mtx;
    bool              registered;
    int               rssi_dbm;
    char              operator_name[32];
    modem_lte_mode_t  active_mode;
} s_status_cache = { 0 };

static void status_cache_lock(void)   { if (s_status_cache.mtx) xSemaphoreTake(s_status_cache.mtx, portMAX_DELAY); }
static void status_cache_unlock(void) { if (s_status_cache.mtx) xSemaphoreGive(s_status_cache.mtx); }

/* Load cellular config from NVS. Returns ESP_OK on success and fills the
 * outputs; returns ESP_ERR_NVS_NOT_FOUND if either the vmflow namespace
 * does not exist yet OR the apn key is missing/empty (caller treats both
 * as "no cellular config saved"). Returns ESP_ERR_INVALID_ARG if apn_out
 * is NULL or apn_size is 0. */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out) {
    if (!apn_out || apn_size == 0) return ESP_ERR_INVALID_ARG;

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_ERR_NVS_NOT_FOUND;
    if (err != ESP_OK) return err;

    size_t s = apn_size;
    err = nvs_get_str(h, NVS_KEY_APN, apn_out, &s);
    if (err != ESP_OK || strlen(apn_out) == 0) {
        nvs_close(h);
        return ESP_ERR_NVS_NOT_FOUND;
    }

    if (pin_out && pin_size > 0) {
        s = pin_size;
        if (nvs_get_str(h, NVS_KEY_PIN, pin_out, &s) != ESP_OK) {
            pin_out[0] = '\0';
        }
    }

    if (mode_out) {
        uint8_t m = MODEM_LTE_MODE_BOTH;
        nvs_get_u8(h, NVS_KEY_MODE, &m);
        /* Reject garbage from a corrupted or hand-edited NVS. */
        if (m < MODEM_LTE_MODE_CATM || m > MODEM_LTE_MODE_BOTH) {
            m = MODEM_LTE_MODE_BOTH;
        }
        *mode_out = (modem_lte_mode_t)m;
    }

    nvs_close(h);
    return ESP_OK;
}

esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode) {
    if (!apn || strlen(apn) == 0) return ESP_ERR_INVALID_ARG;

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    err = nvs_set_str(h, NVS_KEY_APN, apn);
    if (err == ESP_OK && pin) {
        err = nvs_set_str(h, NVS_KEY_PIN, pin);
    }
    if (err == ESP_OK) {
        err = nvs_set_u8(h, NVS_KEY_MODE, (uint8_t)mode);
    }
    if (err == ESP_OK) {
        err = nvs_commit(h);
    }
    nvs_close(h);
    return err;
}

/* The actual probe body — runs in a CPU-1-pinned helper task to dodge
 * an ESP-IDF v5.5.1 bug where iterating CPU-0 shared-vector descriptors
 * inside esp_intr_alloc trips an assert (find_desc_for_source
 * intr_alloc.c:199 svd != NULL). By running on CPU 1, the iteration
 * skips CPU-0 vectors entirely (else-if condition `vd->cpu == cpu`),
 * sidestepping the corrupted entry. The PPP netif and UART driver
 * end up bound to CPU 1, but that's fine — interrupts on either core
 * service the same UART hardware. */
static bool modem_probe_body(void);
static int8_t csq_to_dbm(int raw);
static void pwrkey_pulse(void);

typedef struct {
    SemaphoreHandle_t done;
    bool result;
} probe_args_t;

static void modem_probe_cpu1_task(void *arg) {
    probe_args_t *p = (probe_args_t *)arg;
    p->result = modem_probe_body();
    xSemaphoreGive(p->done);
    vTaskDelete(NULL);
}

bool modem_probe(void) {
    if (s_probed_present) {
        ESP_LOGI(TAG, "modem_probe: already probed (present)");
        return true;
    }

    probe_args_t args = { .done = xSemaphoreCreateBinary(), .result = false };
    if (!args.done) {
        ESP_LOGE(TAG, "modem_probe: semaphore alloc failed");
        return false;
    }
    BaseType_t ok = xTaskCreatePinnedToCore(modem_probe_cpu1_task,
                                              "modem_probe",
                                              8192, &args, 5, NULL, 1 /* CPU 1 */);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "modem_probe: failed to spawn CPU-1 task");
        vSemaphoreDelete(args.done);
        return false;
    }
    xSemaphoreTake(args.done, portMAX_DELAY);
    vSemaphoreDelete(args.done);
    return args.result;
}

static bool modem_probe_body(void) {
    /* Status cache mutex — created lazily so callers from non-bring-up
     * contexts (e.g. /api/v1/system/info HTTP handler) can read the
     * snapshot the moment we start populating it. */
    if (!s_status_cache.mtx) {
        s_status_cache.mtx = xSemaphoreCreateMutex();
        s_status_cache.active_mode = MODEM_LTE_MODE_BOTH;
    }

    /* Recovery-serialisation mutex — pre-create here while we're still
     * on the single boot task, so the lazy init in modem_op_lock never
     * races between watchdog + cellular_bring_up_task + ppp_reconnect_task
     * on first-use. */
    if (!s_modem_op_mtx) {
        s_modem_op_mtx = xSemaphoreCreateRecursiveMutex();
    }

    /* Build the temporary DTE/DCE. */
    esp_modem_dte_config_t dte_config = ESP_MODEM_DTE_DEFAULT_CONFIG();
    dte_config.uart_config.port_num   = MODEM_UART_PORT;
    dte_config.uart_config.baud_rate  = MODEM_BAUD;
    dte_config.uart_config.tx_io_num  = MODEM_PIN_TX;
    dte_config.uart_config.rx_io_num  = MODEM_PIN_RX;
    dte_config.uart_config.rts_io_num = -1;
    dte_config.uart_config.cts_io_num = -1;
    /* event_queue_size stays at the default 30 — esp_modem's UartTerminal
     * task asserts on a NULL event queue, so we cannot disable it.
     * The intr_alloc-shared-vector workaround for IDF v5.5.1 is in the
     * esp_modem managed_components patch (see modem_components_patch). */

    /* APN doesn't matter for the probe; pass an empty placeholder. */
    esp_modem_dce_config_t dce_config = ESP_MODEM_DCE_DEFAULT_CONFIG("");

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_PPP();
    s_netif = esp_netif_new(&netif_cfg);
    if (!s_netif) {
        ESP_LOGE(TAG, "esp_netif_new failed");
        return false;
    }

    s_dce = esp_modem_new_dev(ESP_MODEM_DCE_SIM7070, &dte_config, &dce_config, s_netif);
    if (!s_dce) {
        ESP_LOGE(TAG, "esp_modem_new_dev failed");
        esp_netif_destroy(s_netif);
        s_netif = NULL;
        return false;
    }

    /* Modem detection ladder, ordered by likelihood + cost.
     *
     * Three realistic states the modem can be in when we reach here:
     *   (A) warm-COMMAND — modem is on, in AT command mode. Single sync
     *       responds in ~500 ms.
     *   (B) warm-DATA    — modem is on, stuck in PPP DATA mode from a
     *       prior session (the modem stays powered across an ESP soft-
     *       reset, so any reboot — claim restart, watchdog reboot, OTA —
     *       lands here). Sync fails because AT bytes get eaten as PPP
     *       frames. Recovery: PPP escape via "+++" sequence (~7 s for
     *       esp_modem's internal 3 retries).
     *   (C) cold         — modem has no power, needs a PWRKEY pulse +
     *       ~4-12 s boot wait before AT works.
     *
     * Order matters because each path has a different cost on the wrong
     * state. Earlier (firmware dc9a2dc) we tried (B) by reordering to
     * cold-first, hoping to optimise initial provisioning. Field log
     * 2026-04-28 (firmware 9ca049f) showed the trade-off was wrong:
     * cold-first added 24 s on every soft-reset (warm-DATA case)
     * because PWRKEY-pulse on a running modem powers it OFF and the
     * 15 s poll then runs against a dead modem. Warm-DATA is the more
     * common case (every reboot after first boot) so we put it second
     * to PPP-escape it cheaply.
     *
     * Path costs:
     *   (A) ~0.5 s     — sync hit
     *   (B) ~7-8 s     — escape + sync
     *   (C) ~13-17 s   — escape miss + PWRKEY + boot poll */

    /* (A) Warm-COMMAND fast-path — single sync attempt. */
    esp_err_t ret = esp_modem_sync(s_dce);
    ESP_LOGI(TAG, "esp_modem_sync (warm-COMMAND probe): %s", esp_err_to_name(ret));

    if (ret != ESP_OK) {
        /* (B) Warm-DATA recovery — escape PPP via "+++". esp_modem's
         * set_mode(COMMAND) sends the escape, waits, retries up to 3x.
         * On a cold modem this still takes ~7 s (escape misses 3x) but
         * sets up the next path correctly.
         *
         * No PMU on this board to short-circuit a WiFi-only PCB (no
         * SIM7080G populated) — on that variant this just burns ~7 s
         * against floating UART pins before falling through to (C). */
        esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
        vTaskDelay(pdMS_TO_TICKS(500));
        ret = esp_modem_sync(s_dce);
        ESP_LOGI(TAG, "esp_modem_sync (after PPP escape): %s", esp_err_to_name(ret));
    }

    if (ret != ESP_OK) {
        /* (C) Cold-boot path — PWRKEY pulse + poll for AT readiness up
         * to 15 s. Each sync attempt has its own ~500 ms internal
         * timeout, so worst-case we burn the full window before
         * falling through. Same WiFi-only-PCB caveat as (B) above. */
        ESP_LOGI(TAG, "issuing PWRKEY pulse for cold-boot...");
        pwrkey_pulse();
        for (int i = 0; i < 15; i++) {
            vTaskDelay(pdMS_TO_TICKS(1000));
            ret = esp_modem_sync(s_dce);
            if (ret == ESP_OK) {
                ESP_LOGI(TAG, "esp_modem_sync (after PWRKEY + %d s): ESP_OK", i + 1);
                break;
            }
        }
    }

    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "no modem detected");
        esp_modem_destroy(s_dce);
        esp_netif_destroy(s_netif);
        s_dce = NULL;
        s_netif = NULL;
        gpio_reset_pin(MODEM_PIN_PWR);
        return false;
    }

    /* Configure PPP-related netif params now (one-time, at netif creation
     * time) so we don't re-set on every connect/disconnect cycle. */
    esp_netif_ppp_config_t ppp_cfg = { .ppp_phase_event_enabled = true };
    esp_netif_ppp_set_params(s_netif, &ppp_cfg);

    s_probed_present = true;
    ESP_LOGI(TAG, "modem detected and synced");
    return true;
}

bool modem_is_present(void) {
    return s_probed_present;
}

struct esp_modem_dce *modem_get_dce(void) {
    return (struct esp_modem_dce *)s_dce;
}

esp_err_t modem_init(const char *apn, const char *pin, modem_lte_mode_t mode) {
    if (!s_dce) {
        ESP_LOGE(TAG, "modem_init called before successful modem_probe");
        return ESP_ERR_INVALID_STATE;
    }
    if (!apn || strlen(apn) == 0) {
        ESP_LOGE(TAG, "modem_init: APN required");
        return ESP_ERR_INVALID_ARG;
    }

    status_cache_lock();
    s_status_cache.active_mode = mode;
    status_cache_unlock();

    esp_err_t err;

    /* AT+CSCLK=0: disable the modem's slow-clock / DTR-controlled sleep
     * mode. SIMCom AT Command Manual V1.05 §5.2.7 documents two modes:
     * 0 = disable, 1 = DTR-controlled. On a plug-powered MDB cashless
     * device we never want sleep, so 0 is correct. (Earlier code comment
     * here referenced a "CSCLK=2 = auto-sleep on UART idle" mode — that
     * does NOT exist in the documented SIM7080G AT manual; it was likely
     * confusion with older SIM800-series modules. Sending CSCLK=0 still
     * helps because it ensures the value is set even if some firmware
     * rev defaults to 1 with floating DTR.)
     *
     * Best-effort. */
    err = esp_modem_at(s_dce, "AT+CSCLK=0", NULL, 5000);
    ESP_LOGI(TAG, "AT+CSCLK=0: %s", esp_err_to_name(err));

    /* AT+CGEREP=2,1: report PDP context unsolicited events (mode 2:
     * buffer URCs while MT-TE link is reserved, forward when freed;
     * bfr 1: store URCs that arrive during reserved windows). Useful
     * as a diagnostic if the carrier is detaching us — events would
     * surface during PPP-COMMAND escapes (e.g. on watchdog ping or
     * recovery ladder). Best-effort. */
    err = esp_modem_at(s_dce, "AT+CGEREP=2,1", NULL, 5000);
    ESP_LOGI(TAG, "AT+CGEREP=2,1: %s", esp_err_to_name(err));

    /* SIM PIN, if provided. AT+CPIN expects only the PIN if it's needed;
     * if the SIM is PIN-less, sending AT+CPIN errors and we ignore that.
     * Done before the CFUN=0 cycle so the SIM is unlocked early — CPIN
     * needs the SIM powered, which is most reliable at default CFUN=1. */
    if (pin && strlen(pin) > 0) {
        err = esp_modem_set_pin(s_dce, pin);
        ESP_LOGI(TAG, "esp_modem_set_pin: %s", esp_err_to_name(err));
        /* Tolerate failure — SIM may not require PIN. */
    }

    /* NOTE on the missing AT+CFUN=0 cycle: SIMCom's S6 §6.2 reference
     * flow wraps CNMP/CMNB/CGDCONT in CFUN=0 → ... → CFUN=1, and an
     * earlier version of this code did so too (commit 497d3f7). Field
     * log 2026-04-29 (firmware f5d34bf) showed that introducing the
     * CFUN=0 cycle caused the FIRST PPP attempt after boot to fail
     * with IPCP timeout (30 s wait) — the post-CFUN=1 reattach left
     * the PDP context in a half-bound state where CGCONTRDP reports
     * the bearer "active" but the actual data plane isn't yet ready
     * for ATD*99##. The L1.5 recovery (now just CGACT=0,1, no
     * re-activate) then fixed it on the second try.
     *
     * That regression cost ~70 s on every cold boot for a "vendor
     * conformity" benefit that doesn't apply to PPP — Espressif's own
     * esp_modem ESP_MODEM_DCE_SIM7070 example does NOT do the cycle,
     * because for PPP the ATD*99## itself triggers the data-plane
     * bind, not CFUN=1. The S6 canonical flow is for the modem's
     * INTERNAL TCP stack (CNACT/CIPSTART), not host PPP.
     *
     * So we deliberately do NOT cycle CFUN here. CNMP/CMNB are
     * AUTO_SAVE per S1 §5.2.16/5.2.17 — they apply immediately
     * without a cycle, and modem_connect's CFUN=1 (which is a no-op
     * if already at 1) handles the registration. */

    /* Network mode: 38 = LTE only (we don't want GSM fallback). */
    err = esp_modem_at(s_dce, "AT+CNMP=38", NULL, 8000);
    ESP_LOGI(TAG, "AT+CNMP=38: %s", esp_err_to_name(err));

    /* CMNB selects within LTE: 1=Cat-M, 2=NB-IoT, 3=both. */
    char cmnb_cmd[24];
    snprintf(cmnb_cmd, sizeof(cmnb_cmd), "AT+CMNB=%d", (int)mode);
    err = esp_modem_at(s_dce, cmnb_cmd, NULL, 8000);
    ESP_LOGI(TAG, "%s: %s", cmnb_cmd, esp_err_to_name(err));

    /* Configure APN via the esp_modem helper (writes AT+CGDCONT). This
     * one IS load-bearing — without an APN the modem cannot attach.
     * Set with radio off (CFUN=0) so the next CFUN=1 attaches cleanly
     * with the new APN, matching SIMCom S6 §6.2 reference flow. */
    err = esp_modem_set_apn(s_dce, apn);
    ESP_LOGI(TAG, "esp_modem_set_apn(%s): %s", apn, esp_err_to_name(err));
    if (err != ESP_OK) return err;

    /* Enable +CEREG URC BEFORE the next CFUN=1 (in modem_connect) so
     * the URC fires on the post-attach registration event. If we set
     * it after CFUN=1, the URC may be missed for a fast attach. */
    esp_modem_at(s_dce, "AT+CEREG=1", NULL, 8000);

    /* Disable PSM (Power Save Mode) and eDRX (extended Discontinuous
     * Reception). IoT-oriented APNs like Telekom's `sensor.net` enable
     * both by default to save battery — at the cost of MQTT/TLS
     * reachability:
     *
     *   - PSM: modem detaches and sleeps for up to 3.5h, drops carrier
     *     NAT translations, server-initiated traffic is lost, outbound
     *     SYNs come back as ICMP host-unreachable until the modem
     *     wakes on its own schedule.
     *   - eDRX: modem listens for paging only every X seconds (up to
     *     ~163s on LTE-M, ~10485s on NB-IoT). Carrier NAT entries
     *     evict during the dark window, MQTT pings can't reach back.
     *
     * Field symptom (captured from a Telekom IoT SIM):
     *   E esp-tls: [sock=N] connect() error: Host is unreachable
     *   E mqtt_client: Error transport connect
     *   ...repeated every 5s as the MQTT client retries...
     *
     * Even though PPP nominally stays up (lwIP's netif still has the
     * IP), TCP packets just never reach the broker. We need an
     * always-on radio for an MDB cashless device — battery isn't a
     * concern, plug power is. So: disable both. Best-effort: some
     * carriers reject the AT (we want PSM off but they won't allow
     * client-side override) — log and continue. */
    esp_modem_at(s_dce, "AT+CPSMS=0", NULL, 5000);
    /* AcT 4 = LTE-M (Cat-M1), 5 = NB-IoT. Sending both covers either
     * RAT regardless of CMNB above. */
    esp_modem_at(s_dce, "AT+CEDRXS=0,4", NULL, 5000);
    esp_modem_at(s_dce, "AT+CEDRXS=0,5", NULL, 5000);
    ESP_LOGI(TAG, "PSM + eDRX disabled (IoT power-save off)");

    /* Phantom-PPP defence — see field log at commit 0cbcc1e for the
     * full saga of why we're NOT proactively running CIPSHUT/CNACT
     * cleanup here:
     *
     *   1. Phantom-PPP first observed: TLS cert downloads ok, CKE
     *      never reaches server. Theory: SIM7080G dual stack residue.
     *   2. Added AT+CIPSHUT + AT+CNACT=0,0 to clear residue.
     *   3. Field test showed those ATs leave the modem unresponsive
     *      for 60+ s on warm boots, AND detach from PS network.
     *   4. Added AT+CGATT=1 to force re-attach. Made it worse — modem
     *      doesn't even ack CGATT=1 in 30 s.
     *
     * The cleanups did more harm than good. Removed.
     *
     * Phantom-PPP is now caught REACTIVELY by two layers:
     *
     *   a) cellular_bring_up_task probes 1.1.1.1:53 with 5 s timeout
     *      after IP_EVENT_PPP_GOT_IP, BEFORE firing UPLINK_UP.
     *      Failed probe → recovery ladder fires.
     *   b) Recovery ladder (PDP→RF→Soft→Hard reset) at the right
     *      modem state where each reset is appropriate for the level
     *      of breakage observed.
     *
     * Net effect: same protection, no aggressive proactive ATs that
     * the modem firmware mishandles. */

    return ESP_OK;
}

/* Extract the registration `stat` field from a +CEREG response.
 * Format: "+CEREG: <n>,<stat>[,...]". Returns -1 if unparseable. */
static int parse_cereg_stat(const char *resp) {
    const char *p = strstr(resp, "+CEREG:");
    if (!p) return -1;
    int n = 0, stat = -1;
    if (sscanf(p, "+CEREG: %d,%d", &n, &stat) != 2) return -1;
    return stat;
}

/* Poll AT+CEREG? until stat == 1 (home) or 5 (roaming). Up to 60 s.
 * Uses positional parsing rather than strstr(",1") to avoid false
 * positives on trailing AcT or location fields.
 *
 * Side effect: each iteration also samples AT+CSQ and updates the
 * shared status cache (registered + rssi_dbm). modem_status() reads
 * only that cache, so the captive portal can poll /system/info every
 * 2s without queueing AT commands behind us. */
static esp_err_t modem_wait_registered(void) {
    /* esp_modem_at copies up to CONFIG_ESP_MODEM_C_API_STR_MAX (128) bytes
     * regardless of buffer size — match that to avoid stack overflow on
     * verbose firmware responses. */
    char resp[128];
    for (int i = 0; i < 30; i++) {
        memset(resp, 0, sizeof(resp));
        esp_err_t err = esp_modem_at(s_dce, "AT+CEREG?", resp, 3000);
        bool registered = false;
        if (err == ESP_OK) {
            int stat = parse_cereg_stat(resp);
            registered = (stat == 1 || stat == 5);
        }

        /* Sample CSQ on every tick — cheap (~50 ms) and gives the
         * captive portal a live signal-strength readout while waiting. */
        char csq[64] = {0};
        int rssi_dbm_now = 0;
        if (esp_modem_at(s_dce, "AT+CSQ", csq, 1500) == ESP_OK) {
            const char *p = strstr(csq, "+CSQ:");
            int rssi_raw = -1, ber = -1;
            if (p && sscanf(p, "+CSQ: %d,%d", &rssi_raw, &ber) >= 1 &&
                rssi_raw >= 0 && rssi_raw <= 31) {
                rssi_dbm_now = csq_to_dbm(rssi_raw);
            }
        }

        status_cache_lock();
        s_status_cache.registered = registered;
        if (rssi_dbm_now != 0) s_status_cache.rssi_dbm = rssi_dbm_now;
        status_cache_unlock();

        if (registered) {
            ESP_LOGI(TAG, "EPS registered: %s", resp);
            return ESP_OK;
        }
        ESP_LOGW(TAG, "not registered (attempt %d/30): %s", i + 1, resp);
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    return ESP_ERR_TIMEOUT;
}

esp_err_t modem_connect(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    /* Make sure RF is on (some modems boot at CFUN=4 = airplane).
     *
     * CFUN=1 is the load-bearing radio-enable command — without it the
     * modem stays in airplane mode and CEREG never fires. SIM7080G can
     * take 10-25 seconds to acknowledge CFUN=1 on cold boot because it
     * has to bring up the RF front-end, scan bands, and read the SIM
     * card before responding OK. Earlier 5s timeout was way too short
     * and made the cellular path silently broken on a fresh boot —
     * AT+CEREG? would then keep returning empty because the radio
     * hadn't actually come up yet. 30 s is the practical safe ceiling. */
    esp_err_t err = esp_modem_at(s_dce, "AT+CFUN=1", NULL, 30000);
    ESP_LOGI(TAG, "AT+CFUN=1: %s", esp_err_to_name(err));

    err = modem_wait_registered();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "registration timeout");
        return err;
    }

    /* Verify PDP context is actually active before entering DATA mode.
     *
     * On LTE the default bearer auto-activates with registration, but
     * the activation can lag the +CEREG: 1 URC by a couple of seconds.
     * AT+CGCONTRDP returns the dynamic IP/DNS/gateway the network
     * assigned us — if the response is empty we registered but the
     * data attach hasn't completed. Going to DATA mode now would yield
     * the "PPP up but no data" symptom (ATD returns CONNECT but the
     * underlying GTP tunnel isn't really there yet).
     *
     * We poll for up to 5 s. Best-effort — if AT+CGCONTRDP isn't
     * supported on a particular firmware rev we fall through and let
     * the post-PPP reachability probe in network.c catch any residual
     * "phantom PPP" cases. */
    {
        char rdp_resp[256];
        for (int i = 0; i < 5; i++) {
            memset(rdp_resp, 0, sizeof(rdp_resp));
            if (esp_modem_at(s_dce, "AT+CGCONTRDP=1", rdp_resp, 3000) == ESP_OK
                    && strstr(rdp_resp, "+CGCONTRDP:") != NULL) {
                ESP_LOGI(TAG, "PDP context active: %.120s%s",
                         rdp_resp, strlen(rdp_resp) > 120 ? "..." : "");
                break;
            }
            ESP_LOGW(TAG, "PDP not yet active (try %d/5), waiting 1 s", i + 1);
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }

    /* Pull operator name + actual RAT into the cache while we're still
     * in COMMAND mode — once we switch to DATA, AT becomes expensive
     * (PPP escape). Best-effort: ignore failure, the cache just stays
     * at the configured preference (CMNB).
     *
     * Response format (3GPP TS 27.007 §7.3):
     *   +COPS: <mode>,<format>,"<oper>",<AcT>
     * e.g. on Telekom IoT:
     *   +COPS: 0,0,"Telekom.de",7
     *
     * <AcT> values relevant to SIM7080G:
     *   7 = E-UTRAN  (LTE-M / Cat-M1)
     *   9 = E-UTRAN NB-S1 (NB-IoT)
     * Anything else (GSM 0/3, UMTS 2, etc.) shouldn't happen on this
     * modem since CNMP=38 forces LTE-only — we leave active_mode at
     * the configured value if we see an unexpected AcT. */
    {
        char resp[128] = {0};
        if (esp_modem_at(s_dce, "AT+COPS?", resp, 2000) == ESP_OK) {
            ESP_LOGI(TAG, "AT+COPS?: %s", resp);
            const char *first  = strchr(resp, '"');
            const char *second = first ? strchr(first + 1, '"') : NULL;
            if (first && second && second > first + 1) {
                size_t len = second - first - 1;
                if (len >= sizeof(s_status_cache.operator_name)) {
                    len = sizeof(s_status_cache.operator_name) - 1;
                }
                status_cache_lock();
                memcpy(s_status_cache.operator_name, first + 1, len);
                s_status_cache.operator_name[len] = '\0';
                status_cache_unlock();

                /* AcT is the digit after the comma following the closing quote. */
                const char *p = second + 1;
                while (*p == ',' || *p == ' ') p++;
                if (*p >= '0' && *p <= '9') {
                    int act = *p - '0';
                    modem_lte_mode_t actual = MODEM_LTE_MODE_BOTH;
                    if      (act == 7) actual = MODEM_LTE_MODE_CATM;
                    else if (act == 9) actual = MODEM_LTE_MODE_NBIOT;
                    if (actual != MODEM_LTE_MODE_BOTH) {
                        status_cache_lock();
                        s_status_cache.active_mode = actual;
                        status_cache_unlock();
                        ESP_LOGI(TAG, "registered on RAT %d → %s", act,
                                 actual == MODEM_LTE_MODE_CATM ? "LTE-M" : "NB-IoT");
                    } else {
                        ESP_LOGW(TAG, "registered on unexpected AcT %d — keeping configured mode", act);
                    }
                }
            }
        }
    }

    /* PPP params already set in modem_probe — just enter DATA mode. */
    err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_DATA);
    ESP_LOGI(TAG, "set DATA mode: %s", esp_err_to_name(err));
    if (err == ESP_OK) {
        s_in_data_mode = true;
    }
    return err;
}

esp_err_t modem_disconnect(void) {
    if (!s_dce) return ESP_OK;
    /* Clear the flag eagerly — once we initiate the COMMAND transition,
     * any in-flight watchdog ping must see "not in DATA" so the AT goes
     * out via the right path. set_mode itself can take seconds (PPP
     * teardown round-trips); the modem stops eating AT bytes the moment
     * the +++/ATH escape sequence completes mid-call. */
    s_in_data_mode = false;
    esp_err_t err = esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    ESP_LOGI(TAG, "set COMMAND mode: %s", esp_err_to_name(err));
    return err;
}

/* Lightweight pause/resume — uses esp_modem's pause_netif which suspends
 * the lwIP PPP netif (no full teardown) and switches the modem to
 * COMMAND mode in ~1 s. Resume is also ~1 s. Total round-trip cost for
 * a quick AT-command window is ~2 s vs ~32 s for modem_disconnect +
 * modem_connect.
 *
 * Field rationale: claim flow over modem-internal HTTPS used to call
 * modem_disconnect (32 s teardown) → AT commands (4 s) →
 * modem_connect (6 s) = ~42 s. Switching to pause/resume cuts that
 * to ~6 s end-to-end. */
esp_err_t modem_pause(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;
    if (!s_in_data_mode) {
        ESP_LOGW(TAG, "modem_pause: not in DATA mode — nothing to pause");
        return ESP_FAIL;
    }
    esp_err_t err = esp_modem_pause_net(s_dce, true);
    if (err == ESP_OK) {
        s_in_data_mode = false;
        ESP_LOGI(TAG, "PPP paused (modem in COMMAND mode)");
    } else {
        ESP_LOGW(TAG, "esp_modem_pause_net(true) failed: %s", esp_err_to_name(err));
    }
    return err;
}

esp_err_t modem_resume(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;
    esp_err_t err = esp_modem_pause_net(s_dce, false);
    if (err == ESP_OK) {
        s_in_data_mode = true;
        ESP_LOGI(TAG, "PPP resumed (modem in DATA mode)");
    } else {
        ESP_LOGW(TAG, "esp_modem_pause_net(false) failed: %s", esp_err_to_name(err));
    }
    return err;
}

/* PWRKEY pulse helper. Single 1.2s press — that's a TOGGLE on SIM7080G:
 * if the modem is off it powers it on; if on, it powers it off (graceful
 * shutdown, ~3s before STATUS goes low).
 *
 * Original SIM7080 Hardware Design v1.04 §3.4: PWRKEY low ≥1.0s for
 * power-on, ≥1.2s for power-off. We use 1.2s which works for both. */
static void pwrkey_pulse(void) {
    gpio_set_direction(MODEM_PIN_PWR, GPIO_MODE_OUTPUT);
    const int idle_level    = MODEM_PWRKEY_INVERTED ? 0 : 1;
    const int pressed_level = MODEM_PWRKEY_INVERTED ? 1 : 0;

    gpio_set_level(MODEM_PIN_PWR, idle_level);
    vTaskDelay(pdMS_TO_TICKS(100));
    gpio_set_level(MODEM_PIN_PWR, pressed_level);
    vTaskDelay(pdMS_TO_TICKS(1200));
    gpio_set_level(MODEM_PIN_PWR, idle_level);
}

void modem_power_cycle(void) {
    /* Original use case: modem is OFF (cold boot), this pulse turns it ON.
     * Used by modem_probe at boot. Keeping name + behaviour for backward
     * compat. For an actual power CYCLE on a running modem, use
     * modem_hard_reset() instead — that's the function field-tests showed
     * we actually need (single PWRKEY pulse on a running modem only
     * powers it off and leaves it off).
     *
     * Caller is responsible for knowing the modem is currently OFF. */
    pwrkey_pulse();
    ESP_LOGI(TAG, "PWRKEY pulsed; waiting 8 s for boot...");
    vTaskDelay(pdMS_TO_TICKS(8000));
}

/* === Recovery escalation ladder ============================================
 *
 * Per SIMCom AT Command Manual + LilyGo + esp-protocols field reports, the
 * stable recovery path on SIM7080G has four levels, in order of cost:
 *
 *   L1.5  modem_pdp_reset()    ~5 s   — CGACT down/up. Fixes "stuck PDP
 *                                       context" where a previous session's
 *                                       state lingers.
 *   L1.6  modem_rf_reset()    ~10 s   — AT+CFUN=0/1. Fixes stuck cell
 *                                       registration / handover failures.
 *   L2    modem_soft_restart() ~12 s  — AT+CFUN=1,1 firmware reboot. Fixes
 *                                       almost all internal modem-firmware
 *                                       hangs without losing power.
 *   L3    modem_hard_reset()  ~15 s   — PWRKEY toggle-pair. Last resort
 *                                       short of factory reset; resets
 *                                       hardware unconditionally.
 *
 * Each must be followed by modem_init() + modem_connect() to re-establish
 * the application stack. Recovery total budget under 1 minute before
 * escalating to next level, so worst-case ~3-4 minutes ladder traversal
 * before bailing OFFLINE. The ppp_reconnect_task / cellular_bring_up_task
 * paths drive this ladder. */

/* L1.5: PDP context deactivation. Cheapest reset — keeps RF + registration.
 *
 * IMPORTANT: We deliberately do NOT call AT+CGACT=1,1 to re-activate.
 * SIMCom AT Command Manual V1.05 §6.2.3 NOTE explicitly states:
 *
 *   "This command is used to test PDPs with network simulators.
 *    Successful activation of PDP on real network is not guaranteed."
 *
 * On LTE/Cat-M/NB-IoT the default PDP context auto-activates with EPS
 * registration — we just need to deactivate cleanly. The next CFUN=1
 * cycle (or even just registration time) re-binds the bearer
 * automatically. Manually issuing CGACT=1,1 is exactly what creates
 * the half-bound "phantom-PPP" state where IPCP completes but outbound
 * traffic silently drops at the GTP layer — see CLAUDE.md "LTE PDP
 * context auto-activates" memory.
 *
 * Caller is responsible for the modem_connect() call afterwards which
 * does CFUN=1 → CEREG poll → CGCONTRDP verify. That's the path
 * SIMCom's own §6.2 reference flow uses. */
esp_err_t modem_pdp_reset(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    /* Must be in COMMAND mode to issue AT. If we're in DATA, escape. */
    s_in_data_mode = false;
    esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    vTaskDelay(pdMS_TO_TICKS(500));

    char resp[64];
    ESP_LOGW(TAG, "L1.5 recovery: AT+CGACT=0,1 (deactivate PDP — auto-reattach via CFUN cycle)");
    esp_err_t err = esp_modem_at(s_dce, "AT+CGACT=0,1", resp, 5000);
    vTaskDelay(pdMS_TO_TICKS(1000));
    ESP_LOGI(TAG, "L1.5 recovery: result=%s (re-activation deferred to next modem_connect)",
             esp_err_to_name(err));
    return err;
}

/* L1.6: Radio reset. Resets RF stack, keeps SIM session and modem firmware. */
esp_err_t modem_rf_reset(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    s_in_data_mode = false;
    esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    vTaskDelay(pdMS_TO_TICKS(500));

    char resp[32];
    ESP_LOGW(TAG, "L1.6 recovery: AT+CFUN=0 (radio off)");
    esp_modem_at(s_dce, "AT+CFUN=0", resp, 10000);
    vTaskDelay(pdMS_TO_TICKS(2000));   /* let the network see the detach */
    ESP_LOGW(TAG, "L1.6 recovery: AT+CFUN=1 (radio on)");
    esp_err_t err = esp_modem_at(s_dce, "AT+CFUN=1", resp, 30000);
    ESP_LOGI(TAG, "L1.6 recovery: result=%s", esp_err_to_name(err));
    return err;
}

/* L2: Soft firmware restart. Modem stays powered; firmware reboots cleanly.
 * AT+CFUN=1,1 returns OK first then the modem detaches/reattaches. We can't
 * AT until ~10s later. */
esp_err_t modem_soft_restart(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    s_in_data_mode = false;
    esp_modem_set_mode(s_dce, ESP_MODEM_MODE_COMMAND);
    vTaskDelay(pdMS_TO_TICKS(500));

    char resp[32];
    ESP_LOGW(TAG, "L2 recovery: AT+CFUN=1,1 (soft restart)");
    esp_modem_at(s_dce, "AT+CFUN=1,1", resp, 5000);
    vTaskDelay(pdMS_TO_TICKS(10000));   /* boot wait */
    ESP_LOGI(TAG, "L2 recovery: modem should be back");
    return ESP_OK;
}

/* L3: Hardware power cycle via a PWRKEY toggle pair. The cleanest reset
 * short of factory_reset — resets the modem hardware unconditionally
 * regardless of internal state. No PMU on this board to power-gate the
 * modem, so this is the best we can do. */
void modem_hard_reset(void) {
    /* Power-cycling the modem makes any prior DATA-mode binding moot —
     * clear the flag first so a watchdog tick during the boot wait
     * doesn't see "PPP up" and skip its AT-ping. */
    s_in_data_mode = false;

    /* PWRKEY pulse pair. First press toggles state (modem-on → off,
     * modem-off → on); we wait through the modem's shutdown sequence
     * (~3 s typical), then a second press to ensure we end up in the
     * "on" state. */
    ESP_LOGW(TAG, "L3 recovery: PWRKEY toggle-pair");
    pwrkey_pulse();                    /* may turn off if was on */
    vTaskDelay(pdMS_TO_TICKS(3000));   /* let modem complete shutdown */
    pwrkey_pulse();                    /* turn on (if off) */

    /* Poll for modem readiness instead of a fixed wait. SIM7080G boot
     * after the PWRKEY toggle-pair takes typically 6-12 s, but
     * has been observed up to 18 s on cold cells (signal scan +
     * SIM-read on weak coverage). The previous fixed 8 s wait was
     * shorter than the typical case — every subsequent AT (modem_init's
     * CNMP/CMNB/CFUN) timed out for 16-25 s into the not-yet-booted
     * modem (field log 2026-04-28 lines 283358-391858), turning a
     * 15 s recovery into a 2-minute cascade.
     *
     * Initial 5 s settle is below the practical floor — no point
     * polling earlier than that. Each poll uses esp_modem_sync's
     * default 500 ms timeout, so worst-case 20 polls = ~25 s total
     * after settle. */
    ESP_LOGI(TAG, "L3 recovery: polling for modem readiness (initial 5 s settle)...");
    vTaskDelay(pdMS_TO_TICKS(5000));

    if (!s_dce) {
        /* Probe failed — nothing to sync against. Give the rails the
         * old fixed wait as a fallback courtesy. */
        vTaskDelay(pdMS_TO_TICKS(8000));
        return;
    }

    for (int i = 0; i < 20; i++) {
        if (esp_modem_sync(s_dce) == ESP_OK) {
            ESP_LOGI(TAG, "L3 recovery: modem responsive after %d s post-settle", i + 1);
            return;
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    ESP_LOGW(TAG, "L3 recovery: modem still not responsive after 25 s — proceeding anyway");
}

/* Lightweight power-kick — fire-and-forget cycle for use just before
 * esp_restart(). No readiness polling: host is about to reboot anyway,
 * and modem_probe on the next boot does its own sync polling.
 *
 * No PMU on this board, so this is a single PWRKEY toggle: it will turn
 * the modem off if it was on. The next boot's modem_probe will warm-DATA
 * -test then do its own PWRKEY if the modem ends up off. Not as clean as
 * a true power cycle but non-blocking (~500 ms). */
void modem_kick_for_host_reboot(void) {
    s_in_data_mode = false;
    ESP_LOGW(TAG, "kick-reboot: single PWRKEY toggle");
    pwrkey_pulse();
}

/* Convert AT+CSQ raw value (0-31, 99 = unknown) to dBm. Per 3GPP 27.007:
 *   raw = 0   → -113 dBm
 *   raw = 31  → -51 dBm
 *   raw = 99  → unknown (return 0)
 *   else      → -113 + 2 * raw */
static int8_t csq_to_dbm(int raw) {
    if (raw == 99 || raw < 0 || raw > 31) return 0;
    return -113 + (raw * 2);
}

void modem_status(modem_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->active_mode = MODEM_LTE_MODE_BOTH;

    if (!s_dce) return;

    /* Pure cache read — no AT commands. Issuing AT here would queue
     * behind cellular_bring_up_task's CFUN=1 / CEREG-poll loop and
     * stall the captive portal HTTP server for tens of seconds.
     *
     * The cache is filled by:
     *   - modem_wait_registered (registered + rssi, every 2s during
     *     registration)
     *   - modem_connect post-registration (operator name, one-shot
     *     before DATA-mode switch)
     *   - watchdog tick post-PPP could refresh, but in DATA mode an
     *     AT requires PPP escape and is expensive — we accept slightly
     *     stale RSSI/operator in steady state.
     */
    status_cache_lock();
    out->registered  = s_status_cache.registered;
    out->rssi_dbm    = s_status_cache.rssi_dbm;
    out->active_mode = s_status_cache.active_mode;
    strncpy(out->operator_name, s_status_cache.operator_name, sizeof(out->operator_name) - 1);
    status_cache_unlock();

    /* IP address comes from the netif (no AT involved, always safe). */
    if (s_netif) {
        esp_netif_ip_info_t ip_info;
        if (esp_netif_get_ip_info(s_netif, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
            esp_ip4addr_ntoa(&ip_info.ip, out->ip, sizeof(out->ip));
        }
    }
}

/* === Watchdog =========================================================
 *
 * Polls the modem with a bare "AT" every WATCHDOG_TICK_SEC. On three
 * consecutive failures escalates to power-cycle + re-init + re-connect.
 * Layer-3 hard-reboot is the existing mqtt_watchdog_cb in main.c —
 * we never call esp_restart() from here.
 *
 * Forward-compatibility note (P5): the watchdog tick also refreshes
 * RSSI / operator into a static struct, so /system/info and the
 * MQTT status payload can read them without re-issuing AT every poll.
 * ===================================================================== */

#define WATCHDOG_TICK_SEC            30
#define WATCHDOG_FAIL_TO_POWER_CYCLE  3
#define WATCHDOG_POWER_CYCLE_LIMIT    2

static TaskHandle_t  s_watchdog_task = NULL;
static int           s_consec_fails  = 0;
static int           s_power_cycles  = 0;

esp_err_t modem_at_keepalive_ping(void) {
    if (!s_dce) return ESP_ERR_INVALID_STATE;

    /* In DATA (PPP) mode AT commands cannot pass through — the bytes
     * would be interpreted as PPP frames. Earlier versions tried to
     * "escape" by calling esp_modem_set_mode(COMMAND), but that tears
     * the live PPP link down: every 30s tick killed any in-flight
     * HTTP/MQTT/TLS session, observed in the field as
     *
     *   D HTTP_CLIENT: Write header[4]: POST /functions/v1/claim-device ...
     *   D esp-netif_lwip-ppp: esp_netif_stop_ppp: Stopped PPP connection
     *   E esp-tls-mbedtls: read error :-0x004C
     *
     * 30 s after PPP came up. The claim could never finish.
     *
     * In DATA mode we rely on PPP's own LCP-echo mechanism (lwIP
     * pppos default ~30 s interval, 4 retries) to detect a dead
     * modem. If the PPP link drops, IP_EVENT_PPP_LOST_IP fires and
     * Layer-1 reconnect handles it. So: skip the AT ping in DATA mode
     * and report OK — the PPP layer is the authoritative liveness
     * signal there.
     *
     * IMPORTANT: we use the s_in_data_mode flag (set/cleared on
     * application-side esp_modem_set_mode transitions) rather than
     * esp_netif_get_ip_info. lwIP can clear the netif's IP after an
     * LCP-echo failure but before IP_EVENT_PPP_LOST_IP fires, leaving
     * a window where the IP-based gate would say "no IP, AT-ping is
     * fine" — and the AT bytes would be eaten by the still-up PPP
     * link, time out 3x in 90 s, and trigger a false hard-reset (field
     * 2026-04-28). The mode flag tracks intent independently of lwIP
     * timing and never reports a false negative. */
    if (s_in_data_mode) {
        return ESP_OK;
    }

    /* COMMAND mode (registration phase or recovery): AT works directly. */
    char resp[32];
    return esp_modem_at(s_dce, "AT", resp, 3000);
}

static void modem_watchdog_task(void *arg) {
    (void)arg;
    ESP_LOGI(TAG, "watchdog: starting (tick=%ds, fail-to-pulse=%d)",
             WATCHDOG_TICK_SEC, WATCHDOG_FAIL_TO_POWER_CYCLE);

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(WATCHDOG_TICK_SEC * 1000));

        esp_err_t err = modem_at_keepalive_ping();
        if (err == ESP_OK) {
            if (s_consec_fails) {
                ESP_LOGI(TAG, "watchdog: AT recovered after %d fails", s_consec_fails);
            }
            s_consec_fails = 0;
            s_power_cycles = 0;
            continue;
        }

        s_consec_fails++;
        ESP_LOGW(TAG, "watchdog: AT ping failed (%d/%d): %s",
                 s_consec_fails, WATCHDOG_FAIL_TO_POWER_CYCLE,
                 esp_err_to_name(err));

        if (s_consec_fails < WATCHDOG_FAIL_TO_POWER_CYCLE) continue;

        /* Layer 2: hard-reset the modem (PWRKEY toggle-pair) and re-init.
         * Bounded by WATCHDOG_POWER_CYCLE_LIMIT so a dead chip doesn't burn
         * flash cycles forever — Layer 3 (mqtt_watchdog_cb) reboots the
         * device after another 5-10 minutes.
         *
         * NOTE: previously called modem_power_cycle() which only pulses
         * PWRKEY once. On a running SIM7080G a single 1.2 s PWRKEY pulse
         * is the "graceful power-off" command, not a reset — the modem
         * shuts down and stays off, leaving subsequent AT commands timing
         * out forever. modem_hard_reset() does the actual cycle: PMU DC3
         * cut + re-enable + PWRKEY-pulse-to-boot. */
        if (s_power_cycles >= WATCHDOG_POWER_CYCLE_LIMIT) {
            ESP_LOGE(TAG, "watchdog: power-cycle limit reached — leaving Layer 3 to handle");
            s_consec_fails = 0;   /* let it re-arm; Layer 3 will reboot eventually */
            continue;
        }

        ESP_LOGW(TAG, "watchdog: Layer 2 — modem_hard_reset + re-init (#%d)",
                 s_power_cycles + 1);

        /* Take the recovery lock for the entire hard-reset → init →
         * connect sequence so a parallel ppp_reconnect_task or
         * cellular_bring_up_task (driven by an in-flight PPP_LOST_IP)
         * can't interleave its own modem_disconnect/modem_connect with
         * ours. Field log 2026-04-28 captured exactly this race: at
         * t=263 s watchdog ran modem_init while at t=304 s
         * ppp_reconnect_task ran modem_disconnect on the same DCE,
         * leaving the modem wedged for 90+ s. */
        modem_op_lock();

        modem_hard_reset();
        s_power_cycles++;

        /* Re-init with the saved NVS config (same path cellular_bring_up_task
         * uses). If config is missing, log and let Layer 3 reboot — there's
         * nothing useful we can do. */
        char apn[MODEM_APN_MAX], pin[MODEM_PIN_MAX];
        modem_lte_mode_t mode;
        if (modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode) != ESP_OK) {
            ESP_LOGE(TAG, "watchdog: no NVS config to re-init with");
            modem_op_unlock();
            continue;
        }
        if (modem_init(apn, pin, mode) != ESP_OK) {
            ESP_LOGE(TAG, "watchdog: modem_init after pulse failed");
            modem_op_unlock();
            continue;
        }
        if (modem_connect() != ESP_OK) {
            ESP_LOGE(TAG, "watchdog: modem_connect after pulse failed");
            modem_op_unlock();
            continue;
        }
        ESP_LOGI(TAG, "watchdog: recovered via Layer 2");
        s_consec_fails = 0;
        modem_op_unlock();
        /* leave s_power_cycles as-is so the limit binds across rapid retries */
    }
}

void modem_start_watchdog(void) {
    if (s_watchdog_task) return;
    xTaskCreate(modem_watchdog_task, "modem_wdt", 4096, NULL, 2, &s_watchdog_task);
}

void modem_stop_watchdog(void) {
    /* P4: not used. Real implementation would vTaskDelete + null the
     * handle, but no caller needs that yet. Reserved for future use. */
}
