/*
 * stage_wds_start — WDS_START_NETWORK with 6 TLVs (BYTE-EXACT vendor parity).
 *
 * Decoded from capture_20260530_213719/qmi_trace.log; sent by qcrild (NOT
 * netmgrd — netmgrd does port/format setup, qcrild does bearer activation):
 *
 *   [124.659588] qcrild → WDS port len=38 msg_id=0x0020
 *     REQ[38] 00 04 00 20 00 1f 00       — QMI hdr body=31
 *             14 08 00 "internet"        — TLV 0x14 APN
 *             16 01 00 00                — TLV 0x16 len=1 val=0x00 (auth_protocol = NONE)
 *             19 01 00 04                — TLV 0x19 len=1 val=0x04 (IP family IPv4)
 *             31 01 00 05                — TLV 0x31 len=1 val=0x05 (ext_tech_pref — same as 0xfff2)
 *             35 01 00 01                — TLV 0x35 len=1 val=0x01 (call_type / action)
 *             39 01 00 01                — TLV 0x39 len=1 val=0x01 (profile_idx?)
 *
 * 6 TLVs (not 7 as VENDOR_STRACE_ANALYSIS.md guessed). No username/password
 * for auth=NONE — vendor omits 0x15/0x16/0x17 entirely.
 *
 * The same exact REQ[38] repeats every retry (txid bumps but body identical).
 *
 * After START_NETWORK we issue GET_CURRENT_SETTINGS to record the
 * actual bearer IP/GW/DNS/MTU into the ctx and state files.
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <string.h>

#define STAGE "wds_start"

#define MSG_AF_SET_MODE      0x00AF  /* proprietary "set client mode" — vendor uses */
#define MSG_4D_SET_IP_FAMILY 0x004D  /* WDS_SET_CLIENT_IP_FAMILY_PREF */
#define MSG_START_NETWORK    0x0020
#define MSG_GET_SETTINGS     0x002D

/* Vendor "internet" APN values (must match stage_fff2 for consistency). */
#define AUTH_NONE             0x00
#define IP_FAMILY_IPV4        0x04
#define EXT_TECH_INTERNET     0x05     /* same as in stage_fff2 */
#define CALL_TYPE_DATA        0x01     /* TLV 0x35: 0x01 in capture */
#define PROFILE_IDX_DEFAULT   0x01     /* TLV 0x39: 0x01 in capture */

static void log_ip(const char *label, uint32_t v)
{
	LOGI(STAGE, "  %-14s %u.%u.%u.%u", label,
	     (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
}

static int issue_get_settings(struct vi_ctx *ctx)
{
	uint8_t req[64], resp[1024];
	int off = qmi_hdr_req(req, ctx->txid++, MSG_GET_SETTINGS, 0);
	int after_hdr = off;
	uint32_t mask = 0xffffffffU;             /* request everything */
	off = qmi_tlv_u32(req, off, 0x10, mask);
	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "GET_SETTINGS req", req, off);
	int n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
			 req, off, MSG_GET_SETTINGS,
			 resp, sizeof(resp), 2000);
	if (n < 0) {
		LOGW(STAGE, "GET_SETTINGS no response — bearer up but config unknown");
		return -1;
	}
	log_hex(LOG_DEBUG, STAGE, "GET_SETTINGS resp", resp, n);

	uint32_t v;
	if (qmi_tlv_get_u32(resp, n, 0x1E, &v)) { ctx->bearer_ipv4 = v; log_ip("IPv4 addr",  v); state_record("bearer_ipv4", "%u.%u.%u.%u", (v>>24)&0xff,(v>>16)&0xff,(v>>8)&0xff,v&0xff); }
	if (qmi_tlv_get_u32(resp, n, 0x20, &v)) { ctx->bearer_gw   = v; log_ip("gateway",    v); state_record("bearer_gw",   "%u.%u.%u.%u", (v>>24)&0xff,(v>>16)&0xff,(v>>8)&0xff,v&0xff); }
	if (qmi_tlv_get_u32(resp, n, 0x21, &v)) {
		ctx->bearer_mask = v;
		log_ip("subnet mask", v);
		/* Compute prefix length from subnet mask. Operator may give
		 * any of /29, /30, /31 (cellular point-to-point). */
		uint32_t mask = v;
		int prefix = 0;
		while (mask & 0x80000000U) { prefix++; mask <<= 1; }
		state_record("bearer_prefix", "%d", prefix);
		LOGI(STAGE, "  prefix         /%d", prefix);
	}
	if (qmi_tlv_get_u32(resp, n, 0x15, &v)) { ctx->bearer_dns1 = v; log_ip("DNS primary",v); }
	if (qmi_tlv_get_u32(resp, n, 0x16, &v)) { ctx->bearer_dns2 = v; log_ip("DNS second", v); }
	if (qmi_tlv_get_u32(resp, n, 0x29, &v)) { ctx->bearer_mtu  = v; LOGI(STAGE, "  %-14s %u", "MTU", v); state_record("bearer_mtu", "%u", v); }
	return 0;
}

int stage_wds_start(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would 0x00af + 0x004d + WDS_START_NETWORK apn='%s'",
		     ctx->apn);
		return 0;
	}

	if (!ctx->wds_port) {
		LOGE(STAGE, "WDS port not set");
		return 1;
	}

	uint8_t req[256], resp[512];
	int n, rc;

	if (ctx->simple_wds) {
		LOGI(STAGE, "--simple-wds: skipping 0x00AF + 0x004D precedents, sending 2-TLV START");
		goto start_network;
	}

	/* --- Vendor precedent step 1: msg 0x00AF (proprietary client mode set).
	 * Capture (qcrild:13301 fd=93 t=124.640): TLV 0x01 len=4 val=0x00000002.
	 * Response is plain SUCCESS. Without this, WDS_START returns err=74. */
	{
		int off = qmi_hdr_req(req, ctx->txid++, MSG_AF_SET_MODE, 0);
		int after_hdr = off;
		off = qmi_tlv_u32(req, off, 0x01, 0x00000002);
		uint16_t body = off - after_hdr;
		req[5] = body & 0xff;
		req[6] = (body >> 8) & 0xff;

		log_hex(LOG_DEBUG, STAGE, "0x00af req", req, off);
		n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
			     req, off, MSG_AF_SET_MODE,
			     resp, sizeof(resp), 2000);
		if (n < 0) {
			LOGE(STAGE, "0x00af no response");
			return 2;
		}
		log_hex(LOG_DEBUG, STAGE, "0x00af resp", resp, n);
		rc = qmi_result(resp, n);
		if (rc != 0) {
			LOGW(STAGE, "0x00af err=%d (vendor gets SUCCESS, continuing)", rc);
		} else {
			LOGI(STAGE, "0x00af (client mode set) OK");
		}
	}

	/* --- Vendor precedent step 2: msg 0x004D (WDS_SET_CLIENT_IP_FAMILY_PREF).
	 * Capture: TLV 0x01 len=1 val=0x04 (IPv4 preference). */
	{
		int off = qmi_hdr_req(req, ctx->txid++, MSG_4D_SET_IP_FAMILY, 0);
		int after_hdr = off;
		off = qmi_tlv_u8(req, off, 0x01, IP_FAMILY_IPV4);
		uint16_t body = off - after_hdr;
		req[5] = body & 0xff;
		req[6] = (body >> 8) & 0xff;

		log_hex(LOG_DEBUG, STAGE, "0x004d req", req, off);
		n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
			     req, off, MSG_4D_SET_IP_FAMILY,
			     resp, sizeof(resp), 2000);
		if (n < 0) {
			LOGE(STAGE, "0x004d no response");
			return 2;
		}
		log_hex(LOG_DEBUG, STAGE, "0x004d resp", resp, n);
		rc = qmi_result(resp, n);
		if (rc != 0) {
			LOGW(STAGE, "0x004d err=%d (continuing)", rc);
		} else {
			LOGI(STAGE, "0x004d (IP family pref IPv4) OK");
		}
	}

start_network:;
	int apn_len = strlen(ctx->apn);
	int off = qmi_hdr_req(req, ctx->txid++, MSG_START_NETWORK, 0);
	int after_hdr = off;

	if (ctx->simple_wds) {
		/* Minimal 2-TLV form — matches trace/wds-bearer.c which is proven
		 * to work on this modem (2G EDGE + LTE, per
		 * [[project-milestone-cellular-dl-works]] and bypass-MM tests).
		 * No tech_pref, no call_type, no profile_idx — let modem use
		 * defaults for current RAT. */
		off = qmi_tlv_bytes(req, off, 0x14, ctx->apn, apn_len);
		off = qmi_tlv_u8   (req, off, 0x19, IP_FAMILY_IPV4);
	} else {
		/* Full 6-TLV vendor-byte-exact form (LTE-flavored). */
		off = qmi_tlv_bytes(req, off, 0x14, ctx->apn, apn_len);
		off = qmi_tlv_u8   (req, off, 0x16, AUTH_NONE);
		off = qmi_tlv_u8   (req, off, 0x19, IP_FAMILY_IPV4);
		off = qmi_tlv_u8   (req, off, 0x31, EXT_TECH_INTERNET);
		off = qmi_tlv_u8   (req, off, 0x35, CALL_TYPE_DATA);
		off = qmi_tlv_u8   (req, off, 0x39, PROFILE_IDX_DEFAULT);
	}

	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "START_NETWORK req", req, off);
	n = qrtr_txn(ctx->fd, 0, ctx->wds_port,
		     req, off, MSG_START_NETWORK,
		     resp, sizeof(resp), 10000);   /* bearer setup can take seconds */
	if (n < 0) {
		LOGE(STAGE, "WDS_START_NETWORK no response");
		return 2;
	}
	log_hex(LOG_DEBUG, STAGE, "START_NETWORK resp", resp, n);

	rc = qmi_result(resp, n);
	if (rc != 0) {
		LOGE(STAGE, "WDS_START_NETWORK err=%d", rc);
		state_record("bearer_state", "FAIL_%d", rc);
		return 3;
	}

	uint32_t pdh = 0;
	if (qmi_tlv_get_u32(resp, n, 0x01, &pdh)) {
		ctx->bearer_pkt_data_handle = pdh;
		state_record("bearer_pdh", "0x%08x", pdh);
		LOGI(STAGE, "bearer UP — packet_data_handle = 0x%08x", pdh);
	}
	state_record("bearer_state", "UP");

	/* Fetch the assigned IP/GW/DNS/MTU. */
	issue_get_settings(ctx);
	return 0;
}
