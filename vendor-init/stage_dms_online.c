/*
 * stage_dms_online — ensure modem is in ONLINE operating mode.
 *
 * User hypothesis 2026-05-31: WDS_START_NETWORK err=74 across 5 deploy
 * iterations may stem from modem being in low-power / offline mode rather
 * than ONLINE. ModemManager keeps modem ONLINE during normal operation;
 * after `systemctl stop ModemManager` the modem may not get a graceful
 * signoff and could transition to LOW_POWER, depending on how MM ended.
 *
 * Vendor capture (Android Lineage) never sends DMS_SET_OPERATING_MODE
 * because vendor RIL keeps modem ONLINE since boot — our mainline doesn't
 * have that guarantee. This stage:
 *
 *   1. opens DMS QRTR socket (svc 0x02, port 82 on this modem)
 *   2. DMS_GET_OPERATING_MODE (msg 0x002B) — log current state
 *   3. if not ONLINE: DMS_SET_OPERATING_MODE (msg 0x002C) to ONLINE
 *   4. close socket
 *
 * Mode values per QMI DMS spec:
 *   0 = ONLINE
 *   1 = LOW_POWER  (airplane mode)
 *   2 = FACTORY_TEST
 *   3 = OFFLINE
 *   4 = RESET
 *   5 = SHUTTING_DOWN
 *   6 = PERSISTENT_LOW_POWER
 *
 * Set msg format:  msg=0x002C body: TLV 0x01 len=1 val=<mode>
 * Get msg format:  msg=0x002B body=0
 * Get response:    TLV 0x02 result; TLV 0x01 len=1 val=<current mode>
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <unistd.h>

#define STAGE "dms_online"

/* QMI DMS message IDs (per libqmi spec + capture 020003 verification):
 *   0x002B = DMS_GET_DEVICE_REV_ID   (NOT what we want — was wrong here)
 *   0x002C = DMS_SET_DEVICE_REV_ID
 *   0x002D = DMS_GET_OPERATING_MODE  ← correct GET
 *   0x002E = DMS_SET_OPERATING_MODE  ← correct SET
 * Earlier 0x002B / 0x002C constants were OFF BY TWO — caused err=94
 * (QMI_ERR_NOT_SUPPORTED) on the wrong msg ID. */
#define MSG_DMS_GET_OPERATING_MODE 0x002D
#define MSG_DMS_SET_OPERATING_MODE 0x002E

#define DMS_MODE_ONLINE              0x00
#define DMS_MODE_LOW_POWER           0x01
#define DMS_MODE_FACTORY_TEST        0x02
#define DMS_MODE_OFFLINE             0x03
#define DMS_MODE_RESET               0x04
#define DMS_MODE_SHUTTING_DOWN       0x05
#define DMS_MODE_PERSISTENT_LP       0x06

static const char *mode_name(uint8_t m)
{
	switch (m) {
	case DMS_MODE_ONLINE:        return "ONLINE";
	case DMS_MODE_LOW_POWER:     return "LOW_POWER";
	case DMS_MODE_FACTORY_TEST:  return "FACTORY_TEST";
	case DMS_MODE_OFFLINE:       return "OFFLINE";
	case DMS_MODE_RESET:         return "RESET";
	case DMS_MODE_SHUTTING_DOWN: return "SHUTTING_DOWN";
	case DMS_MODE_PERSISTENT_LP: return "PERSISTENT_LOW_POWER";
	default:                     return "UNKNOWN";
	}
}

int stage_dms_online(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would GET + (if needed) SET DMS operating mode to ONLINE");
		return 0;
	}

	int fd = qrtr_open();
	if (fd < 0) {
		LOGE(STAGE, "qrtr_open failed");
		return 1;
	}

	uint32_t dms_port = qrtr_lookup(fd, QRTR_SVC_DMS);
	if (!dms_port) {
		LOGE(STAGE, "DMS service (0x%04x) not found", QRTR_SVC_DMS);
		close(fd);
		return 1;
	}
	state_record("dms_port", "%u", dms_port);
	LOGI(STAGE, "DMS service at port=%u", dms_port);

	uint16_t txid = 1;
	uint8_t req[64], resp[256];

	/* 1. GET current operating mode. */
	int off = qmi_hdr_req(req, txid++, MSG_DMS_GET_OPERATING_MODE, 0);
	log_hex(LOG_DEBUG, STAGE, "GET req", req, off);
	int n = qrtr_txn(fd, 0, dms_port,
			 req, off, MSG_DMS_GET_OPERATING_MODE,
			 resp, sizeof(resp), 2000);
	if (n < 0) {
		LOGE(STAGE, "GET no response");
		close(fd);
		return 2;
	}
	log_hex(LOG_DEBUG, STAGE, "GET resp", resp, n);

	int rc = qmi_result(resp, n);
	if (rc != 0) {
		/* Non-fatal: if we can't read mode, just skip the SET and hope
		 * modem is already ONLINE. Subsequent stages will fail loudly
		 * if it isn't. */
		LOGW(STAGE, "DMS GET_OPERATING_MODE err=%d — skipping mode SET, assuming ONLINE",
		     rc);
		state_record("dms_mode_before", "GET_ERR_%d", rc);
		close(fd);
		return 0;
	}

	int v_off, v_len;
	uint8_t current = 0xFF;
	if (qmi_tlv_find(resp, n, 0x01, &v_off, &v_len) && v_len >= 1)
		current = resp[v_off];

	state_record("dms_mode_before", "%u (%s)", current, mode_name(current));
	LOGI(STAGE, "current DMS operating mode = %u (%s)", current, mode_name(current));

	if (current == DMS_MODE_ONLINE) {
		LOGI(STAGE, "modem already ONLINE — skipping SET");
		close(fd);
		return 0;
	}

	/* 2. SET to ONLINE. */
	LOGW(STAGE, "modem is %s — sending SET_OPERATING_MODE=ONLINE",
	     mode_name(current));
	off = qmi_hdr_req(req, txid++, MSG_DMS_SET_OPERATING_MODE, 0);
	int after_hdr = off;
	off = qmi_tlv_u8(req, off, 0x01, DMS_MODE_ONLINE);
	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "SET req", req, off);
	n = qrtr_txn(fd, 0, dms_port,
		     req, off, MSG_DMS_SET_OPERATING_MODE,
		     resp, sizeof(resp), 5000);
	if (n < 0) {
		LOGE(STAGE, "SET no response");
		close(fd);
		return 2;
	}
	log_hex(LOG_DEBUG, STAGE, "SET resp", resp, n);

	rc = qmi_result(resp, n);
	close(fd);

	state_record("dms_set_online_result", "%d", rc);
	if (rc != 0) {
		LOGE(STAGE, "DMS SET_OPERATING_MODE=ONLINE err=%d", rc);
		return 3;
	}
	LOGI(STAGE, "DMS SET_OPERATING_MODE=ONLINE OK — modem should be ONLINE now");

	/* Give modem a moment to actually reach ONLINE state before bearer setup. */
	usleep(500 * 1000);   /* 500 ms */
	return 0;
}
