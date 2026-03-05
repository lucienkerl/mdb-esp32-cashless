#include <string.h>
#include "freertos/FreeRTOS.h"
#include "esp_wifi.h"
#include "esp_http_server.h"
#include "nvs_flash.h"
#include "cJSON.h"
#include <esp_log.h>
#include "lwip/udp.h"
#include "lwip/ip_addr.h"
#include "webui_server.h"

#define TAG "webui"

static httpd_handle_t server = NULL;

extern const uint8_t index_html_start[] asm("_binary_index_html_start");
extern const uint8_t index_html_end[]   asm("_binary_index_html_end");
static struct udp_pcb *dns_pcb = NULL;

/* ---------- State name helper ---------- */

static const char* state_name(machine_state_t s) {
    switch (s) {
        case INACTIVE_STATE:  return "INACTIVE";
        case DISABLED_STATE:  return "DISABLED";
        case ENABLED_STATE:   return "ENABLED";
        case IDLE_STATE:      return "IDLE";
        case VEND_STATE:      return "VEND";
        default:              return "UNKNOWN";
    }
}

/* ---------- DNS captive portal ---------- */

static void dns_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    if (!p) return;

    uint8_t *data = (uint8_t *)p->payload;
    data[2] |= 0x80;
    data[3] |= 0x80;
    data[7]  = 1;

    uint8_t response[] = {
        0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x3C, 0x00, 0x04,
        192, 168, 4, 1
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
    httpd_resp_send(req, (const char *)index_html_start, html_len);
    return ESP_OK;
}

static esp_err_t state_get_handler(httpd_req_t *req) {
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "state", state_name(reader0x10.machineState));
    cJSON_AddNumberToObject(root, "featureLevel", reader0x10.featureLevel);
    cJSON_AddNumberToObject(root, "scaleFactor", reader0x10.scaleFactor);
    cJSON_AddNumberToObject(root, "decimalPlaces", reader0x10.decimalPlaces);
    cJSON_AddBoolToObject(root, "readerEnabled", reader_enabled);
    cJSON_AddStringToObject(root, "manufacturer", reader0x10_manufacturer);
    cJSON_AddStringToObject(root, "serial", reader0x10_serial);
    cJSON_AddStringToObject(root, "model", reader0x10_model);
    cJSON_AddStringToObject(root, "swVersion", reader0x10_sw_version);

    // Get IP
    esp_netif_ip_info_t ip_info;
    esp_netif_t *sta = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (sta && esp_netif_get_ip_info(sta, &ip_info) == ESP_OK && ip_info.ip.addr != 0) {
        char ip_str[16];
        snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&ip_info.ip));
        cJSON_AddStringToObject(root, "ip", ip_str);
    } else {
        cJSON_AddStringToObject(root, "ip", "192.168.4.1");
    }

    char *json_str = cJSON_PrintUnformatted(root);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json_str);
    cJSON_Delete(root);
    return ESP_OK;
}

/* Helper to read POST body */
static int read_post_body(httpd_req_t *req, char *buf, size_t buf_size) {
    int total_len = req->content_len;
    if (total_len >= (int)buf_size) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Payload too large");
        return -1;
    }
    int cur_len = 0, received;
    while (cur_len < total_len) {
        received = httpd_req_recv(req, buf + cur_len, total_len - cur_len);
        if (received <= 0) {
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to receive data");
            return -1;
        }
        cur_len += received;
    }
    buf[total_len] = '\0';
    return total_len;
}

static esp_err_t vend_post_handler(httpd_req_t *req) {
    char buf[128];
    if (read_post_body(req, buf, sizeof(buf)) < 0) return ESP_FAIL;

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Invalid JSON\"}");
        return ESP_OK;
    }

    cJSON *j_item = cJSON_GetObjectItem(root, "item_number");
    cJSON *j_price = cJSON_GetObjectItem(root, "item_price");

    vend_request_t vr = {
        .itemNumber = j_item && cJSON_IsNumber(j_item) ? (uint16_t)j_item->valueint : 1,
        .itemPrice = j_price && cJSON_IsNumber(j_price) ? (uint16_t)j_price->valueint : 0,
    };
    cJSON_Delete(root);

    if (xQueueSend(vend_request_queue, &vr, pdMS_TO_TICKS(100)) == pdTRUE) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"ok\":true}");
    } else {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Queue full\"}");
    }
    return ESP_OK;
}

static esp_err_t vend_cancel_post_handler(httpd_req_t *req) {
    // Vend Cancel: set state back so VMC sends VEND CANCEL (13H 01H) on next loop
    // For now, just reset to IDLE — the VMC loop handles the rest
    if (reader0x10.machineState == VEND_STATE) {
        reader0x10.machineState = IDLE_STATE;
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"ok\":true,\"msg\":\"Vend cancelled\"}");
    } else {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Not in VEND state\"}");
    }
    return ESP_OK;
}

static esp_err_t cashsale_post_handler(httpd_req_t *req) {
    char buf[128];
    if (read_post_body(req, buf, sizeof(buf)) < 0) return ESP_FAIL;

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Invalid JSON\"}");
        return ESP_OK;
    }

    cJSON *j_item = cJSON_GetObjectItem(root, "item_number");
    cJSON *j_price = cJSON_GetObjectItem(root, "item_price");

    // Cash sale is sent via the same queue but only processed when state == ENABLED
    vend_request_t vr = {
        .itemNumber = j_item && cJSON_IsNumber(j_item) ? (uint16_t)j_item->valueint : 1,
        .itemPrice = j_price && cJSON_IsNumber(j_price) ? (uint16_t)j_price->valueint : 0,
    };
    cJSON_Delete(root);

    if (reader0x10.machineState != ENABLED_STATE) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Not in ENABLED state for cash sale\"}");
        return ESP_OK;
    }

    if (xQueueSend(vend_request_queue, &vr, pdMS_TO_TICKS(100)) == pdTRUE) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"ok\":true}");
    } else {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Queue full\"}");
    }
    return ESP_OK;
}

static esp_err_t reset_post_handler(httpd_req_t *req) {
    reader0x10.machineState = INACTIVE_STATE;
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

static esp_err_t reader_post_handler(httpd_req_t *req) {
    char buf[64];
    if (read_post_body(req, buf, sizeof(buf)) < 0) return ESP_FAIL;

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"error\":\"Invalid JSON\"}");
        return ESP_OK;
    }

    cJSON *j_en = cJSON_GetObjectItem(root, "enabled");
    if (j_en && cJSON_IsBool(j_en)) {
        reader_enabled = cJSON_IsTrue(j_en);
    }
    cJSON_Delete(root);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, reader_enabled ? "{\"ok\":true,\"enabled\":true}" : "{\"ok\":true,\"enabled\":false}");
    return ESP_OK;
}

static esp_err_t log_get_handler(httpd_req_t *req) {
    cJSON *arr = cJSON_CreateArray();

    int count = mdb_log_count < MDB_LOG_SIZE ? mdb_log_count : MDB_LOG_SIZE;
    int start = (mdb_log_head - count + MDB_LOG_SIZE) % MDB_LOG_SIZE;

    for (int i = 0; i < count; i++) {
        int idx = (start + i) % MDB_LOG_SIZE;
        mdb_log_entry_t *e = &mdb_log[idx];

        cJSON *obj = cJSON_CreateObject();
        cJSON_AddNumberToObject(obj, "ts", e->timestamp_ms);
        char dir[2] = { e->direction, '\0' };
        cJSON_AddStringToObject(obj, "dir", dir);
        cJSON_AddStringToObject(obj, "msg", e->description);
        cJSON_AddItemToArray(arr, obj);
    }

    char *json_str = cJSON_PrintUnformatted(arr);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, json_str, HTTPD_RESP_USE_STRLEN);
    cJSON_free(json_str);
    cJSON_Delete(arr);
    return ESP_OK;
}

static esp_err_t wifi_scan_get_handler(httpd_req_t *req) {
    wifi_scan_config_t scan_cfg = {
        .ssid = NULL, .bssid = NULL, .channel = 0, .show_hidden = false,
        .scan_type = WIFI_SCAN_TYPE_ACTIVE,
        .scan_time = { .active = { .min = 100, .max = 300 } },
    };

    esp_err_t err = esp_wifi_scan_start(&scan_cfg, true);
    if (err != ESP_OK) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"networks\":[]}");
        return ESP_OK;
    }

    uint16_t ap_count = 0;
    esp_wifi_scan_get_ap_num(&ap_count);
    if (ap_count > 20) ap_count = 20;

    wifi_ap_record_t *ap_records = calloc(ap_count, sizeof(wifi_ap_record_t));
    if (!ap_records) {
        httpd_resp_set_type(req, "application/json");
        httpd_resp_sendstr(req, "{\"networks\":[]}");
        return ESP_OK;
    }
    esp_wifi_scan_get_ap_records(&ap_count, ap_records);

    cJSON *root = cJSON_CreateObject();
    cJSON *networks = cJSON_AddArrayToObject(root, "networks");

    for (int i = 0; i < ap_count; i++) {
        const char *ssid = (const char *)ap_records[i].ssid;
        if (strlen(ssid) == 0) continue;
        if (strcmp(ssid, VMC_AP_SSID) == 0) continue;

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

static esp_err_t wifi_set_post_handler(httpd_req_t *req) {
    char buf[256];
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

    wifi_config_t wifi_config = {0};
    strncpy((char *)wifi_config.sta.ssid, j_ssid->valuestring, sizeof(wifi_config.sta.ssid) - 1);
    if (j_pass && cJSON_IsString(j_pass))
        strncpy((char *)wifi_config.sta.password, j_pass->valuestring, sizeof(wifi_config.sta.password) - 1);

    esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    cJSON_Delete(root);

    esp_wifi_connect();

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

static esp_err_t captive_handler(httpd_req_t *req) {
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
    if (dns_pcb != NULL) return;
    dns_pcb = udp_new();
    udp_bind(dns_pcb, IP_ADDR_ANY, 53);
    udp_recv(dns_pcb, dns_recv, NULL);
    ESP_LOGI(TAG, "DNS started");
}

/* ---------- HTTP server ---------- */

void stop_webui_server(void) {
    if (server == NULL) return;
    httpd_stop(server);
    server = NULL;
}

void start_webui_server(void) {
    if (server != NULL) return;

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 16;

    if (httpd_start(&server, &config) != ESP_OK) {
        ESP_LOGE(TAG, "Failed to start HTTP server");
        return;
    }

    static const httpd_uri_t uris[] = {
        { .uri = "/",                .method = HTTP_GET,  .handler = index_get_handler       },
        { .uri = "/api/state",       .method = HTTP_GET,  .handler = state_get_handler        },
        { .uri = "/api/vend",        .method = HTTP_POST, .handler = vend_post_handler         },
        { .uri = "/api/vend-cancel", .method = HTTP_POST, .handler = vend_cancel_post_handler  },
        { .uri = "/api/cashsale",    .method = HTTP_POST, .handler = cashsale_post_handler     },
        { .uri = "/api/reset",       .method = HTTP_POST, .handler = reset_post_handler        },
        { .uri = "/api/reader",      .method = HTTP_POST, .handler = reader_post_handler       },
        { .uri = "/api/log",         .method = HTTP_GET,  .handler = log_get_handler           },
        { .uri = "/api/wifi/scan",   .method = HTTP_GET,  .handler = wifi_scan_get_handler     },
        { .uri = "/api/wifi/set",    .method = HTTP_POST, .handler = wifi_set_post_handler     },
        { .uri = "/generate_204",    .method = HTTP_GET,  .handler = captive_handler           },
        { .uri = "/hotspot-detect.html", .method = HTTP_GET, .handler = captive_handler        },
    };

    for (int i = 0; i < sizeof(uris) / sizeof(uris[0]); i++) {
        httpd_register_uri_handler(server, &uris[i]);
    }

    ESP_LOGI(TAG, "WebUI server started");
}

/* ---------- SoftAP ---------- */

void start_softap(void) {
    wifi_config_t wifi_config = {
        .ap = {
            .ssid = VMC_AP_SSID,
            .ssid_len = strlen(VMC_AP_SSID),
            .password = VMC_AP_PASS,
            .max_connection = 4,
            .authmode = WIFI_AUTH_WPA_WPA2_PSK,
        },
    };
    esp_err_t err = esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    ESP_LOGI(TAG, "SoftAP config set (SSID=\"%s\") -> %s", VMC_AP_SSID, esp_err_to_name(err));
}
