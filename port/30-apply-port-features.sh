#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 30-apply-port-features.sh
#
# Step 3 of the IPA v2.6L port: the datapath/throughput features that turn
# a probing driver into the 20.5 Mbps DL production configuration.
# REQUIRED - the driver compiles without this step but cellular data
# will not flow (no IPACM in userspace means nobody configures the pipes).
#
# Sections (in order):
#   qmapv3    qmapv3_ul_enable opt-in knob (vendor-parity UL, experimental)
#   q6rules   fixes for installing the 24 modem-supplied UL filter rules
#             (vendor code double-translated ip/action -> 0 rules matched)
#   autoipacm in-kernel IPACM emulation: replays the SET_EGRESS_DATA_FORMAT,
#             SET_INGRESS_DATA_FORMAT and ADD_MUX_CHANNEL ioctls the Android
#             IPACM daemon would issue, installs the 6 DL-acceleration
#             filter rules (ICMP/mcast/bcast x v4/v6) and performs the
#             INSTALL_FILTER_RULE + FILTER_INSTALLED_NOTIF QMI handshake
#             that engages modem-side HW DL forwarding
#   icc       interconnect bandwidth voting through msm_bus_compat.c
#   clk       fixed-NOMINAL clock policy (see the separate powersave patch
#             for re-enabling dynamic scaling)
#   knobs     ipa_wan_busypoll / ipa_disable_wan_agg A/B test params
#   power     system_power_efficient_wq for periodic work
#
# Idempotent: same guard discipline as 20-apply-port-fixes.sh.
#
# Usage:  ./30-apply-port-features.sh [--root /path/to/kernel]

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

section "Opt-in QMAPv3 UL (experimental, pairs with vendor-init --full-ul)"
read -r -d '' OLD <<'PORT_EOF' || true
static int num_q6_rule, old_num_q6_rule;
static int rmnet_index;
static bool egress_set, a7_ul_flt_set;
static struct workqueue_struct *ipa_rm_q6_workqueue; /* IPA_RM workqueue*/
static atomic_t is_initialized;
static atomic_t is_ssr;
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static int num_q6_rule, old_num_q6_rule;
static int rmnet_index;
static bool egress_set, a7_ul_flt_set;
/* 2026-05-31: opt-in UL QMAPv3 path. Default 0 = current proven-working
 * QMAPv1 UL (no IPA-level UL csum offload, no UL header beyond 4B QMAP).
 * Set to 1 to enable vendor-parity QMAPv3 UL: hdr_len=8 + cs_offload_en=UL +
 * cs_metadata_hdr_offset=1, matching lineage-sdm660-22.2/.../rmnet_ipa.c:1675.
 *
 * Pairs with vendor-init userspace setting WDA_UL_PROTO=7 AND rmnet flag
 * `egress-mapv4-checksum on` on qmapmux0.0. Without those, this knob alone
 * does nothing (vendor-init keeps modem on UL=5).
 *
 * Toggle live: echo 1 > /sys/module/ipa_driver/parameters/qmapv3_ul_enable
 * (requires re-init — easiest is to stop+restart ModemManager OR re-run
 * vendor-init). On break, reboot returns to safe defaults. */
static int qmapv3_ul_enable;
module_param(qmapv3_ul_enable, int, 0644);
MODULE_PARM_DESC(qmapv3_ul_enable,
	"Enable QMAPv3 UL on EGRESS pipe 4 (hdr_len=8 + cs_offload_en=UL). "
	"Default 0 (QMAPv1 UL, proven-working). 1 = vendor-parity UL QMAPv3 "
	"(experimental — needs vendor-init WDA_UL_PROTO=7 + egress-mapv4-checksum on)");
static struct workqueue_struct *ipa_rm_q6_workqueue; /* IPA_RM workqueue*/
static atomic_t is_initialized;
static atomic_t is_ssr;
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: qmapv3_ul_enable module param (opt-in vendor-parity UL QMAPv3)"


section "Q6 modem filter-rule install fixes (the rules actually match now)"
read -r -d '' OLD <<'PORT_EOF' || true

	mutex_lock(&ipa_qmi_lock);
	for (i = 0; i < num_q6_rule; i++) {
		param->ip = ipa_qmi_ctx->q6_ul_filter_rule[i].ip;
		memset(&flt_rule_entry, 0, sizeof(struct ipa_flt_rule_add));
		flt_rule_entry.at_rear = true;
		flt_rule_entry.rule.action =
			ipa_qmi_ctx->q6_ul_filter_rule[i].action;
		flt_rule_entry.rule.rt_tbl_idx
		= ipa_qmi_ctx->q6_ul_filter_rule[i].rt_tbl_idx;
		flt_rule_entry.rule.retain_hdr = true;

		/* debug rt-hdl*/
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

	mutex_lock(&ipa_qmi_lock);
	for (i = 0; i < num_q6_rule; i++) {
		/* IP type was ALREADY translated from QMI -> IPA enum in
		 * copy_ul_filter_rule_to_ipa(). Use the value directly.
		 * Previous code did a SECOND broken translation that mapped
		 * IPA_IP_v6 (1) back to IPA_IP_v4 (0) -- causing all 11 IPv6
		 * modem rules to install as IPv4, and all 13 wildcard rules
		 * (translated to IPA_IP_MAX=2) to install as IPv6. Result:
		 * zero rules actually matched modem packets.
		 *
		 * NOTE on IPA_IP_MAX: modem sometimes sends QMI ip_type=0
		 * (INVALID per QMI v01 enum, but in vendor Android IPACM
		 * convention this means "V4V6 wildcard"). copy_ul_filter_*
		 * maps that to IPA_IP_MAX. ipa2_add_flt_rule rejects
		 * IPA_IP_MAX with -EINVAL (validates ip < IPA_IP_MAX).
		 * Vendor IPACM userspace handles this by installing the
		 * rule TWICE: once for v4, once for v6. We replicate that
		 * dual-install logic below.
		 */
		memset(&flt_rule_entry, 0, sizeof(struct ipa_flt_rule_add));
		flt_rule_entry.at_rear = true;
		/* action is ALREADY an IPA enum (IPA_PASS_TO_*), translated from
		 * the QMI filter_action in copy_ul_filter_rule_to_ipa(). Use it
		 * directly, exactly as vendor does. A prior switch here re-mapped
		 * it as if it were a raw QMI code, mis-translating every non-
		 * ROUTING action (SRC_NAT/DST_NAT/EXCEPTION). */
		flt_rule_entry.rule.action =
			ipa_qmi_ctx->q6_ul_filter_rule[i].action;
		flt_rule_entry.rule.rt_tbl_idx =
			ipa_qmi_ctx->q6_ul_filter_rule[i].rt_tbl_idx;
		flt_rule_entry.rule.retain_hdr = true;

		/* debug rt-hdl*/
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: stop double-translating Q6 rule ip/action (broke all modem rules)"

read -r -d '' OLD <<'PORT_EOF' || true
			sizeof(struct ipa_ipfltri_rule_eq));
		memcpy(&(param->rules[0]), &flt_rule_entry,
			sizeof(struct ipa_flt_rule_add));
		if (ipa2_add_flt_rule((struct ipa_ioc_add_flt_rule *)param)) {
			retval = -EFAULT;
			IPAWANERR("add A7 UL filter rule(%d) failed\n", i);
		} else {
			/* store the rule handler */
			ipa_qmi_ctx->q6_ul_filter_rule_hdl[i] =
				param->rules[0].flt_rule_hdl;
		}
	}
	mutex_unlock(&ipa_qmi_lock);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
			sizeof(struct ipa_ipfltri_rule_eq));
		memcpy(&(param->rules[0]), &flt_rule_entry,
			sizeof(struct ipa_flt_rule_add));
		/* IPA_IP_MAX = V4V6 wildcard from modem (QMI ip_type=0).
		 * ipa2_add_flt_rule validates ip < IPA_IP_MAX, so we have
		 * to install twice (once per ip family) just like vendor
		 * IPACM does. We store the v4 handle in q6_ul_filter_rule_hdl
		 * (the v6 install is fire-and-forget for the modem-side
		 * filter table — Q6 only tracks handles by index).
		 */
		if (ipa_qmi_ctx->q6_ul_filter_rule[i].ip == IPA_IP_MAX) {
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
	mutex_unlock(&ipa_qmi_lock);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: install V4V6 wildcard rules twice (v4+v6) like vendor IPACM"

read -r -d '' OLD <<'PORT_EOF' || true
	param->num_hdls = (uint8_t) 1;

	for (i = 0; i < old_num_q6_rule; i++) {
		param->ip = ipa_qmi_ctx->q6_ul_filter_rule[i].ip;
		memset(&flt_rule_entry, 0, sizeof(struct ipa_flt_rule_del));
		flt_rule_entry.hdl = ipa_qmi_ctx->q6_ul_filter_rule_hdl[i];
		/* debug rt-hdl*/
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	param->num_hdls = (uint8_t) 1;

	for (i = 0; i < old_num_q6_rule; i++) {
		/* Translate QMI ip type to IPA driver enum */
		if (ipa_qmi_ctx->q6_ul_filter_rule[i].ip == 1)	/* QMI v4 */
			param->ip = IPA_IP_v4;
		else if (ipa_qmi_ctx->q6_ul_filter_rule[i].ip == 2)	/* QMI v6 */
			param->ip = IPA_IP_v6;
		else	/* already translated or unknown */
			param->ip = ipa_qmi_ctx->q6_ul_filter_rule[i].ip;
		memset(&flt_rule_entry, 0, sizeof(struct ipa_flt_rule_del));
		flt_rule_entry.hdl = ipa_qmi_ctx->q6_ul_filter_rule_hdl[i];
		/* debug rt-hdl*/
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: delete-path ip-type translation for replaced Q6 rules"


section "In-kernel IPACM emulation (EGRESS/INGRESS/ADD_MUX + DL-accel handshake)"
read -r -d '' OLD <<'PORT_EOF' || true
static struct mutex add_mux_channel_lock;
static int wwan_add_ul_flt_rule_to_ipa(void);
static int wwan_del_ul_flt_rule_to_ipa(void);
static void ipa_wwan_msg_free_cb(void*, u32, u32);
static void ipa_rmnet_rx_cb(void *priv);
static int ipa_rmnet_poll(struct napi_struct *napi, int budget);
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
static struct mutex add_mux_channel_lock;
static int wwan_add_ul_flt_rule_to_ipa(void);
static int wwan_del_ul_flt_rule_to_ipa(void);
/* In-kernel IPACM emulation: replicate the 3 ioctls IPACM userspace
 * normally drives (SET_EGRESS, SET_INGRESS, ADD_MUX_CHANNEL) so the
 * vendor driver brings up pipe 5 + AP filters without userspace help.
 * Hooked off ipa_q6_handshake_complete with ~3s delay matching the
 * vendor_sondas.log timing (t=71.98s ioctls vs t=68.6s handshake).
 */
static struct delayed_work auto_ipacm_init_work;
static atomic_t auto_ipacm_init_done = ATOMIC_INIT(0);
static void vendor_auto_ipacm_init_fn(struct work_struct *work);
static int handle_ingress_format(struct net_device *dev,
		struct rmnet_ioctl_extended_s *in);

/* Phase 4s: add explicit ICMP (proto=1) filter rule with PASS_TO_ROUTING
 * action and rt_idx = ipa_dflt_wan_rt (= 8). Vendor IPACM's
 * IPACM_Wan::config_dft_firewall_rules / add_dft_filtering_rule installs
 * per-protocol catchall rules so stateless protocols (ICMP, ALG ports)
 * get explicit hardware acceptance instead of relying on session-state
 * matching of TCP/UDP wildcards.
 *
 * On mainline (no IPACM userspace) we have 24 Q6 modem-supplied wildcard
 * rules from Phase 4f, but those may not all match ICMP behaviorally —
 * adding this explicit rule narrows the matching path.
 */
static int install_icmp_passthrough_rule(void);
static int install_mcast_bcast_filter_rules(void);
static int install_wan_dl_qmi_filter_notify(void);
static int install_wan_dl_qmi_filter_installed_notif(void);

/* Track installed apps-side flt rule handles for the 6 DL acceleration rules
 * (icmp/mcast/bcast for both v4 + v6). Used by install_wan_dl_qmi_filter_notify
 * to send INSTALL_FILTER_RULE 0x0023 to modem with matching specs, and by
 * install_wan_dl_qmi_filter_installed_notif to send FILTER_INSTALLED_NOTIF
 * 0x0024 with these handles after install confirmed. */
static u32 wan_dl_flt_icmp_v4_hdl;
static u32 wan_dl_flt_icmp_v6_hdl;
static u32 wan_dl_flt_mcast_v4_hdl;
static u32 wan_dl_flt_bcast_v4_hdl;
static u32 wan_dl_flt_mcast_v6_hdl;
static u32 wan_dl_flt_lnklcl_v6_hdl;
static void ipa_wwan_msg_free_cb(void*, u32, u32);
static void ipa_rmnet_rx_cb(void *priv);
static int ipa_rmnet_poll(struct napi_struct *napi, int budget);
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: auto-IPACM declarations + DL-acceleration rule handles"

read -r -d '' OLD <<'PORT_EOF' || true
	rmnet_ipa_send_quota_reach_ind();
}

/**
 * ipa_q6_handshake_complete() - Perform operations once Q6 is up
 * @ssr_bootup - Indicates whether this is a cold boot-up or post-SSR.
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	rmnet_ipa_send_quota_reach_ind();
}

/*
 * Resolve the modem-side WAN routing-table index for the local WAN-DL
 * passthrough filter rules.
 *
 * eq_attrib filter rules may only target a MODEM routing table:
 * __ipa_add_flt_rule() rejects rt_tbl_idx > v{4,6}_modem_rt_index_hi
 * (== 6 on 2.6L, 3 on v2.0). The historical hardcoded rt_tbl_idx=8
 * (ipa_dflt_wan_rt — an APPS-range table, 7+) is therefore *always*
 * bounced with "invalid RT tbl" and these rules never install.
 *
 * Query the per-interface ext_props the modem registered (the same
 * source install_wan_dl_qmi_filter_notify() already uses) for the real
 * index. Returns IPA_WAN_DL_RT_IDX_NONE if it can't be resolved, in
 * which case the caller skips the (non-critical) install rather than
 * pushing a knowingly-invalid index.
 */
#define IPA_WAN_DL_RT_IDX_NONE 0xffffffffu
static u32 wan_dl_modem_rt_tbl_idx(void)
{
	struct ipa_ioc_query_intf intf_query;
	struct ipa_ioc_query_intf_ext_props *ext_q;
	u32 idx = IPA_WAN_DL_RT_IDX_NONE;
	const char *vc;
	size_t sz;

	if (rmnet_index <= 0)
		return IPA_WAN_DL_RT_IDX_NONE;

	vc = mux_channel[0].vchannel_name;
	memset(&intf_query, 0, sizeof(intf_query));
	strscpy(intf_query.name, vc, sizeof(intf_query.name));
	if (ipa_query_intf(&intf_query) != 0 || intf_query.num_ext_props == 0)
		return IPA_WAN_DL_RT_IDX_NONE;

	sz = sizeof(*ext_q) +
	     intf_query.num_ext_props * sizeof(struct ipa_ioc_ext_intf_prop);
	ext_q = kzalloc(sz, GFP_KERNEL);
	if (!ext_q)
		return IPA_WAN_DL_RT_IDX_NONE;

	strscpy(ext_q->name, vc, sizeof(ext_q->name));
	ext_q->num_ext_props = intf_query.num_ext_props;
	if (ipa_query_intf_ext_props(ext_q) == 0 && ext_q->num_ext_props > 0)
		idx = ext_q->ext[0].rt_tbl_idx;
	kfree(ext_q);

	return idx;
}

/*
 * Phase 4s: install explicit ICMP catch-all UL filter rule.
 * Replicates vendor IPACM_Wan::config_dft_firewall_rules's ICMP path.
 * Rule: protocol_eq=1 (ICMP), action=PASS_TO_ROUTING, rt_idx from
 * ext_props (modem WAN routing table). Installed for both v4 and v6.
 */
static int install_icmp_passthrough_rule(void)
{
	struct ipa_ioc_add_flt_rule *param;
	struct ipa_flt_rule_add *flt_rule;
	u32 pyld_sz, rt_idx;
	int rc, total_ok = 0;

	rt_idx = wan_dl_modem_rt_tbl_idx();
	if (rt_idx == IPA_WAN_DL_RT_IDX_NONE) {
		IPAWANDBG("WAN-DL modem rt_tbl_idx unavailable, skip ICMP rule\n");
		return 0;  /* non-critical */
	}

	pyld_sz = sizeof(struct ipa_ioc_add_flt_rule) +
		  sizeof(struct ipa_flt_rule_add);
	param = kzalloc(pyld_sz, GFP_KERNEL);
	if (!param)
		return -ENOMEM;

	param->commit = 1;
	param->ep = IPA_CLIENT_APPS_LAN_WAN_PROD;
	param->global = false;
	param->num_rules = 1;
	flt_rule = &param->rules[0];

	flt_rule->at_rear = true;
	flt_rule->flt_rule_hdl = -1;
	flt_rule->rule.action = IPA_PASS_TO_ROUTING;
	flt_rule->rule.rt_tbl_idx = rt_idx;  /* modem WAN rt tbl (ext_props) */
	flt_rule->rule.retain_hdr = true;
	flt_rule->rule.eq_attrib_type = true;
	/* protocol_eq: ICMP = 1 (v4) / ICMPv6 = 58 (v6, next_hdr) */
	flt_rule->rule.eq_attrib.rule_eq_bitmap = (1 << 1);
	flt_rule->rule.eq_attrib.protocol_eq_present = 1;

	/* v4 ICMP install */
	param->ip = IPA_IP_v4;
	flt_rule->rule.eq_attrib.protocol_eq = 1;  /* ICMP */
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_icmp_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}

	/* v6 ICMPv6 install */
	param->ip = IPA_IP_v6;
	flt_rule->rule.eq_attrib.protocol_eq = 58;  /* ICMPv6 next_hdr */
	flt_rule->flt_rule_hdl = -1;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_icmp_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}

	kfree(param);
	return total_ok ? 0 : -EFAULT;
}

/**
 * install_mcast_bcast_filter_rules() — install IPv4 multicast + broadcast
 * passthrough filter rules on APPS_LAN_WAN_PROD with action PASS_TO_ROUTING
 * and rt_tbl_idx=8 (ipa_dflt_wan_rt). Mirrors vendor IPACM's
 * IPACM_Wan::add_dft_filtering_rule v4 path (IPACM_Wan.cpp:3527-3608) for the
 * 2 wildcard-class rules. Saves resulting handles in wan_dl_flt_{mcast,bcast}_v4_hdl
 * so install_wan_dl_qmi_filter_notify can reference them in the QMI msg + notif.
 *
 * Equation form (matches what IPA_IOC_GENERATE_FLT_EQ produces from
 * attr-form dst_addr=X mask=Y):
 *   mcast 224.0.0.0/4:  offset_meq_32[0] = {offset=12, value=0xE0000000, mask=0xF0000000}
 *   bcast 255.255.255.255/32: offset_meq_32[0] = {offset=12, value=0xFFFFFFFF, mask=0xFFFFFFFF}
 *   rule_eq_bitmap = BIT(2)  (num_offset_meq_32=1, slot 0 used)
 */
static int install_mcast_bcast_filter_rules(void)
{
	struct ipa_ioc_add_flt_rule *param;
	struct ipa_flt_rule_add *flt_rule;
	u32 pyld_sz, rt_idx;
	int rc, total_ok = 0;

	rt_idx = wan_dl_modem_rt_tbl_idx();
	if (rt_idx == IPA_WAN_DL_RT_IDX_NONE) {
		IPAWANDBG("WAN-DL modem rt_tbl_idx unavailable, skip mcast/bcast rules\n");
		return 0;  /* non-critical */
	}

	pyld_sz = sizeof(struct ipa_ioc_add_flt_rule) +
		  sizeof(struct ipa_flt_rule_add);
	param = kzalloc(pyld_sz, GFP_KERNEL);
	if (!param)
		return -ENOMEM;

	param->commit = 1;
	param->ep = IPA_CLIENT_APPS_LAN_WAN_PROD;
	param->global = false;
	param->num_rules = 1;
	param->ip = IPA_IP_v4;
	flt_rule = &param->rules[0];

	flt_rule->at_rear = true;
	flt_rule->rule.action = IPA_PASS_TO_ROUTING;
	flt_rule->rule.rt_tbl_idx = rt_idx;  /* modem WAN rt tbl (ext_props) */
	flt_rule->rule.retain_hdr = true;
	flt_rule->rule.eq_attrib_type = true;

	/* mcast 224.0.0.0/4 */
	flt_rule->flt_rule_hdl = -1;
	memset(&flt_rule->rule.eq_attrib, 0, sizeof(flt_rule->rule.eq_attrib));
	flt_rule->rule.eq_attrib.rule_eq_bitmap = (1 << 2);  /* num_offset_meq_32=1 */
	flt_rule->rule.eq_attrib.num_offset_meq_32 = 1;
	flt_rule->rule.eq_attrib.offset_meq_32[0].offset = 12;        /* IPv4 dst_addr */
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xE0000000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xF0000000;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_mcast_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}

	/* bcast 255.255.255.255/32 */
	flt_rule->flt_rule_hdl = -1;
	memset(&flt_rule->rule.eq_attrib, 0, sizeof(flt_rule->rule.eq_attrib));
	flt_rule->rule.eq_attrib.rule_eq_bitmap = (1 << 2);
	flt_rule->rule.eq_attrib.num_offset_meq_32 = 1;
	flt_rule->rule.eq_attrib.offset_meq_32[0].offset = 12;
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFFFFFFFF;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFFFFFFFF;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_bcast_v4_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}

	/* === v6 rules === Mirror vendor IPACM_Wan::add_dft_filtering_rule v6
	 * (IPACM_Wan.cpp:3611-3770). Vendor sends FF00::/8 multicast and
	 * FE80::/10 link-local as PASS_TO_ROUTING toward APPS for the WAN_DL
	 * acceleration set. Both match on offset 8 of IPv6 header (dst_addr
	 * upper 32 bits). */
	param->ip = IPA_IP_v6;

	/* v6 mcast: ff00::/8 — match first byte of dst_addr (offset 24 from
	 * IPv6 header start) = 0xff. Encoded as 32-bit offset = 24, value =
	 * 0xff000000, mask = 0xff000000. */
	flt_rule->flt_rule_hdl = -1;
	memset(&flt_rule->rule.eq_attrib, 0, sizeof(flt_rule->rule.eq_attrib));
	flt_rule->rule.eq_attrib.rule_eq_bitmap = (1 << 2);
	flt_rule->rule.eq_attrib.num_offset_meq_32 = 1;
	flt_rule->rule.eq_attrib.offset_meq_32[0].offset = 24;
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFF000000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFF000000;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_mcast_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}

	/* v6 link-local: fe80::/10 — top 10 bits = 0xFE80. Match first 16
	 * bits of dst_addr. Encoded as 32-bit offset = 24, value =
	 * 0xfe800000, mask = 0xffc00000 (top 10 bits). */
	flt_rule->flt_rule_hdl = -1;
	memset(&flt_rule->rule.eq_attrib, 0, sizeof(flt_rule->rule.eq_attrib));
	flt_rule->rule.eq_attrib.rule_eq_bitmap = (1 << 2);
	flt_rule->rule.eq_attrib.num_offset_meq_32 = 1;
	flt_rule->rule.eq_attrib.offset_meq_32[0].offset = 24;
	flt_rule->rule.eq_attrib.offset_meq_32[0].value  = 0xFE800000;
	flt_rule->rule.eq_attrib.offset_meq_32[0].mask   = 0xFFC00000;
	rc = ipa2_add_flt_rule(param);
	if (!rc) {
		wan_dl_flt_lnklcl_v6_hdl = param->rules[0].flt_rule_hdl;
		total_ok++;
	}

	kfree(param);
	return total_ok ? 0 : -EFAULT;
}

/**
 * install_wan_dl_qmi_filter_notify() — send QMI INSTALL_FILTER_RULE (0x0023)
 * to modem Q6 telling it to install matching DL filter specs on its TX side.
 * This is the **critical** handshake that engages modem-side IPA HW accelerated
 * DL forwarding. Without it, modem keeps DL on slow Q6 SW relay (= our 240 KB/s
 * cap).
 *
 * Mirrors vendor IPACM_Filtering::AddWanDLFilteringRule (IPACM_Filtering.cpp:259-408)
 * for the 3-rule minimal set (icmp + mcast + bcast). Vendor IPACM uplny_log.txt
 * shows exactly 3 specs per INSTALL_FILTER_RULE call (matches our case).
 *
 * Required preconditions:
 *   - ipa_q6_clnt is up (modem QMI handshake complete)
 *   - install_icmp_passthrough_rule + install_mcast_bcast_filter_rules called
 *     (rule handles cached in wan_dl_flt_*_v4_hdl)
 *   - rt_tbl_idx=8 corresponds to ipa_dflt_wan_rt (true on this driver)
 *   - mux_id=1 matches what ADD_MUX_CHANNEL set
 *
 * Note: kernel qmi_filter_request_send rejects source_pipe_index_valid=1
 * with "vendor wants 0" check (see ipa_qmi_service.c:636). So we leave it 0.
 */
static int install_wan_dl_qmi_filter_notify(void)
{
	struct ipa_install_fltr_rule_req_msg_v01 *req;
	struct ipa_filter_spec_type_v01 *spec;
	int rc;

	/* Task #189: query per-interface ext_props for real mux_id + rt_tbl_idx.
	 * Vendor IPACM (IPACM_Iface.cpp:507) queries IPA_IOC_QUERY_INTF +
	 * QUERY_INTF_EXT_PROPS to get per-interface values. Hardcoded mux_id=1
	 * and rt_tbl_idx=8 are correct for default qmapmux0.0 only — for other
	 * mux channels they may differ. Read from ipa_ctx->intf_list (populated
	 * by wwan_register_to_ipa() at ADD_MUX_CHANNEL time). */
	u8  dl_mux_id    = 1;        /* fallback */
	u32 dl_rt_tbl_idx = 8;       /* fallback = ipa_dflt_wan_rt */

	if (rmnet_index > 0) {
		struct ipa_ioc_query_intf intf_query;
		const char *vc = mux_channel[0].vchannel_name;

		memset(&intf_query, 0, sizeof(intf_query));
		strscpy(intf_query.name, vc, sizeof(intf_query.name));
		if (ipa_query_intf(&intf_query) == 0 &&
		    intf_query.num_ext_props > 0) {
			struct ipa_ioc_query_intf_ext_props *ext_q;
			size_t sz = sizeof(*ext_q) +
				intf_query.num_ext_props *
				sizeof(struct ipa_ioc_ext_intf_prop);

			ext_q = kzalloc(sz, GFP_KERNEL);
			if (ext_q) {
				strscpy(ext_q->name, vc, sizeof(ext_q->name));
				ext_q->num_ext_props = intf_query.num_ext_props;
				if (ipa_query_intf_ext_props(ext_q) == 0 &&
				    ext_q->num_ext_props > 0) {
					dl_mux_id     = ext_q->ext[0].mux_id;
					dl_rt_tbl_idx = ext_q->ext[0].rt_tbl_idx;
				}
				kfree(ext_q);
			}
		}
	}

	req = kzalloc(sizeof(*req), GFP_KERNEL);
	if (!req)
		return -ENOMEM;

	req->filter_spec_list_valid = 1;
	req->filter_spec_list_len = 6;  /* Phase 3: expanded from 3 to 6 specs */
	req->source_pipe_index_valid = 0;  /* kernel rejects =1 */
	req->source_pipe_index = ipa2_get_ep_mapping(IPA_CLIENT_APPS_LAN_WAN_PROD);

	/* Spec 0: v4 ICMP — protocol == 1 */
	spec = &req->filter_spec_list[0];
	spec->filter_spec_identifier = 0;
	spec->ip_type = QMI_IPA_IP_TYPE_V4_V01;
	spec->filter_action = QMI_IPA_FILTER_ACTION_ROUTING_V01;
	spec->is_routing_table_index_valid = 1;
	spec->route_table_index = 8;  /* ipa_dflt_wan_rt */
	spec->is_mux_id_valid = 1;
	spec->mux_id = 1;
	spec->filter_rule.rule_eq_bitmap = (1 << 1);  /* protocol_eq_present */
	spec->filter_rule.protocol_eq_present = 1;
	spec->filter_rule.protocol_eq = 1;

	/* Spec 1: v4 mcast 224.0.0.0/4 */
	spec = &req->filter_spec_list[1];
	spec->filter_spec_identifier = 1;
	spec->ip_type = QMI_IPA_IP_TYPE_V4_V01;
	spec->filter_action = QMI_IPA_FILTER_ACTION_ROUTING_V01;
	spec->is_routing_table_index_valid = 1;
	spec->route_table_index = 8;
	spec->is_mux_id_valid = 1;
	spec->mux_id = 1;
	spec->filter_rule.rule_eq_bitmap = (1 << 2);  /* num_offset_meq_32 */
	spec->filter_rule.num_offset_meq_32 = 1;
	spec->filter_rule.offset_meq_32[0].offset = 12;
	spec->filter_rule.offset_meq_32[0].value  = 0xE0000000;
	spec->filter_rule.offset_meq_32[0].mask   = 0xF0000000;

	/* Spec 2: v4 bcast 255.255.255.255/32 */
	spec = &req->filter_spec_list[2];
	spec->filter_spec_identifier = 2;
	spec->ip_type = QMI_IPA_IP_TYPE_V4_V01;
	spec->filter_action = QMI_IPA_FILTER_ACTION_ROUTING_V01;
	spec->is_routing_table_index_valid = 1;
	spec->route_table_index = 8;
	spec->is_mux_id_valid = 1;
	spec->mux_id = 1;
	spec->filter_rule.rule_eq_bitmap = (1 << 2);
	spec->filter_rule.num_offset_meq_32 = 1;
	spec->filter_rule.offset_meq_32[0].offset = 12;
	spec->filter_rule.offset_meq_32[0].value  = 0xFFFFFFFF;
	spec->filter_rule.offset_meq_32[0].mask   = 0xFFFFFFFF;

	/* Spec 3: v6 ICMPv6 — next_hdr == 58 */
	spec = &req->filter_spec_list[3];
	spec->filter_spec_identifier = 3;
	spec->ip_type = QMI_IPA_IP_TYPE_V6_V01;
	spec->filter_action = QMI_IPA_FILTER_ACTION_ROUTING_V01;
	spec->is_routing_table_index_valid = 1;
	spec->route_table_index = 8;
	spec->is_mux_id_valid = 1;
	spec->mux_id = 1;
	spec->filter_rule.rule_eq_bitmap = (1 << 1);  /* protocol_eq_present */
	spec->filter_rule.protocol_eq_present = 1;
	spec->filter_rule.protocol_eq = 58;  /* ICMPv6 next_hdr */

	/* Spec 4: v6 mcast ff00::/8 — first byte of v6 dst_addr at offset 24 */
	spec = &req->filter_spec_list[4];
	spec->filter_spec_identifier = 4;
	spec->ip_type = QMI_IPA_IP_TYPE_V6_V01;
	spec->filter_action = QMI_IPA_FILTER_ACTION_ROUTING_V01;
	spec->is_routing_table_index_valid = 1;
	spec->route_table_index = 8;
	spec->is_mux_id_valid = 1;
	spec->mux_id = 1;
	spec->filter_rule.rule_eq_bitmap = (1 << 2);
	spec->filter_rule.num_offset_meq_32 = 1;
	spec->filter_rule.offset_meq_32[0].offset = 24;
	spec->filter_rule.offset_meq_32[0].value  = 0xFF000000;
	spec->filter_rule.offset_meq_32[0].mask   = 0xFF000000;

	/* Spec 5: v6 link-local fe80::/10 */
	spec = &req->filter_spec_list[5];
	spec->filter_spec_identifier = 5;
	spec->ip_type = QMI_IPA_IP_TYPE_V6_V01;
	spec->filter_action = QMI_IPA_FILTER_ACTION_ROUTING_V01;
	spec->is_routing_table_index_valid = 1;
	spec->route_table_index = 8;
	spec->is_mux_id_valid = 1;
	spec->mux_id = 1;
	spec->filter_rule.rule_eq_bitmap = (1 << 2);
	spec->filter_rule.num_offset_meq_32 = 1;
	spec->filter_rule.offset_meq_32[0].offset = 24;
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

/**
 * install_wan_dl_qmi_filter_installed_notif() — send FILTER_INSTALLED_NOTIF
 * (msg 0x0024) to modem Q6 AFTER INSTALL_FILTER_RULE accepted. Tells Q6
 * "we (AP) really installed the matching specs on our end, here are our
 * A7-side handles + indices, you may now engage HW-accelerated DL
 * forwarding".
 *
 * Mirrors vendor IPACM_Filtering::SendFilteringRuleIndex (IPACM_Filtering.cpp).
 * Vendor IPACM sends this msg ROUTINELY after every INSTALL_FILTER_RULE
 * confirmed — modem firmware likely requires this confirmation before
 * activating HW accel for the bearer.
 *
 * Phase 3 — comprehensive audit Finding D 2026-05-30. Sent after our
 * install_wan_dl_qmi_filter_notify succeeds.
 */
static int install_wan_dl_qmi_filter_installed_notif(void)
{
	struct ipa_fltr_installed_notif_req_msg_v01 *req;
	int rc;
	u32 src_pipe = ipa2_get_ep_mapping(IPA_CLIENT_APPS_LAN_WAN_PROD);

	req = kzalloc(sizeof(*req), GFP_KERNEL);
	if (!req)
		return -ENOMEM;

	req->source_pipe_index = src_pipe;
	req->install_status = IPA_QMI_RESULT_SUCCESS_V01;
	req->filter_index_list_len = 6;
	/* index 0 = first slot of A7-side filter table; modem maps these
	 * indices to its own filter table slots */
	req->filter_index_list[0].filter_handle = wan_dl_flt_icmp_v4_hdl;
	req->filter_index_list[0].filter_index  = 0;
	req->filter_index_list[1].filter_handle = wan_dl_flt_mcast_v4_hdl;
	req->filter_index_list[1].filter_index  = 1;
	req->filter_index_list[2].filter_handle = wan_dl_flt_bcast_v4_hdl;
	req->filter_index_list[2].filter_index  = 2;
	req->filter_index_list[3].filter_handle = wan_dl_flt_icmp_v6_hdl;
	req->filter_index_list[3].filter_index  = 3;
	req->filter_index_list[4].filter_handle = wan_dl_flt_mcast_v6_hdl;
	req->filter_index_list[4].filter_index  = 4;
	req->filter_index_list[5].filter_handle = wan_dl_flt_lnklcl_v6_hdl;
	req->filter_index_list[5].filter_index  = 5;

	/* embedded pipe info — match what vendor sets */
	req->embedded_pipe_index_valid = 1;
	req->embedded_pipe_index = src_pipe;
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

/*
 * In-kernel emulation of IPACM userspace ioctl sequence on rmnet_ipa0.
 * Values replicate exactly what vendor_sondas.log captured:
 *   SET_EGRESS_DATA_FORMAT  data=0x16 (MAP|AGG|CHECKSUM)
 *   SET_INGRESS_DATA_FORMAT data=0x3e (MAP|DEAGG|DEMUX|CS|AGG_DATA),
 *                           agg_size=8192, agg_count=10
 *   ADD_MUX_CHANNEL         mux_id=1, vchannel="rmnet_data0"
 * The EGRESS path internally triggers wwan_add_ul_flt_rule_to_ipa()
 * (24-spec INSTALL_FILTER_RULE QMI -> modem) if num_q6_rule was cached.
 */
static void vendor_auto_ipacm_init_fn(struct work_struct *work)
{
	struct net_device *dev = ipa_netdevs[0];
	struct rmnet_ioctl_extended_s ext;
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
	 * worked but capped DL ~64 KB/s because modem responded with single
	 * IP packet per QMAP frame (no DL aggregation negotiated).
	 *
	 * IPA HW UL aggregation: IPA collects multiple 4-byte QMAP packets
	 * from mainline rmnet and bundles them into aggregated frames before
	 * forwarding to modem (one BAM transfer carries 6 KB / 10 packets /
	 * 1 ms worth). This is HW-level aggregation; mainline rmnet still
	 * sends one IP per call -- IPA HW does the combining.
	 *
	 * Symmetric AGG config (UL matches modem-side DL DEAGG params at
	 * INGRESS step 2 below) lets modem detect AGG-capable AP and enable
	 * DL aggregation in return, lifting DL throughput.
	 *
	 * hdr_len stays 4 (no checksum metadata) so mainline rmnet's pure
	 * 4-byte QMAP still parses correctly -- only AGG framing is added
	 * by IPA HW around the packet stream.
	 */
	/* Phase 4o: revert to vendor-derived defaults. Phases 4m/4n tested
	 * larger AGG windows and showed NO throughput improvement over 4k.
	 * On Vodafone CZ LTE the bottleneck is carrier-side rate cap
	 * (~67 KB/s for this APN/SIM), not AP-side AGG buffer size. Vendor
	 * defaults give the best single-stream throughput because:
	 *  - Smaller byte/pkt limits keep TCP ACKs flushing promptly
	 *  - Less buffering delay on the predominantly small UL traffic
	 *  - HW behavior matches what modem expects
	 */
	memset(&apps_to_ipa_ep_cfg, 0, sizeof(apps_to_ipa_ep_cfg));
	if (qmapv3_ul_enable) {
		/* QMAPv3 UL: matches lineage-sdm660-22.2/.../rmnet_ipa.c:1675-1678
		 * NOTE: NEED matching wda-force UL=7 + egress-mapv4-checksum on,
		 * else under-headered UL frames break bearer. Opt-in only. */
		apps_to_ipa_ep_cfg.ipa_ep_cfg.hdr.hdr_len = 8;
		apps_to_ipa_ep_cfg.ipa_ep_cfg.cfg.cs_offload_en =
			IPA_ENABLE_CS_OFFLOAD_UL;
		apps_to_ipa_ep_cfg.ipa_ep_cfg.cfg.cs_metadata_hdr_offset = 1;
	} else {
		apps_to_ipa_ep_cfg.ipa_ep_cfg.hdr.hdr_len = 4;
	}
	apps_to_ipa_ep_cfg.ipa_ep_cfg.aggr.aggr_en = IPA_ENABLE_AGGR;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.aggr.aggr = IPA_GENERIC;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.aggr.aggr_byte_limit = 6;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.aggr.aggr_pkt_limit = 10;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.aggr.aggr_time_limit = 1;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.hdr.hdr_ofst_metadata_valid = 1;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.hdr.hdr_ofst_metadata = 0;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.mode.dst = IPA_CLIENT_APPS_LAN_WAN_PROD;
	apps_to_ipa_ep_cfg.ipa_ep_cfg.mode.mode = IPA_BASIC;
	apps_to_ipa_ep_cfg.client = IPA_CLIENT_APPS_LAN_WAN_PROD;
	apps_to_ipa_ep_cfg.notify = apps_ipa_tx_complete_notify;
	apps_to_ipa_ep_cfg.desc_fifo_sz = IPA_SYS_TX_DATA_DESC_FIFO_SZ;
	apps_to_ipa_ep_cfg.priv = dev;

	rc = ipa2_setup_sys_pipe(&apps_to_ipa_ep_cfg, &apps_to_ipa_hdl);
	if (rc) {
		return;
	}
	egress_set = true;

	if (num_q6_rule != 0) {
		mutex_lock(&add_mux_channel_lock);
		rc = wwan_add_ul_flt_rule_to_ipa();
		mutex_unlock(&add_mux_channel_lock);
		if (rc)
			;
		else
			a7_ul_flt_set = true;
	}

	/* Phase 4s: explicit ICMP catchall rule (v4 + v6).
	 * Goes AFTER Q6 wildcard rules so it has highest priority match
	 * for ICMP packets. Vendor IPACM does this in config_dft_firewall_rules.
	 */
	rc = install_icmp_passthrough_rule();

	/* Phase 1: mcast + bcast filter rules (matching vendor IPACM minimum
	 * DL acceleration rule set). Together with ICMP rule above = 3 specs
	 * that get sent to modem in Phase 2 QMI handshake below. */
	rc = install_mcast_bcast_filter_rules();

	/* Phase 2: send QMI INSTALL_FILTER_RULE (msg 0x0023) to modem Q6.
	 * This is the CRITICAL HANDSHAKE that engages modem-side HW DL
	 * acceleration. Without it modem keeps DL on slow Q6 SW relay path
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
	 * Phase 4o: revert to vendor defaults. Phase 4m bumped to 16K/20
	 * (vendor ipa_assign_policy_v2 auto-calc → 14KB HW window) but the
	 * larger DL aggregation window showed no measurable benefit since
	 * carrier rate cap is the real DL bottleneck. Vendor sondas-derived
	 * 8K/10 matches stock Android behavior exactly.
	 */
	memset(&ext, 0, sizeof(ext));
	ext.extended_ioctl = RMNET_IOCTL_SET_INGRESS_DATA_FORMAT;
	ext.u.ingress_format.__data = RMNET_IOCTL_INGRESS_FORMAT_MAP
		| RMNET_IOCTL_INGRESS_FORMAT_DEAGGREGATION
		| RMNET_IOCTL_INGRESS_FORMAT_DEMUXING
		| RMNET_IOCTL_INGRESS_FORMAT_CHECKSUM
		| RMNET_IOCTL_INGRESS_FORMAT_AGG_DATA;
	ext.u.ingress_format.agg_size = 8192;
	ext.u.ingress_format.agg_count = 10;
	rc = handle_ingress_format(dev, &ext);
	if (rc) {
		return;
	}

	/* 3) ADD_MUX_CHANNEL mux_id=1 vchannel="qmapmux0.0" — MM/rmnet creates
	 * this child netdev via netlink; we register the same name as a
	 * "logical" IPA interface label so q6_ul_filter_rules + qmap header
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
	strncpy(mux_channel[rmnet_index].vchannel_name, "qmapmux0.0",
		IFNAMSIZ - 1);
	mux_channel[rmnet_index].vchannel_name[IFNAMSIZ - 1] = '\0';
	if (num_q6_rule != 0) {
		rc = wwan_register_to_ipa(rmnet_index);
		if (rc < 0) {
			mutex_unlock(&add_mux_channel_lock);
			return;
		}
		mux_channel[rmnet_index].mux_channel_set = true;
		mux_channel[rmnet_index].ul_flt_reg = true;
	} else {
		mux_channel[rmnet_index].mux_channel_set = true;
		mux_channel[rmnet_index].ul_flt_reg = false;
	}
	rmnet_index++;
	mutex_unlock(&add_mux_channel_lock);

	atomic_set(&auto_ipacm_init_done, 1);

	/* Phase 4q: start tethering stats polling that vendor IPACM would
	 * normally trigger via WAN_IOC_POLL_TETHERING_STATS ioctl on /dev/ipa.
	 * On mainline noone calls that ioctl so polling_interval stays 0 and
	 * no periodic QMI stats query reaches modem. Activate it ourselves:
	 * every 1 second send QMI_IPA_GET_DATA_STATS to modem. This keeps
	 * the modem-side data session "actively visible" and may unlock more
	 * aggressive DL aggregation since modem detects ongoing AP interest.
	 *
	 * Mux_id 1 = our qmapmux0.0 bearer (set above in step 3).
	 */
	ipa_rmnet_ctx.metered_mux_id = 1;
	ipa_rmnet_ctx.polling_interval = 1;
	queue_delayed_work(system_power_efficient_wq,
			   &ipa_tether_stats_poll_wakequeue_work, 0);

}

/**
 * ipa_q6_handshake_complete() - Perform operations once Q6 is up
 * @ssr_bootup - Indicates whether this is a cold boot-up or post-SSR.
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: auto-IPACM body - rules, QMI INSTALL_FILTER_RULE+NOTIF, EGRESS/INGRESS/ADD_MUX emulation"

read -r -d '' OLD <<'PORT_EOF' || true
		/* Enable holb monitoring on Q6 pipes. */
		ipa_q6_monitor_holb_mitigation(true);
	}
}

int __init ipa_wwan_init(void)
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		/* Enable holb monitoring on Q6 pipes. */
		ipa_q6_monitor_holb_mitigation(true);
	}
	/* In-kernel IPACM emulation: fire the EGRESS/INGRESS/ADD_MUX sequence
	 * ~3s after Q6 handshake. Vendor sondas put IPACM ioctls at t=71.98s
	 * vs handshake at t=68.6s; 3s preserves that gap. The work itself is
	 * one-shot (flag-guarded), but schedule re-arms post-SSR.
	 */
	if (!atomic_read(&auto_ipacm_init_done))
		schedule_delayed_work(&auto_ipacm_init_work,
				      msecs_to_jiffies(3000));
}

int __init ipa_wwan_init(void)
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: schedule auto-IPACM ~3s after Q6 handshake (vendor timing)"

read -r -d '' OLD <<'PORT_EOF' || true
	mutex_init(&add_mux_channel_lock);
	ipa_to_apps_hdl = -1;

	ipa_qmi_init();

	/* Register for Modem SSR */
	subsys_notify_handle = subsys_notif_register_notifier(SUBSYS_MODEM,
						&ssr_notifier);
	if (!IS_ERR(subsys_notify_handle))
		return platform_driver_register(&rmnet_ipa_driver);
	else
		return (int)PTR_ERR(subsys_notify_handle);
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	mutex_init(&add_mux_channel_lock);
	ipa_to_apps_hdl = -1;

	INIT_DELAYED_WORK(&auto_ipacm_init_work, vendor_auto_ipacm_init_fn);
	ipa_qmi_init();

	/* Register for Modem SSR */
	subsys_notify_handle = qcom_register_ssr_notifier("mpss",
						&ssr_notifier);
	if (!IS_ERR(subsys_notify_handle)) {
		/* __late_load_ssr_patch__ - handle late module load.
		 * If modem rproc is already up by the time we registered
		 * (typical for module load via insmod after boot), no
		 * SSR powerup events will fire for us. Manually invoke the
		 * equivalent of BEFORE_POWERUP + AFTER_POWERUP synthesizing
		 * the handshake. */
		ipa2_proxy_clk_vote();
		pr_info("IPA: late-load SSR fallback - proxy_clk_vote done\n");
		return platform_driver_register(&rmnet_ipa_driver);
	}
	else
		return (int)PTR_ERR(subsys_notify_handle);
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: init auto-IPACM work; direct qcom_register_ssr_notifier + late-load proxy clk vote"

read -r -d '' OLD <<'PORT_EOF' || true
{
	int ret;

	ipa_qmi_cleanup();
	mutex_destroy(&ipa_to_apps_pipe_handle_guard);
	mutex_destroy(&add_mux_channel_lock);
	ret = subsys_notif_unregister_notifier(subsys_notify_handle,
					&ssr_notifier);
	if (ret)
		IPAWANERR(
		"Error subsys_notif_unregister_notifier system %s, ret=%d\n",
		SUBSYS_MODEM, ret);
	platform_driver_unregister(&rmnet_ipa_driver);
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
{
	int ret;

	cancel_delayed_work_sync(&auto_ipacm_init_work);
	ipa_qmi_cleanup();
	mutex_destroy(&ipa_to_apps_pipe_handle_guard);
	mutex_destroy(&add_mux_channel_lock);
	ret = qcom_unregister_ssr_notifier(subsys_notify_handle,
					&ssr_notifier);
	if (ret)
		IPAWANERR(
		"Error qcom_unregister_ssr_notifier system %s, ret=%d\n",
		"mpss", ret);
	platform_driver_unregister(&rmnet_ipa_driver);
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: cleanup - cancel auto-IPACM work + qcom_unregister_ssr_notifier"


section "Interconnect (icc) bandwidth voting via msm_bus_compat"
read -r -d '' OLD <<'PORT_EOF' || true
	}

	if (ipa_ctx->ipa_hw_mode != IPA_HW_MODE_VIRTUAL) {
		/* get BUS handle */
		/* Check if bus handle is already registered */
		if (!register_ipa_bus_hdl)
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}

	if (ipa_ctx->ipa_hw_mode != IPA_HW_MODE_VIRTUAL) {
		/* Hand the IPA device to the msm_bus → interconnect translator
		 * so subsequent msm_bus_scale_register_client() can resolve the
		 * named "ipa-mem" / "ipa-imem" icc paths declared in DT. */
		msm_bus_compat_set_device(ipa_dev);
		/* get BUS handle */
		/* Check if bus handle is already registered */
		if (!register_ipa_bus_hdl)
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: hand IPA device to msm_bus_compat before bus-handle registration (ipa_init)"

read -r -d '' OLD <<'PORT_EOF' || true
	}
	if (bus_scale_table != NULL) {
		if (of_device_is_compatible(dev->of_node, "qcom,ipa")) {
			/*
			 * Register with bus client to check if msm_bus
			 * is completely initialized.
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	}
	if (bus_scale_table != NULL) {
		if (of_device_is_compatible(dev->of_node, "qcom,ipa")) {
			/* msm_bus_compat layer needs the device to resolve
			 * named icc paths from DT. Must precede the first
			 * register_client call in this probe-time bus check. */
			msm_bus_compat_set_device(dev);
			/*
			 * Register with bus client to check if msm_bus
			 * is completely initialized.
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: ditto for the probe-time msm_bus readiness check"


section "IPA core clock policy"
read -r -d '' OLD <<'PORT_EOF' || true
	if (result)
		goto fail_clk;

	/* Enable ipa_ctx->enable_clock_scaling */
	ipa_ctx->enable_clock_scaling = 1;
	ipa_ctx->curr_ipa_clk_rate = ipa_ctx->ctrl->ipa_clk_rate_turbo;

	/* enable IPA clocks explicitly to allow the initialization */
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	if (result)
		goto fail_clk;

	/* Mainline tuning: disable dynamic clock scaling.
	 *
	 * Vendor enables scaling which picks IPA core_clk rate (75/150/200 MHz)
	 * from current bandwidth_mbps. At our LTE baseline ~0.5 Mbps, every
	 * threshold check falls through to SVS = 75 MHz — the slowest setting,
	 * which halves processing capacity for no reason.
	 *
	 * With scaling disabled, ipa2_set_clock_plan_from_pm() lands in the
	 * else-branch that pins needed_voltage = IPA_VOLTAGE_NOMINAL (150 MHz).
	 * curr_ipa_clk_rate is still initialised to TURBO here, so init paths
	 * see full bandwidth before NOMINAL takes over.
	 */
	ipa_ctx->enable_clock_scaling = 0;
	ipa_ctx->curr_ipa_clk_rate = ipa_ctx->ctrl->ipa_clk_rate_turbo;

	/* enable IPA clocks explicitly to allow the initialization */
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa.c" "ipa.c: disable dynamic clock scaling - pin NOMINAL (DT pins TURBO); see powersave patch"


section "Runtime A/B datapath knobs (default off / vendor behavior)"
read -r -d '' OLD <<'PORT_EOF' || true
#include <linux/dmapool.h>
#include <linux/list.h>
#include <linux/netdevice.h>
#include "ipa_i.h"
#include "ipa_trace.h"

#define IPA_WAN_AGGR_PKT_CNT 5
#define IPA_LAST_DESC_CNT 0xFFFF
#define POLLING_INACTIVITY_RX 40
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
#include <linux/dmapool.h>
#include <linux/list.h>
#include <linux/netdevice.h>
#include <linux/moduleparam.h>
#include "ipa_i.h"
#include "ipa_trace.h"

/* Busy-poll WAN RX instead of relying on the ~1Hz SPS EOT IRQ. Default off
 * (original interrupt-driven behavior); toggle via
 *   /sys/module/<ipa_module>/parameters/ipa_wan_busypoll  (1=on). */
static int ipa_wan_busypoll;
module_param(ipa_wan_busypoll, int, 0644);
MODULE_PARM_DESC(ipa_wan_busypoll, "Keep WAN RX in NAPI poll mode (workaround 1Hz EOT IRQ)");

/* Disable IPA HW aggregation on APPS_WAN_CONS (pipe 5). Tested 2026-05-30:
 * the "AGG = 2-buffer parallel reorder source" hypothesis was REFUTED —
 * a NO_AGG build measured 71 KB/s vs 120-240 KB/s baseline, i.e. disabling
 * AGG made things worse; the AP-side AGG path is the faster one. Kept as a
 * runtime A/B knob for future experiments; default 0 = vendor production.
 *   /sys/module/<ipa_module>/parameters/ipa_disable_wan_agg  (1=bypass, 0=off). */
static int ipa_disable_wan_agg;
module_param(ipa_disable_wan_agg, int, 0644);
MODULE_PARM_DESC(ipa_disable_wan_agg, "Bypass IPA HW AGG on pipe 5 (test only — empirically -50% throughput)");

#define IPA_WAN_AGGR_PKT_CNT 5
#define IPA_LAST_DESC_CNT 0xFFFF
#define POLLING_INACTIVITY_RX 40
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: ipa_wan_busypoll + ipa_disable_wan_agg module params"

read -r -d '' OLD <<'PORT_EOF' || true
		ep->inactive_cycles++;
		ep->client_notify(ep->priv, IPA_CLIENT_COMP_NAPI, 0);

		if (ep->inactive_cycles > 3 || ep->sys->len == 0) {
			ep->switch_to_intr = true;
			delay = 0;
		} else if (cnt < weight) {
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		ep->inactive_cycles++;
		ep->client_notify(ep->priv, IPA_CLIENT_COMP_NAPI, 0);

		if (ipa_wan_busypoll && ep->inactive_cycles <= 1000) {
			/* Busy-poll: the SPS EOT IRQ on WAN_CONS fires only ~1Hz,
			 * so switching to interrupt mode on an empty queue starves
			 * RX (ceiling = NAPI_WEIGHT x ~1Hz). Instead keep re-polling
			 * at ~1 jiffy granularity to drain aggregation buffers as
			 * they close, independent of the (broken) EOT IRQ. Give up
			 * to interrupt mode only after ~1000 idle cycles. */
			delay = 1;
		} else if (ep->inactive_cycles > 3 || ep->sys->len == 0) {
			ep->switch_to_intr = true;
			delay = 0;
		} else if (cnt < weight) {
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: busy-poll branch in WAN RX NAPI poll (1Hz EOT IRQ workaround)"

read -r -d '' OLD <<'PORT_EOF' || true
				in->ipa_ep_cfg.aggr.aggr_pkt_limit =
				IPA_GENERIC_AGGR_PKT_LIMIT;
			}
		}
	} else if (IPA_CLIENT_IS_WLAN_CONS(in->client)) {
		IPADBG("assigning policy to client:%d",
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
				in->ipa_ep_cfg.aggr.aggr_pkt_limit =
				IPA_GENERIC_AGGR_PKT_LIMIT;
			}
			/* Test 2026-05-29 reorder hypothesis: bypass HW AGG on pipe 5
			 * to eliminate 2-buffer parallel completion path that creates
			 * 2-way TCP interleave on single-pkt modem streams.
			 * CRITICAL: must also clear ipa_client_apps_wan_cons_agg_gro
			 * SW flag, else ipa_wan_rx_pyld_hdlr takes the AGG_GRO fast
			 * path expecting an AGG buffer that no longer exists. */
			if (ipa_disable_wan_agg) {
				in->ipa_ep_cfg.aggr.aggr_en = IPA_BYPASS_AGGR;
				in->ipa_ep_cfg.aggr.aggr = 0;
				in->ipa_ep_cfg.aggr.aggr_byte_limit = 0;
				in->ipa_ep_cfg.aggr.aggr_pkt_limit = 0;
				in->ipa_ep_cfg.aggr.aggr_time_limit = 0;
				in->ipa_ep_cfg.aggr.aggr_sw_eof_active = false;
				/* Force STATUS records on so ipa_wan_rx_pyld_hdlr's
				 * proper deaggr STATUS path runs (since AGG_GRO is off) */
				sys->ep->status.status_en = true;
				ipa_ctx->ipa_client_apps_wan_cons_agg_gro = false;
			}
		}
	} else if (IPA_CLIENT_IS_WLAN_CONS(in->client)) {
		IPADBG("assigning policy to client:%d",
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/ipa_dp.c" "ipa_dp.c: NO_AGG A/B branch in ipa_assign_policy (empirically slower; keep off)"


section "Power-efficient workqueues"
read -r -d '' OLD <<'PORT_EOF' || true
	release_work->needed_bw = 0;
	release_work->dec_usage_count = false;
	INIT_DELAYED_WORK(&release_work->work, delayed_release_work_func);
	schedule_delayed_work(&release_work->work,
			msecs_to_jiffies(IPA_RM_RELEASE_DELAY_IN_MSEC));
	result = 0;
bail:
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
	release_work->needed_bw = 0;
	release_work->dec_usage_count = false;
	INIT_DELAYED_WORK(&release_work->work, delayed_release_work_func);
	queue_delayed_work(system_power_efficient_wq, &release_work->work,
			msecs_to_jiffies(IPA_RM_RELEASE_DELAY_IN_MSEC));
	result = 0;
bail:
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_rm.c" "ipa_rm.c: delayed release work on system_power_efficient_wq"

read -r -d '' OLD <<'PORT_EOF' || true

	/* Schedule again only if there's an active polling interval */
	if (ipa_rmnet_ctx.polling_interval != 0)
		schedule_delayed_work(&ipa_tether_stats_poll_wakequeue_work,
			msecs_to_jiffies(ipa_rmnet_ctx.polling_interval*1000));
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true

	/* Schedule again only if there's an active polling interval */
	if (ipa_rmnet_ctx.polling_interval != 0)
		queue_delayed_work(system_power_efficient_wq, &ipa_tether_stats_poll_wakequeue_work,
			msecs_to_jiffies(ipa_rmnet_ctx.polling_interval*1000));
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: tether-stats poll on system_power_efficient_wq (resched)"

read -r -d '' OLD <<'PORT_EOF' || true
		return 0;
	}

	schedule_delayed_work(&ipa_tether_stats_poll_wakequeue_work, 0);
	return 0;
}
PORT_EOF
read -r -d '' NEW <<'PORT_EOF' || true
		return 0;
	}

	queue_delayed_work(system_power_efficient_wq, &ipa_tether_stats_poll_wakequeue_work, 0);
	return 0;
}
PORT_EOF
apply_edit "drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c" "rmnet_ipa.c: tether-stats poll on system_power_efficient_wq (kickoff)"

echo
echo "============================================================"
echo "Done. $applied edit(s) applied, $skipped already present."
echo "============================================================"
