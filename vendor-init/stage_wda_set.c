/*
 * stage_wda_set — WDA_SET_DATA_FORMAT (msg 0x0020 on WDA service 0x1A).
 *
 * BYTE-EXACT decode from capture_20260530_213719/qmi_trace.log:
 *
 *   [117.177926] netmgrd → port=72 len=78 msg_id=0x0020
 *     REQ[78] 00 01 00 20 00 47 00       — body=71
 *             11 04 00 02 00 00 00       — TLV 0x11 link_protocol     = 2 (raw_ip)
 *             12 04 00 07 00 00 00       — TLV 0x12 ul_data_agg_proto = 7 (QMAPv3)
 *             13 04 00 07 00 00 00       — TLV 0x13 dl_data_agg_proto = 7 (QMAPv3)
 *             15 04 00 0a 00 00 00       — TLV 0x15 dl_max_datagrams  = 10
 *             16 04 00 00 20 00 00       — TLV 0x16 dl_max_size       = 8192 (req)
 *             17 08 00 04 00 00 00 01 00 00 00 — TLV 0x17 ep_info {type=4, if=1}
 *             19 04 00 00 00 00 00       — TLV 0x19                    = 0
 *             1a 01 00 01                — TLV 0x1a (1B)               = 1
 *             1b 04 00 00 00 00 00       — TLV 0x1b                    = 0
 *             1c 04 00 00 00 00 00       — TLV 0x1c                    = 0
 *
 *   RESP[85] modem echoes:
 *     0x12=7, 0x13=7 (QMAPv3 ACCEPTED both directions)
 *     0x15=10, 0x16=0x3f=63 (dl_max_size CAPPED to 63 — HW field width!)
 *     0x18=0xFFFFFFFF (ul_max_size unlimited)
 *
 * KEY INSIGHT: dl_max_size=63 is a HARDWARE limit (6-bit field). Vendor
 * gets 63 back too. This invalidates the earlier "modem firmware-locks
 * us to 63" reading from [[project-wda-definitive-carrier-cap]]; both
 * sides get 63. The lever is QMAPv3 + the 4 extra TLVs (0x19/0x1a/0x1b/0x1c)
 * that vendor sends but our prior tools did not.
 *
 * If subsequent throughput stays at 67 KB/s after vendor-init runs, the
 * cap is NOT WDA-related. If it jumps, the missing TLVs were the lever.
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <unistd.h>      /* close() */

#define STAGE "wda_set"

#define MSG_WDA_SET_DATA_FORMAT 0x0020

static const uint8_t EP_INFO[8] = {
	0x04, 0x00, 0x00, 0x00,    /* ep_type = 4 (HSUSB/IPA) */
	0x01, 0x00, 0x00, 0x00,    /* iface_id = 1 */
};

int stage_wda_set(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would WDA SET dl=%d ul=%d size=%d dgrams=%d",
		     WDA_DL_PROTO,
		     ctx->full_ul ? WDA_UL_PROTO_V3 : WDA_UL_PROTO_V1,
		     WDA_DL_SIZE, WDA_DL_DGRAMS);
		return 0;
	}

	/* Own socket — WDA SET is one-shot system-wide config. */
	int fd = qrtr_open();
	if (fd < 0) {
		LOGE(STAGE, "qrtr_open failed");
		return 1;
	}

	ctx->wda_port = qrtr_lookup(fd, QRTR_SVC_WDA);
	if (!ctx->wda_port) {
		LOGE(STAGE, "WDA service (0x%04x) not found", QRTR_SVC_WDA);
		close(fd);
		return 1;
	}
	state_record("wda_port", "%u", ctx->wda_port);

	uint16_t txid = 1;
	uint8_t req[128], resp[256];
	int off = qmi_hdr_req(req, txid, MSG_WDA_SET_DATA_FORMAT, 0);
	int after_hdr = off;
	off = qmi_tlv_u32  (req, off, 0x11, 2);                  /* link = raw_ip */
	off = qmi_tlv_u32  (req, off, 0x12,
		ctx->full_ul ? WDA_UL_PROTO_V3 : WDA_UL_PROTO_V1);
	off = qmi_tlv_u32  (req, off, 0x13, WDA_DL_PROTO);
	off = qmi_tlv_u32  (req, off, 0x15, WDA_DL_DGRAMS);
	off = qmi_tlv_u32  (req, off, 0x16, WDA_DL_SIZE);
	off = qmi_tlv_bytes(req, off, 0x17, EP_INFO, sizeof(EP_INFO));
	/* Critical vendor-extra TLVs — likely what triggers full HW engagement. */
	off = qmi_tlv_u32  (req, off, 0x19, 0);
	off = qmi_tlv_u8   (req, off, 0x1A, 1);                  /* 1-byte! */
	off = qmi_tlv_u32  (req, off, 0x1B, 0);
	off = qmi_tlv_u32  (req, off, 0x1C, 0);
	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "req", req, off);
	int n = qrtr_txn(fd, 0, ctx->wda_port,
			 req, off, MSG_WDA_SET_DATA_FORMAT,
			 resp, sizeof(resp), 2000);
	if (n < 0) {
		LOGE(STAGE, "no response");
		close(fd);
		return 2;
	}
	log_hex(LOG_DEBUG, STAGE, "resp", resp, n);

	int rc = qmi_result(resp, n);
	close(fd);    /* WDA state is system-wide; socket no longer needed */

	if (rc != 0) {
		LOGE(STAGE, "WDA SET err=%d", rc);
		return 3;
	}

	/* Decode echoed actual capability (TLVs 0x12, 0x13, 0x15, 0x16). */
	uint32_t echoed_ul = 0, echoed_dl = 0, echoed_max = 0, echoed_dg = 0;
	qmi_tlv_get_u32(resp, n, 0x12, &echoed_ul);
	qmi_tlv_get_u32(resp, n, 0x13, &echoed_dl);
	qmi_tlv_get_u32(resp, n, 0x15, &echoed_dg);
	qmi_tlv_get_u32(resp, n, 0x16, &echoed_max);

	LOGI(STAGE, "WDA OK; modem echoed: ul_proto=%u dl_proto=%u dl_max_size=%u dl_dgrams=%u",
	     echoed_ul, echoed_dl, echoed_max, echoed_dg);
	state_record("wda_dl_proto",     "%u", echoed_dl);
	state_record("wda_ul_proto",     "%u", echoed_ul);
	state_record("wda_dl_max_size",  "%u", echoed_max);
	state_record("wda_dl_dgrams",    "%u", echoed_dg);

	if (echoed_dl != WDA_DL_PROTO) {
		LOGW(STAGE, "modem DOWNGRADED dl_proto: requested %u, got %u — earlier stage(s) likely incomplete",
		     WDA_DL_PROTO, echoed_dl);
	}
	/* Vendor capture shows dl_max_size CAPPED to 63 (HW field width).
	 * If we get something else, log it; 63 itself is expected and normal. */
	if (echoed_max != 63) {
		LOGW(STAGE, "unexpected dl_max_size echo: %u (vendor gets 63 = HW cap)",
		     echoed_max);
	}
	return 0;
}
