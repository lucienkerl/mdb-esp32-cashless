#ifndef WEBUI_SERVER_H
#define WEBUI_SERVER_H

#include <stddef.h>
#include "esp_err.h"

/* SoftAP credential helpers.
 *
 * SSID is computed deterministically from the WIFI_IF_STA MAC at every boot
 * (no NVS storage). Format: "VMflow-XXXXXX" where XXXXXX = last 3 bytes of
 * the MAC in uppercase hex.
 *
 * Password comes from NVS namespace "vmflow", key "softap_pwd", written by
 * provision_claim_task after a successful claim. If the key is missing,
 * empty, or shorter than 8 chars (WPA2 PSK minimum), the helper writes an
 * empty string into out and start_softap brings the AP up as WIFI_AUTH_OPEN.
 * The firmware never generates a random password itself — that is the
 * backend's job at claim time.
 *
 * Spec: docs/superpowers/specs/2026-04-30-softap-per-device-credentials-design.md
 */

#define SOFTAP_SSID_MAX        32   /* "VMflow-XXXXXX" + NUL fits comfortably */
#define SOFTAP_PWD_MAX         16

/** Fill `out` with "VMflow-XXXXXX" where XXXXXX is the last 3 bytes of the
 *  STA MAC in uppercase hex. */
esp_err_t softap_get_ssid(char *out, size_t out_len);

/** Read NVS "softap_pwd". On success out contains either a WPA2-valid
 *  password (≥8 chars NUL-terminated) or the empty string (signal: open AP).
 *  Always returns ESP_OK; underlying NVS errors are absorbed into the
 *  empty-string fallback so the AP always comes up in some form. */
esp_err_t softap_get_password(char *out, size_t out_len);

void start_softap(void);
void start_rest_server(void);
void stop_rest_server(void);

void start_dns_server(void);
void stop_dns_server(void);

#endif
