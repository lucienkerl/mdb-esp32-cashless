#include <string.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_wifi.h"
#include "esp_http_server.h"
#include "esp_timer.h"
#include "esp_app_desc.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include <esp_log.h>
#include "lwip/udp.h"
#include "lwip/ip_addr.h"
#include "esp_chip_info.h"
#include "webui_server.h"
#include "network.h"
#include "modem.h"
#include "provision.h"
#include "restart.h"

#define TAG "webui"


static httpd_handle_t rest_server = NULL;

extern const uint8_t index_html_start[] asm("_binary_index_html_start");
extern const uint8_t index_html_end[]   asm("_binary_index_html_end");
static struct udp_pcb *dns_pcb;

/* -----------     DNS captive portal     ---------- */

static void dns_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {

    if (!p) return;

    uint8_t *data = (uint8_t *)p->payload;
    data[2] |= 0x80;  // QR = response
    data[3] |= 0x80;  // RA = recursion available
    data[7]  = 1;     // ANCOUNT = 1

    uint8_t response[] = {
        0xC0, 0x0C,             // pointer to domain name
        0x00, 0x01,             // type A
        0x00, 0x01,             // class IN
        0x00, 0x00, 0x00, 0x3C, // TTL 60s
        0x00, 0x04,             // data length
        192, 168, 4, 1          // AP IP
    };

    struct pbuf *resp = pbuf_alloc(PBUF_TRANSPORT, p->len + sizeof(response), PBUF_RAM);
    memcpy(resp->payload, data, p->len);
    memcpy((uint8_t *)resp->payload + p->len, response, sizeof(response));
    udp_sendto(pcb, resp, addr, port);
    pbuf_free(resp);
    pbuf_free(p);
}

/* ---------- HTTP handlers ---------- */

static esp_err_t index_get_handler(httpd_req_t *req) {
    const size_t html_len = index_html_end - index_html_start;
    httpd_resp_set_type(req, "text/html");
    /* The page is re-embedded into the firmware binary on every build (no
     * separate filesystem/data partition to reflash), so an OTA update can
     * change its content while the URL stays "/" — without this header a
     * phone that already cached the portal page from a previous firmware
     * version keeps showing the stale one after an update. */
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_send(req, (const char *)index_html_start, html_len);
    return ESP_OK;
}

static const char *wizard_state_str(network_state_t s) {
    switch (s) {
        case NETWORK_STATE_BOOTING:               return "booting";
        case NETWORK_STATE_OFFLINE:               return "offline";
        case NETWORK_STATE_SOFTAP_ONLY:           return "cellular_config";
        case NETWORK_STATE_WIFI_CONNECTING:       return "wifi_connecting";
        case NETWORK_STATE_WIFI_UP:               return "ready_to_claim";  /* if not claimed yet */
        case NETWORK_STATE_CELLULAR_REGISTERING:  return "cellular_registering";
        case NETWORK_STATE_CELLULAR_UP:           return "ready_to_claim";  /* if not claimed yet */
    }
    return "unknown";
}

static const char *lte_mode_str(modem_lte_mode_t m) {
    switch (m) {
        case MODEM_LTE_MODE_CATM:  return "LTE-M";
        case MODEM_LTE_MODE_NBIOT: return "NB-IoT";
        case MODEM_LTE_MODE_BOTH:  return "Auto";
    }
    return "unknown";
}

static esp_err_t system_info_get_handler(httpd_req_t *req) {
    network_status_t st;
    network_get_status(&st);

    /* Read claim + provisioning state + diagnostic identifiers from NVS.
     * Surfaced in /system/info so the captive-portal "claimed" view can
     * show the user who they are, where they're talking to, and what
     * firmware is running — useful for field debugging without a
     * serial cable. */
    char company_id[40] = "";
    char device_id[40]  = "";
    char prov_code[16]  = "";
    char srv_url[128]   = "";
    char mqtt_host[64]  = "";
    char mqtt_port[8]   = "";
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READONLY, &h) == ESP_OK) {
        size_t sl;
        sl = sizeof(company_id); nvs_get_str(h, "company_id", company_id, &sl);
        sl = sizeof(device_id);  nvs_get_str(h, "device_id",  device_id,  &sl);
        sl = sizeof(prov_code);  nvs_get_str(h, "prov_code",  prov_code,  &sl);
        sl = sizeof(srv_url);    nvs_get_str(h, "srv_url",    srv_url,    &sl);
        sl = sizeof(mqtt_host);  nvs_get_str(h, "mqtt_host",  mqtt_host,  &sl);
        sl = sizeof(mqtt_port);  nvs_get_str(h, "mqtt_port",  mqtt_port,  &sl);
        nvs_close(h);
    }
    bool claimed       = (strlen(company_id) > 0);
    bool prov_code_set = (strlen(prov_code)  > 0);

    /* Variant is keyed off the actual probe outcome, NOT off the current
     * network state. SOFTAP_ONLY can mean either "cellular board waiting
     * for APN" OR "WiFi-only board with no saved creds" — using
     * modem_is_present() disambiguates. */
    bool modem_present = modem_is_present();

    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "variant", modem_present ? "cellular" : "wifi");

    /* Uplink switch (Option A): only offered once this board has ever
     * confirmed modem hardware (network_has_cellular_hw persists across
     * the "currently running in WiFi mode, probe skipped" case, where
     * modem_present above would otherwise read false and hide the
     * switch on a board that's plainly capable of it). */
    cJSON *usw = cJSON_AddObjectToObject(root, "uplink_switch");
    cJSON_AddBoolToObject(usw, "available", network_has_cellular_hw());
    cJSON_AddStringToObject(usw, "preference",
                             network_get_uplink_preference() ? "wifi" : "cellular");

    /* Wizard state mapping. SOFTAP_ONLY needs special handling because it
     * means different things on the two variants.
     *
     * Two special cases that wrap normal state mapping:
     *
     * (1) PROBING: while the synchronous modem_probe is still running
     *     (first ~5 s of boot), report wizard_state="probing". Without
     *     this, the UI would briefly render the WiFi setup form (because
     *     modem_present=false until probe completes), then flicker to
     *     the cellular form once the modem is detected.
     *
     * (2) CLAIMED_CONNECTING: device has NVS credentials (claimed) but
     *     uplink isn't up yet. Happens during the window between
     *     post-claim tracked_restart's reboot and CELLULAR_UP — modem
     *     is rebooting, registering, doing IPCP. Without this state
     *     the UI would render "Setup complete" with empty signal/IP
     *     fields, looking broken even though things are progressing.
     *     We render a "Establishing connection…" view instead. */
    const char *ws;
    if (claimed) {
        bool uplink_up = (st.state == NETWORK_STATE_CELLULAR_UP ||
                          st.state == NETWORK_STATE_WIFI_UP);
        ws = uplink_up ? "claimed" : "claimed_connecting";
    } else if (!network_modem_probe_complete()) {
        ws = "probing";
    } else if (st.state == NETWORK_STATE_SOFTAP_ONLY) {
        ws = modem_present ? "cellular_config" : "wifi_connecting";
    } else {
        ws = wizard_state_str(st.state);
    }
    cJSON_AddStringToObject(root, "wizard_state", ws);

    cJSON *uplink = cJSON_AddObjectToObject(root, "uplink");
    cJSON_AddStringToObject(uplink, "kind", st.uplink_kind);

    if (st.wifi_initialised) {
        cJSON *w = cJSON_AddObjectToObject(uplink, "wifi");
        cJSON_AddStringToObject(w, "ssid", st.wifi_ssid);
        cJSON_AddNumberToObject(w, "rssi", st.wifi_rssi);
        cJSON_AddStringToObject(w, "ip",   st.wifi_ip);
    } else {
        cJSON_AddNullToObject(uplink, "wifi");
    }

    if (modem_present) {
        cJSON *c = cJSON_AddObjectToObject(uplink, "cellular");
        cJSON_AddStringToObject(c, "operator",  st.cellular_operator);
        cJSON_AddStringToObject(c, "mode",      lte_mode_str(st.cellular_mode));
        cJSON_AddNumberToObject(c, "rssi_dbm",  st.cellular_rssi_dbm);
        cJSON_AddStringToObject(c, "ip",        st.cellular_ip);
        cJSON_AddBoolToObject(c,   "registered", st.cellular_registered);
    } else {
        cJSON_AddNullToObject(uplink, "cellular");
    }

    cJSON *claim = cJSON_AddObjectToObject(root, "claim");
    cJSON_AddBoolToObject(claim, "claimed",       claimed);
    cJSON_AddBoolToObject(claim, "prov_code_set", prov_code_set);
    /* Identifiers + endpoints exposed only when actually claimed —
     * pre-claim they're empty/uninteresting and would clutter the UI. */
    if (claimed) {
        cJSON_AddStringToObject(claim, "company_id", company_id);
        cJSON_AddStringToObject(claim, "device_id",  device_id);
        cJSON_AddStringToObject(claim, "srv_url",    srv_url);
        cJSON_AddStringToObject(claim, "mqtt_host",  mqtt_host);
        cJSON_AddStringToObject(claim, "mqtt_port",  mqtt_port);
    }

    /* Device block — always populated. Useful even pre-claim so the
     * user can identify the physical device (MAC) and firmware build. */
    cJSON *device = cJSON_AddObjectToObject(root, "device");
    {
        uint8_t mac[6] = { 0 };
        esp_wifi_get_mac(WIFI_IF_STA, mac);
        char mac_str[18];
        snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        cJSON_AddStringToObject(device, "mac", mac_str);

        const esp_app_desc_t *app = esp_app_get_description();
        cJSON_AddStringToObject(device, "firmware",  app ? app->version : "");
        cJSON_AddStringToObject(device, "build_date", app ? app->date    : "");

        int uptime_s = (int)(esp_timer_get_time() / 1000000LL);
        cJSON_AddNumberToObject(device, "uptime_s", uptime_s);
    }

    char *json_str = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json_str);
    cJSON_Delete(root);
    return ESP_OK;
}

/* ---------- Wizard endpoint helpers ---------- */

static esp_err_t recv_json_body(httpd_req_t *req, char *buf, size_t bufsize) {
    int total = req->content_len;
    if (total <= 0 || total >= (int)bufsize) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "body too large or empty");
        return ESP_FAIL;
    }
    int cur = 0;
    while (cur < total) {
        int r = httpd_req_recv(req, buf + cur, total - cur);
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "recv failed");
            return ESP_FAIL;
        }
        cur += r;
    }
    buf[total] = '\0';
    return ESP_OK;
}

static esp_err_t send_ok(httpd_req_t *req) {
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

static esp_err_t send_err_json(httpd_req_t *req, const char *msg) {
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", msg);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, buf);
    return ESP_OK;
}

/* POST /api/v1/system/skip-probe — user-facing dismissal of the
 * "Detecting modem…" loading view in the captive portal. Marks the
 * device as committed-to-WiFi-mode regardless of what modem_probe
 * eventually finds. Replies 409 if the cellular branch was already
 * taken (probe finished and detected a modem before this call). */
static esp_err_t skip_probe_handler(httpd_req_t *req) {
    esp_err_t err = network_skip_modem_probe();
    if (err == ESP_ERR_INVALID_STATE) {
        httpd_resp_set_status(req, "409 Conflict");
        return send_err_json(req, "cellular branch already committed — power-cycle to retry");
    }
    if (err != ESP_OK) return send_err_json(req, esp_err_to_name(err));
    return send_ok(req);
}

/* POST /api/v1/cellular/configure  body: {apn, pin, lte_mode}
 *   apn: required string
 *   pin: optional string (empty = no PIN)
 *   lte_mode: integer 1=CatM 2=NBIoT 3=Both */
static esp_err_t cellular_configure_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *japn = cJSON_GetObjectItem(root, "apn");
    cJSON *jpin = cJSON_GetObjectItem(root, "pin");
    cJSON *jmode = cJSON_GetObjectItem(root, "lte_mode");
    if (!japn || !cJSON_IsString(japn) || strlen(japn->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "apn required");
    }
    int mode = jmode && cJSON_IsNumber(jmode) ? (int)jmode->valuedouble : MODEM_LTE_MODE_BOTH;
    if (mode < 1 || mode > 3) mode = MODEM_LTE_MODE_BOTH;

    const char *pin = (jpin && cJSON_IsString(jpin)) ? jpin->valuestring : "";

    esp_err_t err = network_cellular_configure(japn->valuestring, pin, (modem_lte_mode_t)mode);
    cJSON_Delete(root);

    if (err == ESP_ERR_INVALID_STATE) return send_err_json(req, "bring-up already in progress");
    if (err != ESP_OK)                return send_err_json(req, esp_err_to_name(err));
    return send_ok(req);
}

/* POST /api/v1/wifi/configure  body: {ssid, password} */
static esp_err_t wifi_configure_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *jssid = cJSON_GetObjectItem(root, "ssid");
    cJSON *jpass = cJSON_GetObjectItem(root, "password");
    if (!jssid || !cJSON_IsString(jssid) || strlen(jssid->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "ssid required");
    }
    const char *pass = (jpass && cJSON_IsString(jpass)) ? jpass->valuestring : "";

    esp_err_t err = network_wifi_configure(jssid->valuestring, pass);
    cJSON_Delete(root);

    if (err == ESP_ERR_NOT_SUPPORTED) return send_err_json(req, "WiFi not configurable on cellular board");
    if (err != ESP_OK)                return send_err_json(req, esp_err_to_name(err));
    return send_ok(req);
}

/* Fire-and-forget: give the HTTP response time to flush before rebooting,
 * same trick provision_claim_task's callers rely on implicitly (there the
 * restart happens deep inside an async task; here the handler itself
 * would otherwise reboot before httpd finishes writing the reply). */
static void uplink_pref_restart_task(void *arg) {
    vTaskDelay(pdMS_TO_TICKS(300));
    tracked_restart("uplink_pref");
}

/* POST /api/v1/uplink/prefer  body: {prefer: "wifi"|"cellular", ssid?, password?}
 *
 * Option A uplink switch — WiFi *instead of* cellular, never both. Only
 * meaningful on a board that has ever confirmed modem hardware present
 * (network_has_cellular_hw); rejected otherwise. Switching to "wifi"
 * accepts optional ssid/password in the same request so the very next
 * boot can connect immediately — no second SoftAP round-trip needed.
 * Always reboots on success (network_init() only branches at boot). */
static esp_err_t uplink_prefer_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *jprefer = cJSON_GetObjectItem(root, "prefer");
    if (!jprefer || !cJSON_IsString(jprefer)) {
        cJSON_Delete(root);
        return send_err_json(req, "prefer required (\"wifi\" or \"cellular\")");
    }
    bool prefer_wifi;
    if (strcmp(jprefer->valuestring, "wifi") == 0) {
        prefer_wifi = true;
    } else if (strcmp(jprefer->valuestring, "cellular") == 0) {
        prefer_wifi = false;
    } else {
        cJSON_Delete(root);
        return send_err_json(req, "prefer must be \"wifi\" or \"cellular\"");
    }

    cJSON *jssid = cJSON_GetObjectItem(root, "ssid");
    cJSON *jpass = cJSON_GetObjectItem(root, "password");
    const char *ssid = (jssid && cJSON_IsString(jssid)) ? jssid->valuestring : NULL;
    const char *pass = (jpass && cJSON_IsString(jpass)) ? jpass->valuestring : "";

    esp_err_t err = network_set_uplink_preference(prefer_wifi, ssid, pass);
    cJSON_Delete(root);

    if (err == ESP_ERR_NOT_SUPPORTED) return send_err_json(req, "no cellular hardware confirmed on this device");
    if (err != ESP_OK)                return send_err_json(req, esp_err_to_name(err));

    xTaskCreate(uplink_pref_restart_task, "uplink_restart", 3072, NULL, 5, NULL);
    return send_ok(req);
}

/* POST /api/v1/claim  body: {prov_code, srv_url} */
static esp_err_t claim_handler(httpd_req_t *req) {
    char buf[512];
    if (recv_json_body(req, buf, sizeof(buf)) != ESP_OK) return ESP_OK;

    cJSON *root = cJSON_Parse(buf);
    if (!root) return send_err_json(req, "invalid JSON");

    cJSON *jcode = cJSON_GetObjectItem(root, "prov_code");
    cJSON *jurl  = cJSON_GetObjectItem(root, "srv_url");
    if (!jcode || !cJSON_IsString(jcode) || strlen(jcode->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "prov_code required");
    }
    if (!jurl || !cJSON_IsString(jurl) || strlen(jurl->valuestring) == 0) {
        cJSON_Delete(root);
        return send_err_json(req, "srv_url required");
    }

    /* Persist prov_code + srv_url to NVS so the claim task can pick
     * them up. */
    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, "prov_code", jcode->valuestring);
        nvs_set_str(h, "srv_url",   jurl->valuestring);
        nvs_commit(h);
        nvs_close(h);
    }
    cJSON_Delete(root);

    /* Spawn strategy: the claim task does an HTTPS POST that needs an
     * uplink with DNS. On a WiFi board, the captive portal is hit
     * BEFORE STA finishes connecting — spawning here would race the
     * STA bring-up and fail with getaddrinfo() = EAI_AGAIN. Instead:
     *
     *   - Already up (cellular registered, or STA already had IP from
     *     a prior connect): spawn now.
     *   - Not up yet: don't spawn here. The network event handler in
     *     mdb-slave-esp32s3.c spawns the task on NETWORK_EVENT_UPLINK_UP,
     *     which fires when STA gets IP / PPP completes IPCP — at which
     *     point DNS resolves cleanly. */
    network_status_t st;
    network_get_status(&st);
    if (st.uplink_up) {
        xTaskCreate(provision_claim_task, "prov_claim", 16384, NULL, 5, NULL);
    } else {
        ESP_LOGI(TAG, "claim: uplink not yet up — task will spawn on UPLINK_UP");
    }
    return send_ok(req);
}

static esp_err_t wifi_scan_get_handler(httpd_req_t *req) {

    wifi_scan_config_t scan_cfg = {
        .ssid        = NULL,
        .bssid       = NULL,
        .channel     = 0,
        .show_hidden = false,
        .scan_type   = WIFI_SCAN_TYPE_ACTIVE,
        .scan_time   = { .active = { .min = 100, .max = 300 } },
    };

    esp_err_t err = esp_wifi_scan_start(&scan_cfg, true);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "WiFi scan failed: %s", esp_err_to_name(err));
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"networks\":[],\"error\":\"scan_failed\"}");
        return ESP_OK;
    }

    uint16_t ap_count = 0;
    esp_wifi_scan_get_ap_num(&ap_count);
    if (ap_count > 20) ap_count = 20;

    wifi_ap_record_t *ap_records = calloc(ap_count, sizeof(wifi_ap_record_t));
    if (!ap_records) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"networks\":[],\"error\":\"out_of_memory\"}");
        return ESP_OK;
    }
    esp_wifi_scan_get_ap_records(&ap_count, ap_records);

    /* Sort by RSSI descending (simple bubble sort, n<=20) */
    for (int i = 0; i < ap_count - 1; i++) {
        for (int j = 0; j < ap_count - i - 1; j++) {
            if (ap_records[j].rssi < ap_records[j + 1].rssi) {
                wifi_ap_record_t tmp = ap_records[j];
                ap_records[j] = ap_records[j + 1];
                ap_records[j + 1] = tmp;
            }
        }
    }

    /* Build deduplicated JSON array, filtering own AP and hidden networks */
    cJSON *root = cJSON_CreateObject();
    cJSON *networks = cJSON_AddArrayToObject(root, "networks");

    char own_ssid[SOFTAP_SSID_MAX] = {0};
    softap_get_ssid(own_ssid, sizeof(own_ssid));

    char seen_ssids[20][33];
    int seen_count = 0;

    for (int i = 0; i < ap_count; i++) {
        const char *ssid = (const char *)ap_records[i].ssid;

        /* Skip empty SSIDs (hidden networks) */
        if (strlen(ssid) == 0) continue;

        /* Skip own AP */
        if (strcmp(ssid, own_ssid) == 0) continue;

        /* Skip duplicates (already sorted by RSSI, first occurrence is strongest) */
        bool dup = false;
        for (int s = 0; s < seen_count; s++) {
            if (strcmp(seen_ssids[s], ssid) == 0) { dup = true; break; }
        }
        if (dup) continue;

        if (seen_count < 20) {
            strncpy(seen_ssids[seen_count], ssid, 32);
            seen_ssids[seen_count][32] = '\0';
            seen_count++;
        }

        cJSON *net = cJSON_CreateObject();
        cJSON_AddStringToObject(net, "ssid", ssid);
        cJSON_AddNumberToObject(net, "rssi", ap_records[i].rssi);
        cJSON_AddBoolToObject(net, "secure", ap_records[i].authmode != WIFI_AUTH_OPEN);
        cJSON_AddItemToArray(networks, net);
    }

    free(ap_records);

    char *json_str = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json_str);
    cJSON_Delete(root);

    return ESP_OK;
}

static esp_err_t captive_handler(httpd_req_t *req) {
    ESP_LOGI(TAG, "Captive portal redirect: %s", req->uri);
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/* Catch-all 404 handler. Returns a 302 redirect to '/' so iOS, Android,
 * macOS, Windows, and Linux captive-portal probes that hit any path we
 * don't explicitly register still trigger the OS's "Sign in to network"
 * popup.
 *
 * Without this, only the specific probe URLs we list as exact handlers
 * worked — modern OS captive portal detection uses many paths (and they
 * change between releases). iOS 26 in particular probes additional paths
 * like /library/test/success.html under captive.apple.com.
 *
 * We intentionally redirect rather than serve the index inline: a 302
 * is the most reliable trigger for the captive-portal popup across all
 * OS versions in the field. */
static esp_err_t catchall_404_handler(httpd_req_t *req, httpd_err_code_t err) {
    (void)err;
    ESP_LOGI(TAG, "captive 404 → redirect: %s", req->uri);
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/* ---------- DNS ---------- */

void stop_dns_server(void) {
    if (dns_pcb == NULL) return;
    udp_recv(dns_pcb, NULL, NULL);
    udp_remove(dns_pcb);
    dns_pcb = NULL;
    ESP_LOGI(TAG, "DNS stopped");
}

void start_dns_server(void) {
    dns_pcb = udp_new();
    udp_bind(dns_pcb, IP_ADDR_ANY, 53);
    udp_recv(dns_pcb, dns_recv, NULL);
    ESP_LOGI(TAG, "DNS started");
}

/* ---------- HTTP server ---------- */

void stop_rest_server(void) {
    if (rest_server == NULL) return;
    httpd_stop(rest_server);
    rest_server = NULL;
}

void start_rest_server(void) {
    if (rest_server != NULL) return;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    /* Allow more handler slots than the default 8 — we register seven
     * exact API URIs plus a clutch of captive-portal probe paths. */
    config.max_uri_handlers = 16;
    httpd_start(&rest_server, &config);

    static const httpd_uri_t uris[] = {
        { .uri = "/",                          .method = HTTP_GET,  .handler = index_get_handler          },
        { .uri = "/api/v1/system/info",        .method = HTTP_GET,  .handler = system_info_get_handler    },
        { .uri = "/api/v1/system/skip-probe",  .method = HTTP_POST, .handler = skip_probe_handler         },
        { .uri = "/api/v1/wifi/scan",          .method = HTTP_GET,  .handler = wifi_scan_get_handler      },
        { .uri = "/api/v1/cellular/configure", .method = HTTP_POST, .handler = cellular_configure_handler },
        { .uri = "/api/v1/wifi/configure",     .method = HTTP_POST, .handler = wifi_configure_handler     },
        { .uri = "/api/v1/uplink/prefer",      .method = HTTP_POST, .handler = uplink_prefer_handler      },
        { .uri = "/api/v1/claim",              .method = HTTP_POST, .handler = claim_handler              },

        /* OS captive-portal probe paths.
         *
         * Each OS picks one (or several) of these to detect whether the
         * network requires sign-in. Returning a 302 to '/' triggers the
         * "Sign in to network" auto-popup on every modern OS:
         *   Android:    /generate_204               (gstatic, kindle, etc.)
         *   iOS/macOS:  /hotspot-detect.html        (captive.apple.com)
         *   iOS 16+:    /library/test/success.html  (newer paths)
         *   Windows:    /connecttest.txt            (msftconnecttest.com)
         *               /ncsi.txt                   (msftncsi.com)
         *   Linux:      /                           (NetworkManager) — handled by index
         *               /generate_204               (also used)
         *               /canonical.html             (Ubuntu)
         *   Firefox:    /success.txt                (detectportal.firefox.com)
         *
         * The catch-all 404 handler below covers any probe paths we
         * forget — but explicit handlers log nicer for debugging. */
        { .uri = "/generate_204",              .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/hotspot-detect.html",       .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/library/test/success.html", .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/connecttest.txt",           .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/ncsi.txt",                  .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/canonical.html",            .method = HTTP_GET,  .handler = captive_handler            },
        { .uri = "/success.txt",               .method = HTTP_GET,  .handler = captive_handler            },
    };

    for (int i = 0; i < sizeof(uris) / sizeof(uris[0]); i++) {
        httpd_register_uri_handler(rest_server, &uris[i]);
    }

    /* Last line of defence: any GET we don't explicitly handle gets the
     * same 302 → '/' redirect. Covers OS-specific probes we don't know
     * about (and future ones). */
    httpd_register_err_handler(rest_server, HTTPD_404_NOT_FOUND, catchall_404_handler);
}

/* ---------- SoftAP ---------- */

esp_err_t softap_get_ssid(char *out, size_t out_len) {
    if (!out || out_len < 14) return ESP_ERR_INVALID_ARG;  /* "VMflow-AABBCC" + NUL = 14 */
    uint8_t mac[6];
    esp_err_t err = esp_wifi_get_mac(WIFI_IF_STA, mac);
    if (err != ESP_OK) return err;
    snprintf(out, out_len, "VMflow-%02X%02X%02X", mac[3], mac[4], mac[5]);
    return ESP_OK;
}

esp_err_t softap_get_password(char *out, size_t out_len) {
    if (!out || out_len < 9) return ESP_ERR_INVALID_ARG;  /* WPA2 PSK min is 8 + NUL */
    out[0] = '\0';  /* default: empty string ⇒ open AP */

    nvs_handle_t h;
    esp_err_t err = nvs_open("vmflow", NVS_READONLY, &h);
    if (err == ESP_OK) {
        size_t len = out_len;
        err = nvs_get_str(h, "softap_pwd", out, &len);
        nvs_close(h);
        if (err != ESP_OK || strlen(out) < 8) {
            /* Missing, too short, or read error — fall through to empty.
             * This is the path taken before the device is claimed, and on
             * existing already-claimed devices that haven't been re-claimed
             * since OTA. start_softap brings up the AP as open. */
            out[0] = '\0';
        }
    }
    return ESP_OK;
}

void start_softap(void) {
    char ssid[SOFTAP_SSID_MAX];
    char pwd[SOFTAP_PWD_MAX];

    if (softap_get_ssid(ssid, sizeof(ssid)) != ESP_OK) {
        ESP_LOGE(TAG, "SoftAP SSID fetch failed; using static fallback");
        snprintf(ssid, sizeof(ssid), "VMflow");
    }
    softap_get_password(pwd, sizeof(pwd));  /* never errors; empty pwd ⇒ open */

    bool open = (pwd[0] == '\0');

    wifi_config_t wifi_config = {
        .ap = {
            .ssid_len       = strlen(ssid),
            .max_connection = 4,
            .authmode       = open ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA_WPA2_PSK,
        },
    };
    strncpy((char *)wifi_config.ap.ssid, ssid, sizeof(wifi_config.ap.ssid));
    if (!open) {
        strncpy((char *)wifi_config.ap.password, pwd, sizeof(wifi_config.ap.password));
    }

    esp_err_t err = esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    ESP_LOGI(TAG, "SoftAP config set (SSID=\"%s\" auth=%s) → %s",
             ssid, open ? "OPEN" : "WPA2", esp_err_to_name(err));
}
