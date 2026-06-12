/*
 * stage_post_tune — apply Starlord (SDM660) vendor sysctl/ethtool/RPS knobs.
 *
 * Values from linux/trace/netmgr_config.xml <listitem name="Starlord">.
 * These run AFTER bearer is up. Not strictly required for bearer to work,
 * but vendor sets all of them and they materially affect throughput:
 *
 *   - netdev_max_backlog = 10000
 *   - tcp_no_metrics_save = 1     (vendor relies on per-flow tuning)
 *   - hystart disable / initial_ssthresh = 1400 (fast cwnd ramp on cellular)
 *   - GRO on ingress qmapmux0.0
 *   - GSO on egress qmapmux0.0
 *   - RPS masks: pnd_rps_mask=2 (rmnet_ipa0 → CPU1)
 *                vnd_rps_mask=4 (qmapmux0.0 → CPU2)
 *
 * All applied via shell-outs to existing utilities (sysctl, ethtool, echo).
 * No-op silently if a file/tool is missing (some sysctls don't exist on
 * mainline kernels).
 */

#include "vendor-init.h"
#include "log.h"
#include "state.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>

#define STAGE "post_tune"

static void try_cmd(const char *desc, const char *cmd)
{
	LOGD(STAGE, "exec: %s", cmd);
	int rc = system(cmd);
	if (rc != 0)
		LOGW(STAGE, "%s failed (rc=%d): %s", desc, rc, cmd);
	else
		LOGI(STAGE, "%s OK", desc);
}

/* Best-effort variant for knobs that are EXPECTED to be unavailable on
 * some kernels — failure is logged at debug level only. */
static void try_cmd_opt(const char *desc, const char *cmd)
{
	LOGD(STAGE, "exec: %s", cmd);
	if (system(cmd) != 0)
		LOGD(STAGE, "%s not available (expected on upstream rmnet)", desc);
	else
		LOGI(STAGE, "%s OK", desc);
}

static void try_write(const char *path, const char *value)
{
	FILE *f = fopen(path, "w");
	if (!f) {
		LOGD(STAGE, "skip %s (not present)", path);
		return;
	}
	fputs(value, f);
	fclose(f);
	LOGI(STAGE, "%s <- %s", path, value);
}

int stage_post_tune(struct vi_ctx *ctx)
{
	(void)ctx;
	if (ctx->dry_run) {
		LOGI(STAGE, "(dry run) would apply Starlord sysctl/ethtool/RPS + rmnet CKSUMV4 flags");
		return 0;
	}

	/* --- rmnet INGRESS_CKSUMV4 flag (MUST run before traffic flows) ---
	 *
	 * For WDA_DL_PROTO=7 (QMAPv3 DL) every DL packet has an 8-byte csum
	 * trailer. Mainline rmnet strips it only when port->data_format has
	 * RMNET_FLAGS_INGRESS_MAP_CKSUMV4 (bit 0x04) set.
	 *
	 * NOTE we deliberately DO NOT set EGRESS_MAP_CKSUMV4 (0x08) here.
	 * Vendor-init currently keeps WDA_UL_PROTO=5 — the IPA EGRESS pipe 4
	 * is still configured for plain 4-byte QMAP (no UL csum header). If
	 * we told mainline rmnet to insert the 4-byte UL csum header, IPA HW
	 * would still expect QMAP-only 4-byte header → mismatch → corrupted
	 * UL packets → modem drops everything. Setting EGRESS_CKSUMV4 only
	 * makes sense AFTER patching auto_ipacm_init step 1 to:
	 *   hdr.hdr_len = 8;
	 *   cfg.cs_offload_en = IPA_ENABLE_CS_OFFLOAD_UL;
	 *   cfg.cs_metadata_hdr_offset = 1;
	 * (vendor lineage-sdm660-22.2/.../rmnet_ipa.c:1675-1678).
	 *
	 * RTM_SETLINK on a child rmnet device updates the parent port's
	 * data_format (rmnet_config.c:346). Result here:
	 *   data_format = DEAGG | INGRESS_CKSUMV4 = 0x05
	 *
	 * iproute2 5.x supports ingress-cksum-v4 on/off keywords; older
	 * syntax wants raw flags/mask hex. We try modern first, then legacy. */
	/* 2026-05-31 update: without ModemManager, no one creates the qmapmux0.0
	 * rmnet child device. ModemManager normally does `ip link add type
	 * rmnet` when bearer activates; in MM-free mode we have to do it
	 * ourselves. Try add (idempotent — silently fails if exists), then
	 * bring parent + child up, then set flags. */
	try_cmd("rmnet_ipa0 UP",
		"ip link set rmnet_ipa0 up >/dev/null 2>&1");
	/* Create with MINIMAL flags only (DEAGG + INGRESS_MAP_CKSUMV4 for
	 * QMAPv3 DL trailer strip). EGRESS_MAP_CKSUMV4 is added LATER, only
	 * when --full-ul is set AND driver has qmapv3_ul_enable=1. Adding it
	 * here unconditionally causes UL packet mismatch: rmnet generates
	 * 4-byte UL csum header (= 8-byte total UL frame), driver EGRESS
	 * pipe 4 with default hdr_len=4 expects only 4-byte QMAP, modem gets
	 * over-headered UL → drops everything. */
	try_cmd("create qmapmux0.0 child (modern)",
		"ip link add link rmnet_ipa0 name qmapmux0.0 type rmnet "
		"mux_id 1 ingress-deaggregation on ingress-mapv4-checksum on "
		">/dev/null 2>&1");
	/* If create failed because device exists, fall through to set-flags. */
	/* Set qmapmux0.0 MTU to the bearer-advertised MTU (TLV 0x29 from
	 * WDS_GET_CURRENT_SETTINGS, typically 1500 for cellular). rmnet
	 * default child MTU = parent (rmnet_ipa0 = 2000) - 4-byte QMAP =
	 * 1996, but cellular path MTU is ≤ 1500 — leaving qmapmux0.0 at 1996
	 * causes fragmentation / drops for TCP/HTTPS over the cellular link.
	 * Modem's MTU value is authoritative; use it. */
	if (ctx->bearer_mtu > 0 && ctx->bearer_mtu < 2000) {
		char buf[128];
		snprintf(buf, sizeof(buf),
			 "ip link set qmapmux0.0 mtu %u >/dev/null 2>&1",
			 ctx->bearer_mtu);
		try_cmd("qmapmux0.0 MTU set", buf);
	}

	try_cmd("qmapmux0.0 UP",
		"ip link set qmapmux0.0 up >/dev/null 2>&1");

	/* Set/update flags on (possibly already-existing) qmapmux0.0. Empirically
	 * confirmed syntax: explicit mux_id + ingress-deaggregation + checksum
	 * flags. With ctx->full_ul also set egress-mapv4-checksum. */
	if (ctx->full_ul) {
		try_cmd("rmnet INGRESS+EGRESS MAP_CKSUMV4 (QMAPv3 both ways)",
			"ip link set qmapmux0.0 type rmnet mux_id 1 "
			"ingress-deaggregation on "
			"ingress-mapv4-checksum on egress-mapv4-checksum on "
			">/dev/null 2>&1");
		state_record("rmnet_data_format_request",
			"DEAGG + INGRESS_MAP_CKSUMV4 + EGRESS_MAP_CKSUMV4");
	} else {
		try_cmd("rmnet INGRESS_MAP_CKSUMV4 (QMAPv3 DL trailer strip)",
			"ip link set qmapmux0.0 type rmnet mux_id 1 "
			"ingress-deaggregation on ingress-mapv4-checksum on "
			">/dev/null 2>&1");
		state_record("rmnet_data_format_request",
			"DEAGG + INGRESS_MAP_CKSUMV4");
	}

	/* --- sysctl --- */
	try_write("/proc/sys/net/core/netdev_max_backlog", "10000");
	try_write("/proc/sys/net/ipv4/tcp_no_metrics_save", "1");
	try_write("/proc/sys/net/ipv4/tcp_initial_ssthresh", "1400");
	try_write("/sys/module/tcp_cubic/parameters/hystart", "0");
	try_write("/sys/module/tcp_cubic/parameters/hystart_detect", "0");

	/* --- ethtool: GRO/GSO on rmnet_ipa0 + qmapmux0.0 ---
	 * ethtool may print noisy failures if features aren't supported; pipe
	 * to /dev/null for cleanliness. */
	try_cmd("rmnet_ipa0 GRO on",  "ethtool -K rmnet_ipa0 gro on >/dev/null 2>&1");
	try_cmd("qmapmux0.0 GRO on",  "ethtool -K qmapmux0.0 gro on >/dev/null 2>&1");
	/* Upstream rmnet advertises no GSO/TSO feature bits, so these two
	 * cannot succeed there (ethtool exits 1) — segmentation happens in
	 * software before the parent device either way. Kept best-effort
	 * for kernels whose rmnet does advertise them (Android downstream,
	 * possible future mainline). */
	try_cmd_opt("qmapmux0.0 GSO on", "ethtool -K qmapmux0.0 gso on >/dev/null 2>&1");
	try_cmd_opt("qmapmux0.0 TSO on", "ethtool -K qmapmux0.0 tso on >/dev/null 2>&1");

	/* --- UL TX checksum offload: force OFF in BOTH configs ---
	 *
	 * The IPA UL checksum OFFLOAD is broken on this modem. When the stack
	 * defers the L4 checksum (NETIF_F_IP_CSUM advertised → tx-checksum-ipv4:
	 * on → CHECKSUM_PARTIAL skbs) and the IPA HW is asked to complete it,
	 * the result is wrong and the peer drops every TCP/UDP uplink packet.
	 * ICMP (which takes rmnet's memset-zeroed-header sw_csum path, never
	 * offloaded) is unaffected — that's the tell.
	 *
	 * Proven on-device 2026-06-12 to a ping-OK server: tx-checksum ON →
	 * TCP UL 0/10; tx-checksum OFF → TCP UL 10/10. Turning it off makes the
	 * stack compute a correct SOFTWARE L4 checksum and rmnet zero the UL
	 * csum header (sw_csum path in rmnet_map_v4_checksum_uplink_packet), so
	 * no HW offload is attempted.
	 *
	 * Required in BOTH configs:
	 *  - asymmetric (QMAPv1 UL): no offload completes the deferred csum.
	 *  - symmetric (QMAPv3 UL, --full-ul): the 8-byte UL header / hdr_len=8
	 *    pipe is correct, but the csum OFFLOAD itself is broken — so use the
	 *    same SW-csum path. THIS is what makes symmetric UL actually work:
	 *    it lifts UL from ~65 KB/s to ~26 Mbit/s (the win is QMAPv3 UL
	 *    aggregation, independent of the offload), and resolves the old
	 *    "symmetric QMAPv3 UL = 100% packet loss" caveat — that loss was the
	 *    broken offload, not the QMAPv3 UL format.
	 *
	 * Verify: ethtool -k qmapmux0.0 | grep tx-checksum-ipv4   # = off
	 */
	try_cmd("qmapmux0.0 tx-checksum OFF (IPA UL csum offload is broken — SW csum)",
		"ethtool -K qmapmux0.0 tx-checksum-ipv4 off "
		"tx-checksum-ipv6 off >/dev/null 2>&1");
	try_cmd_opt("rmnet_ipa0 tx-checksum OFF",
		"ethtool -K rmnet_ipa0 tx-checksum-ipv4 off "
		"tx-checksum-ipv6 off >/dev/null 2>&1");
	state_record("rmnet_ul_txcsum",
		ctx->full_ul ? "off (QMAPv3 UL — SW csum; HW offload broken)"
			     : "off (QMAPv1 UL — SW csum)");

	/* --- RPS masks --- */
	try_write("/sys/class/net/rmnet_ipa0/queues/rx-0/rps_cpus", "2");
	try_write("/sys/class/net/qmapmux0.0/queues/rx-0/rps_cpus", "4");

	state_record("post_tune", "applied");
	return 0;
}
