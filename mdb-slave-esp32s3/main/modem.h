/*
 * VMflow.xyz
 *
 * modem.h — SIM7080G driver public API
 *
 * Single source of truth for the cellular modem lifecycle. Consumers
 * (network.c in P2, webui_server.c in P3) interact with the modem only
 * through this header — no esp_modem_* symbols leak.
 */

#ifndef MODEM_H
#define MODEM_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <esp_err.h>

#ifdef __cplusplus
extern "C" {
#endif

/* LTE network mode encoding — matches AT+CMNB and SIM7080G_CMNB Kconfig. */
typedef enum {
    MODEM_LTE_MODE_CATM  = 1,
    MODEM_LTE_MODE_NBIOT = 2,
    MODEM_LTE_MODE_BOTH  = 3,
} modem_lte_mode_t;

/* Snapshot of modem state. All fields are best-effort; consumers must
 * tolerate empty strings and rssi_dbm == 0 (means "unknown"). */
typedef struct {
    bool                registered;       /* AT+CEREG stat 1 (home) or 5 (roaming) */
    int8_t              rssi_dbm;         /* derived from AT+CSQ; 0 = unknown */
    char                operator_name[32];/* e.g. "Vodafone DE"; empty if unknown */
    char                ip[16];           /* PPP-assigned IPv4 dotted; empty if no PPP */
    modem_lte_mode_t    active_mode;      /* what the modem actually negotiated */
} modem_status_t;

/* ---- Lifecycle ---- */

/*
 * Detect whether a SIM7080G is wired and responsive.
 *
 * Sequence (safe on boards without a modem):
 *   1. Configure UART2 at 115200, GPIOs RX/TX/PWR per pin defaults.
 *   2. Try esp_modem_sync() (modem may already be on after warm reset).
 *   3. If fail: switch to ESP_MODEM_MODE_COMMAND (PPP escape), retry sync.
 *   4. If still fail: pulse PWRKEY (turns the modem on if attached), retry.
 *   5. Returns true only if AT sync succeeds; false otherwise.
 *
 * Total worst-case duration: ~13 s on a board without a modem (sync
 * timeouts + a no-op power pulse). Quick path (warm modem already on):
 * < 500 ms.
 *
 * Idempotent — safe to call multiple times. Does NOT enable any cellular
 * function (CFUN stays at whatever the modem booted with).
 */
bool modem_probe(void);

/*
 * Selects the modem UART RX/TX and PWRKEY GPIOs. Call before modem_probe()
 * (i.e. before network_init()). Without a call the driver uses the pins of
 * the SIM7080G board (RX 18, TX 17, PWRKEY 14).
 */
void modem_set_pins(int rx, int tx, int pwrkey);

/*
 * Returns whether the most recent modem_probe() succeeded — i.e. whether
 * a SIM7080G is actually attached and synced. Used by network.c to
 * disambiguate `NETWORK_STATE_SOFTAP_ONLY` (which can be reached either
 * from a cellular board without an APN OR a WiFi-only board with no
 * saved credentials) so the captive portal renders the correct variant.
 */
bool modem_is_present(void);

/*
 * Configure the modem with credentials and prepare for network attach.
 * Must be called after a successful modem_probe(). Does not establish
 * PPP — call modem_connect() for that.
 *
 * `apn` is required (non-NULL, non-empty). `pin` may be NULL or empty
 * (no PIN). `mode` selects LTE-M / NB-IoT / both.
 */
esp_err_t modem_init(const char *apn, const char *pin, modem_lte_mode_t mode);

/*
 * Bring the modem online: enable RF (CFUN=1), wait for network
 * registration (AT+CEREG, up to 60 s), switch to PPP data mode. On
 * success, the PPP netif becomes the default route.
 */
esp_err_t modem_connect(void);

/*
 * Tear down the PPP link cleanly and return to AT command mode. Safe
 * to call even if PPP is not currently active.
 *
 * NOTE: This is a FULL teardown — esp_modem's set_mode(COMMAND) waits
 * up to 30 s for lwIP PPP to gracefully exit. For short AT-command
 * windows (signal-quality query, one-shot HTTPS), prefer modem_pause()
 * which is ~1 s instead of ~30 s. Reserve modem_disconnect() for paths
 * that genuinely need to switch the modem out of DATA mode permanently
 * (e.g. before a power cycle, or within the recovery ladder).
 */
esp_err_t modem_disconnect(void);

/*
 * Pause the PPP netif and switch the modem to COMMAND mode for a
 * short AT-command window. Much faster than modem_disconnect (~1 s
 * vs ~30 s) because it does NOT tear down the lwIP PPP state — the
 * netif is suspended and resumed in place.
 *
 * Use modem_resume() to release. While paused:
 *   - PPP cannot send/receive traffic (MQTT, HTTP, etc. block)
 *   - AT commands work normally via esp_modem_at / esp_modem_at_raw
 *   - The PDP context binding to PPP is preserved, so resume is fast
 *
 * !!! IMPORTANT — NOT compatible with the SIM7080G internal TLS
 * stack (AT+SHCONN, AT+CIPSTART, AT+CMQTTSTART, etc.). With PPP
 * paused-but-bound, the PDP context is still owned by lwIP — when
 * we then activate AT+CNACT=0,1 to bring up the internal bearer,
 * the modem creates a parallel binding that confuses the data plane:
 * SHCONN returns garbled HDLC frames ("~!E"). Anything that uses the
 * modem-internal IP stack must use the full modem_disconnect path
 * (releases the PDP context cleanly). modem_pause is only useful for
 * pure AT-command queries that don't open new sockets (e.g. AT+CSQ,
 * AT+COPS?, AT+CGSN diagnostic probes).
 *
 * Returns ESP_OK on success, ESP_FAIL if the modem is not in DATA
 * mode (no PPP active to pause).
 */
esp_err_t modem_pause(void);
esp_err_t modem_resume(void);

/*
 * Single PWRKEY pulse + 8 s boot wait. Designed for the cold-boot path
 * (modem off, turn on). On a RUNNING modem this only powers it OFF —
 * use modem_hard_reset() for an actual cycle.
 */
void modem_power_cycle(void);

/*
 * Recovery escalation ladder (per SIMCom AT Command Manual §10 +
 * production field reports). Each layer is independently callable;
 * caller decides escalation order. Each must be followed by
 * modem_init() + modem_connect() to re-establish the data session.
 *
 * L1.5 — PDP context cycle (CGACT down/up). ~5 s. Cheapest reset.
 * L1.6 — Radio reset (CFUN=0/1). ~10 s. Re-attaches to network.
 * L2   — Soft firmware restart (CFUN=1,1). ~12 s. Modem reboots cleanly.
 * L3   — Hardware reset (PMU DC3 cut + PWRKEY). ~15 s. Last resort
 *        before factory_reset; resets modem hardware unconditionally.
 */
esp_err_t modem_pdp_reset(void);
esp_err_t modem_rf_reset(void);
esp_err_t modem_soft_restart(void);
void      modem_hard_reset(void);

/*
 * Lightweight power-cycle for use immediately before esp_restart().
 * Cuts DC3 (modem off), short cap-drain delay, re-enables DC3, fires
 * one PWRKEY pulse — and returns. Does NOT poll for modem readiness.
 * The host should call esp_restart() right after; modem boot
 * (~6-12 s) overlaps with ESP32 boot (~2 s) + modem_probe's own
 * readiness polling on the new boot.
 *
 * Use case: after `tracked_restart("provision")` etc., the modem is
 * left in a dirty state (PPP DATA mode, internal CNACT bearer up).
 * Without a power kick, the next boot's PPP fails IPCP and the
 * recovery ladder eats 3-4 minutes. With this kick, the next boot
 * sees a clean cold-booted modem and PPP comes up first try.
 */
void modem_kick_for_host_reboot(void);

/*
 * Refresh and return current modem status. Cheap to call (issues
 * AT+CSQ, AT+CEREG?, AT+COPS?). Times out fast (<3 s).
 */
void modem_status(modem_status_t *out);

/* ---- NVS helpers (cellular config) ---- */

/* Recommended buffer sizes for the load helper. */
#define MODEM_APN_MAX   64
#define MODEM_PIN_MAX   12

/*
 * Load cellular config from NVS namespace "vmflow", keys
 * "apn" / "sim_pin" / "lte_mode". Returns ESP_OK on success and fills
 * the outputs. Returns ESP_ERR_NVS_NOT_FOUND if either the namespace
 * does not exist yet OR the apn key is missing/empty (caller treats
 * both as "no cellular config saved"). Returns ESP_ERR_INVALID_ARG if
 * apn_out is NULL or apn_size is 0. pin_out and mode_out are optional.
 */
esp_err_t modem_nvs_load(char *apn_out, size_t apn_size,
                         char *pin_out, size_t pin_size,
                         modem_lte_mode_t *mode_out);

/*
 * Save cellular config to NVS. apn must be non-NULL and non-empty;
 * pin may be NULL or empty. Returns the underlying NVS error on
 * failure.
 */
esp_err_t modem_nvs_save(const char *apn, const char *pin, modem_lte_mode_t mode);

/* ---- Direct DCE access (advanced) ----
 *
 * Returns the internal esp_modem_dce_t handle, or NULL if the modem
 * has not been probed. Used by modem_https.c to issue raw AT commands
 * for the modem-internal HTTPS path. Most callers should NOT use this —
 * it's a deliberate violation of the modem.h abstraction, justified
 * only for the one-shot claim flow that needs direct AT access.
 */
struct esp_modem_dce;
struct esp_modem_dce *modem_get_dce(void);

/* ---- Recovery serialisation ----
 *
 * All recovery primitives (modem_init / modem_connect / modem_disconnect
 * / modem_pdp_reset / modem_rf_reset / modem_soft_restart /
 * modem_hard_reset) interact with the same DCE state machine and must
 * not run in parallel from different tasks. The DCE has its own DTE
 * lock that serialises individual AT calls, but it does NOT prevent
 * one task from issuing AT+CFUN=0 while another is mid-CEREG-poll —
 * the result is interleaved state churn that the SIM7080G handles
 * poorly (modem ends up in an undefined RAT/CFUN/CGATT combination).
 *
 * Field symptom (captured 2026-04-28 in initial provisioning):
 *   - watchdog Layer-2 hard-reset starts at t=263s (3x AT timeouts)
 *   - lwIP fires PPP_LOST_IP at t=304s (LCP echo died ~150s ago)
 *   - ppp_reconnect_task spawns and calls modem_disconnect on a modem
 *     that watchdog is mid-init'ing — both run concurrently, modem is
 *     left wedged for 90+ s before either completes
 *
 * Callers that drive a multi-step recovery (cellular_bring_up_task,
 * ppp_reconnect_task, the watchdog) MUST wrap their entire flow in
 * modem_op_lock/unlock. The mutex is recursive (same task can take it
 * multiple times). Hold time can be tens of seconds; do not call from
 * latency-sensitive paths. */
void modem_op_lock(void);
void modem_op_unlock(void);

/* ---- Watchdog ---- */

/*
 * Periodic AT keepalive sent to the modem from a low-priority FreeRTOS
 * task (started via modem_start_watchdog). Returns ESP_OK if the modem
 * responded to the bare "AT" within ~3s. Failure modes:
 *   - In PPP DATA mode the modem won't respond to AT — caller must
 *     issue an escape (+++) first; the watchdog handles this internally.
 *   - Three consecutive failures trigger modem_power_cycle + re-init.
 */
esp_err_t modem_at_keepalive_ping(void);

/*
 * Start the watchdog task. Must be called only after a successful
 * modem_connect. Idempotent — second call is a no-op. The task runs
 * forever (no stop API in P4; modem_stop_watchdog is a placeholder
 * for future use).
 */
void modem_start_watchdog(void);
void modem_stop_watchdog(void);   /* P4: no-op; reserved */

#ifdef __cplusplus
}
#endif

#endif /* MODEM_H */
