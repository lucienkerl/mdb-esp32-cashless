idf_component_register(SRCS "mdb-master-esp32s3.c" "webui_server.c"
                    INCLUDE_DIRS "."
                    EMBED_FILES "../webui/index.html"
                    REQUIRES esp_wifi esp_http_server driver nvs_flash lwip json esp_netif esp_timer)
