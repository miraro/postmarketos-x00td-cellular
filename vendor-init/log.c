#include "log.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

int g_log_level = LOG_INFO;
const char *g_log_file = "/var/log/vendor-init.log";
double g_t0_monotonic = 0.0;

static FILE *g_lf = NULL;

static double monotonic_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *level_tag(int level)
{
	switch (level) {
	case LOG_ERROR: return "ERROR";
	case LOG_WARN:  return "WARN ";
	case LOG_INFO:  return "INFO ";
	case LOG_DEBUG: return "DEBUG";
	default:        return "?????";
	}
}

void log_init(int level, const char *file)
{
	g_log_level = level;
	if (file && *file)
		g_log_file = file;
	g_t0_monotonic = monotonic_now();

	/* Open log file (append). On failure, silently fall back to stderr-only. */
	g_lf = fopen(g_log_file, "a");
	if (g_lf) {
		setvbuf(g_lf, NULL, _IOLBF, 0);
		fprintf(g_lf, "\n----- vendor-init start pid=%d -----\n", (int)getpid());
	}
}

void log_close(void)
{
	if (g_lf) {
		fprintf(g_lf, "----- vendor-init end -----\n");
		fclose(g_lf);
		g_lf = NULL;
	}
}

static void emit(int level, const char *stage, const char *body)
{
	double t = monotonic_now() - g_t0_monotonic;
	const char *tag = level_tag(level);
	const char *st = stage ? stage : "main";

	/* stderr: always for ERROR/WARN, INFO when not redirected silently */
	if (level <= g_log_level)
		fprintf(stderr, "[T+%7.3f] [%s] [%s] %s\n", t, tag, st, body);

	if (g_lf)
		fprintf(g_lf, "[T+%7.3f] [%s] [%s] %s\n", t, tag, st, body);
}

void log_msg(int level, const char *stage, const char *fmt, ...)
{
	if (level > g_log_level && !g_lf)
		return;

	char buf[2048];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	emit(level, stage, buf);
}

void log_hex(int level, const char *stage, const char *label,
	     const uint8_t *buf, int len)
{
	if (level > g_log_level && !g_lf)
		return;

	char line[256];
	int o = snprintf(line, sizeof(line), "%s (%d B)", label, len);
	emit(level, stage, line);

	for (int i = 0; i < len; i += 16) {
		o = snprintf(line, sizeof(line), "  %04x:", i);
		for (int j = 0; j < 16 && i + j < len; j++)
			o += snprintf(line + o, sizeof(line) - o,
				      " %02x", buf[i + j]);
		emit(level, stage, line);
	}
}
