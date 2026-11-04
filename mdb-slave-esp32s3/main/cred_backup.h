/*
 * cred_backup.h — second copy of the device's credentials outside NVS.
 *
 * Why: everything the device needs to come back online after a reboot
 * (WiFi STA credentials, company_id/device_id/passkey, server + MQTT
 * settings, SoftAP password, APN, ...) lives in the one small NVS
 * partition. When nvs_flash_init() reports NO_FREE_PAGES or
 * NEW_VERSION_FOUND the only way forward is nvs_flash_erase(), and the
 * device then boots like a factory-new one: open "VMflow-XXXX" SoftAP,
 * unclaimed, no WiFi. Two boards in the field have done exactly that.
 *
 * The backup lives in the `phy_init` partition, which both partition
 * tables (stock partitions_two_ota_large.csv on the original board, the
 * custom partitions.csv on WROOM-1U) carry but nothing uses:
 * CONFIG_ESP_PHY_INIT_DATA_IN_PARTITION is off, so PHY init data is
 * compiled in and the partition is never read. Using it needs no
 * partition table change, so it works on boards updated over the air.
 *
 * The image is CRC-protected (cred_backup_format.h) and rewritten only
 * when its content changes, so flash wear is a handful of sector erases
 * over the device's life.
 *
 * Deliberate factory resets (BOOT button, captive-portal reset) must call
 * cred_backup_erase() — otherwise the next boot would restore what the
 * user meant to wipe.
 */
#pragma once

#include <stdbool.h>

/* Locates the partition and validates the stored image. Call once after
 * nvs_flash_init() (successful or not), before any other function here. */
void cred_backup_init(void);

/* True when a valid backup of a claimed device is stored. */
bool cred_backup_available(void);

/* Writes every key of the backup that is missing in NVS namespace
 * "vmflow" back into NVS. Existing keys are never overwritten. Returns
 * the number of keys restored. */
int cred_backup_restore_nvs(void);

/* If the WiFi STA config has no SSID and the backup has one, puts the
 * backed-up SSID + password back via esp_wifi_set_config. Call after
 * esp_wifi_init(). Returns true when it restored something. */
bool cred_backup_restore_wifi_if_empty(void);

/* Snapshots the current credentials (NVS "vmflow" + WiFi STA config) and
 * rewrites the backup when they differ from what is stored. Only does
 * anything on a claimed device. Runs in its own short-lived task, so it is
 * safe to call from an event callback. */
void cred_backup_sync_async(void);

/* Erases the backup. For deliberate factory resets only. */
void cred_backup_erase(void);
