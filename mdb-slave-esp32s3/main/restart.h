/*
 * VMflow.xyz
 *
 * restart.h — Tracked-restart entry point
 *
 * Forward declaration for tracked_restart, defined in
 * mdb-slave-esp32s3.c. Saves restart_reason + uptime to NVS (published
 * over MQTT after the next boot), kicks the modem's power if present,
 * then calls esp_restart(). Used by webui_server.c's uplink-preference
 * handler so a mode switch is reboot-tracked the same way OTA/config/
 * claim restarts are.
 */

#ifndef RESTART_H
#define RESTART_H

/* reason must be a string literal (not freed). */
void tracked_restart(const char *reason);

#endif /* RESTART_H */
