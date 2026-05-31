/*
 * stage_dpm_open — Data Port Mapper OPEN_PORT_REQ (msg 0x0020 on DPM svc 0x2F).
 *
 * Decoded byte-for-byte from capture_20260530_213719/qmi_trace.log:
 *
 *   [116.495961] netmgrd → port=68 len=27 msg_id=0x0020
 *     REQ[27] 00 02 00 20 00 14 00       — QMI hdr: ctl=REQ msg=0x0020 body=20
 *             11 11 00                   — TLV 0x11 len=17
 *               01                       — count = 1 endpoint
 *               04 00 00 00              — ep_type    = 4 (HSUSB/IPA)
 *               01 00 00 00              — if_id      = 1
 *               04 00 00 00              — tx_endpoint = 4 (AP→modem pipe 4)
 *               05 00 00 00              — rx_endpoint = 5 (modem→AP pipe 5)
 *
 *   [116.496314] netmgrd ← port=68 len=14 msg_id=0x0020
 *     RESP[14] 02 02 00 20 00 07 00 02 04 00 00 00 00 00
 *              → result TLV 0x02 len=4 val={0,0} = SUCCESS
 *
 * Service 0x2F (47) = DPM. Earlier value 0x47 was wrong (different number).
 *
 * Without this stage the modem stays in "no port mapping known" state,
 * which is exactly what triggers degraded WDA defaults observed in
 * [[project-wda-definitive-carrier-cap]] STORNO.
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <unistd.h>      /* close() */

#define STAGE "dpm_open"

#define MSG_DPM_OPEN_PORT_REQ 0x0020

/* Endpoint descriptor blob (17 bytes, exact byte order from capture). */
static const uint8_t EP_DESC[17] = {
	0x01,                          /* count = 1 endpoint */
	0x04, 0x00, 0x00, 0x00,        /* ep_type     = 4 (HSUSB/IPA) */
	0x01, 0x00, 0x00, 0x00,        /* if_id       = 1 */
	0x04, 0x00, 0x00, 0x00,        /* tx_endpoint = 4 (AP→modem TX pipe) */
	0x05, 0x00, 0x00, 0x00,        /* rx_endpoint = 5 (modem→AP RX pipe) */
};

int stage_dpm_open(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would lookup DPM svc=0x%04x + DPM_OPEN_PORT_REQ ep=4/5",
		     QRTR_SVC_DPM);
		return 0;
	}

	/* Open OWN socket — DPM is one-shot system-wide config. */
	int fd = qrtr_open();
	if (fd < 0) {
		LOGE(STAGE, "qrtr_open failed");
		return 1;
	}

	ctx->dpm_port = qrtr_lookup(fd, QRTR_SVC_DPM);
	if (!ctx->dpm_port) {
		LOGE(STAGE, "DPM service (0x%04x) not found — fatal: vendor always finds it",
		     QRTR_SVC_DPM);
		state_record("dpm_port", "0 (not found)");
		close(fd);
		return 1;
	}
	state_record("dpm_port", "%u", ctx->dpm_port);
	LOGI(STAGE, "DPM service at port=%u", ctx->dpm_port);

	uint16_t txid = 1;
	uint8_t req[64], resp[256];
	int off = qmi_hdr_req(req, txid, MSG_DPM_OPEN_PORT_REQ, 0);
	int after_hdr = off;
	off = qmi_tlv_bytes(req, off, 0x11, EP_DESC, sizeof(EP_DESC));
	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "req", req, off);
	int n = qrtr_txn(fd, 0, ctx->dpm_port,
			 req, off, MSG_DPM_OPEN_PORT_REQ,
			 resp, sizeof(resp), 2000);
	if (n < 0) {
		LOGE(STAGE, "no response from DPM");
		close(fd);
		return 2;
	}
	log_hex(LOG_DEBUG, STAGE, "resp", resp, n);

	int rc = qmi_result(resp, n);
	state_record("dpm_open_result", "%d", rc);
	close(fd);    /* DPM state is system-wide; socket no longer needed */

	if (rc != 0) {
		LOGE(STAGE, "DPM_OPEN_PORT_REQ err=%d", rc);
		return 3;
	}
	LOGI(STAGE, "DPM_OPEN_PORT_REQ OK (ep_type=4 if=1 tx_pipe=4 rx_pipe=5) — socket closed");
	return 0;
}
