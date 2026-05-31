/*
 * stage_dsd — no-op (Data System Determination is NOT needed for throughput).
 *
 * Rationale: DSD is a READ-ONLY notification service. Clients register to
 * receive indications about modem system state changes — RAT switches
 * (LTE↔3G), APN profile updates, IMS domain changes. It does NOT initiate
 * bearer setup, does NOT gate WDA capability, does NOT affect throughput.
 *
 * Capture re-parse 2026-05-30 confirmed: vendor qcrild does look up service
 * 0x42 but the captured per-msg payload is ambiguous (multiple instances,
 * audio_pd path mixed in). Without clear bytes AND without a real reason
 * DSD would affect throughput, keep this stage as a no-op skeleton.
 *
 * Re-enable when:
 *  - Need to recover gracefully from RAT switches (VoLTE / SRVCC)
 *  - Need IMS domain tracking
 *  - Throughput cap definitively traced to missing DSD register (unlikely)
 *
 * Lookup still runs (cheap, useful for debug); state file records port.
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <unistd.h>      /* close() */

#define STAGE "dsd"

int stage_dsd(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would lookup DSD svc=0x%04x + INDICATION_REGISTER",
		     QRTR_SVC_DSD);
		return 0;
	}

	int fd = qrtr_open();
	if (fd < 0)
		return 0;     /* non-fatal — DSD is informational */

	ctx->dsd_port = qrtr_lookup(fd, QRTR_SVC_DSD);
	if (ctx->dsd_port) {
		state_record("dsd_port", "%u", ctx->dsd_port);
		LOGI(STAGE, "DSD service at port=%u (lookup only — no register sent, see file header)",
		     ctx->dsd_port);
	} else {
		state_record("dsd_port", "0 (not found)");
		LOGI(STAGE, "DSD service not present — fine, this stage is a no-op");
	}
	close(fd);
	return 0;
}
