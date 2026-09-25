#pragma once
#include <stdint.h>
#include <stddef.h>
typedef int esp_err_t;
#define ESP_OK 0
#define UART_PIN_NO_CHANGE (-1)
#define UART_SIGNAL_RXD_INV 1
typedef enum { UART_DATA_8_BITS } uart_word_length_t;
typedef enum { UART_PARITY_DISABLE } uart_parity_t;
typedef enum { UART_STOP_BITS_1 } uart_stop_bits_t;
typedef enum { UART_HW_FLOWCTRL_DISABLE } uart_hw_flowcontrol_t;
typedef enum { UART_SCLK_DEFAULT } uart_sclk_t;
typedef struct {
    int baud_rate;
    uart_word_length_t data_bits;
    uart_parity_t parity;
    uart_stop_bits_t stop_bits;
    uart_hw_flowcontrol_t flow_ctrl;
    uart_sclk_t source_clk;
} uart_config_t;
static inline const char *esp_err_to_name(esp_err_t e) { (void)e; return "ok"; }
static inline esp_err_t uart_param_config(int p, const uart_config_t *c) { (void)p; (void)c; return ESP_OK; }
static inline esp_err_t uart_set_pin(int p, int tx, int rx, int rts, int cts) { (void)p;(void)tx;(void)rx;(void)rts;(void)cts; return ESP_OK; }
static inline esp_err_t uart_driver_install(int p, int rxb, int txb, int q, void *qh, int f) { (void)p;(void)rxb;(void)txb;(void)q;(void)qh;(void)f; return ESP_OK; }
static inline esp_err_t uart_driver_delete(int p) { (void)p; return ESP_OK; }
static inline esp_err_t uart_set_line_inverse(int p, int m) { (void)p; (void)m; return ESP_OK; }
static inline int uart_read_bytes(int p, uint8_t *buf, uint32_t len, int ticks) { (void)p;(void)buf;(void)len;(void)ticks; return 0; }
