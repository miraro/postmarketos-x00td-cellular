#ifndef VENDOR_INIT_STATE_H
#define VENDOR_INIT_STATE_H

#include <stdint.h>

/* Run-state directory. Created on log_init. */
#define STATE_DIR "/run/vendor-init"

/* Mark current stage. Writes /run/vendor-init/stage = name. */
void state_set_stage(const char *stage);

/* Mark final result. Writes /run/vendor-init/state. */
void state_set_result(const char *result);   /* READY / FAILED_<stage> */

/* Record an arbitrary key=value pair, one file per key, for inspection.
 *   key=bearer_ip  value="10.205.220.182"
 *   key=mux_count  value="17"
 *   key=wda_dl_proto value="5"
 * Files at /run/vendor-init/<key>. */
void state_record(const char *key, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));

#endif
