set(srcs "mdb-master-esp32s3.c" "webui_server.c")

idf_component_register(SRCS "${srcs}"
                    INCLUDE_DIRS "."
                    EMBED_FILES "../webui/index.html"
                    REQUIRES esp_wifi esp_http_server nvs_flash lwip json esp_netif driver esp_timer)
