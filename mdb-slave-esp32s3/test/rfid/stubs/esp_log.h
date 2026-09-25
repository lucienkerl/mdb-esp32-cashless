#pragma once
#include <stdio.h>
#include <stdlib.h>   /* getenv */
#define ESP_LOGI(tag, fmt, ...) do { if (getenv("RFID_VERBOSE")) printf("I %s: " fmt "\n", tag, ##__VA_ARGS__); } while (0)
#define ESP_LOGW(tag, fmt, ...) do { if (getenv("RFID_VERBOSE")) printf("W %s: " fmt "\n", tag, ##__VA_ARGS__); } while (0)
#define ESP_LOGE(tag, fmt, ...) do { if (getenv("RFID_VERBOSE")) printf("E %s: " fmt "\n", tag, ##__VA_ARGS__); } while (0)
