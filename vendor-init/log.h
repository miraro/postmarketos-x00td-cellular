#ifndef VENDOR_INIT_LOG_H
#define VENDOR_INIT_LOG_H

#include <stdint.h>

/* Log levels. ERROR always prints, DEBUG only when --verbose. */
enum {
	LOG_ERROR = 0,
	LOG_WARN  = 1,
	LOG_INFO  = 2,
	LOG_DEBUG = 3,
};

extern int g_log_level;             /* default LOG_INFO */
extern const char *g_log_file;      /* default /var/log/vendor-init.log */
extern double g_t0_monotonic;       /* program start, set by log_init() */

void log_init(int level, const char *file);
void log_close(void);

/* Structured printf with timestamp + stage tag (current stage from state). */
void log_msg(int level, const char *stage, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

/* Hex dump for QMI payloads. NULL stage = no tag. */
void log_hex(int level, const char *stage, const char *label,
	     const uint8_t *buf, int len);

/* Convenience wrappers. */
#define LOGE(stage, ...) log_msg(LOG_ERROR, (stage), __VA_ARGS__)
#define LOGW(stage, ...) log_msg(LOG_WARN,  (stage), __VA_ARGS__)
#define LOGI(stage, ...) log_msg(LOG_INFO,  (stage), __VA_ARGS__)
#define LOGD(stage, ...) log_msg(LOG_DEBUG, (stage), __VA_ARGS__)

#endif
