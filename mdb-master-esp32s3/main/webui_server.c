/*
 * VMflow.xyz
 *
 * webui_server.c - HTTP server, DNS captive portal, product NVS,
 *                  and event logging for the MDB Master Web UI
 */

#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "esp_wifi.h"
#include "esp_http_server.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include <esp_log.h>
#include <esp_timer.h>
#include "lwip/udp.h"
#include "lwip/ip_addr.h"
#include "webui_server.h"

#define TAG "webui"
#define NVS_NAMESPACE "vmc"

static httpd_handle_t rest_server = NULL;
static struct udp_pcb *dns_pcb = NULL;

extern const uint8_t index_html_start[] asm("_binary_index_html_start");
extern const uint8_t index_html_end[]   asm("_binary_index_html_end");

/* ================================================================
 *  Event logging (ring buffer)
 * ================================================================ */

void add_event(const char *fmt, ...)
{
    if (!event_mutex) return;

    xSemaphoreTake(event_mutex, portMAX_DELAY);

    event_entry_t *e = &event_log[event_log_head];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(e->text, MAX_EVENT_LEN, fmt, ap);
    va_end(ap);
    e->timestamp_ms = esp_timer_get_time() / 1000;

    event_log_head = (event_log_head + 1) % MAX_EVENTS;
    if (event_log_count < MAX_EVENTS) event_log_count++;

    xSemaphoreGive(event_mutex);

    ESP_LOGI(TAG, "EVENT: %s", e->text);
}

/* ================================================================
 *  Products NVS persistence
 * ================================================================ */

void set_default_products(void)
{
    static const struct { uint8_t slot; const char *name; uint16_t price; } defaults[] = {
        { 1, "Coffee",        150 },
        { 2, "Espresso",      120 },
        { 3, "Cappuccino",    180 },
        { 4, "Water",          80 },
        { 5, "Cola",          150 },
        { 6, "Juice",         160 },
        { 7, "Tea",           100 },
        { 8, "Hot Chocolate",  150 },
        { 9, "Energy Drink",  200 },
        {10, "Snack Bar",     120 },
    };
    product_count = sizeof(defaults) / sizeof(defaults[0]);
    for (int i = 0; i < product_count; i++) {
        products[i].slot        = defaults[i].slot;
        products[i].price_cents = defaults[i].price;
        strncpy(products[i].name, defaults[i].name, sizeof(products[i].name) - 1);
        products[i].name[sizeof(products[i].name) - 1] = '\0';
    }
}

void save_products_to_nvs(void)
{
    cJSON *arr = cJSON_CreateArray();
    for (int i = 0; i < product_count; i++) {
        cJSON *obj = cJSON_CreateObject();
        cJSON_AddNumberToObject(obj, "s", products[i].slot);
        cJSON_AddStringToObject(obj, "n", products[i].name);
        cJSON_AddNumberToObject(obj, "p", products[i].price_cents);
        cJSON_AddItemToArray(arr, obj);
    }
    char *json = cJSON_PrintUnformatted(arr);
    cJSON_Delete(arr);

    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_str(h, "products", json);
        nvs_commit(h);
        nvs_close(h);
        ESP_LOGI(TAG, "Products saved (%d items)", product_count);
    }
    cJSON_free(json);
}

void load_products_from_nvs(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGI(TAG, "No NVS namespace, loading defaults");
        set_default_products();
        return;
    }

    size_t len = 0;
    if (nvs_get_str(h, "products", NULL, &len) != ESP_OK || len == 0) {
        nvs_close(h);
        ESP_LOGI(TAG, "No products in NVS, loading defaults");
        set_default_products();
        return;
    }

    char *buf = malloc(len);
    if (!buf) { nvs_close(h); set_default_products(); return; }
    nvs_get_str(h, "products", buf, &len);
    nvs_close(h);

    cJSON *arr = cJSON_Parse(buf);
    free(buf);
    if (!arr || !cJSON_IsArray(arr)) {
        if (arr) cJSON_Delete(arr);
        set_default_products();
        return;
    }

    product_count = 0;
    cJSON *item;
    cJSON_ArrayForEach(item, arr) {
        if (product_count >= MAX_PRODUCTS) break;
        cJSON *js = cJSON_GetObjectItem(item, "s");
        cJSON *jn = cJSON_GetObjectItem(item, "n");
        cJSON *jp = cJSON_GetObjectItem(item, "p");
        if (!js || !jn || !jp) continue;
        products[product_count].slot        = (uint8_t)js->valuedouble;
        products[product_count].price_cents = (uint16_t)jp->valuedouble;
        strncpy(products[product_count].name, jn->valuestring,
                sizeof(products[product_count].name) - 1);
        products[product_count].name[sizeof(products[product_count].name) - 1] = '\0';
        product_count++;
    }
    cJSON_Delete(arr);
    ESP_LOGI(TAG, "Loaded %d products from NVS", product_count);
}

/* ================================================================
 *  Helper: read full POST body
 * ================================================================ */

static int read_post_body(httpd_req_t *req, char *buf, size_t max_len)
{
    int total = req->content_len;
    if (total >= (int)max_len) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Payload too large");
        return -1;
    }
    int cur = 0, r;
    while (cur < total) {
        r = httpd_req_recv(req, buf + cur, total - cur);
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Receive failed");
            return -1;
        }
        cur += r;
    }
    buf[total] = '\0';
    return total;
}

/* ================================================================
 *  DNS captive portal
 * ================================================================ */

static void dns_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                     const ip_addr_t *addr, u16_t port)
{
    if (!p) return;

    uint8_t *data = (uint8_t *)p->payload;
    data[2] |= 0x80;
    data[3] |= 0x80;
    data[7]  = 1;

    uint8_t response[] = {
        0xC0, 0x0C,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00, 0x00, 0x3C,
        0x00, 0x04,
        192, 168, 4, 1
    };

    struct pbuf *resp = pbuf_alloc(PBUF_TRANSPORT, p->len + sizeof(response), PBUF_RAM);
    if (resp) {
        memcpy(resp->payload, data, p->len);
        memcpy((uint8_t *)resp->payload + p->len, response, sizeof(response));
        udp_sendto(pcb, resp, addr, port);
        pbuf_free(resp);
    }
    pbuf_free(p);
}

/* ================================================================
 *  HTTP handlers
 * ================================================================ */

/* GET / — serve embedded HTML */
static esp_err_t index_get_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    httpd_resp_send(req, (const char *)index_html_start,
                    index_html_end - index_html_start);
    return ESP_OK;
}

/* GET /api/v1/status */
static esp_err_t status_get_handler(httpd_req_t *req)
{
    static const char *state_names[] = {
        "INACTIVE", "DISABLED", "ENABLED", "IDLE", "VEND"
    };

    cJSON *root = cJSON_CreateObject();
    int st = (int)reader0x10.machineState;
    cJSON_AddStringToObject(root, "state",
                            (st >= 0 && st <= 4) ? state_names[st] : "UNKNOWN");
    cJSON_AddNumberToObject(root, "state_code",  st);
    cJSON_AddStringToObject(root, "manufacturer", device_manufacturer);
    cJSON_AddStringToObject(root, "serial",       device_serial);
    cJSON_AddStringToObject(root, "model",        device_model);
    cJSON_AddStringToObject(root, "sw_version",   device_sw_version);
    cJSON_AddStringToObject(root, "sta_ip",       sta_ip_addr);
    cJSON_AddNumberToObject(root, "poll_fails",   reader0x10.poll_fail_count);
    cJSON_AddNumberToObject(root, "scale_factor", reader0x10.scaleFactor);
    cJSON_AddNumberToObject(root, "decimal_places", reader0x10.decimalPlaces);

    char *json = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json);
    cJSON_Delete(root);
    return ESP_OK;
}

/* GET /api/v1/products */
static esp_err_t products_get_handler(httpd_req_t *req)
{
    cJSON *root = cJSON_CreateObject();
    cJSON *arr  = cJSON_AddArrayToObject(root, "products");
    for (int i = 0; i < product_count; i++) {
        cJSON *obj = cJSON_CreateObject();
        cJSON_AddNumberToObject(obj, "slot",  products[i].slot);
        cJSON_AddStringToObject(obj, "name",  products[i].name);
        cJSON_AddNumberToObject(obj, "price", products[i].price_cents);
        cJSON_AddItemToArray(arr, obj);
    }

    char *json = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json);
    cJSON_Delete(root);
    return ESP_OK;
}

/* POST /api/v1/products */
static esp_err_t products_set_handler(httpd_req_t *req)
{
    char buf[2048];
    if (read_post_body(req, buf, sizeof(buf)) < 0) return ESP_FAIL;

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Invalid JSON\"}");
        return ESP_OK;
    }

    cJSON *arr = cJSON_GetObjectItem(root, "products");
    if (!arr || !cJSON_IsArray(arr)) {
        cJSON_Delete(root);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"products array required\"}");
        return ESP_OK;
    }

    product_count = 0;
    cJSON *item;
    cJSON_ArrayForEach(item, arr) {
        if (product_count >= MAX_PRODUCTS) break;
        cJSON *js = cJSON_GetObjectItem(item, "slot");
        cJSON *jn = cJSON_GetObjectItem(item, "name");
        cJSON *jp = cJSON_GetObjectItem(item, "price");
        if (!js || !jn || !jp) continue;
        products[product_count].slot        = (uint8_t)js->valuedouble;
        products[product_count].price_cents = (uint16_t)jp->valuedouble;
        strncpy(products[product_count].name, jn->valuestring,
                sizeof(products[product_count].name) - 1);
        products[product_count].name[sizeof(products[product_count].name) - 1] = '\0';
        product_count++;
    }
    cJSON_Delete(root);

    save_products_to_nvs();
    add_event("Products updated (%d items)", product_count);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

/* POST /api/v1/vend */
static esp_err_t vend_post_handler(httpd_req_t *req)
{
    char buf[256];
    if (read_post_body(req, buf, sizeof(buf)) < 0) return ESP_FAIL;

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Invalid JSON\"}");
        return ESP_OK;
    }

    cJSON *j_item  = cJSON_GetObjectItem(root, "item_number");
    cJSON *j_price = cJSON_GetObjectItem(root, "price");
    if (!j_item || !j_price) {
        cJSON_Delete(root);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"item_number and price required\"}");
        return ESP_OK;
    }

    vend_request_t vr = {
        .item_number = (uint16_t)j_item->valuedouble,
        .price_cents = (uint16_t)j_price->valuedouble,
    };
    cJSON_Delete(root);

    if (xQueueSend(vend_queue, &vr, 0) != pdTRUE) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"ok\":false,\"error\":\"Queue full, try again\"}");
        return ESP_OK;
    }

    add_event("Vend queued: slot %d, EUR %.2f",
              vr.item_number, vr.price_cents / 100.0);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

/* GET /api/v1/events */
static esp_err_t events_get_handler(httpd_req_t *req)
{
    cJSON *root = cJSON_CreateObject();
    cJSON *arr  = cJSON_AddArrayToObject(root, "events");

    xSemaphoreTake(event_mutex, portMAX_DELAY);

    int start;
    if (event_log_count < MAX_EVENTS) {
        start = 0;
    } else {
        start = event_log_head;          /* oldest entry */
    }

    for (int i = 0; i < event_log_count; i++) {
        int idx = (start + i) % MAX_EVENTS;
        cJSON *obj = cJSON_CreateObject();
        cJSON_AddStringToObject(obj, "text", event_log[idx].text);
        cJSON_AddNumberToObject(obj, "time", event_log[idx].timestamp_ms);
        cJSON_AddItemToArray(arr, obj);
    }

    xSemaphoreGive(event_mutex);

    char *json = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json);
    cJSON_Delete(root);
    return ESP_OK;
}

/* GET /api/v1/wifi/scan */
static esp_err_t wifi_scan_get_handler(httpd_req_t *req)
{
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

    /* Bubble-sort by RSSI descending */
    for (int i = 0; i < ap_count - 1; i++)
        for (int j = 0; j < ap_count - i - 1; j++)
            if (ap_records[j].rssi < ap_records[j + 1].rssi) {
                wifi_ap_record_t tmp = ap_records[j];
                ap_records[j]     = ap_records[j + 1];
                ap_records[j + 1] = tmp;
            }

    cJSON *root     = cJSON_CreateObject();
    cJSON *networks = cJSON_AddArrayToObject(root, "networks");
    char seen[20][33];
    int  seen_n = 0;

    for (int i = 0; i < ap_count; i++) {
        const char *ssid = (const char *)ap_records[i].ssid;
        if (strlen(ssid) == 0)              continue;
        if (strcmp(ssid, AP_SSID) == 0)     continue;
        bool dup = false;
        for (int s = 0; s < seen_n; s++)
            if (strcmp(seen[s], ssid) == 0) { dup = true; break; }
        if (dup) continue;
        if (seen_n < 20) { strncpy(seen[seen_n], ssid, 32); seen[seen_n][32] = '\0'; seen_n++; }

        cJSON *net = cJSON_CreateObject();
        cJSON_AddStringToObject(net, "ssid", ssid);
        cJSON_AddNumberToObject(net, "rssi", ap_records[i].rssi);
        cJSON_AddBoolToObject(net,   "secure", ap_records[i].authmode != WIFI_AUTH_OPEN);
        cJSON_AddItemToArray(networks, net);
    }
    free(ap_records);

    char *json = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json);
    cJSON_Delete(root);
    return ESP_OK;
}

/* POST /api/v1/wifi/connect */
static esp_err_t wifi_connect_handler(httpd_req_t *req)
{
    char buf[512];
    if (read_post_body(req, buf, sizeof(buf)) < 0) return ESP_FAIL;

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Invalid JSON\"}");
        return ESP_OK;
    }

    cJSON *j_ssid = cJSON_GetObjectItem(root, "ssid");
    cJSON *j_pass = cJSON_GetObjectItem(root, "password");

    if (!j_ssid || !cJSON_IsString(j_ssid) || strlen(j_ssid->valuestring) == 0) {
        cJSON_Delete(root);
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"ssid required\"}");
        return ESP_OK;
    }

    wifi_config_t cfg = {0};
    esp_wifi_get_config(WIFI_IF_STA, &cfg);
    strncpy((char *)cfg.sta.ssid, j_ssid->valuestring, sizeof(cfg.sta.ssid) - 1);
    strncpy((char *)cfg.sta.password,
            (j_pass && cJSON_IsString(j_pass)) ? j_pass->valuestring : "",
            sizeof(cfg.sta.password) - 1);
    esp_wifi_set_config(WIFI_IF_STA, &cfg);
    cJSON_Delete(root);

    add_event("WiFi connecting to %s", cfg.sta.ssid);
    esp_wifi_connect();

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

/* Captive portal redirects */
static esp_err_t captive_handler(httpd_req_t *req)
{
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", "/");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/* Empty favicon to suppress 404 */
static esp_err_t favicon_handler(httpd_req_t *req)
{
    httpd_resp_set_status(req, "204 No Content");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

/* ================================================================
 *  DNS server start/stop
 * ================================================================ */

void start_dns_server(void)
{
    if (dns_pcb) return;
    dns_pcb = udp_new();
    udp_bind(dns_pcb, IP_ADDR_ANY, 53);
    udp_recv(dns_pcb, dns_recv, NULL);
    ESP_LOGI(TAG, "DNS started");
}

void stop_dns_server(void)
{
    if (!dns_pcb) return;
    udp_recv(dns_pcb, NULL, NULL);
    udp_remove(dns_pcb);
    dns_pcb = NULL;
    ESP_LOGI(TAG, "DNS stopped");
}

/* ================================================================
 *  HTTP server start/stop
 * ================================================================ */

void stop_rest_server(void)
{
    if (!rest_server) return;
    httpd_stop(rest_server);
    rest_server = NULL;
}

void start_rest_server(void)
{
    if (rest_server) return;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 12;
    config.uri_match_fn     = httpd_uri_match_wildcard;

    if (httpd_start(&rest_server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server");
        return;
    }

    static const httpd_uri_t uris[] = {
        { .uri = "/",                     .method = HTTP_GET,  .handler = index_get_handler    },
        { .uri = "/api/v1/status",        .method = HTTP_GET,  .handler = status_get_handler   },
        { .uri = "/api/v1/products",      .method = HTTP_GET,  .handler = products_get_handler },
        { .uri = "/api/v1/products",      .method = HTTP_POST, .handler = products_set_handler },
        { .uri = "/api/v1/vend",          .method = HTTP_POST, .handler = vend_post_handler    },
        { .uri = "/api/v1/events",        .method = HTTP_GET,  .handler = events_get_handler   },
        { .uri = "/api/v1/wifi/scan",     .method = HTTP_GET,  .handler = wifi_scan_get_handler},
        { .uri = "/api/v1/wifi/connect",  .method = HTTP_POST, .handler = wifi_connect_handler },
        { .uri = "/generate_204",         .method = HTTP_GET,  .handler = captive_handler      },
        { .uri = "/hotspot-detect.html",  .method = HTTP_GET,  .handler = captive_handler      },
        { .uri = "/favicon.ico",          .method = HTTP_GET,  .handler = favicon_handler      },
    };

    for (int i = 0; i < sizeof(uris) / sizeof(uris[0]); i++)
        httpd_register_uri_handler(rest_server, &uris[i]);

    ESP_LOGI(TAG, "HTTP server started (port 80)");
}

/* ================================================================
 *  SoftAP
 * ================================================================ */

void start_softap(void)
{
    wifi_config_t wifi_config = {
        .ap = {
            .ssid           = AP_SSID,
            .ssid_len       = strlen(AP_SSID),
            .password       = AP_PASS,
            .max_connection = 4,
            .authmode       = WIFI_AUTH_WPA_WPA2_PSK,
        },
    };
    esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    ESP_LOGI(TAG, "SoftAP configured (SSID=\"%s\")", AP_SSID);
}
