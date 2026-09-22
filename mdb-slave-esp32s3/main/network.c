/*
 * VMflow.xyz
 *
 * network.c — Network manager implementation.
 *
 * Owns:
 *   - WIFI_EVENT / IP_EVENT handler (lifted out of mdb-slave-esp32s3.c
 *     in P2 C2 — Task 4)
 *   - WiFi STA reconnect-with-SoftAP-fallback policy
 *   - Boot-time modem probe + WiFi-vs-cellular branch (cellular branch
 *     lands in P2 C3)
 *   - SoftAP lifecycle (start/stop on demand, plus the implicit fallback
 *     after WIFI_SOFTAP_AFTER failed STA connect attempts)
 *
 * The single registered consumer callback receives UPLINK_UP/DOWN +
 * SOFTAP_STARTED/STOPPED. The app code (mdb-slave-esp32s3.c) uses that
 * callback to start MQTT, NTP, and the MQTT watchdog — instead of
 * touching WiFi events directly.
 */

#include "network.h"

#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <esp_log.h>
#include <esp_err.h>
#include <esp_wifi.h>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_netif_ip_addr.h>
#include <esp_netif_net_stack.h>
#include <esp_timer.h>
#include <lwip/netif.h>
#include <nvs.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"

#include "webui_server.h"

#define TAG "network"

/* Reachability probe: open a TCP connect to a known stable endpoint
 * with a short timeout. Returns true if SYN-ACK comes back within
 * timeout_ms. Used to detect "phantom PPP" — IPCP completed and lwIP
 * has an IP, but the modem-side data path is broken (e.g. PDP context
 * half-bound) so outbound packets silently drop. We do this BEFORE
 * declaring NETWORK_EVENT_UPLINK_UP so MQTT/claim don't waste minutes
 * on a dead path.
 *
 * 1.1.1.1:53 is Cloudflare's anycast public DNS — universally reachable
 * from any cellular APN, low RTT, never blocked by corporate filters
 * the way port 80/443 sometimes are. SYN-ACK on port 53 confirms
 * outbound + inbound TCP both work end-to-end through the carrier. */
bool network_probe_tcp(const char *host, int port, int timeout_ms);

static bool probe_internet_tcp(const char *host, int port, int timeout_ms) {
    struct addrinfo hints = { 0 };
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *result = NULL;
    if (getaddrinfo(host, NULL, &hints, &result) != 0 || !result) {
        ESP_LOGW(TAG, "probe: getaddrinfo(%s) failed", host);
        return false;
    }

    struct sockaddr_in addr = *(struct sockaddr_in *)result->ai_addr;
    addr.sin_port = htons(port);
    freeaddrinfo(result);

    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock < 0) return false;

    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    bool ok = false;
    int  rc = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) {
        ok = true;
    } else if (errno == EINPROGRESS) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv = {
            .tv_sec  = timeout_ms / 1000,
            .tv_usec = (timeout_ms % 1000) * 1000,
        };
        if (select(sock + 1, NULL, &wfds, NULL, &tv) > 0) {
            int        sock_err   = 0;
            socklen_t  err_len    = sizeof(sock_err);
            if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &sock_err, &err_len) == 0
                    && sock_err == 0) {
                ok = true;
            }
        }
    }

    close(sock);
    return ok;
}

/* Public alias — exposes the same probe to callers in mdb-slave-esp32s3.c
 * (e.g. provision_claim_task pre-claim warm-up). Kept as a thin wrapper
 * so internal callers continue to use the static name. */
bool network_probe_tcp(const char *host, int port, int timeout_ms) {
    return probe_internet_tcp(host, port, timeout_ms);
}

/* PPP synchronisation: esp_modem_set_mode(DATA) returns as soon as PPP
 * starts negotiating, NOT when IPCP completes — at that moment lwIP has
 * no IP, no DNS server, and no default route. If we fired UPLINK_UP
 * here, MQTT/HTTP clients would immediately try getaddrinfo() and fail
 * with EAI_NODATA. We therefore wait for IP_EVENT_PPP_GOT_IP (set as a
 * bit on this event group from network_ppp_event_handler) before
 * declaring the cellular uplink up. */
#define PPP_GOT_IP_BIT          BIT0
static EventGroupHandle_t       s_ppp_event_group = NULL;

/* OFFLINE retry: re-spawn cellular_bring_up_task after this many seconds
 * when both the recovery ladder and Layer-1 PPP reconnect have given up. */
#define OFFLINE_RETRY_DELAY_S   30

/* SoftAP fallback policy — moved verbatim from mdb-slave-esp32s3.c
 * (was main.c lines 77-78). DO NOT change values without coordinating
 * with field-deployed firmware behaviour expectations. */
#define WIFI_SOFTAP_AFTER             5    /* start SoftAP after this many STA failures */
#define WIFI_RECONNECT_INTERVAL_SEC   60   /* retry WiFi every 60s while in SoftAP */

/* ---- Module state ---- */

static network_state_t      s_state = NETWORK_STATE_BOOTING;

static int                  s_wifi_retry_num = 0;
static bool                 s_softap_active  = false;
static esp_timer_handle_t   s_wifi_reconnect_timer = NULL;

static network_event_cb_t   s_event_cb = NULL;
static void                *s_event_user_data = NULL;

/* Probe-state tracking — consumed by webui_server's /system/info to
 * render a "Detecting modem…" loading view instead of flicker-
 * starting in WiFi mode. Set true by network_init after modem_probe
 * returns (regardless of result). Also flips true when the user
 * explicitly skips the wait via network_skip_modem_probe. */
static volatile bool        s_probe_complete = false;
static volatile bool        s_user_committed_wifi = false;

/* WiFi STA initialisation tracking — toggled true the first time
 * network_init's WiFi branch (or network_skip_modem_probe) runs the
 * STA netif + handler + APSTA-mode setup. Both call sites consult
 * this to avoid double-initialising (esp_netif_create_default_wifi_sta
 * + esp_event_handler_instance_register would error on the second
 * pass). */
static volatile bool        s_wifi_sta_initialised = false;

/* ---- Helpers ---- */

static void network_fire_event(network_event_t event) {
    if (s_event_cb) s_event_cb(event, s_event_user_data);
}

static void wifi_reconnect_timer_cb(void *arg) {
    (void)arg;
    ESP_LOGI(TAG, "WiFi reconnect timer: retrying esp_wifi_connect()");
    esp_wifi_connect();
}

/* ---- WIFI / IP event handler (lifted from mdb-slave-esp32s3.c) ----
 *
 * Behavioural translation rules vs the original:
 *   - All side-effect calls into webui_server.c (start_softap,
 *     start_dns_server, start_rest_server, stop_*) are kept unchanged.
 *   - State writes go to s_state and fire NETWORK_EVENT_UPLINK_UP /
 *     UPLINK_DOWN at the equivalent transition points.
 *   - The IP_EVENT_STA_GOT_IP branch ONLY does network-level cleanup +
 *     state update + UPLINK_UP fire. The app-level work that used to
 *     live here (provision_claim_task / sntp_init / esp_mqtt_client_start
 *     / mqtt_watchdog_timer setup) now happens in the consumer callback
 *     in mdb-slave-esp32s3.c.
 */

/* Forward declarations — wifi_branch_init_sta is used by both
 * network_init's WiFi branch and network_skip_modem_probe; the latter
 * sits below network_init in the file. network_mark_cellular_hw_present
 * is used by network_init itself but defined near the other uplink-
 * preference helpers, below. */
static void wifi_branch_init_sta(void);
static void network_mark_cellular_hw_present(void);

static void network_wifi_event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data) {

    if (event_base == WIFI_EVENT)
        switch (event_id) {
        case WIFI_EVENT_STA_START: {

            s_wifi_retry_num = 0;
            ESP_LOGI(TAG, "WIFI STA started");

            /* Check whether there is a saved SSID before attempting to connect.
             * esp_wifi_connect() with an empty SSID may return ESP_OK on some
             * IDF versions without ever emitting STA_DISCONNECTED, leaving the
             * SoftAP fallback unreachable. */
            wifi_config_t sta_cfg = {0};
            esp_wifi_get_config(WIFI_IF_STA, &sta_cfg);
            ESP_LOGI(TAG, "Saved SSID: \"%s\"", (char *)sta_cfg.sta.ssid);

            if (strlen((char *)sta_cfg.sta.ssid) == 0) {
                ESP_LOGI(TAG, "No saved WiFi credentials — starting SoftAP");
                start_softap();
                start_dns_server();
                start_rest_server();
                s_softap_active = true;
                s_state = NETWORK_STATE_SOFTAP_ONLY;
                network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);
            } else {
                s_state = NETWORK_STATE_WIFI_CONNECTING;
                esp_err_t conn_err = esp_wifi_connect();
                ESP_LOGI(TAG, "esp_wifi_connect() → %s", esp_err_to_name(conn_err));
                if (conn_err != ESP_OK) {
                    ESP_LOGW(TAG, "Connect failed immediately — starting SoftAP");
                    start_softap();
                    start_dns_server();
                    start_rest_server();
                    s_softap_active = true;
                    s_state = NETWORK_STATE_SOFTAP_ONLY;
                    network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);
                }
            }
            break;
        }
        case WIFI_EVENT_AP_START:
            ESP_LOGI(TAG, "WIFI AP started — SoftAP should now be visible");
            break;
        case WIFI_EVENT_AP_STOP:
            ESP_LOGI(TAG, "WIFI AP stopped");
            break;
        case WIFI_EVENT_AP_STACONNECTED:
            ESP_LOGI(TAG, "Client connected to SoftAP");
            break;
        case WIFI_EVENT_STA_CONNECTED:
            break;
        case WIFI_EVENT_STA_DISCONNECTED: {

            /* Don't explicitly disconnect MQTT here — the MQTT client
             * detects the TCP loss itself and fires MQTT_EVENT_DISCONNECTED,
             * which resets mqtt_started. Calling esp_mqtt_client_disconnect()
             * on a dead socket can block or cause errors. */

            bool was_up = (s_state == NETWORK_STATE_WIFI_UP);

            s_wifi_retry_num++;

            if (s_wifi_retry_num <= WIFI_SOFTAP_AFTER) {
                /* Fast retries first */
                ESP_LOGW(TAG, "WiFi disconnected, retry %d/%d", s_wifi_retry_num, WIFI_SOFTAP_AFTER);
                s_state = NETWORK_STATE_WIFI_CONNECTING;
                esp_wifi_connect();
            } else if (!s_softap_active) {
                /* Start SoftAP for user access, but keep retrying via timer */
                ESP_LOGW(TAG, "WiFi retries exhausted — starting SoftAP + reconnect timer (every %ds)", WIFI_RECONNECT_INTERVAL_SEC);
                start_softap();
                start_dns_server();
                start_rest_server();
                s_softap_active = true;
                s_state = NETWORK_STATE_SOFTAP_ONLY;
                network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);

                /* Start periodic reconnect timer */
                if (s_wifi_reconnect_timer == NULL) {
                    const esp_timer_create_args_t timer_args = {
                        .callback = wifi_reconnect_timer_cb,
                        .name = "wifi_reconnect"
                    };
                    esp_timer_create(&timer_args, &s_wifi_reconnect_timer);
                }
                esp_timer_start_periodic(s_wifi_reconnect_timer, WIFI_RECONNECT_INTERVAL_SEC * 1000000ULL);
            } else {
                /* SoftAP already active, timer handles retries — nothing to do */
                ESP_LOGI(TAG, "WiFi disconnected (SoftAP active, timer will retry)");
                s_state = NETWORK_STATE_SOFTAP_ONLY;
            }

            if (was_up) {
                network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
            }
            break;
        }
        }

    if (event_base == IP_EVENT)
        switch (event_id) {
        case IP_EVENT_STA_GOT_IP: {

            ip_event_got_ip_t *event_ip = (ip_event_got_ip_t *)event_data;
            ESP_LOGW(TAG, "GOT IP: " IPSTR, IP2STR(&event_ip->ip_info.ip));

            s_wifi_retry_num = 0;

            /* Stop reconnect timer if running */
            if (s_wifi_reconnect_timer != NULL) {
                esp_timer_stop(s_wifi_reconnect_timer);
            }

            /* SoftAP persistence: keep "VMflow" + DNS hijack + REST
             * server alive after STA gets IP. The captive-portal page
             * the user opened during initial setup must remain
             * reachable so they can watch the
             * claimed_connecting → claimed transition (and longer-
             * term, see status / re-provision without re-flashing).
             *
             * Earlier this handler tore down REST/DNS and switched
             * mode to STA-only — which kicked iOS off the captive-
             * portal page exactly when we wanted them to see "Setup
             * complete" populate. Mode stays APSTA, AP stays up.
             * Cellular path doesn't tear AP down either (PPP_GOT_IP
             * handler doesn't touch s_softap_active), so this aligns
             * the two uplink types. */
            s_state = NETWORK_STATE_WIFI_UP;
            network_fire_event(NETWORK_EVENT_UPLINK_UP);

            break;
        }
        }
}

/* Forward decl — schedule_offline_retry's body is below ppp_reconnect_task,
 * but cellular_bring_up_task also calls it on recovery-ladder exhaustion. */
static void schedule_offline_retry(void);

/* ---- Cellular bring-up ----
 *
 * Background task that runs modem_init + modem_connect using the APN
 * stored in NVS. Spawned by network_init (when APN is already in NVS)
 * or by network_cellular_configure (when the captive portal saves a
 * fresh APN). Fires NETWORK_EVENT_UPLINK_UP on success.
 */
static void cellular_bring_up_task(void *arg) {
    (void)arg;
    char apn[MODEM_APN_MAX], pin[MODEM_PIN_MAX];
    modem_lte_mode_t mode;

    esp_err_t err = modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "cellular bring-up: no APN — task exiting");
        vTaskDelete(NULL);
        return;
    }

    /* Serialise against parallel recovery paths (watchdog Layer-2,
     * ppp_reconnect_task). Any of those holding the lock means a
     * recovery is in flight — we wait for it to finish before starting
     * ours. By the time we acquire, state may already be CELLULAR_UP;
     * re-check below. */
    modem_op_lock();

    if (s_state == NETWORK_STATE_CELLULAR_UP) {
        ESP_LOGI(TAG, "cellular bring-up: state already CELLULAR_UP after lock — skipping");
        modem_op_unlock();
        vTaskDelete(NULL);
        return;
    }

    s_state = NETWORK_STATE_CELLULAR_REGISTERING;

    err = modem_init(apn, pin, mode);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "modem_init failed: %s", esp_err_to_name(err));
        s_state = NETWORK_STATE_OFFLINE;
        modem_op_unlock();
        vTaskDelete(NULL);
        return;
    }

    /* PPP bring-up + IPCP-timeout recovery loop.
     *
     * SIM7080G occasionally accepts ATD*99## but never completes IPCP —
     * symptom seen in the field is `set DATA mode: ESP_OK` followed by
     * 30 s of silence, never a +IP. Causes range from a stale PDP
     * context (most common, fixes with CGACT cycle) to a hung modem
     * firmware (needs CFUN=1,1) to wedged hardware (needs DC3 cut).
     *
     * Per SIMCom AT Command Manual + esp-protocols field reports we
     * walk a recovery escalation ladder: PDP reset → RF reset → soft
     * restart → hard reset, attempting modem_connect() after each.
     * Total worst-case ~3 minutes before bailing OFFLINE; the
     * offline_retry timer then re-runs the whole bring-up after 30 s.
     *
     * Each step that escalates beyond CGACT also requires a fresh
     * modem_init() because CFUN-or-power-cycle wipes our config (CNMP,
     * CMNB, CGDCONT, CEREG, CPSMS, CEDRXS). */
    enum {
        STEP_INITIAL,
        STEP_PDP,
        STEP_RF,
        STEP_SOFT,
        STEP_HARD,
        STEP_DONE,
    } step;

    bool ipcp_ok = false;
    for (step = STEP_INITIAL; step != STEP_DONE && !ipcp_ok; ) {
        const char *step_name = NULL;

        /* Apply the recovery primitive for this step. STEP_INITIAL is
         * the first try — modem_init has already run, jump straight
         * into modem_connect. Subsequent steps repair-then-reconfigure. */
        switch (step) {
            case STEP_INITIAL:
                step_name = "initial connect";
                break;
            case STEP_PDP:
                step_name = "PDP reset";
                modem_pdp_reset();
                break;
            case STEP_RF:
                step_name = "RF reset";
                modem_rf_reset();
                break;
            case STEP_SOFT:
                step_name = "soft restart";
                modem_soft_restart();
                modem_init(apn, pin, mode);   /* re-apply config */
                break;
            case STEP_HARD:
                step_name = "hard reset";
                modem_hard_reset();
                modem_init(apn, pin, mode);
                break;
            default:
                break;
        }

        ESP_LOGI(TAG, "PPP attempt: %s", step_name);
        err = modem_connect();
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "modem_connect after %s failed: %s — escalating",
                     step_name, esp_err_to_name(err));
        } else if (s_ppp_event_group) {
            EventBits_t bits = xEventGroupWaitBits(s_ppp_event_group, PPP_GOT_IP_BIT,
                                                   pdFALSE, pdTRUE, pdMS_TO_TICKS(30000));
            if (bits & PPP_GOT_IP_BIT) {
                /* IPCP says we have an IP. Now confirm the data path
                 * actually works by probing a known stable endpoint.
                 * This catches "phantom PPP" — a half-bound PDP context
                 * where IPCP completed but outbound packets silently
                 * drop at the modem's GTP layer. Without this probe we
                 * declare UPLINK_UP, MQTT/claim try and waste up to
                 * Cloudflare-edge timeout (15 s) per attempt before
                 * we even consider escalating. */
                ESP_LOGI(TAG, "IPCP completed after %s — probing internet", step_name);
                if (probe_internet_tcp("1.1.1.1", 53, 5000)) {
                    ESP_LOGI(TAG, "internet reachable after %s", step_name);
                    ipcp_ok = true;
                    break;
                }
                ESP_LOGW(TAG, "internet probe failed after %s (phantom PPP) — escalating",
                         step_name);
            } else {
                ESP_LOGW(TAG, "IPCP timeout after %s — escalating", step_name);
            }
        }

        /* Advance to next escalation level. */
        step = (step == STEP_INITIAL) ? STEP_PDP
             : (step == STEP_PDP)     ? STEP_RF
             : (step == STEP_RF)      ? STEP_SOFT
             : (step == STEP_SOFT)    ? STEP_HARD
             :                          STEP_DONE;
    }

    if (!ipcp_ok) {
        ESP_LOGE(TAG, "PPP recovery ladder exhausted — OFFLINE, retry in %d s",
                 OFFLINE_RETRY_DELAY_S);
        s_state = NETWORK_STATE_OFFLINE;
        network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
        schedule_offline_retry();
        modem_op_unlock();
        vTaskDelete(NULL);
        return;
    }

    s_state = NETWORK_STATE_CELLULAR_UP;
    ESP_LOGI(TAG, "cellular up");
    /* Start the modem watchdog (Layer 2 recovery). Idempotent — re-spawning
     * cellular_bring_up_task after a Layer-2 power-cycle won't double-start
     * the task. Gated to this task ONLY so WiFi-only boards never spawn it. */
    modem_start_watchdog();
    network_fire_event(NETWORK_EVENT_UPLINK_UP);
    modem_op_unlock();
    vTaskDelete(NULL);
}

/* Layer 1 PPP reconnect: 3 fast attempts via modem_disconnect + modem_connect
 * before falling back to OFFLINE (where the modem watchdog Layer 2 picks up
 * on its next tick). Total worst-case duration ~6-30s depending on how long
 * each modem_connect takes (CFUN + registration + PPP). */
#define PPP_RECONNECT_ATTEMPTS  3
static int s_ppp_reconnect_attempts = 0;

static void ppp_reconnect_task(void *arg) {
    (void)arg;

    /* Acquire the recovery lock. Watchdog Layer-2 or another bring-up
     * may already be running — wait for it. By the time we acquire,
     * state may have transitioned to CELLULAR_UP (recovery succeeded
     * elsewhere) — bail out so we don't tear down a freshly-restored
     * PPP link via our own modem_disconnect call. */
    modem_op_lock();

    if (s_state == NETWORK_STATE_CELLULAR_UP) {
        ESP_LOGI(TAG, "PPP reconnect: state already CELLULAR_UP after lock — skipping");
        s_ppp_reconnect_attempts = 0;
        modem_op_unlock();
        vTaskDelete(NULL);
        return;
    }

    while (s_ppp_reconnect_attempts < PPP_RECONNECT_ATTEMPTS) {
        s_ppp_reconnect_attempts++;
        ESP_LOGW(TAG, "PPP reconnect attempt %d/%d",
                 s_ppp_reconnect_attempts, PPP_RECONNECT_ATTEMPTS);

        modem_disconnect();
        vTaskDelay(pdMS_TO_TICKS(2000));

        if (modem_connect() == ESP_OK) {
            ESP_LOGI(TAG, "PPP reconnect: modem_connect ok, waiting for IPCP");
            /* Same gate as cellular_bring_up_task — wait for actual
             * IP/DNS install, not just for set_mode(DATA) to return. */
            if (s_ppp_event_group) {
                EventBits_t bits = xEventGroupWaitBits(s_ppp_event_group, PPP_GOT_IP_BIT,
                                                       pdFALSE, pdTRUE, pdMS_TO_TICKS(30000));
                if (!(bits & PPP_GOT_IP_BIT)) {
                    ESP_LOGW(TAG, "PPP reconnect: IPCP timeout, retrying");
                    continue;
                }
            }
            ESP_LOGI(TAG, "PPP reconnect succeeded on attempt %d", s_ppp_reconnect_attempts);
            s_state = NETWORK_STATE_CELLULAR_UP;
            s_ppp_reconnect_attempts = 0;
            network_fire_event(NETWORK_EVENT_UPLINK_UP);
            modem_op_unlock();
            vTaskDelete(NULL);
            return;
        }
    }
    /* All Layer-1 attempts exhausted — drop to OFFLINE and schedule a
     * delayed retry. Without this, OFFLINE was a dead-end: the modem
     * watchdog (Layer 2) only fires on AT-ping failure and skips the
     * ping entirely while PPP looks alive, so it could miss the
     * unreachable state for minutes; mqtt_watchdog (Layer 3) only
     * hard-reboots after 10 min. We prefer to keep retrying.
     *
     * Schedule a fresh cellular_bring_up_task after OFFLINE_RETRY_DELAY_S
     * — that path runs the full modem_init + modem_connect sequence,
     * which is the right thing to do if Layer 1 couldn't recover (e.g.
     * the modem itself is hung and needs power-cycling, or registration
     * was lost). */
    ESP_LOGE(TAG, "PPP Layer-1 reconnect exhausted — dropping to OFFLINE, "
                  "will retry in %d s", OFFLINE_RETRY_DELAY_S);
    s_ppp_reconnect_attempts = 0;
    s_state = NETWORK_STATE_OFFLINE;
    network_fire_event(NETWORK_EVENT_UPLINK_DOWN);
    schedule_offline_retry();
    modem_op_unlock();
    vTaskDelete(NULL);
}

/* Periodic retry while in OFFLINE — re-spawns cellular_bring_up_task
 * after a fixed delay. Independent of the modem watchdog so we recover
 * even when AT pings are skipped (which happens whenever PPP looks
 * locally alive even though carrier-side is dead). */
static esp_timer_handle_t s_offline_retry_timer = NULL;

static void offline_retry_cb(void *arg) {
    (void)arg;
    if (s_state != NETWORK_STATE_OFFLINE) {
        ESP_LOGI(TAG, "offline retry: state changed to %d, skipping", s_state);
        return;
    }
    ESP_LOGW(TAG, "offline retry: re-spawning cellular_bring_up_task");
    s_state = NETWORK_STATE_CELLULAR_REGISTERING;
    xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
}

static void schedule_offline_retry(void) {
    if (!s_offline_retry_timer) {
        const esp_timer_create_args_t args = {
            .callback = offline_retry_cb,
            .name     = "offline_retry"
        };
        esp_timer_create(&args, &s_offline_retry_timer);
    }
    /* one-shot — re-armed by next exhaustion */
    esp_timer_stop(s_offline_retry_timer);
    esp_timer_start_once(s_offline_retry_timer, OFFLINE_RETRY_DELAY_S * 1000000ULL);
}

/* PPP status event handler — fires on NETIF_PPP_LOST_IP and friends.
 * On LOST_IP we spawn ppp_reconnect_task (Layer 1) instead of dropping
 * straight to OFFLINE. */
static void network_ppp_event_handler(void *arg, esp_event_base_t event_base,
                                       int32_t event_id, void *event_data) {
    (void)arg; (void)event_data;
    if (event_base != IP_EVENT) return;
    if (event_id == IP_EVENT_PPP_GOT_IP) {
        ip_event_got_ip_t *ev = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "PPP GOT_IP: " IPSTR, IP2STR(&ev->ip_info.ip));

        /* Force PPP as the outbound default netif. Otherwise the SoftAP
         * (route_prio 10) competes with PPP (20) — usually PPP wins,
         * but we set it explicitly to remove ambiguity. */
        esp_netif_set_default_netif(ev->esp_netif);

        /* Clamp PPP MTU to 1280 → advertised TCP MSS = 1240.
         *
         * Field log 2026-04-28 (firmware dc9a2dc, Telekom IoT/sensor.net,
         * 1NCE SIM): TCP connect to Cloudflare-fronted Supabase backend
         * succeeded ("handshake in progress"), then the TLS handshake
         * silently stalled for 60 s. Path: ClientHello (~500 B) leaves
         * fine, but ServerHello + Certificate + ServerKeyExchange comes
         * back across multiple TCP segments, some of which exceed the
         * carrier's effective IP MTU. Telekom's GTP-U encapsulation eats
         * ~70 B from the 1500-byte PPP MTU, and the carrier silently
         * drops the over-sized inbound segments — TCP retransmit doesn't
         * help because the carrier keeps dropping them at the same
         * threshold. ICMP "fragmentation needed" never reaches us
         * (filtered upstream), so PMTU discovery is a non-starter.
         *
         * 1280 is the IPv6 minimum and the safest universal-fit value
         * for cellular paths. Throughput cost vs the default 1500: ~3-5%
         * on bulk transfers, negligible on our mostly-small MQTT and
         * claim payloads.
         *
         * Setting netif->mtu directly is the standard lwIP idiom (see
         * slipif.c, ppp_init.c). It must happen BEFORE the first TCP
         * connection on this netif so the SYN's MSS option carries the
         * clamped value. We're inside the GOT_IP handler which fires
         * before NETWORK_EVENT_UPLINK_UP, which is what gates MQTT/claim
         * — so this is the correct moment. */
        struct netif *lwip_netif = (struct netif *)esp_netif_get_netif_impl(ev->esp_netif);
        if (lwip_netif) {
            const u16_t prev_mtu = lwip_netif->mtu;
            lwip_netif->mtu = 1280;
#if LWIP_IPV6
            lwip_netif->mtu6 = 1280;
#endif
            ESP_LOGI(TAG, "PPP MTU clamped %u → 1280 (TCP MSS = 1240)", prev_mtu);
        } else {
            ESP_LOGW(TAG, "PPP MTU clamp: esp_netif_get_netif_impl returned NULL");
        }

        /* Make sure DNS works.
         *
         * CONFIG_ESP_NETIF_SET_DNS_PER_DEFAULT_NETIF is off, so lwIP
         * uses the global dns_setserver list. The carrier *should* push
         * DNS during IPCP, but several APNs (sensors.net included) don't,
         * leaving the list empty and getaddrinfo() returning EAI_NONAME
         * (errno 202). Read whatever the PPP layer negotiated, and only
         * force public fallbacks if both slots are empty. */
        esp_netif_dns_info_t main_dns, backup_dns;
        bool have_main = (esp_netif_get_dns_info(ev->esp_netif, ESP_NETIF_DNS_MAIN, &main_dns) == ESP_OK
                          && main_dns.ip.u_addr.ip4.addr != 0);
        bool have_backup = (esp_netif_get_dns_info(ev->esp_netif, ESP_NETIF_DNS_BACKUP, &backup_dns) == ESP_OK
                            && backup_dns.ip.u_addr.ip4.addr != 0);
        char main_str[16] = "(none)", backup_str[16] = "(none)";
        if (have_main)   esp_ip4addr_ntoa(&main_dns.ip.u_addr.ip4,   main_str,   sizeof(main_str));
        if (have_backup) esp_ip4addr_ntoa(&backup_dns.ip.u_addr.ip4, backup_str, sizeof(backup_str));
        ESP_LOGI(TAG, "PPP DNS: main=%s backup=%s", main_str, backup_str);

        if (!have_main) {
            esp_netif_dns_info_t fallback = { 0 };
            fallback.ip.type = ESP_IPADDR_TYPE_V4;
            fallback.ip.u_addr.ip4.addr = esp_ip4addr_aton("8.8.8.8");
            esp_netif_set_dns_info(ev->esp_netif, ESP_NETIF_DNS_MAIN, &fallback);
            ESP_LOGW(TAG, "PPP DNS: carrier did not push DNS — installing 8.8.8.8 as primary");
        }
        if (!have_backup) {
            esp_netif_dns_info_t fallback = { 0 };
            fallback.ip.type = ESP_IPADDR_TYPE_V4;
            fallback.ip.u_addr.ip4.addr = esp_ip4addr_aton("1.1.1.1");
            esp_netif_set_dns_info(ev->esp_netif, ESP_NETIF_DNS_BACKUP, &fallback);
            ESP_LOGW(TAG, "PPP DNS: installing 1.1.1.1 as backup");
        }

        /* Unblock cellular_bring_up_task / ppp_reconnect_task, which
         * wait on this bit before declaring uplink up. esp_modem_set_mode
         * returns before IPCP finishes, so we MUST gate UPLINK_UP on
         * this event — otherwise upstream code (claim, MQTT) runs
         * getaddrinfo before lwIP has installed any DNS server. */
        if (s_ppp_event_group) {
            xEventGroupSetBits(s_ppp_event_group, PPP_GOT_IP_BIT);
        }
    } else if (event_id == IP_EVENT_PPP_LOST_IP) {
        ESP_LOGW(TAG, "PPP LOST_IP");
        if (s_ppp_event_group) {
            xEventGroupClearBits(s_ppp_event_group, PPP_GOT_IP_BIT);
        }
        if (s_state == NETWORK_STATE_CELLULAR_UP) {
            /* Mark the link down BEFORE spawning the reconnect task, not
             * after. ppp_reconnect_task's own first move, once it holds
             * modem_op_lock, is "if s_state is already CELLULAR_UP, some
             * other recovery path must have beaten us to it — bail out
             * without tearing down a freshly-restored link." That check
             * is only meaningful if losing IP actually left s_state
             * somewhere other than CELLULAR_UP; leaving it untouched here
             * made the guard trivially true on every single LOST_IP,
             * so the task always exited immediately without ever
             * attempting a reconnect. Confirmed live (2026-09-15 field
             * log): PPP dropped, "state already CELLULAR_UP after lock —
             * skipping" fired instantly, and the device stayed offline
             * until the 10-minute MQTT watchdog hard-reboot forced a
             * fresh boot — the only path that still worked. */
            s_state = NETWORK_STATE_OFFLINE;
            /* Layer 1: spawn a reconnect task. We do this in a task
             * because modem_disconnect/modem_connect can take seconds,
             * and the event handler must not block. */
            xTaskCreate(ppp_reconnect_task, "ppp_reconn", 4096, NULL, 4, NULL);
        }
    }
}

/* ---- Public API ---- */

void network_init(void) {
    /* PPP IPCP-completion event group — created before any handler
     * registration so the GOT_IP callback always finds a non-NULL handle. */
    if (!s_ppp_event_group) s_ppp_event_group = xEventGroupCreate();

    /* PPP handler registered unconditionally and BEFORE modem_probe — the
     * probe may toggle PPP state and we want the handler ready for
     * IP_EVENT_PPP_LOST_IP / GOT_IP either way. The WiFi handlers are
     * registered later (and only on the WiFi branch) since cellular-only
     * boards never run esp_wifi_init in STA mode. */
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_GOT_IP,
                                         network_ppp_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_PPP_LOST_IP,
                                         network_ppp_event_handler, NULL, NULL);

    /* === Bring SoftAP up BEFORE modem_probe ===========================
     *
     * Why this matters: after a tracked_restart (e.g. post-claim) the
     * iPhone is still connected to "VMflow" and has the captive-portal
     * page open. If SoftAP comes back online within ~2 s, iOS keeps
     * that page alive and the user just sees the data refresh. If we
     * make iOS wait > 5 s (the time modem_probe takes for the warm-
     * COMMAND probe + PPP escape), the iPhone drops the AP and the
     * user has to reconnect manually — userflow broken.
     *
     * Mode choice: APSTA from the very start (not AP-only).
     *
     *   Earlier this function set WIFI_MODE_AP and later flipped to
     *   APSTA in the post-probe WiFi branch. That live mode change
     *   was reported in the field as breaking the iPhone's existing
     *   AP association — esp_wifi_set_mode(APSTA) on a running AP-
     *   only driver triggers an internal reconfigure that briefly
     *   drops the SSID, and iOS sees that as "AP went away" and
     *   abandons the captive-portal page.
     *
     *   Going straight to APSTA at boot avoids the runtime mode flip.
     *   STA is initialised but does NOT auto-connect — the WiFi event
     *   handler is only registered later (in network_init's WiFi
     *   branch, or eagerly via network_skip_modem_probe). Without a
     *   handler, WIFI_EVENT_STA_START is a no-op, so STA sits idle
     *   on cellular boards without any disconnect-retry chatter.
     *
     * Order:
     *   1. Create AP + STA netifs, esp_wifi_init, set APSTA, start →
     *      SoftAP up at ~400 ms, STA initialised but idle (no handler).
     *   2. modem_probe runs (~5-8 s) — SoftAP is already serving.
     *   3. Cellular branch: leave STA idle (no handler registration).
     *      WiFi branch: register WiFi handlers + esp_wifi_connect if
     *      saved credentials. */
    ESP_LOGI(TAG, "network_init: bringing SoftAP up before modem probe");
    esp_netif_create_default_wifi_ap();
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);
    esp_wifi_set_mode(WIFI_MODE_APSTA);
    esp_wifi_start();
    s_state = NETWORK_STATE_SOFTAP_ONLY;
    network_start_softap();

    /* Persisted uplink preference (network_set_uplink_preference) takes
     * effect here, before modem_probe even runs. A modem-equipped board
     * that has been switched to WiFi mode skips the ~1-20s probe
     * entirely — same commitment network_skip_modem_probe() makes for a
     * live in-progress probe, just decided ahead of time from NVS
     * instead of a captive-portal button click. */
    bool modem_present;
    if (network_get_uplink_preference()) {
        ESP_LOGI(TAG, "network_init: uplink preference is WiFi — skipping modem probe");
        s_user_committed_wifi = true;
        modem_present = false;
        s_probe_complete = true;
    } else {
        ESP_LOGI(TAG, "network_init: probing modem...");
        modem_present = modem_probe();
        s_probe_complete = true;
        ESP_LOGI(TAG, "modem_probe → %s", modem_present ? "true" : "false");
        if (modem_present) network_mark_cellular_hw_present();

        /* User can dismiss the probe wait via /api/v1/system/skip-probe;
         * if they did, we honour their commitment to WiFi mode regardless
         * of what the probe actually found. */
        if (s_user_committed_wifi && modem_present) {
            ESP_LOGW(TAG, "user committed to WiFi mode during probe — "
                          "ignoring modem-detected result, taking WiFi branch");
            modem_present = false;
        }
    }

    if (modem_present) {
        ESP_LOGI(TAG, "cellular branch — WiFi STA will NOT be initialised");

        /* SoftAP is already up from the pre-probe stage; just kick off
         * cellular bring-up if APN is in NVS. */
        char apn[MODEM_APN_MAX], pin[MODEM_PIN_MAX];
        modem_lte_mode_t mode;
        esp_err_t err = modem_nvs_load(apn, sizeof(apn), pin, sizeof(pin), &mode);
        if (err == ESP_OK) {
            ESP_LOGI(TAG, "APN found in NVS — starting cellular bring-up task");
            xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
        } else {
            ESP_LOGI(TAG, "no APN in NVS — waiting for captive portal config");
        }

        return;  /* DO NOT init WiFi STA on cellular boards */
    }

    /* ---- WiFi-only branch ---- */
    /* SoftAP and STA are already up (APSTA from boot). Register WiFi
     * event handlers now and, if saved credentials exist, kick STA
     * connect. STA_START fired during esp_wifi_start before any handler
     * was listening, so its auto-connect logic was bypassed — we
     * replicate it here explicitly. */
    wifi_branch_init_sta();

    wifi_config_t sta_cfg = {0};
    esp_wifi_get_config(WIFI_IF_STA, &sta_cfg);
    if (strlen((char *)sta_cfg.sta.ssid) > 0) {
        ESP_LOGI(TAG, "WiFi branch: saved SSID \"%s\" — connecting",
                 (char *)sta_cfg.sta.ssid);
        s_state = NETWORK_STATE_WIFI_CONNECTING;
        esp_wifi_connect();
    } else {
        ESP_LOGI(TAG, "WiFi branch: no saved SSID — captive portal awaits creds");
        /* Stay in NETWORK_STATE_SOFTAP_ONLY (already set pre-probe). */
    }
}

network_state_t network_get_state(void) {
    return s_state;
}

void network_get_status(network_status_t *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->state = s_state;
    out->uplink_up = (s_state == NETWORK_STATE_WIFI_UP || s_state == NETWORK_STATE_CELLULAR_UP);

    if (s_state == NETWORK_STATE_WIFI_UP)        strcpy(out->uplink_kind, "wifi");
    else if (s_state == NETWORK_STATE_CELLULAR_UP) strcpy(out->uplink_kind, "cellular");
    else                                          strcpy(out->uplink_kind, "none");

    /* WiFi block — populated only when WiFi STA has been initialised
     * AND a SSID has been saved/configured. esp_wifi_get_config returns
     * an error pre-init or when WiFi was never started (cellular boards),
     * so we use it as the gate. */
    wifi_config_t wcfg = {0};
    if (esp_wifi_get_config(WIFI_IF_STA, &wcfg) == ESP_OK && wcfg.sta.ssid[0] != 0) {
        out->wifi_initialised = true;
        strncpy(out->wifi_ssid, (const char *)wcfg.sta.ssid, sizeof(out->wifi_ssid) - 1);

        wifi_ap_record_t ap = {0};
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
            out->wifi_rssi = ap.rssi;
        }

        esp_netif_t *sta = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
        if (sta) {
            esp_netif_ip_info_t ip_info;
            if (esp_netif_get_ip_info(sta, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
                esp_ip4addr_ntoa(&ip_info.ip, out->wifi_ip, sizeof(out->wifi_ip));
            }
        }
    }

    /* Cellular block — populated whenever a modem was successfully
     * probed at boot, regardless of current network state. modem_status
     * is a pure cache read (no AT, no blocking), and the cache holds
     * the last-known operator/rssi/mode/registered values from the
     * registration loop and post-CEREG COPS query.
     *
     * Earlier this branch gated on `s_state in
     * {REGISTERING, CELLULAR_UP, SOFTAP_ONLY}`, which made the captive
     * portal banner suddenly show empty Signal/Operator/Mode whenever
     * the state machine flipped to OFFLINE briefly (e.g. mid-PPP
     * reconnect, or any other state transition glitch). Reported in
     * the field as "Daten verschwinden nach einigen Sekunden" — the
     * user sees stale-but-correct data evaporate just because the
     * state momentarily moved. Always-on cellular block fixes that
     * without any data integrity concern: if the modem is present,
     * the cache is meaningful. */
    if (modem_is_present()) {
        modem_status_t ms;
        modem_status(&ms);
        out->modem_present       = true;
        out->cellular_registered = ms.registered;
        out->cellular_rssi_dbm   = ms.rssi_dbm;
        strncpy(out->cellular_operator, ms.operator_name, sizeof(out->cellular_operator) - 1);
        strncpy(out->cellular_ip, ms.ip, sizeof(out->cellular_ip) - 1);
        out->cellular_mode       = ms.active_mode;
    }
}

void network_register_callback(network_event_cb_t cb, void *user_data) {
    s_event_cb = cb;
    s_event_user_data = user_data;
}

esp_err_t network_start_softap(void) {
    if (s_softap_active) {
        ESP_LOGI(TAG, "network_start_softap: already active");
        return ESP_OK;
    }
    start_softap();
    start_dns_server();
    start_rest_server();
    s_softap_active = true;
    network_fire_event(NETWORK_EVENT_SOFTAP_STARTED);
    return ESP_OK;
}

esp_err_t network_stop_softap(void) {
    if (!s_softap_active) {
        return ESP_OK;
    }
    stop_rest_server();
    stop_dns_server();
    s_softap_active = false;
    network_fire_event(NETWORK_EVENT_SOFTAP_STOPPED);
    return ESP_OK;
}

esp_err_t network_cellular_configure(const char *apn, const char *pin, modem_lte_mode_t mode) {
    /* Reject re-entry while a bring-up is in flight. Without this guard a
     * rapidly-resubmitting captive portal could spawn parallel cell_up
     * tasks racing on s_state and double-firing UPLINK_UP. */
    if (s_state == NETWORK_STATE_CELLULAR_REGISTERING) {
        ESP_LOGW(TAG, "network_cellular_configure: bring-up already in progress");
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t err = modem_nvs_save(apn, pin, mode);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "network_cellular_configure: modem_nvs_save failed: %s",
                 esp_err_to_name(err));
        return err;
    }
    /* Spawn the bring-up task — same one network_init uses. */
    xTaskCreate(cellular_bring_up_task, "cell_up", 4096, NULL, 4, NULL);
    return ESP_OK;
}

/* === Uplink preference (Option A: WiFi instead of cellular) ===========
 *
 * Three NVS keys in the "vmflow" namespace, all plain u8 (0/1):
 *   uplink_pref  — 0 (default/unset) = cellular, 1 = WiFi. Consulted once,
 *                  at the very top of network_init(), before modem_probe.
 *   has_modem    — 1 once any boot's modem_probe() has ever returned true.
 *                  Sticky — never cleared short of a factory reset. Lets
 *                  the captive portal offer the switch even while a boot
 *                  is currently running in WiFi mode (where modem_probe
 *                  was skipped and modem_is_present() reads false). */
static void network_mark_cellular_hw_present(void) {
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READWRITE, &h) != ESP_OK) return;
    uint8_t v = 0;
    nvs_get_u8(h, "has_modem", &v);
    if (v != 1) {
        nvs_set_u8(h, "has_modem", 1);
        nvs_commit(h);
    }
    nvs_close(h);
}

bool network_has_cellular_hw(void) {
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READONLY, &h) != ESP_OK) return false;
    uint8_t v = 0;
    nvs_get_u8(h, "has_modem", &v);
    nvs_close(h);
    return v == 1;
}

bool network_get_uplink_preference(void) {
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READONLY, &h) != ESP_OK) return false;
    uint8_t v = 0;
    nvs_get_u8(h, "uplink_pref", &v);
    nvs_close(h);
    return v == 1;
}

esp_err_t network_set_uplink_preference(bool prefer_wifi, const char *ssid, const char *password) {
    if (!network_has_cellular_hw()) {
        ESP_LOGW(TAG, "set_uplink_preference: no confirmed modem on this board — refusing");
        return ESP_ERR_NOT_SUPPORTED;
    }

    /* Save WiFi credentials first (if given) so a failure here doesn't
     * leave the preference flipped with no way to actually connect.
     * esp_wifi_set_config works any time after esp_wifi_init, which
     * network_init() already ran unconditionally at boot — no gate
     * needed here the way network_wifi_configure() has one, since this
     * IS the authorised "switch to WiFi" entry point. */
    if (prefer_wifi && ssid && strlen(ssid) > 0) {
        wifi_config_t cfg = {0};
        esp_wifi_get_config(WIFI_IF_STA, &cfg);
        strncpy((char *)cfg.sta.ssid,     ssid,               sizeof(cfg.sta.ssid)     - 1);
        strncpy((char *)cfg.sta.password, password ? password : "", sizeof(cfg.sta.password) - 1);
        esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &cfg);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "set_uplink_preference: esp_wifi_set_config failed: %s", esp_err_to_name(err));
            return err;
        }
    }

    nvs_handle_t h;
    esp_err_t err = nvs_open("vmflow", NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    nvs_set_u8(h, "uplink_pref", prefer_wifi ? 1 : 0);
    err = nvs_commit(h);
    nvs_close(h);
    if (err == ESP_OK) {
        ESP_LOGW(TAG, "set_uplink_preference: now prefers %s (takes effect on next boot)",
                 prefer_wifi ? "WiFi" : "cellular");
    }
    return err;
}

esp_err_t network_wifi_configure(const char *ssid, const char *password) {
    if (!ssid || strlen(ssid) == 0) return ESP_ERR_INVALID_ARG;

    /* If the caller hits this endpoint during the synchronous modem
     * probe (e.g. user clicked Skip and submitted WiFi creds quickly),
     * STA may not yet be initialised. Wait up to 10 s for the probe
     * + WiFi-branch STA init to complete. Probe itself caps at ~5 s,
     * STA init is fast — so we typically clear in ~5 s worst case. */
    int wait_ms = 0;
    while (!s_probe_complete && wait_ms < 10000) {
        vTaskDelay(pdMS_TO_TICKS(100));
        wait_ms += 100;
    }
    /* Brief settle for network_init's WiFi-branch (called right after
     * setting s_probe_complete) to finish esp_netif_create_default_
     * wifi_sta + esp_wifi_set_mode(APSTA). */
    if (s_state != NETWORK_STATE_WIFI_CONNECTING &&
        s_state != NETWORK_STATE_WIFI_UP) {
        vTaskDelay(pdMS_TO_TICKS(300));
    }

    /* On cellular boards (modem present, user did NOT commit to WiFi)
     * we deliberately ignore WiFi credentials — policy is cellular-
     * only when modem detected.
     *
     * Detail: state-based check is wrong post-refactor because
     * SOFTAP_ONLY is now set on every boot (before probe) — using
     * modem_is_present() + the user-skip flag gives the right result
     * regardless of probe-vs-state-transition timing. */
    if (modem_is_present() && !s_user_committed_wifi) {
        ESP_LOGW(TAG, "network_wifi_configure: ignored on cellular board");
        return ESP_ERR_NOT_SUPPORTED;
    }

    wifi_config_t cfg = {0};
    esp_wifi_get_config(WIFI_IF_STA, &cfg);
    strncpy((char *)cfg.sta.ssid,     ssid,     sizeof(cfg.sta.ssid)     - 1);
    strncpy((char *)cfg.sta.password, password ? password : "",
                                                sizeof(cfg.sta.password) - 1);
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &cfg);
    if (err != ESP_OK) return err;

    return esp_wifi_connect();
}

bool network_modem_probe_complete(void) {
    return s_probe_complete || s_user_committed_wifi;
}

/* Idempotent WiFi event-handler registration. Used by network_init's
 * WiFi branch (post-probe) and by network_skip_modem_probe (immediately
 * on click) — the latter so the captive-portal's WiFi-scan + WiFi-
 * connect paths work while modem_probe is still running.
 *
 * STA netif + APSTA mode are already set up at the top of network_init
 * (BEFORE probe), so no driver reconfigure happens here. We just hook
 * the event handler — without it, WIFI_EVENT_STA_DISCONNECTED retries
 * + scan + connect events go nowhere. Cellular boards skip this so
 * STA sits idle without disconnect-retry chatter. */
static void wifi_branch_init_sta(void) {
    if (s_wifi_sta_initialised) return;
    s_wifi_sta_initialised = true;

    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                         network_wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, ESP_EVENT_ANY_ID,
                                         network_wifi_event_handler, NULL, NULL);
}

esp_err_t network_skip_modem_probe(void) {
    /* If the cellular branch has already been taken (probe finished and
     * detected a modem before user clicked skip), it's too late — the
     * STA was never initialised, and undoing cellular bring-up here
     * would be invasive. Tell the caller to power-cycle. */
    if (s_state == NETWORK_STATE_CELLULAR_REGISTERING ||
        s_state == NETWORK_STATE_CELLULAR_UP) {
        ESP_LOGW(TAG, "skip-probe: cellular branch already committed — "
                      "user must factory-reset to switch to WiFi");
        return ESP_ERR_INVALID_STATE;
    }
    s_user_committed_wifi = true;

    /* Eagerly initialise STA so the WiFi scan + WiFi form work during
     * the still-running modem_probe. network_init's post-probe code
     * is now a no-op for these resources thanks to wifi_branch_init_sta's
     * idempotency. */
    wifi_branch_init_sta();
    s_state = NETWORK_STATE_WIFI_CONNECTING;

    ESP_LOGI(TAG, "skip-probe: user committed to WiFi mode (STA initialised)");
    return ESP_OK;
}
