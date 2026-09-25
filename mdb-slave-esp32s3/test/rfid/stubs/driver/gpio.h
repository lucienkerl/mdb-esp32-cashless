#pragma once
typedef enum { GPIO_PULLUP_ONLY } gpio_pull_mode_t;
static inline int gpio_set_pull_mode(int pin, gpio_pull_mode_t m) { (void)pin; (void)m; return 0; }
