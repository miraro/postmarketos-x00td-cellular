/*
 * stage_nas_rat — force LTE-preferred + initiate registration + wait for LTE.
 *
 * This is the data gap user identified 2026-05-31: vendor RIL did this
 * at boot BEFORE our Android capture window started (t=114s), so capture
 * doesn't show byte-for-byte sequence. The agent's RIL research (see
 * commit message) pointed to the canonical libqmi spec and MM source as
 * the authoritative reference — bit-for-bit compatible with what vendor
 * qcrild sends, since both target the same modem firmware QMI ABI.
 *
 * Sequence (per ModemManager mm-shared-qmi.c:1334-1377 + libqmi
 * /tmp/qmi-service-nas.json id=0x0033):
 *
 *   1. NAS_SET_SYSTEM_SELECTION_PREFERENCE (msg 0x0033) on NAS service
 *      TLV 0x11 Mode Preference (u16)        = LTE|UMTS|GSM = 0x001C
 *      TLV 0x17 Change Duration (u8)         = PERMANENT (0x00)
 *      TLV 0x1E Acquisition Order (array)    = [LTE=0x08, UMTS=0x05, GSM=0x04]
 *      TLV 0x16 Network Selection (seq)      = AUTOMATIC, MCC=0, MNC=0
 *
 *   2. NAS_INITIATE_NETWORK_REGISTER (msg 0x0022)
 *      TLV 0x01 Register Action (u8)         = AUTOMATIC (0x01)
 *
 *   3. Poll NAS_GET_SERVING_SYSTEM (msg 0x0024) until Radio Interface
 *      includes LTE (0x08) — timeout 60s. While polling, modem transitions
 *      from current RAT (GSM/EDGE) to LTE; on Vodafone CZ this is typically
 *      5-30s vs the 10-15 min cold-boot self-attach.
 *
 * Own QRTR socket; close after stage completes (NAS state is system-wide,
 * persists across socket lifetime when Change Duration=PERMANENT).
 */

#include "vendor-init.h"
#include "qrtr.h"
#include "qmi.h"
#include "log.h"
#include "state.h"

#include <unistd.h>
#include <time.h>

#define STAGE "nas_rat"

#define MSG_NAS_SET_SYS_SEL_PREF     0x0033
#define MSG_NAS_INITIATE_NW_REGISTER 0x0022
#define MSG_NAS_GET_SERVING_SYSTEM   0x0024

/* QmiNasRatModePreference bitmask. */
#define RAT_MODE_GSM    0x0004
#define RAT_MODE_UMTS   0x0008
#define RAT_MODE_LTE    0x0010
#define RAT_MODE_LTE_PREFERRED  (RAT_MODE_LTE | RAT_MODE_UMTS | RAT_MODE_GSM)

/* QmiNasRadioInterface gint8 values (for acquisition order + serving system). */
#define RADIO_IF_NONE   0x00
#define RADIO_IF_GSM    0x04
#define RADIO_IF_UMTS   0x05
#define RADIO_IF_LTE    0x08

/* QmiNasChangeDuration u8. */
#define CHANGE_DURATION_PERMANENT  0x00
#define CHANGE_DURATION_TEMPORARY  0x01

/* QmiNasNetworkSelectionPreference u8. */
#define NET_SEL_AUTOMATIC          0x00
#define NET_SEL_MANUAL             0x01

/* Register action u8. */
#define REGISTER_ACTION_AUTOMATIC  0x01
#define REGISTER_ACTION_MANUAL     0x02

#define LTE_WAIT_TIMEOUT_SEC       60
#define LTE_POLL_INTERVAL_MS       1000

static const char *radio_if_name(int8_t r)
{
	switch ((uint8_t)r) {
	case RADIO_IF_NONE: return "none";
	case RADIO_IF_GSM:  return "gsm";
	case RADIO_IF_UMTS: return "umts";
	case RADIO_IF_LTE:  return "lte";
	default:            return "unknown";
	}
}

static int issue_set_sys_sel_pref(int fd, uint32_t nas_port, uint16_t *txid)
{
	uint8_t req[128], resp[256];

	int off = qmi_hdr_req(req, (*txid)++, MSG_NAS_SET_SYS_SEL_PREF, 0);
	int after_hdr = off;

	/* TLV 0x11 Mode Preference (u16 LE). */
	off = qmi_tlv_u16  (req, off, 0x11, RAT_MODE_LTE_PREFERRED);

	/* TLV 0x16 Network Selection (seq: mode u8 + MCC u16 + MNC u16). */
	{
		uint8_t blob[5] = { NET_SEL_AUTOMATIC, 0x00, 0x00, 0x00, 0x00 };
		off = qmi_tlv_bytes(req, off, 0x16, blob, sizeof(blob));
	}

	/* TLV 0x17 Change Duration (u8) — PERMANENT writes NV. */
	off = qmi_tlv_u8(req, off, 0x17, CHANGE_DURATION_PERMANENT);

	/* TLV 0x1E Acquisition Order Preference (array: u8 count + N×gint8). */
	{
		uint8_t blob[1 + 3];
		blob[0] = 3;                /* 3 elements */
		blob[1] = RADIO_IF_LTE;
		blob[2] = RADIO_IF_UMTS;
		blob[3] = RADIO_IF_GSM;
		off = qmi_tlv_bytes(req, off, 0x1E, blob, sizeof(blob));
	}

	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "SET_SYS_SEL_PREF req", req, off);
	int n = qrtr_txn(fd, 0, nas_port, req, off, MSG_NAS_SET_SYS_SEL_PREF,
			 resp, sizeof(resp), 5000);
	if (n < 0) {
		LOGE(STAGE, "SET_SYS_SEL_PREF no response");
		return -1;
	}
	log_hex(LOG_DEBUG, STAGE, "SET_SYS_SEL_PREF resp", resp, n);

	int rc = qmi_result(resp, n);
	state_record("nas_set_pref_result", "%d", rc);
	if (rc != 0) {
		LOGW(STAGE, "SET_SYS_SEL_PREF err=%d (modem may not honor request)", rc);
		return -1;
	}
	LOGI(STAGE, "SET_SYS_SEL_PREF OK (LTE|UMTS|GSM, LTE first, PERMANENT)");
	return 0;
}

static int issue_initiate_register(int fd, uint32_t nas_port, uint16_t *txid)
{
	uint8_t req[64], resp[256];

	int off = qmi_hdr_req(req, (*txid)++, MSG_NAS_INITIATE_NW_REGISTER, 0);
	int after_hdr = off;
	off = qmi_tlv_u8(req, off, 0x01, REGISTER_ACTION_AUTOMATIC);
	uint16_t body = off - after_hdr;
	req[5] = body & 0xff;
	req[6] = (body >> 8) & 0xff;

	log_hex(LOG_DEBUG, STAGE, "INITIATE_NW_REGISTER req", req, off);
	int n = qrtr_txn(fd, 0, nas_port, req, off, MSG_NAS_INITIATE_NW_REGISTER,
			 resp, sizeof(resp), 5000);
	if (n < 0) {
		LOGE(STAGE, "INITIATE_NW_REGISTER no response");
		return -1;
	}
	log_hex(LOG_DEBUG, STAGE, "INITIATE_NW_REGISTER resp", resp, n);

	int rc = qmi_result(resp, n);
	state_record("nas_register_result", "%d", rc);
	if (rc != 0) {
		LOGW(STAGE, "INITIATE_NW_REGISTER err=%d", rc);
		return -1;
	}
	LOGI(STAGE, "INITIATE_NW_REGISTER OK (AUTOMATIC)");
	return 0;
}

/* Returns the current Radio Interface (gint8), or RADIO_IF_NONE on failure.
 *
 * 2026-05-31 fix: previous version parsed TLV 0x11 thinking it was Radio
 * Interfaces — actually that's "Data Service Capability" (2=EDGE, 3=HSDPA,
 * ...). Real radio interface array lives inside TLV 0x01 "Serving System".
 *
 * TLV 0x01 layout (mandatory in NAS_GET_SERVING_SYSTEM response):
 *   u8 registration_state   (0=NOT, 1=REGISTERED, 2=NOT_REGISTERED_SEARCHING, ...)
 *   u8 cs_attach_state
 *   u8 ps_attach_state
 *   u8 selected_network     (1=3GPP2, 2=3GPP)
 *   u8 radio_interface_count
 *   u8[count] radio_interfaces  (1=cdma1x, 2=evdo, 4=gsm, 5=umts, 8=lte, ...)
 *
 * If multiple, prefer LTE → UMTS → other. Also peek at TLV 0x15 (LTE TAC):
 * if present, we're definitely on LTE regardless of TLV 0x01 reporting. */
static int8_t poll_serving_system(int fd, uint32_t nas_port, uint16_t *txid)
{
	uint8_t req[16], resp[1024];

	int off = qmi_hdr_req(req, (*txid)++, MSG_NAS_GET_SERVING_SYSTEM, 0);

	int n = qrtr_txn(fd, 0, nas_port, req, off, MSG_NAS_GET_SERVING_SYSTEM,
			 resp, sizeof(resp), 2000);
	if (n < 0)
		return RADIO_IF_NONE;

	int rc = qmi_result(resp, n);
	if (rc != 0)
		return RADIO_IF_NONE;

	/* Fast path: if TLV 0x15 (LTE Tracking Area Code) is present, on LTE. */
	int v_off, v_len;
	if (qmi_tlv_find(resp, n, 0x15, &v_off, &v_len))
		return RADIO_IF_LTE;

	/* TLV 0x01 = Serving System. Radio interfaces start at byte 4. */
	if (!qmi_tlv_find(resp, n, 0x01, &v_off, &v_len) || v_len < 5)
		return RADIO_IF_NONE;

	uint8_t count = resp[v_off + 4];
	if (count == 0 || v_off + 5 + count > n)
		return RADIO_IF_NONE;

	int8_t best = (int8_t)resp[v_off + 5];
	for (int i = 1; i < count; i++) {
		int8_t r = (int8_t)resp[v_off + 5 + i];
		if (r == RADIO_IF_LTE)
			return RADIO_IF_LTE;
		if (r == RADIO_IF_UMTS && best != RADIO_IF_LTE)
			best = RADIO_IF_UMTS;
	}
	return best;
}

int stage_nas_rat(struct vi_ctx *ctx)
{
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would SET_SYS_SEL_PREF(LTE|UMTS|GSM) + INITIATE_REGISTER + wait LTE");
		return 0;
	}

	int fd = qrtr_open();
	if (fd < 0) {
		LOGE(STAGE, "qrtr_open failed");
		return 1;
	}

	uint32_t nas_port = qrtr_lookup(fd, QRTR_SVC_NAS);
	if (!nas_port) {
		LOGE(STAGE, "NAS service (0x%04x) not found", QRTR_SVC_NAS);
		close(fd);
		return 1;
	}
	state_record("nas_port", "%u", nas_port);
	LOGI(STAGE, "NAS service at port=%u", nas_port);

	uint16_t txid = 1;

	/* Pre-check current Radio Interface — skip work if already on LTE. */
	int8_t current_rat = poll_serving_system(fd, nas_port, &txid);
	state_record("rat_before", "%d (%s)", current_rat, radio_if_name(current_rat));
	LOGI(STAGE, "current Radio Interface = %d (%s)", current_rat, radio_if_name(current_rat));

	if (current_rat == RADIO_IF_LTE) {
		LOGI(STAGE, "modem already on LTE — skipping SET_SYS_SEL_PREF / register");
		close(fd);
		return 0;
	}

	/* 1. Set system selection preference: LTE preferred, GSM/UMTS fallback. */
	if (issue_set_sys_sel_pref(fd, nas_port, &txid) < 0) {
		LOGW(STAGE, "SET_SYS_SEL_PREF failed — modem may still self-attach to LTE eventually");
	}

	/* 2. Kick automatic re-registration. */
	if (issue_initiate_register(fd, nas_port, &txid) < 0) {
		LOGW(STAGE, "INITIATE_NW_REGISTER failed");
	}

	/* 3. Poll for LTE attach with timeout. */
	LOGI(STAGE, "waiting up to %ds for modem to attach to LTE…",
	     LTE_WAIT_TIMEOUT_SEC);
	struct timespec t0, now;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	int8_t last_rat = current_rat;
	int seen_lte = 0;

	for (;;) {
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - t0.tv_sec >= LTE_WAIT_TIMEOUT_SEC)
			break;

		usleep(LTE_POLL_INTERVAL_MS * 1000);

		int8_t r = poll_serving_system(fd, nas_port, &txid);
		if (r != last_rat) {
			LOGI(STAGE, "RAT changed: %s → %s (T+%lds)",
			     radio_if_name(last_rat), radio_if_name(r),
			     now.tv_sec - t0.tv_sec);
			last_rat = r;
		}
		if (r == RADIO_IF_LTE) {
			seen_lte = 1;
			break;
		}
	}

	state_record("rat_after", "%d (%s)", last_rat, radio_if_name(last_rat));

	close(fd);

	if (!seen_lte) {
		LOGW(STAGE, "timed out waiting for LTE — final RAT = %s",
		     radio_if_name(last_rat));
		LOGW(STAGE, "auto-enabling simple-wds mode (LTE-flavored TLVs would fail on non-LTE)");
		ctx->simple_wds = 1;
		return 0;
	}

	LOGI(STAGE, "modem on LTE — proceeding with bearer setup");
	return 0;
}
