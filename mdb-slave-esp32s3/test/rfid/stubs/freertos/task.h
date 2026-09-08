#pragma once
typedef void (*TaskFunction_t)(void *);
static inline int xTaskCreate(TaskFunction_t f, const char *n, int s, void *p, int prio, void *h) {
    (void)f;(void)n;(void)s;(void)p;(void)prio;(void)h; return 1; /* pdPASS */
}
