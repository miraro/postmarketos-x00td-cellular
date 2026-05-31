/*
 * stage_bind_mux — WDS_BIND_MUX_DATA_PORT for ctx->num_muxes channels.
 *
 * Ported from trace/wds-bearer.c step 1. Default num_muxes=1 (one PDN);
 * vendor parity test = MUX_COUNT_VENDOR (17 = 8 primary + 9 reverse).
 *
 * Each bind:
 *   TLV 0x10: ep_info — ep_type u32 + iface_id u32 (vendor: ep_type=4, iface=1)
 *   TLV 0x11: mux_id u8 (1..N)
 *
 * NOTE: vendor sends 17 binds to declare ALL mux channels even when only
 * 1-2 PDNs are active. Modem uses this to size its internal data-port
 * tables; without all binds, it may keep DAP state minimal and reject
 * upgrades requested by later WDA SET.
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <unistd.h>      /* close() */

#define STAGE "bind_mux"

#define MSG_BIND_MUX 0x00A2

/* Vendor endpoint info: ep_type=4 (HSUSB/IPA), iface_id=1. */
static const uint8_t EP_INFO[8] = {
	0x04, 0x00, 0x00, 0x00,  /* ep_type = 4 */
	0x01, 0x00, 0x00, 0x00,  /* iface_id = 1 */
};

int stage_bind_mux(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		for (int m = 1; m <= ctx->num_muxes; m++)
			LOGI(STAGE, "(dry run) would BIND_MUX_DATA_PORT mux_id=%d", m);
		return 0;
	}

	/* Open the PERSISTENT bearer socket. This socket is kept alive past
	 * stage return — stored in ctx->fd — because the modem ties bearer
	 * lifetime to the QRTR client that issued BIND_MUX + WDS_START. If
	 * we close, the bearer drops. main() pause() holds it open until SIGINT.
	 *
	 * stage_wds_start uses the SAME ctx->fd to send 0x00AF, 0x004D and
	 * WDS_START_NETWORK on this same client. Vendor's qcrild fd=93
	 * matches exactly this pattern. */
	int fd = qrtr_open();
	if (fd < 0) {
		LOGE(STAGE, "qrtr_open (bearer socket) failed");
		return 1;
	}

	ctx->wds_port = qrtr_lookup(fd, QRTR_SVC_WDS);
	if (!ctx->wds_port) {
		LOGE(STAGE, "WDS service not found");
		close(fd);
		return 1;
	}
	state_record("wds_port", "%u", ctx->wds_port);

	ctx->fd   = fd;            /* hand off persistent socket to wds_start + main */
	ctx->txid = 1;             /* fresh per-client txid sequence */

	int n_ok = 0;
	for (int m = 1; m <= ctx->num_muxes; m++) {
		uint8_t req[64], resp[256];
		int off = qmi_hdr_req(req, ctx->txid++, MSG_BIND_MUX, 0);
		int after_hdr = off;
		off = qmi_tlv_bytes(req, off, 0x10, EP_INFO, sizeof(EP_INFO));
		off = qmi_tlv_u8   (req, off, 0x11, (uint8_t)m);
		uint16_t body = off - after_hdr;
		req[5] = body & 0xff;
		req[6] = (body >> 8) & 0xff;

		log_hex(LOG_DEBUG, STAGE, "req", req, off);
		int n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
				 req, off, MSG_BIND_MUX,
				 resp, sizeof(resp), 2000);
		if (n < 0) {
			LOGE(STAGE, "no response for mux_id=%d", m);
			return 2;
		}
		log_hex(LOG_DEBUG, STAGE, "resp", resp, n);

		int rc = qmi_result(resp, n);
		if (rc != 0) {
			LOGE(STAGE, "BIND_MUX mux_id=%d err=%d", m, rc);
			return 3;
		}
		LOGI(STAGE, "BIND_MUX mux_id=%d OK", m);
		n_ok++;
	}

	state_record("mux_bound", "%d", n_ok);
	LOGI(STAGE, "%d/%d mux channels bound on persistent socket fd=%d wds_port=%u",
	     n_ok, ctx->num_muxes, ctx->fd, ctx->wds_port);
	return 0;
}
