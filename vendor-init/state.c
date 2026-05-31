#include "state.h"
#include "log.h"

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

static int dir_ensured = 0;

static void ensure_dir(void)
{
	if (dir_ensured)
		return;
	if (mkdir(STATE_DIR, 0755) < 0 && errno != EEXIST)
		LOGW("state", "mkdir %s failed: %s", STATE_DIR, strerror(errno));
	dir_ensured = 1;
}

static void write_file(const char *name, const char *value)
{
	ensure_dir();
	char path[256];
	snprintf(path, sizeof(path), "%s/%s", STATE_DIR, name);
	FILE *f = fopen(path, "w");
	if (!f) {
		LOGW("state", "open %s failed: %s", path, strerror(errno));
		return;
	}
	fputs(value, f);
	fputc('\n', f);
	fclose(f);
}

void state_set_stage(const char *stage)
{
	write_file("stage", stage);
}

void state_set_result(const char *result)
{
	write_file("state", result);
}

void state_record(const char *key, const char *fmt, ...)
{
	char buf[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	write_file(key, buf);
}
