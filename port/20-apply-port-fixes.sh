#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 20-apply-port-fixes.sh
#
# Step 2 of the IPA v2.6L port: bringup-correctness fixes on top of the
# mechanical API conversion done by 10-apply-port-patches.sh. Everything
# here is REQUIRED for a working driver - this is not optional polish.
#
# Sections (in order):
#   compat    type alignment with the shim headers (msm_gsi stub etc.)
#   flexarr   UAPI flexible-array modernization
#   logging   IPAWAN/SPS logging without CONFIG_IPC_LOGGING
#   qmi       QMI wire-format compat (TLV 0x12, vendor-faithful zip_tbl typo)
#   probe     clock/IRQ probe fixes (smmu_clk optional, clk_prepare_enable,
#             platform_get_irq_byname)
#   wakelock  wakelock neutralization
#   hotpath   unlikely() annotations
#   datapath  memset size fix, EP route double-write carry-over
#   netdev    TX_EVT_FIX, ndo_siocdevprivate, max_mtu, NAPI weight, netdev parent
#   mm        ModemManager integration (names "ipa"/"ipa-core", sysfs
#             modem/{tx,rx}_endpoint_id, registration order)
#   ssr       keep driver+workqueues alive across modem restarts
#
# Idempotent: every edit is guarded - if its result is already present the
# edit is skipped; if neither old nor new text is found the script aborts
# (baseline drift - investigate before continuing).
#
# Usage:  ./20-apply-port-fixes.sh [--root /path/to/kernel]

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

section "Type/level alignment with the shim headers"
read -r -d '' OLD <<'PORT_EOF' || true
#ifndef _IPA_I_H_
#define _IPA_I_H_

#include <linux/bitops.h>
#include <linux/cdev.h>
#include <linux/export.h>
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
#ifndef _IPA_I_H_
#define _IPA_I_H_

#include "ipa_compat.h"
#include <linux/bitops.h>
#include <linux/cdev.h>
#include <linux/export.h>
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: include ipa_compat.h up front (belt-and-braces with Makefile -include)"

read -r -d '' OLD <<'PORT_EOF' || true

int ipa2_mhi_resume_channels_internal(enum ipa_client_type client,
		bool LPTransitionRejected, bool brstmode_enabled,
		union __packed gsi_channel_scratch ch_scratch, u8 index);

/*
 * mux id
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

int ipa2_mhi_resume_channels_internal(enum ipa_client_type client,
		bool LPTransitionRejected, bool brstmode_enabled,
		union gsi_channel_scratch ch_scratch, u8 index);

/*
 * mux id
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: drop __packed on union gsi_channel_scratch (match stub msm_gsi.h)"

read -r -d '' OLD <<'PORT_EOF' || true

int ipa2_mhi_resume_channels_internal(enum ipa_client_type client,
		bool LPTransitionRejected, bool brstmode_enabled,
		union __packed gsi_channel_scratch ch_scratch, u8 index)
{
	int res;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

int ipa2_mhi_resume_channels_internal(enum ipa_client_type client,
		bool LPTransitionRejected, bool brstmode_enabled,
		union gsi_channel_scratch ch_scratch, u8 index)
{
	int res;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_mhi.c" "ipa_mhi.c: same __packed alignment for ipa2_mhi_resume_channels_internal()"

read -r -d '' OLD <<'PORT_EOF' || true

/* This part must be outside protection */
#undef TRACE_INCLUDE_PATH
#define TRACE_INCLUDE_PATH .
#include <trace/define_trace.h>
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

/* This part must be outside protection */
#undef TRACE_INCLUDE_PATH
#define TRACE_INCLUDE_PATH ../../drivers/platform/msm/ipa/ipa_v2
#include <trace/define_trace.h>
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_trace.h" "ipa_trace.h: TRACE_INCLUDE_PATH relative to include/trace (out-of-dir build)"


section "UAPI msm_ipa.h: C99 flexible arrays (rules[0] is UB-prone with modern compilers)"
read -r -d '' OLD <<'PORT_EOF' || true
	enum ipa_ip_type ip;
	char rt_tbl_name[IPA_RESOURCE_NAME_MAX];
	uint8_t num_rules;
	struct ipa_rt_rule_add rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	enum ipa_ip_type ip;
	char rt_tbl_name[IPA_RESOURCE_NAME_MAX];
	uint8_t num_rules;
	struct ipa_rt_rule_add rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#1/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	char rt_tbl_name[IPA_RESOURCE_NAME_MAX];
	uint8_t num_rules;
	uint32_t add_after_hdl;
	struct ipa_rt_rule_add rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	char rt_tbl_name[IPA_RESOURCE_NAME_MAX];
	uint8_t num_rules;
	uint32_t add_after_hdl;
	struct ipa_rt_rule_add rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#2/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	uint8_t commit;
	enum ipa_ip_type ip;
	uint8_t num_rules;
	struct ipa_rt_rule_mdfy rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	uint8_t commit;
	enum ipa_ip_type ip;
	uint8_t num_rules;
	struct ipa_rt_rule_mdfy rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#3/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	enum ipa_ip_type ip;
	char rt_tbl_name[IPA_RESOURCE_NAME_MAX];
	uint8_t num_rules;
	struct ipa_rt_rule_add_ext rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	enum ipa_ip_type ip;
	char rt_tbl_name[IPA_RESOURCE_NAME_MAX];
	uint8_t num_rules;
	struct ipa_rt_rule_add_ext rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#4/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	enum ipa_client_type ep;
	uint8_t global;
	uint8_t num_rules;
	struct ipa_flt_rule_add rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	enum ipa_client_type ep;
	uint8_t global;
	uint8_t num_rules;
	struct ipa_flt_rule_add rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#5/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	enum ipa_client_type ep;
	uint8_t num_rules;
	uint32_t add_after_hdl;
	struct ipa_flt_rule_add rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	enum ipa_client_type ep;
	uint8_t num_rules;
	uint32_t add_after_hdl;
	struct ipa_flt_rule_add rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#6/7)"

read -r -d '' OLD <<'PORT_EOF' || true
	uint8_t commit;
	enum ipa_ip_type ip;
	uint8_t num_rules;
	struct ipa_flt_rule_mdfy rules[0];
};

/**
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	uint8_t commit;
	enum ipa_ip_type ip;
	uint8_t num_rules;
	struct ipa_flt_rule_mdfy rules[];
};

/**
PORT_EOF
apply_edit "include/uapi/linux/msm_ipa.h" "msm_ipa.h: rules[0] -> rules[] flexible array (#7/7)"


section "IPAWAN/SPS logging without downstream CONFIG_IPC_LOGGING"
read -r -d '' OLD <<'PORT_EOF' || true
#define DEV_NAME "ipa-wan"
#define SUBSYS_MODEM "mpss"

#define IPAWANDBG(fmt, args...) \
	do { \
		pr_debug(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args); \
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
#define DEV_NAME "ipa-wan"
#define SUBSYS_MODEM "mpss"

#ifdef CONFIG_IPC_LOGGING
#define IPAWANDBG(fmt, args...) \
	do { \
		pr_debug(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args); \
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.h" "ipa_qmi_service.h: gate vendor IPAWAN* macros behind CONFIG_IPC_LOGGING"

read -r -d '' OLD <<'PORT_EOF' || true
			DEV_NAME " %s:%d " fmt, ## args); \
	} while (0)


extern struct ipa_qmi_context *ipa_qmi_ctx;
extern struct mutex ipa_qmi_lock;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			DEV_NAME " %s:%d " fmt, ## args); \
	} while (0)

#else
#define IPAWANDBG(fmt, args...) pr_debug(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args)
#define IPAWANDBG_LOW(fmt, args...) pr_debug(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args)
#define IPAWANERR(fmt, args...) pr_err(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args)
#define IPAWANERR_RL(fmt, args...) pr_err_ratelimited_ipa(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args)
#define IPAWANINFO(fmt, args...) pr_info(DEV_NAME " %s:%d " fmt, __func__, __LINE__, ## args)
#endif

extern struct ipa_qmi_context *ipa_qmi_ctx;
extern struct mutex ipa_qmi_lock;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.h" "ipa_qmi_service.h: pr_debug/pr_err fallbacks when IPC logging is absent"

read -r -d '' OLD <<'PORT_EOF' || true
{
	struct sps_bam *bam = NULL;
	void __iomem *virt_addr = NULL;
	char bam_name[MAX_MSG_LEN];
	u32 manage;
	int ok;
	int result;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
{
	struct sps_bam *bam = NULL;
	void __iomem *virt_addr = NULL;
	char bam_name[MAX_MSG_LEN] __maybe_unused;
	u32 manage;
	int ok;
	int result;
PORT_EOF
apply_edit "drivers/platform/msm/sps/sps.c" "sps.c: bam_name only used by IPC logging -> __maybe_unused"

read -r -d '' OLD <<'PORT_EOF' || true
	if (virt_addr != NULL)
		bam->props.virt_addr = virt_addr;

	snprintf(bam_name, sizeof(bam_name), "sps_bam_%pa_0",
					&bam->props.phys_addr);
	bam->ipc_log0 = ipc_log_context_create(SPS_IPC_LOGPAGES,
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (virt_addr != NULL)
		bam->props.virt_addr = virt_addr;

#ifdef CONFIG_IPC_LOGGING
	snprintf(bam_name, sizeof(bam_name), "sps_bam_%pa_0",
					&bam->props.phys_addr);
	bam->ipc_log0 = ipc_log_context_create(SPS_IPC_LOGPAGES,
PORT_EOF
apply_edit "drivers/platform/msm/sps/sps.c" "sps.c: gate per-BAM ipc_log_context_create block (open)"

read -r -d '' OLD <<'PORT_EOF' || true
	if (!bam->ipc_log4)
		SPS_ERR(sps, "%s : unable to create IPC Logging 4 for bam %pa",
					__func__, &bam->props.phys_addr);

	if (bam_props->ipc_loglevel)
		bam->ipc_loglevel = bam_props->ipc_loglevel;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (!bam->ipc_log4)
		SPS_ERR(sps, "%s : unable to create IPC Logging 4 for bam %pa",
					__func__, &bam->props.phys_addr);
#endif

	if (bam_props->ipc_loglevel)
		bam->ipc_loglevel = bam_props->ipc_loglevel;
PORT_EOF
apply_edit "drivers/platform/msm/sps/sps.c" "sps.c: gate per-BAM ipc_log_context_create block (close)"

read -r -d '' OLD <<'PORT_EOF' || true
	if (sps == NULL)
		return -ENOMEM;

	sps->ipc_log0 = ipc_log_context_create(SPS_IPC_LOGPAGES,
							"sps_ipc_log0", 0);
	if (!sps->ipc_log0)
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (sps == NULL)
		return -ENOMEM;

#ifdef CONFIG_IPC_LOGGING
	sps->ipc_log0 = ipc_log_context_create(SPS_IPC_LOGPAGES,
							"sps_ipc_log0", 0);
	if (!sps->ipc_log0)
PORT_EOF
apply_edit "drivers/platform/msm/sps/sps.c" "sps.c: gate driver-global IPC log contexts (open)"

read -r -d '' OLD <<'PORT_EOF' || true
				SPS_IPC_REG_DUMP_FACTOR, "sps_ipc_log4", 0);
	if (!sps->ipc_log4)
		pr_err("Failed to create IPC log4\n");

	ret = platform_driver_register(&msm_sps_driver);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				SPS_IPC_REG_DUMP_FACTOR, "sps_ipc_log4", 0);
	if (!sps->ipc_log4)
		pr_err("Failed to create IPC log4\n");
#endif

	ret = platform_driver_register(&msm_sps_driver);
PORT_EOF
apply_edit "drivers/platform/msm/sps/sps.c" "sps.c: gate driver-global IPC log contexts (close)"


section "QMI wire-format compatibility with the v2.6L modem"
read -r -d '' OLD <<'PORT_EOF' || true
		IPA_MEM_PART(modem_hdr_proc_ctx_ofst) +
		IPA_MEM_PART(modem_hdr_proc_ctx_size) + smem_restr_bytes - 1;

	req.zip_tbl_info_valid = (IPA_MEM_PART(modem_comp_decomp_size) != 0);
	req.zip_tbl_info.modem_offset_start =
		IPA_MEM_PART(modem_comp_decomp_size) + smem_restr_bytes;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		IPA_MEM_PART(modem_hdr_proc_ctx_ofst) +
		IPA_MEM_PART(modem_hdr_proc_ctx_size) + smem_restr_bytes - 1;

	/* Match vendor byte-for-byte: vendor computes modem_offset_start from
	 * modem_comp_decomp_SIZE (a likely vendor typo, but vendor is the
	 * known-working ground truth and v2.6L tolerates it — comp/decomp is
	 * unused in the cellular path). Reverted from a speculative _ofst
	 * change to keep the QMI INIT handshake identical to vendor. */
	req.zip_tbl_info_valid = (IPA_MEM_PART(modem_comp_decomp_size) != 0);
	req.zip_tbl_info.modem_offset_start =
		IPA_MEM_PART(modem_comp_decomp_size) + smem_restr_bytes;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.c" "ipa_qmi_service.c: document the deliberate vendor-faithful zip_tbl_info typo"

read -r -d '' OLD <<'PORT_EOF' || true
			struct ipa_init_modem_driver_resp_msg_v01,
			default_end_pt),
	},
	{
		.data_type	= QMI_EOTI,
		.array_type	= NO_ARRAY,
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			struct ipa_init_modem_driver_resp_msg_v01,
			default_end_pt),
	},
	/* TLV 0x12: modem_driver_init_pending (PORT FROM LITE) */
	{
		.data_type	= QMI_OPT_FLAG,
		.elem_len	= 1,
		.elem_size	= sizeof(uint8_t),
		.array_type	= NO_ARRAY,
		.tlv_type	= 0x12,
		.offset		= offsetof(
			struct ipa_init_modem_driver_resp_msg_v01,
			modem_driver_init_pending_valid),
	},
	{
		.data_type	= QMI_UNSIGNED_1_BYTE,
		.elem_len	= 1,
		.elem_size	= sizeof(uint8_t),
		.array_type	= NO_ARRAY,
		.tlv_type	= 0x12,
		.offset		= offsetof(
			struct ipa_init_modem_driver_resp_msg_v01,
			modem_driver_init_pending),
	},
	{
		.data_type	= QMI_EOTI,
		.array_type	= NO_ARRAY,
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service_v01.c" "ipa_qmi_service_v01.c: add TLV 0x12 modem_driver_init_pending to INIT_DRIVER resp EI"


section "Probe-time bringup fixes (clocks, IRQ)"
read -r -d '' OLD <<'PORT_EOF' || true
	}

	if (smmu_info.present && smmu_info.arm_smmu) {
		smmu_clk = clk_get(dev, "smmu_clk");
		if (IS_ERR(smmu_clk)) {
			if (smmu_clk != ERR_PTR(-EPROBE_DEFER))
				IPAERR("fail to get smmu clk\n");
			return PTR_ERR(smmu_clk);
		}

		if (clk_get_rate(smmu_clk) == 0) {
			long rate = clk_round_rate(smmu_clk, 1000);

			clk_set_rate(smmu_clk, rate);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	if (smmu_info.present && smmu_info.arm_smmu) {
		/* Mainline rpmcc-sdm660 has no "smmu_clk" — NoC voting now flows
		 * through msm_bus_compat → icc framework instead. Try the clk
		 * anyway in case some out-of-tree provider exposes it; otherwise
		 * leave smmu_clk NULL. */
		smmu_clk = clk_get(dev, "smmu_clk");
		if (IS_ERR(smmu_clk)) {
			if (PTR_ERR(smmu_clk) == -EPROBE_DEFER)
				return -EPROBE_DEFER;
			smmu_clk = NULL;
		} else if (clk_get_rate(smmu_clk) == 0) {
			long rate = clk_round_rate(smmu_clk, 1000);

			clk_set_rate(smmu_clk, rate);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: make smmu_clk optional (mainline rpmcc-sdm660 has none; icc votes instead)"

read -r -d '' OLD <<'PORT_EOF' || true
{
	IPADBG_LOW("enabling gcc_ipa_clk\n");
	if (ipa_clk) {
		clk_prepare(ipa_clk);
		clk_enable(ipa_clk);
		IPADBG_LOW("curr_ipa_clk_rate=%d", ipa_ctx->curr_ipa_clk_rate);
		clk_set_rate(ipa_clk, ipa_ctx->curr_ipa_clk_rate);
		ipa_uc_notify_clk_state(true);
	} else {
		WARN_ON(1);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
{
	IPADBG_LOW("enabling gcc_ipa_clk\n");
	if (ipa_clk) {
		/* Port fix: vendor used clk_prepare() + clk_enable() and ignored
		 * the return values, silently masking RPM SMD clock failures on
		 * mainline. Use atomic clk_prepare_enable() with an error check,
		 * and set the rate after enable (mainline best practice). */
		int ret = clk_prepare_enable(ipa_clk);

		if (ret)
			IPAERR("clk_prepare_enable failed %d\n", ret);
		clk_set_rate(ipa_clk, ipa_ctx->curr_ipa_clk_rate);
		IPADBG_LOW("curr_ipa_clk_rate=%d", ipa_ctx->curr_ipa_clk_rate);
		ipa_uc_notify_clk_state(true);
	} else {
		WARN_ON(1);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: clk_prepare_enable() with error check; set_rate after enable"

read -r -d '' OLD <<'PORT_EOF' || true
	}

	/* Get IPA IRQ number */
	resource = platform_get_resource_byname(pdev, IORESOURCE_IRQ,
			"ipa-irq");
	if (!resource) {
		IPAERR(":get resource failed for ipa-irq!\n");
		return -ENODEV;
	}
	ipa_drv_res->ipa_irq = resource->start;
	IPADBG(":ipa-irq = %d\n", ipa_drv_res->ipa_irq);

	/* Get IPA BAM IRQ number */
	resource = platform_get_resource_byname(pdev, IORESOURCE_IRQ,
			"bam-irq");
	if (!resource) {
		IPAERR(":get resource failed for bam-irq!\n");
		return -ENODEV;
	}
	ipa_drv_res->bam_irq = resource->start;
	IPADBG(":ibam-irq = %d\n", ipa_drv_res->bam_irq);

	result = of_property_read_u32(pdev->dev.of_node, "qcom,ee",
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	/* Get IPA IRQ number */
	ipa_drv_res->ipa_irq = platform_get_irq_byname(pdev, "ipa-irq");
	if (ipa_drv_res->ipa_irq < 0) {
		IPAERR(":get resource failed for ipa-irq!\n");
		return -ENODEV;
	}
	IPADBG(":ipa-irq = %d\n", ipa_drv_res->ipa_irq);

	/* Get IPA BAM IRQ number */
	ipa_drv_res->bam_irq = platform_get_irq_byname(pdev, "bam-irq");
	if (ipa_drv_res->bam_irq < 0) {
		IPAERR(":get resource failed for bam-irq!\n");
		return -ENODEV;
	}
	IPADBG(":ibam-irq = %d\n", ipa_drv_res->bam_irq);

	result = of_property_read_u32(pdev->dev.of_node, "qcom,ee",
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: platform_get_irq_byname() (IORESOURCE_IRQ resources removed in 6.x)"


section "Wakelock neutralization (mainline PM; no Android userspace expects them)"
read -r -d '' OLD <<'PORT_EOF' || true
	ipa_active_clients_unlock();
}

/**
 * ipa_inc_acquire_wakelock() - Increase active clients counter, and
 * acquire wakelock if necessary
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	ipa_active_clients_unlock();
}

#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
/**
 * ipa_inc_acquire_wakelock() - Increase active clients counter, and
 * acquire wakelock if necessary
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: wakelock acquire/release pair behind !CONFIG_DISABLE_IPA_WAKELOCKS (open)"

read -r -d '' OLD <<'PORT_EOF' || true
		IPAERR("client enum %d mask already set. ref cnt = %d\n",
		ref_client, ipa_ctx->wakelock_ref_cnt.cnt);
	ipa_ctx->wakelock_ref_cnt.cnt |= (1 << ref_client);
	if (ipa_ctx->wakelock_ref_cnt.cnt)
		__pm_stay_awake(ipa_ctx->w_lock);
	IPADBG_LOW("active wakelock ref cnt = %d client enum %d\n",
		ipa_ctx->wakelock_ref_cnt.cnt, ref_client);
	spin_unlock_irqrestore(&ipa_ctx->wakelock_ref_cnt.spinlock, flags);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		IPAERR("client enum %d mask already set. ref cnt = %d\n",
		ref_client, ipa_ctx->wakelock_ref_cnt.cnt);
	ipa_ctx->wakelock_ref_cnt.cnt |= (1 << ref_client);
	IPADBG_LOW("active wakelock ref cnt = %d client enum %d\n",
		ipa_ctx->wakelock_ref_cnt.cnt, ref_client);
	spin_unlock_irqrestore(&ipa_ctx->wakelock_ref_cnt.spinlock, flags);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: drop __pm_stay_awake (wakelock accounting kept, OS-level lock neutralized)"

read -r -d '' OLD <<'PORT_EOF' || true
	ipa_ctx->wakelock_ref_cnt.cnt &= ~(1 << ref_client);
	IPADBG_LOW("active wakelock ref cnt = %d client enum %d\n",
		ipa_ctx->wakelock_ref_cnt.cnt, ref_client);
	if (ipa_ctx->wakelock_ref_cnt.cnt == 0)
		__pm_relax(ipa_ctx->w_lock);
	spin_unlock_irqrestore(&ipa_ctx->wakelock_ref_cnt.spinlock, flags);
}

static int ipa_setup_bam_cfg(const struct ipa_plat_drv_res *res)
{
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	ipa_ctx->wakelock_ref_cnt.cnt &= ~(1 << ref_client);
	IPADBG_LOW("active wakelock ref cnt = %d client enum %d\n",
		ipa_ctx->wakelock_ref_cnt.cnt, ref_client);
	spin_unlock_irqrestore(&ipa_ctx->wakelock_ref_cnt.spinlock, flags);
}
#endif

static int ipa_setup_bam_cfg(const struct ipa_plat_drv_res *res)
{
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: drop __pm_relax + close the guard"

read -r -d '' OLD <<'PORT_EOF' || true
					atomic_set(
						&ipa_ctx->sps_pm.dec_clients,
						1);
					/*
					 * acquire wake lock as long as suspend
					 * vote is held
					 */
					ipa_inc_acquire_wakelock(
						IPA_WAKELOCK_REF_CLIENT_SPS);
					ipa_sps_process_irq_schedule_rel();
				}
				mutex_unlock(&ipa_ctx->sps_pm.sps_pm_lock);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
					atomic_set(
						&ipa_ctx->sps_pm.dec_clients,
						1);
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
					/*
					 * acquire wake lock as long as suspend
					 * vote is held
					 */
					ipa_inc_acquire_wakelock(
						IPA_WAKELOCK_REF_CLIENT_SPS);
#endif
					ipa_sps_process_irq_schedule_rel();
				}
				mutex_unlock(&ipa_ctx->sps_pm.sps_pm_lock);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: guard SPS-suspend wakelock acquire"

read -r -d '' OLD <<'PORT_EOF' || true
			ipa_sps_process_irq_schedule_rel();
		} else {
			atomic_set(&ipa_ctx->sps_pm.dec_clients, 0);
			ipa_dec_release_wakelock(IPA_WAKELOCK_REF_CLIENT_SPS);
			IPA_ACTIVE_CLIENTS_DEC_SPECIAL("SPS_RESOURCE");
		}
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			ipa_sps_process_irq_schedule_rel();
		} else {
			atomic_set(&ipa_ctx->sps_pm.dec_clients, 0);
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
			ipa_dec_release_wakelock(IPA_WAKELOCK_REF_CLIENT_SPS);
#endif
			IPA_ACTIVE_CLIENTS_DEC_SPECIAL("SPS_RESOURCE");
		}
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: guard SPS-resume wakelock release"

read -r -d '' OLD <<'PORT_EOF' || true
		goto fail_nat_dev_add;
	}

	/* Register a wakeup source. */
	ipa_ctx->w_lock =
		wakeup_source_register(&ipa_pdev->dev, "IPA_WS");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		goto fail_nat_dev_add;
	}

#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
	/* Register a wakeup source. */
	ipa_ctx->w_lock =
		wakeup_source_register(&ipa_pdev->dev, "IPA_WS");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: guard wakeup_source registration in probe (open)"

read -r -d '' OLD <<'PORT_EOF' || true
	}

	spin_lock_init(&ipa_ctx->wakelock_ref_cnt.spinlock);

	/* Initialize the SPS PM lock. */
	mutex_init(&ipa_ctx->sps_pm.sps_pm_lock);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	spin_lock_init(&ipa_ctx->wakelock_ref_cnt.spinlock);
#endif

	/* Initialize the SPS PM lock. */
	mutex_init(&ipa_ctx->sps_pm.sps_pm_lock);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: guard wakeup_source registration in probe (close)"

read -r -d '' OLD <<'PORT_EOF' || true
fail_create_apps_resource:
	ipa_rm_exit();
fail_ipa_rm_init:
	wakeup_source_unregister(ipa_ctx->w_lock);
	ipa_ctx->w_lock = NULL;
fail_w_source_register:
fail_nat_dev_add:
	cdev_del(&ipa_ctx->cdev);
fail_cdev_add:
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
fail_create_apps_resource:
	ipa_rm_exit();
fail_ipa_rm_init:
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
	wakeup_source_unregister(ipa_ctx->w_lock);
	ipa_ctx->w_lock = NULL;
fail_w_source_register:
#endif
fail_nat_dev_add:
	cdev_del(&ipa_ctx->cdev);
fail_cdev_add:
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: guard wakeup_source error path"

read -r -d '' OLD <<'PORT_EOF' || true
	atomic_set(&sys->curr_polling_state, 0);
	if (!sys->ep->napi_enabled)
		ipa_handle_rx_core(sys, true, false);
	ipa_dec_release_wakelock(sys->ep->wakelock_client);
	return;

fail:
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	atomic_set(&sys->curr_polling_state, 0);
	if (!sys->ep->napi_enabled)
		ipa_handle_rx_core(sys, true, false);
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
	ipa_dec_release_wakelock(sys->ep->wakelock_client);
#endif
	return;

fail:
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: guard wakelock release in RX switch-to-intr path"

read -r -d '' OLD <<'PORT_EOF' || true
			IPAERR("sps_set_config() failed %d\n", ret);
			break;
		}
		ipa_inc_acquire_wakelock(sys->ep->wakelock_client);
		atomic_set(&sys->curr_polling_state, 1);
		trace_intr_to_poll(sys->ep->client);
		queue_work(sys->wq, &sys->work);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			IPAERR("sps_set_config() failed %d\n", ret);
			break;
		}
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
		ipa_inc_acquire_wakelock(sys->ep->wakelock_client);
#endif
		atomic_set(&sys->curr_polling_state, 1);
		trace_intr_to_poll(sys->ep->client);
		queue_work(sys->wq, &sys->work);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: guard wakelock acquire in RX switch-to-poll path"

read -r -d '' OLD <<'PORT_EOF' || true
	int cnt;
};

struct ipa_wakelock_ref_cnt {
	spinlock_t spinlock;
	u32 cnt;
};

struct ipa_tag_completion {
	struct completion comp;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	int cnt;
};

#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
struct ipa_wakelock_ref_cnt {
	spinlock_t spinlock;
	u32 cnt;
};
#endif

struct ipa_tag_completion {
	struct completion comp;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: guard wakelock context fields (pair 1)"

read -r -d '' OLD <<'PORT_EOF' || true
	u32 peer_bam_map_cnt;
	u32 wdi_map_cnt;
	bool use_dma_zone;
	struct wakeup_source *w_lock;
	struct ipa_wakelock_ref_cnt wakelock_ref_cnt;

	/* RMNET_IOCTL_INGRESS_FORMAT_AGG_DATA */
	bool ipa_client_apps_wan_cons_agg_gro;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	u32 peer_bam_map_cnt;
	u32 wdi_map_cnt;
	bool use_dma_zone;
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
	struct wakeup_source *w_lock;
	struct ipa_wakelock_ref_cnt wakelock_ref_cnt;
#endif

	/* RMNET_IOCTL_INGRESS_FORMAT_AGG_DATA */
	bool ipa_client_apps_wan_cons_agg_gro;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: guard wakelock context fields (pair 2)"

read -r -d '' OLD <<'PORT_EOF' || true
			uint32_t qmap_id);
int ipa2_restore_suspend_handler(void);
void ipa_sps_irq_control_all(bool enable);
void ipa_inc_acquire_wakelock(enum ipa_wakelock_ref_client ref_client);
void ipa_dec_release_wakelock(enum ipa_wakelock_ref_client ref_client);
int ipa_iommu_map(struct iommu_domain *domain, unsigned long iova,
	phys_addr_t paddr, size_t size, int prot);
int ipa2_rx_poll(u32 clnt_hdl, int budget);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			uint32_t qmap_id);
int ipa2_restore_suspend_handler(void);
void ipa_sps_irq_control_all(bool enable);
#ifndef CONFIG_DISABLE_IPA_WAKELOCKS
void ipa_inc_acquire_wakelock(enum ipa_wakelock_ref_client ref_client);
void ipa_dec_release_wakelock(enum ipa_wakelock_ref_client ref_client);
#endif
int ipa_iommu_map(struct iommu_domain *domain, unsigned long iova,
	phys_addr_t paddr, size_t size, int prot);
int ipa2_rx_poll(u32 clnt_hdl, int budget);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: guard wakelock prototypes"


section "Hot-path unlikely() annotations (vendor-Asus parity)"
read -r -d '' OLD <<'PORT_EOF' || true
		mem_flag = GFP_KERNEL;

	tx_pkt = kmem_cache_zalloc(ipa_ctx->tx_pkt_wrapper_cache, mem_flag);
	if (!tx_pkt) {
		IPAERR("failed to alloc tx wrapper\n");
		goto fail_mem_alloc;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		mem_flag = GFP_KERNEL;

	tx_pkt = kmem_cache_zalloc(ipa_ctx->tx_pkt_wrapper_cache, mem_flag);
	if (unlikely(!tx_pkt)) {
		IPAERR("failed to alloc tx wrapper\n");
		goto fail_mem_alloc;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#1/14)"

read -r -d '' OLD <<'PORT_EOF' || true
			continue;

		ipa_ep_idx = ipa_get_ep_mapping(client_num);
		if (ipa_ep_idx == -1) {
			IPADBG_LOW("Invalid client.\n");
			continue;
		}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			continue;

		ipa_ep_idx = ipa_get_ep_mapping(client_num);
		if (unlikely(ipa_ep_idx == -1)) {
			IPADBG_LOW("Invalid client.\n");
			continue;
		}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#2/14)"

read -r -d '' OLD <<'PORT_EOF' || true
	}

	ipa_ep_idx = ipa2_get_ep_mapping(sys_in->client);
	if (ipa_ep_idx == -1) {
		IPAERR("Invalid client.\n");
		goto fail_gen;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	ipa_ep_idx = ipa2_get_ep_mapping(sys_in->client);
	if (unlikely(ipa_ep_idx == -1)) {
		IPAERR("Invalid client.\n");
		goto fail_gen;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#3/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		return -EINVAL;
	}

	if (skb->len == 0) {
		IPAERR("packet size is 0\n");
		return -EINVAL;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		return -EINVAL;
	}

	if (unlikely(skb->len == 0)) {
		IPAERR("packet size is 0\n");
		return -EINVAL;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#4/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		 * 1 desc for each frag
		 */
		desc = kzalloc(sizeof(*desc) * (num_frags + 2), GFP_ATOMIC);
		if (!desc) {
			IPAERR("failed to alloc desc array\n");
			goto fail_mem;
		}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		 * 1 desc for each frag
		 */
		desc = kzalloc(sizeof(*desc) * (num_frags + 2), GFP_ATOMIC);
		if (unlikely(!desc)) {
			IPAERR("failed to alloc desc array\n");
			goto fail_mem;
		}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#5/14)"

read -r -d '' OLD <<'PORT_EOF' || true
	 */
	if (IPA_CLIENT_IS_CONS(dst)) {
		src_ep_idx = ipa2_get_ep_mapping(IPA_CLIENT_APPS_LAN_WAN_PROD);
		if (-1 == src_ep_idx) {
			IPAERR("Client %u is not mapped\n",
				IPA_CLIENT_APPS_LAN_WAN_PROD);
			goto fail_gen;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	 */
	if (IPA_CLIENT_IS_CONS(dst)) {
		src_ep_idx = ipa2_get_ep_mapping(IPA_CLIENT_APPS_LAN_WAN_PROD);
		if (unlikely(-1 == src_ep_idx)) {
			IPAERR("Client %u is not mapped\n",
				IPA_CLIENT_APPS_LAN_WAN_PROD);
			goto fail_gen;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#6/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		dst_ep_idx = ipa2_get_ep_mapping(dst);
	} else {
		src_ep_idx = ipa2_get_ep_mapping(dst);
		if (-1 == src_ep_idx) {
			IPAERR("Client %u is not mapped\n", dst);
			goto fail_gen;
		}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		dst_ep_idx = ipa2_get_ep_mapping(dst);
	} else {
		src_ep_idx = ipa2_get_ep_mapping(dst);
		if (unlikely(-1 == src_ep_idx)) {
			IPAERR("Client %u is not mapped\n", dst);
			goto fail_gen;
		}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#7/14)"

read -r -d '' OLD <<'PORT_EOF' || true
			desc[1].callback = NULL;
		}

		if (ipa_send(sys, num_frags + 2, desc, true)) {
			IPAERR("fail to send skb %p num_frags %u SWP\n",
					skb, num_frags);
			goto fail_send;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			desc[1].callback = NULL;
		}

		if (unlikely(ipa_send(sys, num_frags + 2, desc, true))) {
			IPAERR("fail to send skb %p num_frags %u SWP\n",
					skb, num_frags);
			goto fail_send;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#8/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		}

		if (num_frags == 0) {
			if (ipa_send_one(sys, desc, true)) {
				IPAERR("fail to send skb %p HWP\n", skb);
				goto fail_gen;
			}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		}

		if (num_frags == 0) {
			if (unlikely(ipa_send_one(sys, desc, true))) {
				IPAERR("fail to send skb %p HWP\n", skb);
				goto fail_gen;
			}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#9/14)"

read -r -d '' OLD <<'PORT_EOF' || true
			desc[1+f-1].user2 = desc[0].user2;
			desc[0].callback = NULL;

			if (ipa_send(sys, num_frags + 1, desc, true)) {
				IPAERR("fail to send skb %p num_frags %u HWP\n",
						skb, num_frags);
				goto fail_gen;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			desc[1+f-1].user2 = desc[0].user2;
			desc[0].callback = NULL;

			if (unlikely(ipa_send(sys, num_frags + 1, desc, true))) {
				IPAERR("fail to send skb %p num_frags %u HWP\n",
						skb, num_frags);
				goto fail_gen;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#10/14)"

read -r -d '' OLD <<'PORT_EOF' || true
begin:
	while (1) {
		next = (curr + 1) % sys->repl.capacity;
		if (next == atomic_read(&sys->repl.head_idx))
			goto fail_kmem_cache_alloc;

		rx_pkt = kmem_cache_zalloc(ipa_ctx->rx_pkt_wrapper_cache,
					   flag);
		if (!rx_pkt) {
			pr_err_ratelimited("%s fail alloc rx wrapper sys=%p\n",
					__func__, sys);
			goto fail_kmem_cache_alloc;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
begin:
	while (1) {
		next = (curr + 1) % sys->repl.capacity;
		if (unlikely(next == atomic_read(&sys->repl.head_idx)))
			goto fail_kmem_cache_alloc;

		rx_pkt = kmem_cache_zalloc(ipa_ctx->rx_pkt_wrapper_cache,
					   flag);
		if (unlikely(!rx_pkt)) {
			pr_err_ratelimited("%s fail alloc rx wrapper sys=%p\n",
					__func__, sys);
			goto fail_kmem_cache_alloc;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#11/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		rx_pkt->sys = sys;

		rx_pkt->data.skb = sys->get_skb(sys->rx_buff_sz, flag);
		if (rx_pkt->data.skb == NULL) {
			pr_err_ratelimited("%s fail alloc skb sys=%p\n",
					__func__, sys);
			goto fail_skb_alloc;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		rx_pkt->sys = sys;

		rx_pkt->data.skb = sys->get_skb(sys->rx_buff_sz, flag);
		if (unlikely(rx_pkt->data.skb == NULL)) {
			pr_err_ratelimited("%s fail alloc skb sys=%p\n",
					__func__, sys);
			goto fail_skb_alloc;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#12/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		rx_pkt->data.dma_addr = dma_map_single(ipa_ctx->pdev, ptr,
						     sys->rx_buff_sz,
						     DMA_FROM_DEVICE);
		if (dma_mapping_error(ipa_ctx->pdev,
				rx_pkt->data.dma_addr)) {
			pr_err_ratelimited("%s dma map fail %p for %p sys=%p\n",
			       __func__, (void *)rx_pkt->data.dma_addr,
			       ptr, sys);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		rx_pkt->data.dma_addr = dma_map_single(ipa_ctx->pdev, ptr,
						     sys->rx_buff_sz,
						     DMA_FROM_DEVICE);
		if (unlikely(dma_mapping_error(ipa_ctx->pdev,
					       rx_pkt->data.dma_addr))) {
			pr_err_ratelimited("%s dma map fail %p for %p sys=%p\n",
			       __func__, (void *)rx_pkt->data.dma_addr,
			       ptr, sys);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#13/14)"

read -r -d '' OLD <<'PORT_EOF' || true
	}

	ipa_ep_idx = ipa2_get_ep_mapping(sys_in->client);
	if (ipa_ep_idx == -1) {
		IPAERR("Invalid client :%d\n", sys_in->client);
		goto fail_gen;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	ipa_ep_idx = ipa2_get_ep_mapping(sys_in->client);
	if (unlikely(ipa_ep_idx == -1)) {
		IPAERR("Invalid client :%d\n", sys_in->client);
		goto fail_gen;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: unlikely() on error branch (#14/14)"

read -r -d '' OLD <<'PORT_EOF' || true
		return INVALID_EP_MAPPING_INDEX;
	}

	if (client >= IPA_CLIENT_MAX || client < 0) {
		IPAERR_RL("Bad client number! client =%d\n", client);
		return INVALID_EP_MAPPING_INDEX;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		return INVALID_EP_MAPPING_INDEX;
	}

	if (unlikely(client >= IPA_CLIENT_MAX || client < 0)) {
		IPAERR_RL("Bad client number! client =%d\n", client);
		return INVALID_EP_MAPPING_INDEX;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_utils.c" "ipa_utils.c: unlikely() on client-range check in ipa2_get_ep_mapping()"

read -r -d '' OLD <<'PORT_EOF' || true
		break;
	}

	if (!ep_mapping[hw_type_index][client].valid)
		return INVALID_EP_MAPPING_INDEX;

	return ep_mapping[hw_type_index][client].pipe_num;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		break;
	}

	if (unlikely(!ep_mapping[hw_type_index][client].valid))
		return INVALID_EP_MAPPING_INDEX;

	return ep_mapping[hw_type_index][client].pipe_num;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_utils.c" "ipa_utils.c: unlikely() on invalid-mapping check"


section "Datapath correctness fixes"
read -r -d '' OLD <<'PORT_EOF' || true
	struct ipa_hdr_entry *hdr_entry;

	if (buf == NULL) {
		memset(tmp, 0, (IPA_RT_FLT_HW_RULE_BUF_SIZE/4));
		buf = (u8 *)tmp;
	}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	struct ipa_hdr_entry *hdr_entry;

	if (buf == NULL) {
		memset(tmp, 0, (IPA_RT_FLT_HW_RULE_BUF_SIZE/4) * sizeof(uint32_t));
		buf = (u8 *)tmp;
	}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_rt.c" "ipa_rt.c: fix vendor memset size bug (u32 elements, missing *sizeof(uint32_t))"

read -r -d '' OLD <<'PORT_EOF' || true
	IPA_ACTIVE_CLIENTS_INC_EP(ipa2_get_client_mapping(clnt_hdl));

	ipa_ctx->ctrl->ipa_cfg_ep_route(clnt_hdl,
			ipa_ctx->ep[clnt_hdl].rt_tbl_idx);

	IPA_ACTIVE_CLIENTS_DEC_EP(ipa2_get_client_mapping(clnt_hdl));

	return 0;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	IPA_ACTIVE_CLIENTS_INC_EP(ipa2_get_client_mapping(clnt_hdl));

	ipa_ctx->ctrl->ipa_cfg_ep_route(clnt_hdl,
			ipa_ctx->ep[clnt_hdl].rt_tbl_idx);

	IPA_ACTIVE_CLIENTS_DEC_EP(ipa2_get_client_mapping(clnt_hdl));

	/* Empirical bringup carry-over: write the route register a second
	 * time under a fresh clock vote. Inherited from the proven-working
	 * 20.5 Mbps bringup state; never isolated as strictly necessary,
	 * kept because removing it was not re-validated on hardware. */
	IPA_ACTIVE_CLIENTS_INC_EP(ipa2_get_client_mapping(clnt_hdl));
	ipa_ctx->ctrl->ipa_cfg_ep_route(clnt_hdl, ipa_ctx->ep[clnt_hdl].rt_tbl_idx);
	IPA_ACTIVE_CLIENTS_DEC_EP(ipa2_get_client_mapping(clnt_hdl));

	return 0;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_utils.c" "ipa_utils.c: empirical double-write of EP route register (bringup carry-over)"


section "rmnet_ipa0 netdev behavior on mainline"
read -r -d '' OLD <<'PORT_EOF' || true
	}

	if (evt != IPA_WRITE_DONE) {
		IPAWANERR("unsupported evt on Tx callback, Drop the packet\n");
		dev_kfree_skb_any(skb);
		dev->stats.tx_dropped++;
		return;
	}

	wwan_ptr = netdev_priv(dev);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	if (evt != IPA_WRITE_DONE) {
		switch (evt) {
		case IPA_RECEIVE:
			/* Exception loopback from modem-side IPA HW. Status prefix
			 * (first 8 bytes) has the exception code -- dump for diag.
			 * DROP the packet -- re-injecting it via netif_rx confuses
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
		}
	}

	wwan_ptr = netdev_priv(dev);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: TX_EVT_FIX - classify non-WRITE_DONE TX events instead of blind drop"

read -r -d '' OLD <<'PORT_EOF' || true
	return rc;
}

static const struct net_device_ops ipa_wwan_ops_ip = {
	.ndo_open = ipa_wwan_open,
	.ndo_stop = ipa_wwan_stop,
	.ndo_start_xmit = ipa_wwan_xmit,
	.ndo_tx_timeout = ipa_wwan_tx_timeout,
	.ndo_do_ioctl = ipa_wwan_ioctl,
	.ndo_change_mtu = ipa_wwan_change_mtu,
	.ndo_set_mac_address = NULL,
	.ndo_validate_addr = NULL,
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	return rc;
}

/* __rmnet_siocdevprivate_patch__ */
/*
 * Adapter for mainline 5.15+ ndo_siocdevprivate signature.
 * SIOCDEVPRIVATE-range ioctls (0x89F0-0x89FF) arrive here in modern
 * kernels instead of via the legacy ndo_do_ioctl.
 */
static int ipa_wwan_siocdevprivate(struct net_device *dev,
				    struct ifreq *ifr,
				    void __user *data,
				    int cmd)
{
	/* The legacy ipa_wwan_ioctl reads userspace via ifr_ifru.ifru_data,
	 * which the new entry point passes separately in `data`. Patch it
	 * back into the ifreq so the unmodified handler keeps working. */
	ifr->ifr_ifru.ifru_data = (__force void __user *)data;
	return ipa_wwan_ioctl(dev, ifr, cmd);
}

static const struct net_device_ops ipa_wwan_ops_ip = {
	.ndo_open = ipa_wwan_open,
	.ndo_stop = ipa_wwan_stop,
	.ndo_start_xmit = ipa_wwan_xmit,
	.ndo_tx_timeout = ipa_wwan_tx_timeout,
	.ndo_do_ioctl = ipa_wwan_ioctl,
	.ndo_siocdevprivate = ipa_wwan_siocdevprivate,
	.ndo_change_mtu = ipa_wwan_change_mtu,
	.ndo_set_mac_address = NULL,
	.ndo_validate_addr = NULL,
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: ndo_siocdevprivate adapter (RMNET ioctls land here on 5.15+)"

read -r -d '' OLD <<'PORT_EOF' || true
	dev->type = ARPHRD_RAWIP;
	dev->hard_header_len = 0;
	dev->mtu = WWAN_DATA_LEN;
	dev->addr_len = 0;
	dev->flags &= ~(IFF_BROADCAST | IFF_MULTICAST);
	dev->needed_headroom = HEADROOM_FOR_QMAP;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	dev->type = ARPHRD_RAWIP;
	dev->hard_header_len = 0;
	dev->mtu = WWAN_DATA_LEN;
	/* Mainline 6.19 ether_setup() sets max_mtu=ETH_DATA_LEN(1500), clamping
	 * our 2000 override at register_netdev time. Vendor 4.19 had
	 * max_mtu=ETH_MAX_MTU(0xFFFF) so no override needed there. Match
	 * Android's rmnet_ipa0 MTU=2000 (= WWAN_DATA_LEN) for AGG frame headroom. */
	dev->max_mtu = WWAN_DATA_LEN;
	dev->addr_len = 0;
	dev->flags &= ~(IFF_BROADCAST | IFF_MULTICAST);
	dev->needed_headroom = HEADROOM_FOR_QMAP;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: raise max_mtu so vendor MTU 2000 survives register_netdev clamp"

read -r -d '' OLD <<'PORT_EOF' || true

	/* Enable NAPI support in netdevice. */
	if (ipa_rmnet_res.ipa_napi_enable) {
		netif_napi_add(dev, &(wwan_ptr->napi),
			ipa_rmnet_poll, NAPI_WEIGHT);
	}

	ret = register_netdev(dev);
	if (ret) {
		IPAWANERR("unable to register ipa_netdev %d rc=%d\n",
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

	/* Enable NAPI support in netdevice. */
	if (ipa_rmnet_res.ipa_napi_enable) {
		netif_napi_add_weight(dev, &(wwan_ptr->napi),
			ipa_rmnet_poll, NAPI_WEIGHT);
	}

	/* __rmnet_set_netdev_dev_patch__ */
	SET_NETDEV_DEV(dev, &pdev->dev);
	ret = register_netdev(dev);
	if (ret) {
		IPAWANERR("unable to register ipa_netdev %d rc=%d\n",
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: netif_napi_add_weight (keep vendor NAPI_WEIGHT=60) + SET_NETDEV_DEV parent"

read -r -d '' OLD <<'PORT_EOF' || true
	return 0;
}

static void ipa_stop_polling_stats(void)
{
	cancel_delayed_work(&ipa_tether_stats_poll_wakequeue_work);
	ipa_rmnet_ctx.polling_interval = 0;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	return 0;
}

static void __maybe_unused ipa_stop_polling_stats(void)
{
	cancel_delayed_work(&ipa_tether_stats_poll_wakequeue_work);
	ipa_rmnet_ctx.polling_interval = 0;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: ipa_stop_polling_stats unused after SSR fix -> __maybe_unused"


section "ModemManager integration (driver names, sysfs endpoint ids, probe order)"
read -r -d '' OLD <<'PORT_EOF' || true

#if IS_ENABLED(CONFIG_RMNET_IPA)

int ipa_qmi_service_init(uint32_t wan_platform_type);

void ipa_qmi_service_exit(void);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

#if IS_ENABLED(CONFIG_RMNET_IPA)

/* rmnet_ipa module entry/exit — non-static so ipa_api.c can call them
 * from ipa_module_init (see apply-port-patches.sh notes). */
int ipa_wwan_init(void);
void ipa_wwan_cleanup(void);

int ipa_qmi_service_init(uint32_t wan_platform_type);

void ipa_qmi_service_exit(void);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.h" "ipa_qmi_service.h: declare ipa_wwan_init/cleanup (called cross-file from ipa_module_init)"

read -r -d '' OLD <<'PORT_EOF' || true
{
	bool ret;

	IPA_API_DISPATCH_RETURN_BOOL(ipa_get_lan_rx_napi);

	return ret;
}
EXPORT_SYMBOL(ipa_get_lan_rx_napi);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
{
	bool ret;

	if (ipa_api_hw_type == 6)
		return false;
	else {
		IPA_API_DISPATCH_RETURN_BOOL(ipa_get_lan_rx_napi);
		return ret;
	}
}
EXPORT_SYMBOL(ipa_get_lan_rx_napi);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_api.c" "ipa_api.c: v2.6L has no get_lan_rx_napi impl -> return false instead of dispatch"

read -r -d '' OLD <<'PORT_EOF' || true
	.resume_early = ipa_ap_resume,
};

static struct platform_driver ipa_plat_drv = {
	.probe = ipa_generic_plat_drv_probe,
	.driver = {
		.name = DRV_NAME,
		.pm = &ipa_pm_ops,
		.of_match_table = ipa_plat_drv_match,
	},
};
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	.resume_early = ipa_ap_resume,
};

/* ---- sysfs attribute group: modem/{tx,rx}_endpoint_id ----
 *
 * ModemManager 1.20+ src/mm-port-qmi.c:1671 dpm_open_port() reads:
 *   /sys/class/net/rmnet_ipa0/device/modem/tx_endpoint_id
 *   /sys/class/net/rmnet_ipa0/device/modem/rx_endpoint_id
 * to know which IPA endpoints carry modem TX/RX data. Without these,
 * MM logs "Unable to read TX and RX endpoint IDs from sysfs. skipping
 * automatic DPM port opening." → WDA Get returns InvalidArgument → MM
 * CTL fallback fails MUX_RMNET → bearer connect returns "Multiplexing
 * required but not supported".
 *
 * Mainline IPA 3 + ipa2-lite + ipa_v2_hybrid + new ipa_v2_6L all expose
 * these. Adding them to vendor driver per same convention.
 *
 * Hardcoded values for SDM636 v2.6L (per vendor pipe mapping in
 * drivers/platform/msm/ipa/ipa_v2/ipa_utils.c IPA_CLIENT_APPS_LAN_WAN_PROD
 * = pipe 4, IPA_CLIENT_APPS_WAN_CONS = pipe 5). If you port this to
 * another SoC, replace literals with ipa2_get_ep_mapping() calls.
 */
static ssize_t tx_endpoint_id_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", 4);	/* APPS_LAN_WAN_PROD = pipe 4 */
}
static DEVICE_ATTR_RO(tx_endpoint_id);

static ssize_t rx_endpoint_id_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", 5);	/* APPS_WAN_CONS = pipe 5 */
}
static DEVICE_ATTR_RO(rx_endpoint_id);

static struct attribute *ipa_modem_attrs[] = {
	&dev_attr_tx_endpoint_id.attr,
	&dev_attr_rx_endpoint_id.attr,
	NULL,
};

static const struct attribute_group ipa_modem_attr_group = {
	.name = "modem",
	.attrs = ipa_modem_attrs,
};

static const struct attribute_group *ipa_v2_groups[] = {
	&ipa_modem_attr_group,
	NULL,
};

static struct platform_driver ipa_plat_drv = {
	.probe = ipa_generic_plat_drv_probe,
	.driver = {
		/* Renamed from DRV_NAME ("ipa") to "ipa-core" so the
		 * "ipa" platform_driver name can be claimed by rmnet_ipa
		 * driver — which is what owns the rmnet_ipa0 netdev that
		 * MM walks the parent chain from. With this rename:
		 *   /sys/bus/platform/drivers/ipa       = rmnet_ipa driver
		 *   /sys/bus/platform/drivers/ipa-core  = this main driver
		 * MM's stock 77-mm-qcom-soc.rules DRIVERS=="ipa" will now
		 * match on rmnet_ipa0's parent device. DRV_NAME stays "ipa"
		 * so /dev/ipa chardev, class "ipa", etc. unchanged.
		 */
		.name = "ipa-core",
		.pm = &ipa_pm_ops,
		.of_match_table = ipa_plat_drv_match,
		.dev_groups = ipa_v2_groups,
	},
};
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_api.c" "ipa_api.c: modem/{tx,rx}_endpoint_id sysfs + rename driver to \"ipa-core\""

read -r -d '' OLD <<'PORT_EOF' || true
		return pci_register_driver(&ipa_pci_driver);
	}
#endif
	/* Register as a platform device driver */
	{ extern int __init ipa_wwan_init(void); ipa_wwan_init(); }
	return platform_driver_register(&ipa_plat_drv);
}
subsys_initcall(ipa_module_init);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		return pci_register_driver(&ipa_pci_driver);
	}
#endif
	/* IPA_INIT_ORDER_FIX: Register IPA platform driver FIRST.
	 * platform_driver_register() is synchronous on DT match - by the time
	 * it returns, ipa2_is_ready() is true and rmnet probe will succeed.
	 */
	{
		int ret = platform_driver_register(&ipa_plat_drv);
		if (ret)
			return ret;
	}
	/* IPA is initialized - now safe to register rmnet which depends on it */
	{ extern int __init ipa_wwan_init(void); ipa_wwan_init(); }
	return 0;
}
subsys_initcall(ipa_module_init);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_api.c" "ipa_api.c: register IPA platform driver before rmnet (probe-order fix)"

read -r -d '' OLD <<'PORT_EOF' || true
	.resume_noirq = rmnet_ipa_ap_resume,
};

static struct platform_driver rmnet_ipa_driver = {
	.driver = {
		.name = "rmnet_ipa",
		.pm = &rmnet_ipa_pm_ops,
		.of_match_table = rmnet_ipa_dt_match,
	},
	.probe = ipa_wwan_probe,
	.remove = ipa_wwan_remove,
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	.resume_noirq = rmnet_ipa_ap_resume,
};

/* ---- ModemManager sysfs integration ----
 *
 * MM 1.20+ src/mm-port-qmi.c:1671 dpm_open_port() reads
 *   /sys/class/net/rmnet_ipa0/device/modem/tx_endpoint_id
 *   /sys/class/net/rmnet_ipa0/device/modem/rx_endpoint_id
 *
 * The "device" symlink on rmnet_ipa0 points to THIS driver's platform
 * device (soc@0:rmnet_ipa), not the main IPA driver's device. So the
 * sysfs files must hang off THIS platform_driver, not ipa_plat_drv in
 * ipa_api.c.
 *
 * udev DRIVERS== match also walks the parent chain from rmnet_ipa0
 * and finds "rmnet_ipa" — not "ipa". MM's 77-mm-qcom-soc.rules only
 * matches "ipa". A companion userspace udev rule must add the
 * ID_MM_QCOM_SOC tag for DRIVERS=="rmnet_ipa" (see Documentation/
 * ipa_v2-modemmanager.md).
 */
static ssize_t tx_endpoint_id_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", 4);	/* APPS_LAN_WAN_PROD pipe id */
}
static DEVICE_ATTR_RO(tx_endpoint_id);

static ssize_t rx_endpoint_id_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%u\n", 5);	/* APPS_WAN_CONS pipe id */
}
static DEVICE_ATTR_RO(rx_endpoint_id);

static struct attribute *rmnet_ipa_modem_attrs[] = {
	&dev_attr_tx_endpoint_id.attr,
	&dev_attr_rx_endpoint_id.attr,
	NULL,
};

static const struct attribute_group rmnet_ipa_modem_attr_group = {
	.name = "modem",
	.attrs = rmnet_ipa_modem_attrs,
};

static const struct attribute_group *rmnet_ipa_groups[] = {
	&rmnet_ipa_modem_attr_group,
	NULL,
};

static struct platform_driver rmnet_ipa_driver = {
	.driver = {
		/* MM 1.20+ src/mm-port-qmi.c whitelists exact net_driver
		 * names: "ipa", "bam-dmux", "qmi_wwan". With name="rmnet_ipa"
		 * MM rejects bearer create with:
		 *   "Unsupported QMI kernel driver for 'net/rmnet_ipa0': rmnet_ipa"
		 * Renamed to "ipa". Main IPA driver in ipa_api.c was simultaneously
		 * renamed to "ipa-core" to avoid duplicate-name conflict at
		 * platform_driver_register() (kernel rejects duplicates per bus).
		 */
		.name = "ipa",
		.pm = &rmnet_ipa_pm_ops,
		.of_match_table = rmnet_ipa_dt_match,
		.dev_groups = rmnet_ipa_groups,
	},
	.probe = ipa_wwan_probe,
	.remove = ipa_wwan_remove,
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: modem/ sysfs group + claim platform-driver name \"ipa\" for MM whitelist"


section "Modem SSR (subsystem restart) robustness on mainline q6v5"
read -r -d '' OLD <<'PORT_EOF' || true
#include <linux/ipa.h>
#include <uapi/linux/msm_rmnet.h>
#include <net/rmnet_config.h>

#include "ipa_trace.h"
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
#include <linux/ipa.h>
#include <uapi/linux/msm_rmnet.h>
#include <net/rmnet_config.h>
/* __subsys_notif_shim__ */
#include <linux/remoteproc/qcom_rproc.h>

#include "ipa_trace.h"
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: include <linux/remoteproc/qcom_rproc.h> for direct SSR API"

read -r -d '' OLD <<'PORT_EOF' || true
			pr_info("IPA received MPSS BEFORE_SHUTDOWN\n");
			/* send SSR before-shutdown notification to IPACM */
			rmnet_ipa_send_ssr_notification(false);
			atomic_set(&is_ssr, 1);
			ipa_q6_pre_shutdown_cleanup();
			if (ipa_netdevs[0])
				netif_stop_queue(ipa_netdevs[0]);
			ipa_qmi_stop_workqueues();
			wan_ioctl_stop_qmi_messages();
			ipa_stop_polling_stats();
			if (atomic_read(&is_initialized))
				platform_driver_unregister(&rmnet_ipa_driver);
			pr_info("IPA BEFORE_SHUTDOWN handling is complete\n");
			return NOTIFY_DONE;
		}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			pr_info("IPA received MPSS BEFORE_SHUTDOWN\n");
			/* send SSR before-shutdown notification to IPACM */
			rmnet_ipa_send_ssr_notification(false);
			/* __no_stuck_incremental__ - is_ssr=1 removed (was stuck) */
			ipa_q6_pre_shutdown_cleanup();
			if (ipa_netdevs[0])
				netif_stop_queue(ipa_netdevs[0]);
			/* __qmi_workqueue_stuck_fix__ - keep workqueue alive across SSR */
			/* __qmi_workqueue_stuck_fix__ wan_ioctl_stop_qmi_messages skipped */
			/* __qmi_workqueue_stuck_fix__ ipa_stop_polling_stats skipped */
			/* __keep_rmnet_driver_patch__ - keep driver registered
			 * across modem restart cycles so rmnet_ipa0 survives.
			 * Mainline 6.x q6v5 may not reliably emit AFTER_POWERUP
			 * after every BEFORE_SHUTDOWN, so unregistering would
			 * permanently lose the netdev. */
			pr_info("IPA: keeping rmnet_ipa_driver registered across SSR\n");
			pr_info("IPA BEFORE_SHUTDOWN handling is complete\n");
			return NOTIFY_DONE;
		}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: BEFORE_SHUTDOWN - keep driver registered + workqueues alive across SSR"


section "Modern-kbuild hard errors (missing prototypes, fortify, type mismatches)"
read -r -d '' OLD <<'PORT_EOF' || true
#if IS_ENABLED(CONFIG_IPA)
int ipa_plat_drv_probe(struct platform_device *pdev_p,
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
/* Port fix: prototypes for the EXPORT_SYMBOL'd dispatcher entry points
 * below — modern kbuild promotes -Wmissing-prototypes to an error. */
int ipa_sys_setup(struct ipa_sys_connect_params *sys_in,
	unsigned long *ipa_bam_or_gsi_hdl,
	u32 *ipa_pipe_num, u32 *clnt_hdl, bool en_status);
int ipa_sys_teardown(u32 clnt_hdl);
int ipa_sys_update_gsi_hdls(u32 clnt_hdl, unsigned long gsi_ch_hdl,
	unsigned long gsi_ev_hdl);
struct device *ipa_get_pdev(void);

#if IS_ENABLED(CONFIG_IPA)
int ipa_plat_drv_probe(struct platform_device *pdev_p,
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_api.h" "ipa_api.h: prototypes for exported dispatcher entry points"

read -r -d '' OLD <<'PORT_EOF' || true
void ipa_register_client_callback(int (*client_cb)(bool is_lock),
			bool (*teth_port_state)(void), u32 ipa_ep_idx);

void ipa_deregister_client_callback(u32 ipa_ep_idx);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
void ipa_register_client_callback(int (*client_cb)(bool is_lock),
			bool (*teth_port_state)(void),
			enum ipa_client_type client);

void ipa_deregister_client_callback(enum ipa_client_type client);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_common_i.h" "ipa_common_i.h: align client-callback decls with definitions (enum, not u32)"

read -r -d '' OLD <<'PORT_EOF' || true
/**
 * ipa_rm_add_dependency_sync_from_ioctl() - Create a dependency between 2
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
/* Port fix: no header declares this ioctl-path helper; prototype here
 * keeps -Wmissing-prototypes quiet without widening the API surface. */
int ipa_rm_add_dependency_sync_from_ioctl(
	enum ipa_rm_resource_name resource_name,
	enum ipa_rm_resource_name depends_on_name);

/**
 * ipa_rm_add_dependency_sync_from_ioctl() - Create a dependency between 2
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_rm.c" "ipa_rm.c: local prototype for the ioctl-path dependency helper"

read -r -d '' OLD <<'PORT_EOF' || true
	if (ipa_ctx->ipa2_active_clients_logging.log_buffer == NULL) {
		IPAERR("Active Clients Logging memory allocation failed");
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	/* Port fix: log_buffer is an array — vendor checked its address
	 * (always non-NULL); check the actual allocation instead. */
	if (ipa_ctx->ipa2_active_clients_logging.log_buffer[0] == NULL) {
		IPAERR("Active Clients Logging memory allocation failed");
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: NULL-check the allocation, not the array address (-Werror=address)"

read -r -d '' OLD <<'PORT_EOF' || true
struct iommu_domain *ipa2_get_smmu_domain(void);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
struct iommu_domain *ipa2_get_smmu_domain(void);
struct iommu_domain *ipa2_get_smmu_domain_by_type(
	enum ipa_smmu_cb_type cb_type);
int ipa2_cfg_ep_metadata(u32 clnt_hdl,
	const struct ipa_ep_cfg_metadata *ep_md);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_i.h" "ipa_i.h: declare ipa2_get_smmu_domain_by_type + ipa2_cfg_ep_metadata"

read -r -d '' OLD <<'PORT_EOF' || true
static const char * const ipa_get_mode_type_str(
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static const char *ipa_get_mode_type_str(
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_utils.c" "ipa_utils.c: drop ignored const on return type (ipa_get_mode_type_str)"

read -r -d '' OLD <<'PORT_EOF' || true
static const char * const get_aggr_enable_str(
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static const char *get_aggr_enable_str(
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_utils.c" "ipa_utils.c: ditto (get_aggr_enable_str)"

read -r -d '' OLD <<'PORT_EOF' || true
static const char * const get_aggr_type_str(
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static const char *get_aggr_type_str(
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_utils.c" "ipa_utils.c: ditto (get_aggr_type_str)"


section "Modern-kbuild hard errors (pattern fixes)"

# Vendor debugfs/dma write handlers guard the user copy with
#     if (sizeof(dbg_buff) < count + 1) return -EFAULT;
# `count + 1` may overflow (count == SIZE_MAX), so fortify cannot prove the
# copy bounded and fails the build (__bad_copy_to). Rewrite all 9 sites to
# the overflow-safe form. Idempotent (pattern no longer matches once fixed).
fixed=0
for f in drivers/platform/msm/ipa/ipa_v2/ipa_debugfs.c \
         drivers/platform/msm/ipa/ipa_v2/ipa_dma.c; do
	n=$(grep -c 'if (sizeof(dbg_buff) < count + 1)' "$SRC_ROOT/$f" || true)
	if [ "$n" != "0" ]; then
		perl -0777 -i -pe 's/if \(sizeof\(dbg_buff\) < count \+ 1\)/if (count >= sizeof(dbg_buff))/g' "$SRC_ROOT/$f"
		fixed=$((fixed + n))
	fi
done
if [ "$fixed" = "0" ]; then
	echo "  [skip] fortify-safe count guards in debugfs/dma write handlers"
	skipped=$((skipped+1))
else
	echo "  [ok]   fortify-safe count guards in debugfs/dma write handlers ($fixed sites)"
	applied=$((applied+1))
fi

echo
echo "============================================================"
echo "Done. $applied edit(s) applied, $skipped already present."
echo "============================================================"
