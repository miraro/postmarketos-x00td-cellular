/*
 * stage_iattach — WDS_SET_INITIAL_ATTACH_APN (msg 0x00A3 on WDS service).
 *
 * Ported from trace/wds-iattach.c. Vendor netmgrd sets the initial attach
 * APN before any bearer activation; ModemManager does NOT do this. Without
 * it, modem may default to a less capable IMS or test APN.
 *
 * Payload:
 *   TLV 0x10: apn_name (string)
 *   TLV 0x14: ip_support_type (u8) — 3 = IPv4v6 (vendor default)
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <string.h>

#define STAGE "iattach"

#define MSG_SET_INITIAL_ATTACH_APN 0x00A3

int stage_iattach(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would send WDS_SET_INITIAL_ATTACH_APN apn='%s' ip=IPv4v6",
		     ctx->apn);
		return 0;
	}

	if (!ctx->wds_port) {
		ctx->wds_port = qrtr_lookup(ctx->fd, QRTR_SVC_WDS);
		if (!ctx->wds_port) {
			LOGE(STAGE, "WDS service not found");
			return 1;
		}
		state_record("wds_port", "%u", ctx->wds_port);
	}

	uint8_t req[256], resp[512];
	int apn_len = strlen(ctx->apn);
	int body_len = (3 + apn_len) + (3 + 1);

	int off = qmi_hdr_req(req, ctx->txid++, MSG_SET_INITIAL_ATTACH_APN, body_len);
	off = qmi_tlv_bytes(req, off, 0x10, ctx->apn, apn_len);
	off = qmi_tlv_u8   (req, off, 0x14, 3);    /* IPv4v6 */

	log_hex(LOG_DEBUG, STAGE, "req", req, off);
	int n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
			 req, off, MSG_SET_INITIAL_ATTACH_APN,
			 resp, sizeof(resp), 2000);
	if (n < 0) {
		LOGE(STAGE, "no response");
		return 2;
	}
	log_hex(LOG_DEBUG, STAGE, "resp", resp, n);

	int rc = qmi_result(resp, n);
	state_record("iattach_result", "%d", rc);
	if (rc != 0) {
		/* Some modems return 70 (InvalidOperation) when APN already set
		 * — that's actually fine, the attach APN is the same. Log and
		 * continue. */
		LOGW(STAGE, "modem returned err=%d (often benign when APN already set)", rc);
		return 0;
	}
	LOGI(STAGE, "SET_INITIAL_ATTACH_APN apn='%s' OK", ctx->apn);
	return 0;
}
