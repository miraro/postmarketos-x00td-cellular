/*
 * stage_fff2 — proprietary WDS message 0xFFF2 (vendor bearer pre-setup).
 *
 * BYTE-EXACT decode from capture_20260530_213719/qmi_trace.log, sent by
 * netmgrd 272× to WDS port (vendor port 70). Source: Lineage 22 / Android 14.
 *
 * Reference REQ (default "internet" APN, IPv4):
 *   [124.606721] netmgrd → port=70 len=34 msg_id=0xfff2
 *     REQ[34] 00 03 00 f2 ff 1b 00          — QMI hdr body=27
 *             01 01 00 01                   — TLV 0x01 len=1 val=0x01 (req_id)
 *             31 01 00 05                   — TLV 0x31 len=1 val=0x05 (ext_tech for "internet")
 *             14 08 00 "internet"           — TLV 0x14 len=8 APN
 *             19 01 00 04                   — TLV 0x19 len=1 val=0x04 (IPv4)
 *             35 01 00 01                   — TLV 0x35 len=1 val=0x01 (action=create?)
 *
 *   [124.606x] netmgrd ← RESP[35] result=SUCCESS + 10-byte TLV 0x01 payload
 *                        + 5-byte TLV 0x11 payload (context handle?).
 *
 * IPv6 variant (sent right after IPv4, same APN):
 *     REQ[34] differs only at TLV 0x19 value: 06 instead of 04.
 *
 * IMS APN variant (sent at +0.5s):
 *     REQ[33] additionally has TLV 0x32 len=1 val=0xff (between 0x31 and 0x14):
 *             01 01 00 01  31 01 00 02  32 01 00 ff  14 03 00 "ims"  19 ...
 *     Note: ext_tech changes 0x05 → 0x02 for IMS.
 *
 * Per-bearer summary:
 *   "internet" APN: TLV 0x31 = 0x05, NO TLV 0x32, IPv4+IPv6 (2 messages)
 *   "ims"      APN: TLV 0x31 = 0x02, TLV 0x32 = 0xff, IPv4+IPv6 (2 messages)
 *
 * Hypothesis: this primes modem bearer-state machine so subsequent
 * WDA SET + WDS_START_NETWORK are honored at full capability. Without
 * it modem treats us as third-party and stays at degraded defaults.
 *
 * Task #188.
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <string.h>

#define STAGE "fff2"

#define MSG_FFF2 0xFFF2

/* Vendor-observed values for "internet" APN (default bearer). */
#define EXT_TECH_INTERNET  0x05
#define ACTION_CREATE      0x01    /* TLV 0x35 — same across all bearers */

/* Send one 0xFFF2 message for (apn, ip_type). Returns 0 on success. */
static int send_one(struct vi_ctx *ctx, const char *apn, uint8_t ip_type,
		    uint8_t ext_tech)
{
	uint8_t req[256], resp[512];
	int apn_len = (int)strlen(apn);

	int off = qmi_hdr_req(req, ctx->txid++, MSG_FFF2, 0);
	int after_hdr = off;
	off = qmi_tlv_u8   (req, off, 0x01, 0x01);         /* req_id = 0x01 const */
	off = qmi_tlv_u8   (req, off, 0x31, ext_tech);     /* ext_tech */
	off = qmi_tlv_bytes(req, off, 0x14, apn, apn_len); /* APN */
	off = qmi_tlv_u8   (req, off, 0x19, ip_type);      /* IP type */
	off = qmi_tlv_u8   (req, off, 0x35, ACTION_CREATE);

	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "req", req, off);
	int n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
			 req, off, MSG_FFF2,
			 resp, sizeof(resp), 2000);
	if (n < 0) {
		LOGW(STAGE, "no response for apn='%s' ip=0x%02x", apn, ip_type);
		return 0;     /* not fatal — vendor sends without strict waiting */
	}
	log_hex(LOG_DEBUG, STAGE, "resp", resp, n);

	int rc = qmi_result(resp, n);
	if (rc == 0) {
		LOGI(STAGE, "0xFFF2 apn='%s' ip=0x%02x ext_tech=0x%02x → OK",
		     apn, ip_type, ext_tech);
	} else {
		/* In capture, second consecutive IPv6 send returned err=0x2b=43
		 * = "Out_Of_Call" — modem reports bearer not ready yet but
		 * upstream Android continues. Treat as non-fatal warning. */
		LOGW(STAGE, "0xFFF2 apn='%s' ip=0x%02x err=%d (often benign, modem state lag)",
		     apn, ip_type, rc);
	}
	return 0;
}

int stage_fff2(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would send 0xFFF2 for apn='%s' (IPv4 + IPv6)",
		     ctx->apn);
		return 0;
	}
	if (!ctx->wds_port) {
		LOGE(STAGE, "WDS port not set (bind_mux must run first)");
		return 1;
	}

	/* Send IPv4 followed by IPv6, matching vendor pattern for "internet" APN.
	 * For IMS or other APN classes the caller can extend; for our throughput
	 * test the default bearer is what matters. */
	send_one(ctx, ctx->apn, 0x04, EXT_TECH_INTERNET);
	send_one(ctx, ctx->apn, 0x06, EXT_TECH_INTERNET);

	state_record("fff2_sent", "%s/v4+v6", ctx->apn);
	LOGI(STAGE, "0xFFF2 pre-setup sequence sent for apn='%s'", ctx->apn);
	return 0;
}
