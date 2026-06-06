#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 90-apply-diag-sondy.sh  —  OPT-IN bringup diagnostics ("sondy")
#
# Curated set of the diagnostic probes that carried the original X00TD
# bringup (156 h of reverse engineering), re-extracted for porting this
# driver to OTHER SDM6xx devices. Apply on top of the full port pipeline
# (00/05/10/20/30). NEVER ship a production build with this applied —
# the per-packet probes collapse throughput when enabled and even the
# always-on ones spam dmesg.
#
# Tiers:
#   tier 1  IPA_SONDA()      -> ftrace, default ON, cheap, semantic events
#   tier 2  IPA_SONDA_DBG()  -> dmesg, default OFF, per-packet
#           toggle: echo 1 > /sys/module/<ipa module>/parameters/ipa_sonda_dbg
#   always  tagged pr_err one-shots on rare paths (handshake, rule install)
#
# Reading tier 1:  cat /sys/kernel/debug/tracing/trace_pipe | grep IPA_SONDA
#
# Probe families installed here:
#   [QMI_DIAG] [AP_READY] [INIT_DRV_DIAG] [GOLDEN_DATA]   QMI handshake
#   [QMI_FILTER_DIAG] [INSTALL_WIRE] [FLT_INSTALL]
#   [GOLDEN_FLT] [GOLDEN_RT] [DUMP_RT_*]                  rule visibility
#   [SETUP_PIPE_DIAG] [INGRESS_DIAG] [NUM_Q6_DIAG]
#   [EMB_PIPE_DIAG] [TX_EXCP] [WAN_RX_IOV] [NO_AGG]
#   [EMPTY_RT_DIAG]                                       pipes/datapath
#   [AUTO_IPACM] [ICMP_RULE] [MCAST_BCAST]
#   [WAN_DL_QMI] [WAN_DL_NOTIF]                           IPACM emulation
#   [IRQ_STTS_DIAG] [BAM_DIAG]                            raw HW state
#
# NOT carried over (see claude_patches/ archive for the originals):
#   - per-packet SPS/NAPI/RX_SEQ sondas (rewrite via IPA_SONDA_DBG as
#     needed; the originals were tied to a pre-cleanup tree state)
#   - init-time SRAM zero-table hexdumps (DUMP_RT_* at commit time covers
#     the same question with live content)
#   - WDI lifecycle probes (WDI offload is compiled out in this port)
#
# Idempotent: same guard discipline as the other port scripts.
#
# Usage:  ./90-apply-diag-sondy.sh [--root /path/to/kernel]

set -eu

SRC_ROOT="."
while [ $# -gt 0 ]; do
	case "$1" in
		--root) SRC_ROOT="$2"; shift 2 ;;
		--help|-h) sed -n '/^# /{s/^# \?//;p}' "$0" | head -45; exit 0 ;;
		*) echo "Unknown argument: $1"; exit 1 ;;
	esac
done

applied=0
skipped=0

# apply_edit FILE DESCRIPTION - replace exactly one literal occurrence of
# $OLD with $NEW in FILE. Pure substring matching (no regex pitfalls).
# Already-applied edits (NEW present, OLD absent) are skipped, anything
# else that doesn't match aborts loudly.
apply_edit() {
	local f="$SRC_ROOT/$1" desc="$2" n
	[ -f "$f" ] || { echo "ERROR: $f not found (run from kernel root or use --root)" >&2; exit 1; }
	# optional GUARD: for pure append-after-anchor edits whose NEW contains
	# OLD verbatim - presence of GUARD text means "already applied".
	if [ -n "${GUARD:-}" ]; then
		if grep -qF -- "$GUARD" "$f"; then
			GUARD=""
			echo "  [skip] $desc"; skipped=$((skipped+1)); return 0
		fi
		GUARD=""
	fi
	OLD="${OLD%$'\n'}"; NEW="${NEW%$'\n'}"
	n=$(OLD="$OLD" perl -0777 -ne '
		my $c = 0; my $i = 0;
		while (($i = index($_, $ENV{OLD}, $i)) >= 0) { $c++; $i++ }
		print $c' "$f")
	if [ "$n" = "0" ]; then
		if NEW="$NEW" perl -0777 -ne 'exit(index($_, $ENV{NEW}) >= 0 ? 0 : 1)' "$f"; then
			echo "  [skip] $desc"; skipped=$((skipped+1)); return 0
		fi
		echo "ERROR: pattern not found: $desc" >&2
		echo "       file: $1" >&2
		exit 1
	fi
	if [ "$n" != "1" ]; then
		echo "ERROR: pattern matches ${n}x (must be unique): $desc" >&2
		exit 1
	fi
	OLD="$OLD" NEW="$NEW" perl -0777 -i -pe '
		my $i = index($_, $ENV{OLD});
		substr($_, $i, length($ENV{OLD})) = $ENV{NEW} if $i >= 0;' "$f"
	echo "  [ok]   $desc"
	applied=$((applied+1))
}

section() { echo; echo "==> $1"; }

section "Probe infrastructure (IPA_SONDA tiers, module params)"
read -r -d '' OLD <<'PORT_EOF' || true
#define DRV_NAME "ipa"
#define NAT_DEV_NAME "ipaNatTable"
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
#define DRV_NAME "ipa"
#define NAT_DEV_NAME "ipaNatTable"

/* ════ Bringup diagnostics (90-apply-diag-sondy.sh) ════
 *
 * Tier 1 — IPA_SONDA(): low-volume semantic events (QMI handshake, MMIO
 * at probe, table installs). Sink = ftrace ring buffer, default ON:
 *     cat /sys/kernel/debug/tracing/trace_pipe | grep IPA_SONDA
 * Toggle live: /sys/module/<ipa module>/parameters/ipa_rev_eng_active
 *
 * Tier 2 — IPA_SONDA_DBG(): per-packet hot-path probes. Sink = dmesg,
 * default OFF (throughput collapses to single-digit Mbps when on):
 *     echo 1 > /sys/module/<ipa module>/parameters/ipa_sonda_dbg
 *
 * Sprinkle your own IPA_SONDA()/IPA_SONDA_DBG() calls while porting to
 * other SDM6xx devices; both compile out to nothing in production builds
 * (this whole header block only exists after running the diag script).
 */
extern int ipa_rev_eng_active;
extern int ipa_sonda_dbg;

#define IPA_SONDA(fmt, ...) \
	do { \
		if (ipa_rev_eng_active) \
			trace_printk("[IPA_SONDA] %s: " fmt, \
				     __func__, ##__VA_ARGS__); \
	} while (0)

#define IPA_SONDA_DBG(fmt, ...) \
	do { \
		if (ipa_sonda_dbg) \
			pr_err("[IPA_SONDA_DBG] %s: " fmt, \
			       __func__, ##__VA_ARGS__); \
	} while (0)
PORT_EOF
GUARD='IPA_SONDA(fmt, ...)'
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: IPA_SONDA / IPA_SONDA_DBG macros (tier 1 ftrace + tier 2 dmesg)"

read -r -d '' OLD <<'PORT_EOF' || true
static int ipa_disable_wan_agg;
module_param(ipa_disable_wan_agg, int, 0644);
MODULE_PARM_DESC(ipa_disable_wan_agg, "Bypass IPA HW AGG on pipe 5 (test only — empirically -50% throughput)");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static int ipa_disable_wan_agg;
module_param(ipa_disable_wan_agg, int, 0644);
MODULE_PARM_DESC(ipa_disable_wan_agg, "Bypass IPA HW AGG on pipe 5 (test only — empirically -50% throughput)");

/* Diag tiers — see the block comment in ipa_i.h. */
int ipa_rev_eng_active = 1;
module_param(ipa_rev_eng_active, int, 0644);
MODULE_PARM_DESC(ipa_rev_eng_active, "Tier-1 bringup probes to ftrace (cheap, default on)");
int ipa_sonda_dbg;
module_param(ipa_sonda_dbg, int, 0644);
MODULE_PARM_DESC(ipa_sonda_dbg, "Tier-2 per-packet probes to dmesg (slow, default off)");
PORT_EOF
GUARD='int ipa_rev_eng_active = 1;'
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: ipa_rev_eng_active + ipa_sonda_dbg module params"


section "QMI handshake visibility (probe -> INIT_DRIVER -> INIT_COMPLETE_IND)"
read -r -d '' OLD <<'PORT_EOF' || true
static int ipa_q6_clnt_svc_event_notify_svc_new(struct qmi_handle *qmi,
	struct qmi_service *service)
{
	IPAWANDBG("QMI svc:%d vers:%d ins:%d node:%d port:%d\n",
		  service->service, service->version, service->instance,
		  service->node, service->port);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static int ipa_q6_clnt_svc_event_notify_svc_new(struct qmi_handle *qmi,
	struct qmi_service *service)
{
	pr_err("[QMI_DIAG] new_server cb: svc=%d vers=%d ins=%d node=%d port=%d\n",
		service->service, service->version, service->instance,
		service->node, service->port);
	IPAWANDBG("QMI svc:%d vers:%d ins:%d node:%d port:%d\n",
		  service->service, service->version, service->instance,
		  service->node, service->port);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_DIAG] svc_arrive worker entry"

read -r -d '' OLD <<'PORT_EOF' || true
	int rc;
	struct ipa_master_driver_init_complt_ind_msg_v01 ind;

	rc = kernel_connect(ipa_q6_clnt->sock,
		(struct sockaddr_unsized *) &ipa_qmi_ctx->server_sq,
		sizeof(ipa_qmi_ctx->server_sq),
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	int rc;
	struct ipa_master_driver_init_complt_ind_msg_v01 ind;

	pr_err("[QMI_DIAG] svc_arrive worker running\n");
	rc = kernel_connect(ipa_q6_clnt->sock,
		(struct sockaddr_unsized *) &ipa_qmi_ctx->server_sq,
		sizeof(ipa_qmi_ctx->server_sq),
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_DIAG] new_server callback (service/port discovery)"

read -r -d '' OLD <<'PORT_EOF' || true
{
	int rc;

	/* Initialize QMI-service*/
	IPAWANDBG("IPA A7 QMI init OK :>>>>\n");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
{
	int rc;

	pr_err("[QMI_DIAG] ipa_qmi_service_init_worker entry\n");
	/* Initialize QMI-service*/
	IPAWANDBG("IPA A7 QMI init OK :>>>>\n");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_DIAG] service-init worker entry"

read -r -d '' OLD <<'PORT_EOF' || true
		goto destroy_qmi_client_handle;
	}

	rc = qmi_add_lookup(ipa_q6_clnt,
		IPA_Q6_SERVICE_SVC_ID,
		IPA_Q6_SVC_VERS,
		IPA_Q6_SERVICE_INS_ID);

	if (rc < 0) {
		IPAWANERR("Adding Q6 Svc failed\n");
		goto deregister_qmi_client;
	}
	/* get Q6 service and start send modem-initial to Q6 */
	IPAWANDBG("wait service available\n");
	return;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		goto destroy_qmi_client_handle;
	}

	pr_err("[QMI_DIAG] calling qmi_add_lookup svc=%d vers=%d ins=%d\n",
		IPA_Q6_SERVICE_SVC_ID, IPA_Q6_SVC_VERS, IPA_Q6_SERVICE_INS_ID);
	rc = qmi_add_lookup(ipa_q6_clnt,
		IPA_Q6_SERVICE_SVC_ID,
		IPA_Q6_SVC_VERS,
		IPA_Q6_SERVICE_INS_ID);
	pr_err("[QMI_DIAG] qmi_add_lookup ret=%d\n", rc);

	if (rc < 0) {
		IPAWANERR("Adding Q6 Svc failed\n");
		goto deregister_qmi_client;
	}
	/* get Q6 service and start send modem-initial to Q6 */
	pr_err("[QMI_DIAG] waiting for modem-side IPA QMI service to appear\n");
	IPAWANDBG("wait service available\n");
	return;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_DIAG] qmi_add_lookup + wait-for-service"

read -r -d '' OLD <<'PORT_EOF' || true
	if (rc != 0) {
		IPAWANERR("qmi_init_modem_send_sync_msg failed\n");
		/*
		 * This is a very unexpected scenario, which requires a kernel
		 * panic in order to force dumps for QMI/Q6 side analysis.
		 */
		ipa_assert();
		return;
	}
	qmi_modem_init_fin = true;

	/* In cold-bootup, first_time_handshake = false */
	ipa_q6_handshake_complete(first_time_handshake);
	first_time_handshake = true;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (rc != 0) {
		IPAWANERR("qmi_init_modem_send_sync_msg failed\n");
		pr_err("[QMI_DIAG] qmi_init_modem_send_sync_msg FAILED rc=%d\n", rc);
		/*
		 * This is a very unexpected scenario, which requires a kernel
		 * panic in order to force dumps for QMI/Q6 side analysis.
		 */
		ipa_assert();
		return;
	}
	qmi_modem_init_fin = true;
	pr_err("[QMI_DIAG] qmi_modem_init_fin SET TO 1 (handshake OK)\n");

	/* In cold-bootup, first_time_handshake = false */
	pr_err("[QMI_DIAG] calling ipa_q6_handshake_complete first_time=%d\n",
		first_time_handshake);
	ipa_q6_handshake_complete(first_time_handshake);
	pr_err("[QMI_DIAG] ipa_q6_handshake_complete returned\n");
	first_time_handshake = true;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_DIAG] INIT_DRIVER response -> handshake-complete trace"

read -r -d '' OLD <<'PORT_EOF' || true
	}

	qmi_indication_fin = true;
	/* check if need sending indication to modem */
	if (qmi_modem_init_fin)	{
		IPAWANDBG("send indication to modem (%d)\n",
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	qmi_indication_fin = true;
	pr_err("[AP_READY] __ap_readiness_diag__ handle_indication_req: indication_fin=true, modem_init_fin=%d\n",
		qmi_modem_init_fin);
	/* check if need sending indication to modem */
	if (qmi_modem_init_fin)	{
		IPAWANDBG("send indication to modem (%d)\n",
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[AP_READY] indication_register: deferred/sent INIT_COMPLETE_IND (A)"

read -r -d '' OLD <<'PORT_EOF' || true
				ipa_master_driver_init_complt_ind_msg_v01));
		ind.master_driver_init_status.result =
			IPA_QMI_RESULT_SUCCESS_V01;
		rc = qmi_send_indication(qmi_handle,
			&(ipa_qmi_ctx->client_sq),
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_V01,
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_MAX_MSG_LEN_V01,
			ipa_master_driver_init_complt_ind_msg_data_v01_ei,
			&ind);

		if (rc < 0) {
			IPAWANERR("send indication failed\n");
			qmi_indication_fin = false;
		}
	} else {
		IPAWANERR("not send indication\n");
	}
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				ipa_master_driver_init_complt_ind_msg_v01));
		ind.master_driver_init_status.result =
			IPA_QMI_RESULT_SUCCESS_V01;
		pr_err("[AP_READY] sending INIT_COMPLETE_IND (path: indication_req)\n");
		rc = qmi_send_indication(qmi_handle,
			&(ipa_qmi_ctx->client_sq),
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_V01,
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_MAX_MSG_LEN_V01,
			ipa_master_driver_init_complt_ind_msg_data_v01_ei,
			&ind);
		pr_err("[AP_READY] qmi_send_indication (path A) returned %d\n", rc);

		if (rc < 0) {
			IPAWANERR("send indication failed\n");
			qmi_indication_fin = false;
		}
	} else {
		pr_err("[AP_READY] handle_indication_req: deferring IND send (modem_init_fin=false)\n");
		IPAWANERR("not send indication\n");
	}
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[AP_READY] indication_register: send result"

read -r -d '' OLD <<'PORT_EOF' || true
				ipa_master_driver_init_complt_ind_msg_v01));
		ind.master_driver_init_status.result =
			IPA_QMI_RESULT_SUCCESS_V01;
		rc = qmi_send_indication(ipa_svc_handle,
			&ipa_qmi_ctx->client_sq,
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_V01,
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_MAX_MSG_LEN_V01,
			ipa_master_driver_init_complt_ind_msg_data_v01_ei,
			&ind);

		IPAWANDBG("ipa_qmi_service_client good\n");
	} else {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				ipa_master_driver_init_complt_ind_msg_v01));
		ind.master_driver_init_status.result =
			IPA_QMI_RESULT_SUCCESS_V01;
		pr_err("[AP_READY] sending INIT_COMPLETE_IND (path: init_resp)\n");
		rc = qmi_send_indication(ipa_svc_handle,
			&ipa_qmi_ctx->client_sq,
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_V01,
			QMI_IPA_MASTER_DRIVER_INIT_COMPLETE_IND_MAX_MSG_LEN_V01,
			ipa_master_driver_init_complt_ind_msg_data_v01_ei,
			&ind);
		pr_err("[AP_READY] qmi_send_indication (path B) returned %d\n", rc);

		IPAWANDBG("ipa_qmi_service_client good\n");
	} else {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[AP_READY] INIT_COMPLETE_IND send path B (svc_arrive)"

read -r -d '' OLD <<'PORT_EOF' || true
	}

	pr_info("QMI_IPA_INIT_MODEM_DRIVER_REQ_V01 response received\n");
	return ipa_check_qmi_response(rc,
		QMI_IPA_INIT_MODEM_DRIVER_REQ_V01, resp.resp.result,
		resp.resp.error, "ipa_init_modem_driver_resp_msg_v01");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	pr_info("QMI_IPA_INIT_MODEM_DRIVER_REQ_V01 response received\n");

    /* PŘIDAT TENTO BLOK: */
	pr_err("[INIT_DRV_DIAG] modem_driver_init_pending_valid=%d, modem_driver_init_pending=%d\n",
		resp.modem_driver_init_pending_valid,
		resp.modem_driver_init_pending);

	return ipa_check_qmi_response(rc,
		QMI_IPA_INIT_MODEM_DRIVER_REQ_V01, resp.resp.result,
		resp.resp.error, "ipa_init_modem_driver_resp_msg_v01");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[INIT_DRV_DIAG] modem_driver_init_pending TLV 0x12 echo"

read -r -d '' OLD <<'PORT_EOF' || true
	IPAWANDBG("is_ssr_bootup %d\n",
			req.is_ssr_bootup);

	req_desc.max_msg_len = QMI_IPA_INIT_MODEM_DRIVER_REQ_MAX_MSG_LEN_V01;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	IPAWANDBG("is_ssr_bootup %d\n",
			req.is_ssr_bootup);

	pr_err("[GOLDEN_DATA] === INIT_DRIVER memory-map dump start ===\n");
	pr_err("[GOLDEN_DATA] smem_restr_bytes: 0x%x\n", smem_restr_bytes);
	pr_err("[GOLDEN_DATA] V4 route addr: 0x%x (indices: %d)\n",
		req.v4_route_tbl_info.route_tbl_start_addr,
		req.v4_route_tbl_info.num_indices);
	pr_err("[GOLDEN_DATA] V6 route addr: 0x%x (indices: %d)\n",
		req.v6_route_tbl_info.route_tbl_start_addr,
		req.v6_route_tbl_info.num_indices);
	pr_err("[GOLDEN_DATA] V4 filter addr: 0x%x\n", req.v4_filter_tbl_start_addr);
	pr_err("[GOLDEN_DATA] V6 filter addr: 0x%x\n", req.v6_filter_tbl_start_addr);
	pr_err("[GOLDEN_DATA] modem mem start: 0x%x (size: 0x%x)\n",
		req.modem_mem_info.block_start_addr, req.modem_mem_info.size);
	pr_err("[GOLDEN_DATA] HDR table: start 0x%x end 0x%x\n",
		req.hdr_tbl_info.modem_offset_start,
		req.hdr_tbl_info.modem_offset_end);
	pr_err("[GOLDEN_DATA] HDR proc ctx: start 0x%x end 0x%x\n",
		req.hdr_proc_ctx_tbl_info.modem_offset_start,
		req.hdr_proc_ctx_tbl_info.modem_offset_end);
	pr_err("[GOLDEN_DATA] ZIP table: start 0x%x end 0x%x\n",
		req.zip_tbl_info.modem_offset_start,
		req.zip_tbl_info.modem_offset_end);
	if (ipa_ctx)
		pr_err("[GOLDEN_DATA] IPA HW regs phys base: %pa\n",
			&ipa_ctx->ipa_wrapper_base);
	pr_err("[GOLDEN_DATA] === dump end ===\n");

	req_desc.max_msg_len = QMI_IPA_INIT_MODEM_DRIVER_REQ_MAX_MSG_LEN_V01;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[GOLDEN_DATA] INIT_DRIVER SRAM table addresses dump"


section "Filter/routing rule visibility (what really lands in IPA HW tables)"
read -r -d '' OLD <<'PORT_EOF' || true
	struct ipa_msg_desc req_desc, resp_desc;
	int rc;
	int i;

	/* check if modem up */
	if (!qmi_indication_fin ||
		!qmi_modem_init_fin ||
		!ipa_q6_clnt) {
		IPAWANDBG("modem QMI haven't up yet\n");
		return -EINVAL;
	}

	/* check if the filter rules from IPACM is valid */
	if (req->filter_spec_list_len == 0) {
		IPAWANDBG("IPACM pass zero rules to Q6\n");
	} else {
		IPAWANDBG("IPACM pass %u rules to Q6\n",
		req->filter_spec_list_len);
	}

	if (req->filter_spec_list_len >= QMI_IPA_MAX_FILTERS_V01) {
		IPAWANDBG(
		"IPACM passes the number of filtering rules exceed limit\n");
		return -EINVAL;
	} else if (req->source_pipe_index_valid != 0) {
		IPAWANDBG(
		"IPACM passes source_pipe_index_valid not zero 0 != %d\n",
			req->source_pipe_index_valid);
		return -EINVAL;
	} else if (req->source_pipe_index >= ipa_ctx->ipa_num_pipes) {
		IPAWANDBG(
		"IPACM passes source pipe index not valid ID = %d\n",
		req->source_pipe_index);
		return -EINVAL;
	}
	for (i = 0; i < req->filter_spec_list_len; i++) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	struct ipa_msg_desc req_desc, resp_desc;
	int rc;
	int i;
    /* Sonda */
    pr_err("[QMI_FILTER_DIAG] qmi_filter_request_send entered: list_valid=%d, list_len=%d, src_idx_valid=%d, src_idx=%d\n",
           req ? req->filter_spec_list_valid : -1,
           req ? req->filter_spec_list_len : 0,
           req ? req->source_pipe_index_valid : -1,
           req ? req->source_pipe_index : -1);
	if (req && req->filter_spec_list_valid) {
		for (i = 0; i < req->filter_spec_list_len; i++) {
			struct ipa_filter_spec_type_v01 *s = &req->filter_spec_list[i];
			struct ipa_filter_rule_type_v01 *r = &s->filter_rule;
			int k;


			/* Phase 3 — comprehensive wire dump for byte-by-byte
			 * comparison vs vendor strace. Audit Finding C 2026-05-30. */
			pr_err("[INSTALL_WIRE] spec[%d] id=%u ip_type=%d action=%d rt_idx_valid=%u rt_idx=%u mux_id_valid=%u mux_id=%u\n",
			       i, s->filter_spec_identifier, s->ip_type,
			       s->filter_action, s->is_routing_table_index_valid,
			       s->route_table_index, s->is_mux_id_valid, s->mux_id);
			pr_err("[INSTALL_WIRE] spec[%d] rule_eq_bitmap=0x%04x proto_eq_present=%u proto_eq=%u num_meq_32=%u\n",
			       i, r->rule_eq_bitmap, r->protocol_eq_present,
			       r->protocol_eq, r->num_offset_meq_32);
			for (k = 0; k < r->num_offset_meq_32 && k < 2; k++) {
				pr_err("[INSTALL_WIRE] spec[%d]   offset_meq_32[%d]: offset=%u value=0x%08x mask=0x%08x\n",
				       i, k,
				       r->offset_meq_32[k].offset,
				       r->offset_meq_32[k].value,
				       r->offset_meq_32[k].mask);
			}
		}
	}

	/* check if modem up */
	if (!qmi_indication_fin ||
		!qmi_modem_init_fin ||
		!ipa_q6_clnt) {
		pr_err("[QMI_FILTER_DIAG] BAIL: modem QMI not up (qmi_indication_fin=%d qmi_modem_init_fin=%d ipa_q6_clnt=%p)\n",
		       qmi_indication_fin, qmi_modem_init_fin, ipa_q6_clnt);
		return -EINVAL;
	}

	/* check if the filter rules from IPACM is valid */
	if (req->filter_spec_list_len == 0) {
		pr_err("[QMI_FILTER_DIAG] zero rules to Q6 (continuing)\n");
	} else {
		pr_err("[QMI_FILTER_DIAG] %u rules to Q6\n", req->filter_spec_list_len);
	}

	if (req->filter_spec_list_len >= QMI_IPA_MAX_FILTERS_V01) {
		pr_err("[QMI_FILTER_DIAG] BAIL: rules exceed limit (%u >= max)\n", req->filter_spec_list_len);
		return -EINVAL;
	} else if (req->source_pipe_index_valid != 0) {
		pr_err("[QMI_FILTER_DIAG] BAIL: source_pipe_index_valid=%d (vendor wants 0)\n",
		       req->source_pipe_index_valid);
		return -EINVAL;
	} else if (req->source_pipe_index >= ipa_ctx->ipa_num_pipes) {
		pr_err("[QMI_FILTER_DIAG] BAIL: source_pipe_index=%d >= num_pipes=%d\n",
		       req->source_pipe_index, ipa_ctx->ipa_num_pipes);
		return -EINVAL;
	}
	for (i = 0; i < req->filter_spec_list_len; i++) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_FILTER_DIAG]+[INSTALL_WIRE] filter request wire dump"

read -r -d '' OLD <<'PORT_EOF' || true
	mutex_unlock(&ipa_qmi_lock);

	req_desc.max_msg_len = ipa_qmi_filter_request_ex_calc_length(req);
	IPAWANDBG("QMI send request length = %d\n", req_desc.max_msg_len);

	req_desc.msg_id = QMI_IPA_INSTALL_FILTER_RULE_REQ_V01;
	req_desc.ei_array = ipa_install_fltr_rule_req_msg_data_v01_ei;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	mutex_unlock(&ipa_qmi_lock);

	req_desc.max_msg_len = ipa_qmi_filter_request_ex_calc_length(req);
	pr_err("[QMI_FILTER_DIAG] sending QMI request, length=%d\n", req_desc.max_msg_len);

	req_desc.msg_id = QMI_IPA_INSTALL_FILTER_RULE_REQ_V01;
	req_desc.ei_array = ipa_install_fltr_rule_req_msg_data_v01_ei;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_FILTER_DIAG] bail-out reasons"

read -r -d '' OLD <<'PORT_EOF' || true
	resp_desc.ei_array = ipa_install_fltr_rule_resp_msg_data_v01_ei;
	if (unlikely(!ipa_q6_clnt))
		return -ETIMEDOUT;
	rc = ipa_qmi_send_req_wait(ipa_q6_clnt, &req_desc,
			req,
			&resp_desc, &resp,
			QMI_SEND_REQ_TIMEOUT_MS);

	if (rc < 0) {
		IPAWANERR("QMI send Req %d failed, rc= %d\n",
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	resp_desc.ei_array = ipa_install_fltr_rule_resp_msg_data_v01_ei;
	if (unlikely(!ipa_q6_clnt))
		return -ETIMEDOUT;
	pr_err("[QMI_FILTER_DIAG] calling ipa_qmi_send_req_wait...\n");
	rc = ipa_qmi_send_req_wait(ipa_q6_clnt, &req_desc,
			req,
			&resp_desc, &resp,
			QMI_SEND_REQ_TIMEOUT_MS);
	pr_err("[QMI_FILTER_DIAG] ipa_qmi_send_req_wait returned %d, resp.result=%d resp.error=%d\n",
	       rc, resp.resp.result, resp.resp.error);

	if (rc < 0) {
		IPAWANERR("QMI send Req %d failed, rc= %d\n",
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "[QMI_FILTER_DIAG] request length + send result"

read -r -d '' OLD <<'PORT_EOF' || true
			param->ip = IPA_IP_v4;
			if (ipa2_add_flt_rule(param)) {
				retval = -EFAULT;
			} else {
				ipa_qmi_ctx->q6_ul_filter_rule_hdl[i] =
					param->rules[0].flt_rule_hdl;
			}
			memcpy(&(param->rules[0]), &flt_rule_entry,
				sizeof(struct ipa_flt_rule_add));
			param->ip = IPA_IP_v6;
			if (ipa2_add_flt_rule(param)) {
				/* not setting retval -- v4 may have succeeded */
			}
		} else {
			param->ip = ipa_qmi_ctx->q6_ul_filter_rule[i].ip;
			if (ipa2_add_flt_rule(param)) {
				retval = -EFAULT;
			} else {
				ipa_qmi_ctx->q6_ul_filter_rule_hdl[i] =
					param->rules[0].flt_rule_hdl;
			}
		}
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			param->ip = IPA_IP_v4;
			if (ipa2_add_flt_rule(param)) {
				retval = -EFAULT;
				pr_err("[FLT_INSTALL] rule[%d] V4V6/v4 install FAILED\n", i);
			} else {
				ipa_qmi_ctx->q6_ul_filter_rule_hdl[i] =
					param->rules[0].flt_rule_hdl;
				pr_info("[FLT_INSTALL] rule[%d] V4V6/v4 hdl=0x%x OK\n",
					i, param->rules[0].flt_rule_hdl);
			}
			memcpy(&(param->rules[0]), &flt_rule_entry,
				sizeof(struct ipa_flt_rule_add));
			param->ip = IPA_IP_v6;
			if (ipa2_add_flt_rule(param)) {
				pr_err("[FLT_INSTALL] rule[%d] V4V6/v6 install FAILED\n", i);
				/* not setting retval -- v4 may have succeeded */
			} else {
				pr_info("[FLT_INSTALL] rule[%d] V4V6/v6 hdl=0x%x OK\n",
					i, param->rules[0].flt_rule_hdl);
			}
		} else {
			param->ip = ipa_qmi_ctx->q6_ul_filter_rule[i].ip;
			if (ipa2_add_flt_rule(param)) {
				retval = -EFAULT;
				pr_err("[FLT_INSTALL] rule[%d] ip=%d install FAILED\n",
					i, param->ip);
			} else {
				ipa_qmi_ctx->q6_ul_filter_rule_hdl[i] =
					param->rules[0].flt_rule_hdl;
				pr_info("[FLT_INSTALL] rule[%d] ip=%d hdl=0x%x OK\n",
					i, param->ip, param->rules[0].flt_rule_hdl);
			}
		}
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[FLT_INSTALL] per-rule install result + handle"

read -r -d '' OLD <<'PORT_EOF' || true
	struct ipa_mem_buffer flt_tbl_mem;
	u8 *ftbl_membody;

	*hdr_top = 0;
	body = base;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	struct ipa_mem_buffer flt_tbl_mem;
	u8 *ftbl_membody;

    /* --- [ZÓNA 1: START] --- */
    pr_err("[GOLDEN_FLT] >>> VSTUP DO FUNKCE (IP verze: %d) <<<\n", ip);

	*hdr_top = 0;
	body = base;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#1/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	tbl = &ipa_ctx->glob_flt_tbl[ip];

	if (!list_empty(&tbl->head_flt_rule_list)) {
		*hdr_top |= IPA_FLT_BIT_MASK;

		if (!tbl->in_sys) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	tbl = &ipa_ctx->glob_flt_tbl[ip];

	if (!list_empty(&tbl->head_flt_rule_list)) {

        /* --- [ZÓNA 2: GLOBÁLNÍ TABULKA] --- */
        pr_err("[GOLDEN_FLT] Zpracovávám GLOBÁLNÍ tabulku\n");

		*hdr_top |= IPA_FLT_BIT_MASK;

		if (!tbl->in_sys) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#2/7)"

read -r -d '' OLD <<'PORT_EOF' || true
			/* generate the rule-set */
			list_for_each_entry(entry, &tbl->head_flt_rule_list,
					link) {
				if (ipa_generate_flt_hw_rule(ip, entry, body)) {
					IPAERR("failed to gen HW FLT rule\n");
					goto proc_err;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			/* generate the rule-set */
			list_for_each_entry(entry, &tbl->head_flt_rule_list,
					link) {

                /* VLOŽIT SEM: */
                pr_err("[GOLDEN_FLT] GLOB | Akce:%d | RT_Idx:%d\n", 
                       entry->rule.action, 
                       entry->rt_tbl ? entry->rt_tbl->idx : entry->rule.rt_tbl_idx);

				if (ipa_generate_flt_hw_rule(ip, entry, body)) {
					IPAERR("failed to gen HW FLT rule\n");
					goto proc_err;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#3/7)"

read -r -d '' OLD <<'PORT_EOF' || true
			/* generate the rule-set */
			list_for_each_entry(entry, &tbl->head_flt_rule_list,
					link) {
				if (ipa_generate_flt_hw_rule(ip, entry,
							ftbl_membody)) {
					IPAERR("failed to gen HW FLT rule\n");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			/* generate the rule-set */
			list_for_each_entry(entry, &tbl->head_flt_rule_list,
					link) {

                /* VLOŽIT SEM (pro DDR kopii): */
                pr_err("[GOLDEN_FLT] GLOB_SYS | Akce:%d | RT_Idx:%d\n", 
                       entry->rule.action, 
                       entry->rt_tbl ? entry->rt_tbl->idx : entry->rule.rt_tbl_idx);

				if (ipa_generate_flt_hw_rule(ip, entry,
							ftbl_membody)) {
					IPAERR("failed to gen HW FLT rule\n");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#4/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	for (i = 0; i < ipa_ctx->ipa_num_pipes; i++) {
		tbl = &ipa_ctx->flt_tbl[i][ip];
		if (!list_empty(&tbl->head_flt_rule_list)) {
			/* pipe "i" is at bit "i+1" */
			*hdr_top |= (1 << (i + 1));
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	for (i = 0; i < ipa_ctx->ipa_num_pipes; i++) {
		tbl = &ipa_ctx->flt_tbl[i][ip];
		if (!list_empty(&tbl->head_flt_rule_list)) {

            /* VLOŽIT SEM: Informace, že jsme našli rouru s pravidly */
            pr_err("[GOLDEN_FLT] Nalezena pravidla pro ROURU %d\n", i);

			/* pipe "i" is at bit "i+1" */
			*hdr_top |= (1 << (i + 1));
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#5/7)"

read -r -d '' OLD <<'PORT_EOF' || true
				list_for_each_entry(entry,
						&tbl->head_flt_rule_list,
						link) {
					if (ipa_generate_flt_hw_rule(ip, entry,
								body)) {
						IPAERR("fail gen FLT rule\n");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				list_for_each_entry(entry,
						&tbl->head_flt_rule_list,
						link) {

                    /* VLOŽIT SEM: Klíčová data pro rouru */
                    pr_err("[GOLDEN_FLT] ROURA %d | Akce:%d | Cíl RT:%d | uC:%d\n",
                           i, entry->rule.action, 
                           entry->rt_tbl ? entry->rt_tbl->idx : entry->rule.rt_tbl_idx,
                           entry->rule.to_uc);

					if (ipa_generate_flt_hw_rule(ip, entry,
								body)) {
						IPAERR("fail gen FLT rule\n");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#6/7)"

read -r -d '' OLD <<'PORT_EOF' || true
				list_for_each_entry(entry,
						&tbl->head_flt_rule_list,
						link) {
					if (ipa_generate_flt_hw_rule(ip, entry,
							ftbl_membody)) {
						IPAERR("fail gen FLT rule\n");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				list_for_each_entry(entry,
						&tbl->head_flt_rule_list,
						link) {

                    /* VLOŽIT SEM (pro DDR kopii roury): */
                    pr_err("[GOLDEN_FLT] ROURA_SYS %d | Akce:%d | Cíl RT:%d\n",
                           i, entry->rule.action, 
                           entry->rt_tbl ? entry->rt_tbl->idx : entry->rule.rt_tbl_idx);

					if (ipa_generate_flt_hw_rule(ip, entry,
							ftbl_membody)) {
						IPAERR("fail gen FLT rule\n");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_flt.c" "[GOLDEN_FLT] HW filter-rule generation dump (#7/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	desc.type = IPA_IMM_CMD_DESC;
	IPA_DUMP_BUFF(mem->base, mem->phys_base, mem->size);

	if (ipa_send_cmd(1, &desc)) {
		IPAERR("fail to send immediate command\n");
		goto fail_send_cmd;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	desc.type = IPA_IMM_CMD_DESC;
	IPA_DUMP_BUFF(mem->base, mem->phys_base, mem->size);

	if (mem && mem->size && mem->base) {
		print_hex_dump(KERN_ERR, "[DUMP_RT_MEM] ", DUMP_PREFIX_OFFSET,
			       16, 4, mem->base, mem->size, false);
	}

	if (ipa_send_cmd(1, &desc)) {
		IPAERR("fail to send immediate command\n");
		goto fail_send_cmd;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_rt.c" "[DUMP_RT_MEM] routing-table body hexdump at commit"

read -r -d '' OLD <<'PORT_EOF' || true
		desc[1].len = sizeof(struct ipa_hw_imm_cmd_dma_shared_mem);
		desc[1].type = IPA_IMM_CMD_DESC;

		if (ipa_send_cmd(2, desc)) {
			IPAERR("fail to send immediate command\n");
			rc = -EFAULT;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		desc[1].len = sizeof(struct ipa_hw_imm_cmd_dma_shared_mem);
		desc[1].type = IPA_IMM_CMD_DESC;

	if (body.size && body.base) {
		print_hex_dump(KERN_ERR, "[DUMP_RT_BODY] ", DUMP_PREFIX_OFFSET,
			       16, 4, body.base, body.size, false);
	}
	if (head.size && head.base) {
		print_hex_dump(KERN_ERR, "[DUMP_RT_HEAD] ", DUMP_PREFIX_OFFSET,
			       16, 4, head.base, head.size, false);
	}

		if (ipa_send_cmd(2, desc)) {
			IPAERR("fail to send immediate command\n");
			rc = -EFAULT;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_rt.c" "[DUMP_RT_BODY/HEAD] v2 routing-table hexdumps at commit"

read -r -d '' OLD <<'PORT_EOF' || true
	set = &ipa_ctx->rt_tbl_set[ip];
	list_for_each_entry(tbl, &set->head_rt_tbl_list, link) {
		if (!tbl->in_sys) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	set = &ipa_ctx->rt_tbl_set[ip];
	list_for_each_entry(tbl, &set->head_rt_tbl_list, link) {
		pr_err("[GOLDEN_RT] table '%s' | idx %d | rules %d | in_sys %s\n",
		       tbl->name ? tbl->name : "NONAME", tbl->idx,
		       tbl->rule_cnt, tbl->in_sys ? "yes" : "no");
		list_for_each_entry(entry, &tbl->head_rt_rule_list, link) {
			pr_err("[GOLDEN_RT]   rule id %d | dst client %d (pipe %d) | hdr_hdl 0x%x\n",
			       entry->id, entry->rule.dst,
			       ipa2_get_ep_mapping(entry->rule.dst),
			       entry->rule.hdr_hdl);
		}
		if (!tbl->in_sys) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_rt.c" "[GOLDEN_RT] routing-table content dump at HW-rule generation"


section "Pipe setup & datapath diagnostics"
read -r -d '' OLD <<'PORT_EOF' || true
	tx_pkt = kmem_cache_zalloc(ipa_ctx->tx_pkt_wrapper_cache, mem_flag);
	if (unlikely(!tx_pkt)) {
		IPAERR("failed to alloc tx wrapper\n");
		goto fail_mem_alloc;
	}

	if (!desc->dma_address_valid) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	tx_pkt = kmem_cache_zalloc(ipa_ctx->tx_pkt_wrapper_cache, mem_flag);
	if (unlikely(!tx_pkt)) {
		IPAERR("failed to alloc tx wrapper\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_mem_alloc at %s:%d\n", __func__, __LINE__); goto fail_mem_alloc;
	}

	if (!desc->dma_address_valid) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#3)"

read -r -d '' OLD <<'PORT_EOF' || true
	}
	if (dma_mapping_error(ipa_ctx->pdev, dma_address)) {
		IPAERR("dma_map_single failed\n");
		goto fail_dma_map;
	}

	INIT_LIST_HEAD(&tx_pkt->link);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}
	if (dma_mapping_error(ipa_ctx->pdev, dma_address)) {
		IPAERR("dma_map_single failed\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_dma_map at %s:%d\n", __func__, __LINE__); goto fail_dma_map;
	}

	INIT_LIST_HEAD(&tx_pkt->link);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#4)"

read -r -d '' OLD <<'PORT_EOF' || true
 */
int ipa2_setup_sys_pipe(struct ipa_sys_connect_params *sys_in, u32 *clnt_hdl)
{
	struct ipa_ep_context *ep;
	int ipa_ep_idx;
	int result = -EINVAL;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
 */
int ipa2_setup_sys_pipe(struct ipa_sys_connect_params *sys_in, u32 *clnt_hdl)
{
	pr_err("[SETUP_PIPE_DIAG] entry: client=%d\n",
		sys_in ? sys_in->client : -1);

	struct ipa_ep_context *ep;
	int ipa_ep_idx;
	int result = -EINVAL;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#10)"

read -r -d '' OLD <<'PORT_EOF' || true

	if (sys_in == NULL || clnt_hdl == NULL) {
		IPAERR("NULL args\n");
		goto fail_gen;
	}

	if (sys_in->client >= IPA_CLIENT_MAX || sys_in->desc_fifo_sz == 0) {
		IPAERR("bad parm client:%d fifo_sz:%d\n",
			sys_in->client, sys_in->desc_fifo_sz);
		goto fail_gen;
	}

	ipa_ep_idx = ipa2_get_ep_mapping(sys_in->client);
	if (unlikely(ipa_ep_idx == -1)) {
		IPAERR("Invalid client.\n");
		goto fail_gen;
	}

	ep = &ipa_ctx->ep[ipa_ep_idx];
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

	if (sys_in == NULL || clnt_hdl == NULL) {
		IPAERR("NULL args\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_gen at %s:%d\n", __func__, __LINE__); goto fail_gen;
	}

	if (sys_in->client >= IPA_CLIENT_MAX || sys_in->desc_fifo_sz == 0) {
		IPAERR("bad parm client:%d fifo_sz:%d\n",
			sys_in->client, sys_in->desc_fifo_sz);
		pr_err("[SETUP_PIPE_DIAG] goto fail_gen at %s:%d\n", __func__, __LINE__); goto fail_gen;
	}

	ipa_ep_idx = ipa2_get_ep_mapping(sys_in->client);
	if (unlikely(ipa_ep_idx == -1)) {
		IPAERR("Invalid client.\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_gen at %s:%d\n", __func__, __LINE__); goto fail_gen;
	}

	ep = &ipa_ctx->ep[ipa_ep_idx];
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#11)"

read -r -d '' OLD <<'PORT_EOF' || true
	if (ep->valid == 1) {
		if (sys_in->client != IPA_CLIENT_APPS_LAN_WAN_PROD) {
			IPAERR("EP already allocated.\n");
			goto fail_and_disable_clocks;
		} else {
			if (ipa2_cfg_ep_hdr(ipa_ep_idx,
						&sys_in->ipa_ep_cfg.hdr)) {
				IPAERR("fail to configure hdr prop of EP.\n");
				result = -EFAULT;
				goto fail_and_disable_clocks;
			}
			if (ipa2_cfg_ep_cfg(ipa_ep_idx,
						&sys_in->ipa_ep_cfg.cfg)) {
				IPAERR("fail to configure cfg prop of EP.\n");
				result = -EFAULT;
				goto fail_and_disable_clocks;
			}
			IPADBG("client %d (ep: %d) overlay ok sys=%p\n",
					sys_in->client, ipa_ep_idx, ep->sys);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (ep->valid == 1) {
		if (sys_in->client != IPA_CLIENT_APPS_LAN_WAN_PROD) {
			IPAERR("EP already allocated.\n");
			pr_err("[SETUP_PIPE_DIAG] goto fail_and_disable_clocks at %s:%d\n", __func__, __LINE__); goto fail_and_disable_clocks;
		} else {
			if (ipa2_cfg_ep_hdr(ipa_ep_idx,
						&sys_in->ipa_ep_cfg.hdr)) {
				IPAERR("fail to configure hdr prop of EP.\n");
				result = -EFAULT;
				pr_err("[SETUP_PIPE_DIAG] goto fail_and_disable_clocks at %s:%d\n", __func__, __LINE__); goto fail_and_disable_clocks;
			}
			if (ipa2_cfg_ep_cfg(ipa_ep_idx,
						&sys_in->ipa_ep_cfg.cfg)) {
				IPAERR("fail to configure cfg prop of EP.\n");
				result = -EFAULT;
				pr_err("[SETUP_PIPE_DIAG] goto fail_and_disable_clocks at %s:%d\n", __func__, __LINE__); goto fail_and_disable_clocks;
			}
			IPADBG("client %d (ep: %d) overlay ok sys=%p\n",
					sys_in->client, ipa_ep_idx, ep->sys);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#12)"

read -r -d '' OLD <<'PORT_EOF' || true
			IPAERR("failed to sys ctx for client %d\n",
					sys_in->client);
			result = -ENOMEM;
			goto fail_and_disable_clocks;
		}

		ep->sys->ep = ep;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			IPAERR("failed to sys ctx for client %d\n",
					sys_in->client);
			result = -ENOMEM;
			pr_err("[SETUP_PIPE_DIAG] goto fail_and_disable_clocks at %s:%d\n", __func__, __LINE__); goto fail_and_disable_clocks;
		}

		ep->sys->ep = ep;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#13)"

read -r -d '' OLD <<'PORT_EOF' || true
			IPAERR("failed to create wq for client %d\n",
					sys_in->client);
			result = -EFAULT;
			goto fail_wq;
		}

		snprintf(buff, IPA_RESOURCE_NAME_MAX, "iparepwq%d",
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			IPAERR("failed to create wq for client %d\n",
					sys_in->client);
			result = -EFAULT;
			pr_err("[SETUP_PIPE_DIAG] goto fail_wq at %s:%d\n", __func__, __LINE__); goto fail_wq;
		}

		snprintf(buff, IPA_RESOURCE_NAME_MAX, "iparepwq%d",
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#14)"

read -r -d '' OLD <<'PORT_EOF' || true
			IPAERR("failed to create rep wq for client %d\n",
					sys_in->client);
			result = -EFAULT;
			goto fail_wq2;
		}

		INIT_LIST_HEAD(&ep->sys->head_desc_list);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			IPAERR("failed to create rep wq for client %d\n",
					sys_in->client);
			result = -EFAULT;
			pr_err("[SETUP_PIPE_DIAG] goto fail_wq2 at %s:%d\n", __func__, __LINE__); goto fail_wq2;
		}

		INIT_LIST_HEAD(&ep->sys->head_desc_list);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#15)"

read -r -d '' OLD <<'PORT_EOF' || true
	if (ipa_assign_policy(sys_in, ep->sys)) {
		IPAERR("failed to sys ctx for client %d\n", sys_in->client);
		result = -ENOMEM;
		goto fail_gen2;
	}

	ep->valid = 1;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (ipa_assign_policy(sys_in, ep->sys)) {
		IPAERR("failed to sys ctx for client %d\n", sys_in->client);
		result = -ENOMEM;
		pr_err("[SETUP_PIPE_DIAG] goto fail_gen2 at %s:%d\n", __func__, __LINE__); goto fail_gen2;
	}

	ep->valid = 1;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#16)"

read -r -d '' OLD <<'PORT_EOF' || true
			kzalloc(sizeof(struct ipa_status_stats), GFP_KERNEL);
		if (!ep->sys->status_stat) {
			IPAERR("no memory\n");
			goto fail_gen2;
		}
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			kzalloc(sizeof(struct ipa_status_stats), GFP_KERNEL);
		if (!ep->sys->status_stat) {
			IPAERR("no memory\n");
			pr_err("[SETUP_PIPE_DIAG] goto fail_gen2 at %s:%d\n", __func__, __LINE__); goto fail_gen2;
		}
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#17)"

read -r -d '' OLD <<'PORT_EOF' || true
	if (result) {
		IPAERR("enable data path failed res=%d clnt=%d.\n", result,
				ipa_ep_idx);
		goto fail_gen2;
	}

	if (!ep->skip_ep_cfg) {
		if (ipa2_cfg_ep(ipa_ep_idx, &sys_in->ipa_ep_cfg)) {
			IPAERR("fail to configure EP.\n");
			goto fail_gen2;
		}
		if (ipa2_cfg_ep_status(ipa_ep_idx, &ep->status)) {
			IPAERR("fail to configure status of EP.\n");
			goto fail_gen2;
		}
		IPADBG("ep configuration successful\n");
	} else {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (result) {
		IPAERR("enable data path failed res=%d clnt=%d.\n", result,
				ipa_ep_idx);
		pr_err("[SETUP_PIPE_DIAG] goto fail_gen2 at %s:%d\n", __func__, __LINE__); goto fail_gen2;
	}

	if (!ep->skip_ep_cfg) {
		if (ipa2_cfg_ep(ipa_ep_idx, &sys_in->ipa_ep_cfg)) {
			IPAERR("fail to configure EP.\n");
			pr_err("[SETUP_PIPE_DIAG] goto fail_gen2 at %s:%d\n", __func__, __LINE__); goto fail_gen2;
		}
		if (ipa2_cfg_ep_status(ipa_ep_idx, &ep->status)) {
			IPAERR("fail to configure status of EP.\n");
			pr_err("[SETUP_PIPE_DIAG] goto fail_gen2 at %s:%d\n", __func__, __LINE__); goto fail_gen2;
		}
		IPADBG("ep configuration successful\n");
	} else {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#18)"

read -r -d '' OLD <<'PORT_EOF' || true
	ep->ep_hdl = sps_alloc_endpoint();
	if (ep->ep_hdl == NULL) {
		IPAERR("SPS EP allocation failed.\n");
		goto fail_gen2;
	}

	result = sps_get_config(ep->ep_hdl, &ep->connect);
	if (result) {
		IPAERR("fail to get config.\n");
		goto fail_sps_cfg;
	}

	/* Specific Config */
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	ep->ep_hdl = sps_alloc_endpoint();
	if (ep->ep_hdl == NULL) {
		IPAERR("SPS EP allocation failed.\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_gen2 at %s:%d\n", __func__, __LINE__); goto fail_gen2;
	}

	result = sps_get_config(ep->ep_hdl, &ep->connect);
	if (result) {
		IPAERR("fail to get config.\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_sps_cfg at %s:%d\n", __func__, __LINE__); goto fail_sps_cfg;
	}

	/* Specific Config */
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#19)"

read -r -d '' OLD <<'PORT_EOF' || true
	}
	if (ep->connect.desc.base == NULL) {
		IPAERR("fail to get DMA desc memory.\n");
		goto fail_sps_cfg;
	}

	ep->connect.event_thresh = IPA_EVENT_THRESHOLD;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}
	if (ep->connect.desc.base == NULL) {
		IPAERR("fail to get DMA desc memory.\n");
		pr_err("[SETUP_PIPE_DIAG] goto fail_sps_cfg at %s:%d\n", __func__, __LINE__); goto fail_sps_cfg;
	}

	ep->connect.event_thresh = IPA_EVENT_THRESHOLD;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[SETUP_PIPE_DIAG] tagged error-paths in ipa2_setup_sys_pipe (#20)"

read -r -d '' OLD <<'PORT_EOF' || true
				 * proper deaggr STATUS path runs (since AGG_GRO is off) */
				sys->ep->status.status_en = true;
				ipa_ctx->ipa_client_apps_wan_cons_agg_gro = false;
			}
		}
	} else if (IPA_CLIENT_IS_WLAN_CONS(in->client)) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				 * proper deaggr STATUS path runs (since AGG_GRO is off) */
				sys->ep->status.status_en = true;
				ipa_ctx->ipa_client_apps_wan_cons_agg_gro = false;
				pr_info("[NO_AGG] pipe %u (APPS_WAN_CONS): aggr_en=BYPASS, SW AGG_GRO=false, status_en=true, single-buffer passthrough\n",
					in->client);
			}
		}
	} else if (IPA_CLIENT_IS_WLAN_CONS(in->client)) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[NO_AGG] log when the AGG-bypass A/B knob is active"

read -r -d '' OLD <<'PORT_EOF' || true
		if (ret)
			break;

		ipa_wq_rx_common(ep->sys, iov.size);
		cnt += IPA_WAN_AGGR_PKT_CNT;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		if (ret)
			break;

		if (ipa_sonda_dbg)
			pr_err("[WAN_RX_IOV] cnt=%d clnt=%u addr=0x%llx size=%u flags=0x%x\n",
			       cnt, clnt_hdl, (unsigned long long)iov.addr,
			       iov.size, iov.flags);
		ipa_wq_rx_common(ep->sys, iov.size);
		cnt += IPA_WAN_AGGR_PKT_CNT;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "[WAN_RX_IOV] per-iovec WAN RX dump (tier-2 gated)"

read -r -d '' OLD <<'PORT_EOF' || true
				  in->u.ingress_format.agg_size,
				  in->u.ingress_format.agg_count);

		ret = ipa_disable_apps_wan_cons_deaggr(
			  in->u.ingress_format.agg_size,
			  in->u.ingress_format.agg_count);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				  in->u.ingress_format.agg_size,
				  in->u.ingress_format.agg_count);

		pr_err("[INGRESS_DIAG] calling ipa_disable_apps_wan_cons_deaggr\n");
		ret = ipa_disable_apps_wan_cons_deaggr(
			  in->u.ingress_format.agg_size,
			  in->u.ingress_format.agg_count);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[INGRESS_DIAG] deaggr decision + setup_sys_pipe result"

read -r -d '' OLD <<'PORT_EOF' || true
		mutex_unlock(&ipa_to_apps_pipe_handle_guard);
		return -EFAULT;
	}
	ret = ipa2_setup_sys_pipe(&ipa_to_apps_ep_cfg, &ipa_to_apps_hdl);
	mutex_unlock(&ipa_to_apps_pipe_handle_guard);

	if (ret)
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		mutex_unlock(&ipa_to_apps_pipe_handle_guard);
		return -EFAULT;
	}
	pr_err("[INGRESS_DIAG] before ipa2_setup_sys_pipe: client=%d desc_fifo_sz=%u\n",
		ipa_to_apps_ep_cfg.client, ipa_to_apps_ep_cfg.desc_fifo_sz);
	ret = ipa2_setup_sys_pipe(&ipa_to_apps_ep_cfg, &ipa_to_apps_hdl);
	pr_err("[INGRESS_DIAG] ipa2_setup_sys_pipe ret=%d hdl=%u\n", ret, ipa_to_apps_hdl);
	mutex_unlock(&ipa_to_apps_pipe_handle_guard);

	if (ret)
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[INGRESS_DIAG] pipe-5 config before/after"

read -r -d '' OLD <<'PORT_EOF' || true
	IPAWANDBG("Get RMNET_IOCTL_SET_INGRESS_DATA_FORMAT\n");
	if ((in->u.data) & RMNET_IOCTL_INGRESS_FORMAT_CHECKSUM)
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	IPAWANDBG("Get RMNET_IOCTL_SET_INGRESS_DATA_FORMAT\n");
	pr_err("[INGRESS_DIAG] entry: u.data=0x%x agg_size=%u agg_count=%u\n",
		in->u.data, in->u.ingress_format.agg_size,
		in->u.ingress_format.agg_count);
	if ((in->u.data) & RMNET_IOCTL_INGRESS_FORMAT_CHECKSUM)
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[INGRESS_DIAG] SET_INGRESS_DATA_FORMAT entry args"

read -r -d '' OLD <<'PORT_EOF' || true
			if (rc)
				IPAWANERR("failed to config egress endpoint\n");

			if (num_q6_rule != 0) {
				/* already got Q6 UL filter rules*/
				if (ipa_qmi_ctx &&
					!ipa_qmi_ctx->modem_cfg_emb_pipe_flt) {
					/* protect num_q6_rule */
					mutex_lock(&add_mux_channel_lock);
					rc = wwan_add_ul_flt_rule_to_ipa();
					mutex_unlock(&add_mux_channel_lock);
				} else
					rc = 0;
				egress_set = true;
				if (rc)
					IPAWANERR("install UL rules failed\n");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			if (rc)
				IPAWANERR("failed to config egress endpoint\n");

			pr_err("[NUM_Q6_DIAG] SET_EGRESS check: num_q6_rule=%d\n", num_q6_rule);
			if (num_q6_rule != 0) {
				/* already got Q6 UL filter rules*/
                pr_err("[EMB_PIPE_DIAG] num_q6=%d, modem_cfg_emb_pipe_flt=%d\n", num_q6_rule, ipa_qmi_ctx ? ipa_qmi_ctx->modem_cfg_emb_pipe_flt : -1);
				if (ipa_qmi_ctx &&
					!ipa_qmi_ctx->modem_cfg_emb_pipe_flt) {
					/* protect num_q6_rule */
					mutex_lock(&add_mux_channel_lock);
					rc = wwan_add_ul_flt_rule_to_ipa();
                    pr_err("[EMB_PIPE_DIAG] wwan_add_ul_flt_rule_to_ipa returned rc=%d\n", rc);
					mutex_unlock(&add_mux_channel_lock);
				} else
                {
                    pr_err("[EMB_PIPE_DIAG] SKIPPED install (modem_cfg_emb_pipe_flt=TRUE)\n");
					rc = 0;
                }
				egress_set = true;
				if (rc)
					IPAWANERR("install UL rules failed\n");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[NUM_Q6_DIAG]+[EMB_PIPE_DIAG] egress: Q6-rule install decision"

read -r -d '' OLD <<'PORT_EOF' || true
			 * the IP stack since the src IP equals our own qmapmux0.0
			 * address (it's our own UL packet that didn't pass HW filter).
			 */
			dev_kfree_skb_any(skb);
			dev->stats.tx_dropped++;
			return;
		case IPA_CLIENT_START_POLL:
		case IPA_CLIENT_COMP_NAPI:
			return;
		default:
			dev_kfree_skb_any(skb);
			dev->stats.tx_dropped++;
			return;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			 * the IP stack since the src IP equals our own qmapmux0.0
			 * address (it's our own UL packet that didn't pass HW filter).
			 */
			if (printk_ratelimit() && skb->len >= 8) {
				u8 *p = skb->data;
				pr_err("[TX_EXCP] DROP UL exception loopback len=%u op=0x%02x excp=0x%02x mask=0x%02x%02x pktlen=%u src=%u dst=%u\n",
				       skb->len, p[0], p[1], p[3], p[2],
				       (p[4] | (p[5] << 8)),
				       p[6] & 0x1f, p[7] & 0x1f);
			}
			dev_kfree_skb_any(skb);
			dev->stats.tx_dropped++;
			return;
		case IPA_CLIENT_START_POLL:
		case IPA_CLIENT_COMP_NAPI:
			/* NAPI signaling - data might NOT be skb! Don't free. */
			IPAWANDBG("[TX_EVT_FIX] NAPI evt=%d on TX (no-op)\n", evt);
			return;
		default:
			IPAWANERR("[TX_EVT_FIX] truly unknown evt=%d, drop\n", evt);
			dev_kfree_skb_any(skb);
			dev->stats.tx_dropped++;
			return;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[TX_EXCP] ratelimited UL exception-loopback header dump"

read -r -d '' OLD <<'PORT_EOF' || true
		goto fail_apps_pipes;
	}
	IPADBG("empty routing table was allocated in system memory");

	/* setup the A5-IPA pipes */
	if (ipa_setup_apps_pipes()) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		goto fail_apps_pipes;
	}
	IPADBG("empty routing table was allocated in system memory");
	pr_err("[EMPTY_RT_DIAG] base=%p phys_base=0x%llx size=%u\n",
		ipa_ctx->empty_rt_tbl_mem.base,
		(unsigned long long)ipa_ctx->empty_rt_tbl_mem.phys_base,
		ipa_ctx->empty_rt_tbl_mem.size);
	pr_err("[EMPTY_RT_DIAG] dma_mask=0x%llx coherent_mask=0x%llx\n",
		ipa_ctx->pdev->dma_mask ? *ipa_ctx->pdev->dma_mask : 0ULL,
		ipa_ctx->pdev->coherent_dma_mask);
	pr_err("[EMPTY_RT_DIAG] of_node=%p iommu_group=%p\n",
		ipa_ctx->pdev->of_node,
		ipa_ctx->pdev->iommu_group);

	/* setup the A5-IPA pipes */
	if (ipa_setup_apps_pipes()) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "[EMPTY_RT_DIAG] empty-rt-table DMA address sanity dump"


section "auto-IPACM verbose progress logging"
read -r -d '' OLD <<'PORT_EOF' || true
	param->ip = IPA_IP_v4;
	flt_rule->rule.eq_attrib.protocol_eq = 1;  /* ICMP */
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_icmp_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	param->ip = IPA_IP_v4;
	flt_rule->rule.eq_attrib.protocol_eq = 1;  /* ICMP */
	rc = ipa2_add_flt_rule(param);
	if (rc) {
		pr_err("[ICMP_RULE] v4 install FAILED rc=%d\n", rc);
	} else {
		pr_info("[ICMP_RULE] v4 install OK hdl=0x%x\n",
			param->rules[0].flt_rule_hdl);
		wan_dl_flt_icmp_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#1/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.protocol_eq = 58;  /* ICMPv6 next_hdr */
	flt_rule->flt_rule_hdl = -1;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_icmp_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.protocol_eq = 58;  /* ICMPv6 next_hdr */
	flt_rule->flt_rule_hdl = -1;
	rc = ipa2_add_flt_rule(param);
	if (rc) {
		pr_err("[ICMP_RULE] v6 install FAILED rc=%d\n", rc);
	} else {
		pr_info("[ICMP_RULE] v6 install OK hdl=0x%x\n",
			param->rules[0].flt_rule_hdl);
		wan_dl_flt_icmp_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#2/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xE0000000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xF0000000;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_mcast_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xE0000000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xF0000000;
	rc = ipa2_add_flt_rule(param);
	if (rc) {
		pr_err("[MCAST_BCAST] v4 mcast install FAILED rc=%d\n", rc);
	} else {
		pr_info("[MCAST_BCAST] v4 mcast install OK hdl=0x%x\n",
			param->rules[0].flt_rule_hdl);
		wan_dl_flt_mcast_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#3/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFFFFFFFF;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFFFFFFFF;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_bcast_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFFFFFFFF;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFFFFFFFF;
	rc = ipa2_add_flt_rule(param);
	if (rc) {
		pr_err("[MCAST_BCAST] v4 bcast install FAILED rc=%d\n", rc);
	} else {
		pr_info("[MCAST_BCAST] v4 bcast install OK hdl=0x%x\n",
			param->rules[0].flt_rule_hdl);
		wan_dl_flt_bcast_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#4/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFF000000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFF000000;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_mcast_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFF000000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFF000000;
	rc = ipa2_add_flt_rule(param);
	if (rc) {
		pr_err("[MCAST_BCAST] v6 mcast install FAILED rc=%d\n", rc);
	} else {
		pr_info("[MCAST_BCAST] v6 mcast install OK hdl=0x%x\n",
			param->rules[0].flt_rule_hdl);
		wan_dl_flt_mcast_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#5/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFE800000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFFC00000;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_lnklcl_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFE800000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFFC00000;
	rc = ipa2_add_flt_rule(param);
	if (rc) {
		pr_err("[MCAST_BCAST] v6 link-local install FAILED rc=%d\n", rc);
	} else {
		pr_info("[MCAST_BCAST] v6 link-local install OK hdl=0x%x\n",
			param->rules[0].flt_rule_hdl);
		wan_dl_flt_lnklcl_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#6/21)"

read -r -d '' OLD <<'PORT_EOF' || true
				    ext_q->num_ext_props > 0) {
					dl_mux_id     = ext_q->ext[0].mux_id;
					dl_rt_tbl_idx = ext_q->ext[0].rt_tbl_idx;
				}
				kfree(ext_q);
			}
		}
	}

	req = kzalloc(sizeof(*req), GFP_KERNEL);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				    ext_q->num_ext_props > 0) {
					dl_mux_id     = ext_q->ext[0].mux_id;
					dl_rt_tbl_idx = ext_q->ext[0].rt_tbl_idx;
					pr_info("[WAN_DL_QMI] queried %s ext_props[0]: mux_id=%u rt_tbl_idx=%u (was hardcoded 1/8)\n",
						vc, dl_mux_id, dl_rt_tbl_idx);
				} else {
					pr_info("[WAN_DL_QMI] ext_props query failed, using fallback mux_id=1 rt_tbl_idx=8\n");
				}
				kfree(ext_q);
			}
		} else {
			pr_info("[WAN_DL_QMI] intf %s not registered yet (num_q6_rule=%d), using fallback\n",
				vc, num_q6_rule);
		}
	} else {
		pr_info("[WAN_DL_QMI] no mux channels registered, using fallback mux_id=1 rt_tbl_idx=8\n");
	}

	req = kzalloc(sizeof(*req), GFP_KERNEL);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#7/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	spec->filter_rule.offset_meq_32[0].value  = 0xFE800000;
	spec->filter_rule.offset_meq_32[0].mask   = 0xFFC00000;

	rc = qmi_filter_request_send(req);
	if (rc) {
		kfree(req);
		return rc;
	}

	kfree(req);
	return 0;
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	spec->filter_rule.offset_meq_32[0].value  = 0xFE800000;
	spec->filter_rule.offset_meq_32[0].mask   = 0xFFC00000;

	pr_info("[WAN_DL_QMI] Sending INSTALL_FILTER_RULE (6 specs: v4 icmp+mcast+bcast, v6 icmp+mcast+lnklcl) to modem Q6\n");
	rc = qmi_filter_request_send(req);
	if (rc) {
		pr_err("[WAN_DL_QMI] qmi_filter_request_send FAILED rc=%d\n", rc);
		kfree(req);
		return rc;
	}

	pr_info("[WAN_DL_QMI] INSTALL_FILTER_RULE OK — modem Q6 should now HW-accelerate DL forwarding\n");
	kfree(req);
	return 0;
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#8/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	req->embedded_call_mux_id_valid = 1;
	req->embedded_call_mux_id = 1;

	rc = qmi_filter_notify_send(req);
	if (rc) {
		kfree(req);
		return rc;
	}

	kfree(req);
	return 0;
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	req->embedded_call_mux_id_valid = 1;
	req->embedded_call_mux_id = 1;

	pr_info("[WAN_DL_NOTIF] Sending FILTER_INSTALLED_NOTIF (6 handles) to modem Q6\n");
	rc = qmi_filter_notify_send(req);
	if (rc) {
		pr_err("[WAN_DL_NOTIF] qmi_filter_notify_send FAILED rc=%d\n", rc);
		kfree(req);
		return rc;
	}

	pr_info("[WAN_DL_NOTIF] FILTER_INSTALLED_NOTIF OK — modem confirmed A7 install\n");
	kfree(req);
	return 0;
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#9/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	int rc;

	if (atomic_read(&auto_ipacm_init_done)) {
		return;
	}

	if (!dev) {
		schedule_delayed_work(&auto_ipacm_init_work,
				      msecs_to_jiffies(1000));
		return;
	}

	/* 1) SET_EGRESS_DATA_FORMAT (data=0x06: MAP + AGG, no CHECKSUM)
	 *
	 * Phase 4k throughput optimization. Previously data=0x02 (MAP only)
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	int rc;

	if (atomic_read(&auto_ipacm_init_done)) {
		pr_info("[AUTO_IPACM] already done, skipping\n");
		return;
	}

	if (!dev) {
		pr_info("[AUTO_IPACM] rmnet_ipa0 not registered yet, retry in 1s\n");
		schedule_delayed_work(&auto_ipacm_init_work,
				      msecs_to_jiffies(1000));
		return;
	}

	pr_info("[AUTO_IPACM] starting on %s (num_q6_rule=%d)\n",
		dev->name, num_q6_rule);

	/* 1) SET_EGRESS_DATA_FORMAT (data=0x06: MAP + AGG, no CHECKSUM)
	 *
	 * Phase 4k throughput optimization. Previously data=0x02 (MAP only)
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#10/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	 *  - Smaller byte/pkt limits keep TCP ACKs flushing promptly
	 *  - Less buffering delay on the predominantly small UL traffic
	 *  - HW behavior matches what modem expects
	 */
	memset(&apps_to_ipa_ep_cfg, 0, sizeof(apps_to_ipa_ep_cfg));
	if (qmapv3_ul_enable) {
		/* QMAPv3 UL: matches lineage-sdm660-22.2/.../rmnet_ipa.c:1675-1678
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	 *  - Smaller byte/pkt limits keep TCP ACKs flushing promptly
	 *  - Less buffering delay on the predominantly small UL traffic
	 *  - HW behavior matches what modem expects
	 */
	pr_info("[AUTO_IPACM] step 1/3: SET_EGRESS_DATA_FORMAT (MAP+AGG vendor defaults%s)\n",
		qmapv3_ul_enable ? ", +QMAPv3-UL" : "");
	memset(&apps_to_ipa_ep_cfg, 0, sizeof(apps_to_ipa_ep_cfg));
	if (qmapv3_ul_enable) {
		/* QMAPv3 UL: matches lineage-sdm660-22.2/.../rmnet_ipa.c:1675-1678
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#11/21)"

read -r -d '' OLD <<'PORT_EOF' || true

	rc = ipa2_setup_sys_pipe(&apps_to_ipa_ep_cfg, &apps_to_ipa_hdl);
	if (rc) {
		return;
	}
	egress_set = true;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

	rc = ipa2_setup_sys_pipe(&apps_to_ipa_ep_cfg, &apps_to_ipa_hdl);
	if (rc) {
		pr_err("[AUTO_IPACM] EGRESS setup_sys_pipe failed: %d\n", rc);
		return;
	}
	egress_set = true;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#12/21)"

read -r -d '' OLD <<'PORT_EOF' || true
		rc = wwan_add_ul_flt_rule_to_ipa();
		mutex_unlock(&add_mux_channel_lock);
		if (rc)
			;
		else
			a7_ul_flt_set = true;
	}

	/* Phase 4s: explicit ICMP catchall rule (v4 + v6).
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		rc = wwan_add_ul_flt_rule_to_ipa();
		mutex_unlock(&add_mux_channel_lock);
		if (rc)
			pr_err("[AUTO_IPACM] wwan_add_ul_flt_rule_to_ipa rc=%d\n",
			       rc);
		else
			a7_ul_flt_set = true;
	} else {
		pr_info("[AUTO_IPACM] no Q6 UL rules cached yet, EGRESS marked set\n");
	}

	/* Phase 4s: explicit ICMP catchall rule (v4 + v6).
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#13/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	 * for ICMP packets. Vendor IPACM does this in config_dft_firewall_rules.
	 */
	rc = install_icmp_passthrough_rule();

	/* Phase 1: mcast + bcast filter rules (matching vendor IPACM minimum
	 * DL acceleration rule set). Together with ICMP rule above = 3 specs
	 * that get sent to modem in Phase 2 QMI handshake below. */
	rc = install_mcast_bcast_filter_rules();

	/* Phase 2: send QMI INSTALL_FILTER_RULE (msg 0x0023) to modem Q6.
	 * This is the CRITICAL HANDSHAKE that engages modem-side HW DL
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	 * for ICMP packets. Vendor IPACM does this in config_dft_firewall_rules.
	 */
	rc = install_icmp_passthrough_rule();
	if (rc)
		pr_err("[AUTO_IPACM] ICMP passthrough rule install rc=%d\n", rc);
	else
		pr_info("[AUTO_IPACM] step 1b: ICMP passthrough rules installed (v4+v6)\n");

	/* Phase 1: mcast + bcast filter rules (matching vendor IPACM minimum
	 * DL acceleration rule set). Together with ICMP rule above = 3 specs
	 * that get sent to modem in Phase 2 QMI handshake below. */
	rc = install_mcast_bcast_filter_rules();
	if (rc)
		pr_err("[AUTO_IPACM] mcast/bcast rule install rc=%d\n", rc);
	else
		pr_info("[AUTO_IPACM] step 1c: mcast + bcast filter rules installed (v4)\n");

	/* Phase 2: send QMI INSTALL_FILTER_RULE (msg 0x0023) to modem Q6.
	 * This is the CRITICAL HANDSHAKE that engages modem-side HW DL
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#14/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	 * (= our 240 KB/s cap). With it, modem should HW-accelerate DL forwarding
	 * matching the 3 filter specs (icmp+mcast+bcast → rt_tbl_idx=8). */
	rc = install_wan_dl_qmi_filter_notify();

	/* Phase 3 (audit Finding D): FILTER_INSTALLED_NOTIF (msg 0x0024) after
	 * INSTALL_FILTER_RULE accepted. Tells modem we (AP) really installed
	 * matching specs on our end + provides A7-side handles. Modem firmware
	 * may require this confirmation before engaging HW accel. */
	rc = install_wan_dl_qmi_filter_installed_notif();

	/* 2) SET_INGRESS_DATA_FORMAT (data=0x3e, agg=8192/10)
	 *
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	 * (= our 240 KB/s cap). With it, modem should HW-accelerate DL forwarding
	 * matching the 3 filter specs (icmp+mcast+bcast → rt_tbl_idx=8). */
	rc = install_wan_dl_qmi_filter_notify();
	if (rc)
		pr_err("[AUTO_IPACM] WAN DL QMI filter notify rc=%d (modem may not HW-accel DL)\n", rc);
	else
		pr_info("[AUTO_IPACM] step 1d: WAN DL QMI INSTALL_FILTER_RULE sent to modem (DL HW accel engaged)\n");

	/* Phase 3 (audit Finding D): FILTER_INSTALLED_NOTIF (msg 0x0024) after
	 * INSTALL_FILTER_RULE accepted. Tells modem we (AP) really installed
	 * matching specs on our end + provides A7-side handles. Modem firmware
	 * may require this confirmation before engaging HW accel. */
	rc = install_wan_dl_qmi_filter_installed_notif();
	if (rc)
		pr_err("[AUTO_IPACM] WAN DL FILTER_INSTALLED_NOTIF rc=%d\n", rc);
	else
		pr_info("[AUTO_IPACM] step 1e: WAN DL FILTER_INSTALLED_NOTIF sent to modem (confirmation)\n");

	/* 2) SET_INGRESS_DATA_FORMAT (data=0x3e, agg=8192/10)
	 *
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#15/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	 * larger DL aggregation window showed no measurable benefit since
	 * carrier rate cap is the real DL bottleneck. Vendor sondas-derived
	 * 8K/10 matches stock Android behavior exactly.
	 */
	memset(&ext, 0, sizeof(ext));
	ext.extended_ioctl = RMNET_IOCTL_SET_INGRESS_DATA_FORMAT;
	ext.u.ingress_format.__data = RMNET_IOCTL_INGRESS_FORMAT_MAP
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	 * larger DL aggregation window showed no measurable benefit since
	 * carrier rate cap is the real DL bottleneck. Vendor sondas-derived
	 * 8K/10 matches stock Android behavior exactly.
	 */
	pr_info("[AUTO_IPACM] step 2/3: SET_INGRESS_DATA_FORMAT (agg 8K/10 vendor)\n");
	memset(&ext, 0, sizeof(ext));
	ext.extended_ioctl = RMNET_IOCTL_SET_INGRESS_DATA_FORMAT;
	ext.u.ingress_format.__data = RMNET_IOCTL_INGRESS_FORMAT_MAP
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#16/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	ext.u.ingress_format.agg_count = 10;
	rc = handle_ingress_format(dev, &ext);
	if (rc) {
		return;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	ext.u.ingress_format.agg_count = 10;
	rc = handle_ingress_format(dev, &ext);
	if (rc) {
		pr_err("[AUTO_IPACM] INGRESS handler failed: %d\n", rc);
		return;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#17/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	 * are scoped to mux_id=1. This is NOT a netdev create — vendor's
	 * register_to_ipa() only calls ipa_add_qmap_hdr + ipa2_register_intf_ext
	 * which is a string-keyed internal table.
	 */
	mutex_lock(&add_mux_channel_lock);
	if (rmnet_index >= MAX_NUM_OF_MUX_CHANNEL) {
		mutex_unlock(&add_mux_channel_lock);
		return;
	}
	mux_channel[rmnet_index].mux_id = 1;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	 * are scoped to mux_id=1. This is NOT a netdev create — vendor's
	 * register_to_ipa() only calls ipa_add_qmap_hdr + ipa2_register_intf_ext
	 * which is a string-keyed internal table.
	 */
	pr_info("[AUTO_IPACM] step 3/3: ADD_MUX_CHANNEL mux_id=1 vchannel=qmapmux0.0\n");
	mutex_lock(&add_mux_channel_lock);
	if (rmnet_index >= MAX_NUM_OF_MUX_CHANNEL) {
		mutex_unlock(&add_mux_channel_lock);
		pr_err("[AUTO_IPACM] mux channel table full\n");
		return;
	}
	mux_channel[rmnet_index].mux_id = 1;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#18/21)"

read -r -d '' OLD <<'PORT_EOF' || true
		rc = wwan_register_to_ipa(rmnet_index);
		if (rc < 0) {
			mutex_unlock(&add_mux_channel_lock);
			return;
		}
		mux_channel[rmnet_index].mux_channel_set = true;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		rc = wwan_register_to_ipa(rmnet_index);
		if (rc < 0) {
			mutex_unlock(&add_mux_channel_lock);
			pr_err("[AUTO_IPACM] wwan_register_to_ipa rc=%d\n", rc);
			return;
		}
		mux_channel[rmnet_index].mux_channel_set = true;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#19/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	mutex_unlock(&add_mux_channel_lock);

	atomic_set(&auto_ipacm_init_done, 1);

	/* Phase 4q: start tethering stats polling that vendor IPACM would
	 * normally trigger via WAN_IOC_POLL_TETHERING_STATS ioctl on /dev/ipa.
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	mutex_unlock(&add_mux_channel_lock);

	atomic_set(&auto_ipacm_init_done, 1);
	pr_info("[AUTO_IPACM] DONE — pipe 5 should be live now\n");

	/* Phase 4q: start tethering stats polling that vendor IPACM would
	 * normally trigger via WAN_IOC_POLL_TETHERING_STATS ioctl on /dev/ipa.
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#20/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	ipa_rmnet_ctx.polling_interval = 1;
	queue_delayed_work(system_power_efficient_wq,
			   &ipa_tether_stats_poll_wakequeue_work, 0);

}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	ipa_rmnet_ctx.polling_interval = 1;
	queue_delayed_work(system_power_efficient_wq,
			   &ipa_tether_stats_poll_wakequeue_work, 0);
	pr_info("[AUTO_IPACM] step 4/4: tethering stats polling started (%llus)\n",
		ipa_rmnet_ctx.polling_interval);

}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[AUTO_IPACM] verbose progress (#21/21)"

read -r -d '' OLD <<'PORT_EOF' || true
	for (i = 0; i < MAX_NUM_OF_MUX_CHANNEL; i++)
		memset(&mux_channel[i], 0, sizeof(struct rmnet_mux_val));

	/* start A7 QMI service/client */
	if (ipa_rmnet_res.ipa_loaduC)
		/* Android platform loads uC */
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	for (i = 0; i < MAX_NUM_OF_MUX_CHANNEL; i++)
		memset(&mux_channel[i], 0, sizeof(struct rmnet_mux_val));

	pr_err("[QMI_DIAG] probe calling ipa_qmi_service_init loaduC=%d\n",
		ipa_rmnet_res.ipa_loaduC);
	/* start A7 QMI service/client */
	if (ipa_rmnet_res.ipa_loaduC)
		/* Android platform loads uC */
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[QMI_DIAG] probe: ipa_qmi_service_init call"

read -r -d '' OLD <<'PORT_EOF' || true
	else
		/* LE platform not loads uC */
		ipa_qmi_service_init(QMI_IPA_PLATFORM_TYPE_LE_V01);

	/* construct default WAN RT tbl for IPACM */
	ret = ipa_setup_a7_qmap_hdr();
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	else
		/* LE platform not loads uC */
		ipa_qmi_service_init(QMI_IPA_PLATFORM_TYPE_LE_V01);
	pr_err("[QMI_DIAG] ipa_qmi_service_init returned\n");

	/* construct default WAN RT tbl for IPACM */
	ret = ipa_setup_a7_qmap_hdr();
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "[QMI_DIAG] probe: ipa_qmi_service_init returned"


section "Raw hardware state probes"
read -r -d '' OLD <<'PORT_EOF' || true
	u32 i = 0;
	u32 en;
	bool uc_irq;

	en = ipa_read_reg(ipa_ctx->mmio, IPA_IRQ_EN_EE_n_ADDR(ipa_ee));
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	u32 i = 0;
	u32 en;
	bool uc_irq;

	/* Clocks are on here, raw IRQ status registers are safe to read.
	 * Offsets 0x1008/0x1098 sit inside the mapped 0x4000 ipa-base. */
	if (ipa_sonda_dbg && ipa_ctx && ipa_ctx->mmio) {
		u32 ipa_stts = readl_relaxed(ipa_ctx->mmio + 0x1008);
		u32 uc_info = readl_relaxed(ipa_ctx->mmio + 0x1098);

		pr_err("[IRQ_STTS_DIAG] IRQ_STTS_EE0=0x%x SUSPEND_INFO_EE0=0x%x\n",
		       ipa_stts, uc_info);
	}

	en = ipa_read_reg(ipa_ctx->mmio, IPA_IRQ_EN_EE_n_ADDR(ipa_ee));
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_interrupts.c" "[IRQ_STTS_DIAG] raw IPA IRQ status registers (tier-2 gated)"

read -r -d '' OLD <<'PORT_EOF' || true
#include <linux/memory.h>
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
#include <linux/memory.h>
#include <linux/delay.h>	/* udelay() for the BAM_DIAG wake-test */
PORT_EOF
apply_edit "drivers/platform/msm/sps/bam.c" "[BAM_DIAG] include <linux/delay.h> for the wake-test"

read -r -d '' OLD <<'PORT_EOF' || true

	ver = bam_read_reg_field(base, REVISION, 0, BAM_REVISION);

	if ((ver < BAM_MIN_VERSION) || (ver > BAM_MAX_VERSION)) {
		SPS_ERR(dev, "sps:bam 0x%pK(va) Invalid BAM REVISION 0x%x.\n",
				dev->base, ver);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

	ver = bam_read_reg_field(base, REVISION, 0, BAM_REVISION);

	/*
	 * [BAM_DIAG] Enhanced diagnostic for register response.
	 * If REVISION is zero, attempt wake-up while logging CTRL register state
	 * before, between, and after SW_RST writes. This reveals whether hardware
	 * acknowledges writes (CTRL changes) or is gated entirely (CTRL frozen).
	 */
	if (ver == 0) {
		u32 ctrl0, ctrl1, ctrl2, ver2, irq_stts;

		ctrl0 = bam_read_reg(base, CTRL, 0);
		irq_stts = bam_read_reg(base, IRQ_STTS, 0);
		SPS_INFO(dev, "[BAM_DIAG] before: CTRL=0x%x REV=0x%x IRQ_STTS=0x%x\n",
				ctrl0, ver, irq_stts);

		bam_write_reg_field(base, CTRL, 0, BAM_SW_RST, 1);
		udelay(5);
		ctrl1 = bam_read_reg(base, CTRL, 0);
		SPS_INFO(dev, "[BAM_DIAG] after SW_RST=1: CTRL=0x%x (expect bit0 set)\n", ctrl1);

		bam_write_reg_field(base, CTRL, 0, BAM_SW_RST, 0);
		udelay(10);
		ctrl2 = bam_read_reg(base, CTRL, 0);
		ver2 = bam_read_reg_field(base, REVISION, 0, BAM_REVISION);
		SPS_INFO(dev, "[BAM_DIAG] after SW_RST=0: CTRL=0x%x REV=0x%x\n",
				ctrl2, ver2);

		if (ctrl1 == ctrl0) {
			SPS_ERR(dev, "[BAM_DIAG] HW IGNORES writes - CTRL frozen at 0x%x. "
					"Likely AHB clock or power-domain missing.\n", ctrl0);
		} else {
			SPS_INFO(dev, "[BAM_DIAG] HW responds to writes (CTRL 0x%x->0x%x->0x%x). "
					"Problem is REVISION-specific.\n", ctrl0, ctrl1, ctrl2);
		}

		ver = ver2;
	}

	if ((ver < BAM_MIN_VERSION) || (ver > BAM_MAX_VERSION)) {
		SPS_ERR(dev, "sps:bam 0x%pK(va) Invalid BAM REVISION 0x%x.\n",
				dev->base, ver);
PORT_EOF
apply_edit "drivers/platform/msm/sps/bam.c" "[BAM_DIAG] BAM REVISION==0 wake-test (is HW clocked/powered at all?)"

echo
echo "============================================================"
echo "Diag sondy applied: $applied (skipped: $skipped)."
echo "Remember: tier-2 probes off by default (ipa_sonda_dbg=0);"
echo "          do NOT ship production builds with this script applied."
echo "============================================================"
