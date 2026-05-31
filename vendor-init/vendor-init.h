#ifndef VENDOR_INIT_H
#define VENDOR_INIT_H

#include <stdint.h>

/* Default configuration — overridable via CLI flags / env. */
#define DEFAULT_APN      "internet"
#define DEFAULT_MUX_ID   1
#define MUX_COUNT_VENDOR 17        /* Android binds rmnet_data0..7 + r_rmnet_data0..8 */

/* WDA SET_DATA_FORMAT — ASYMMETRIC QMAPv3 DL / QMAPv1 UL for first deploy.
 *
 * Why asymmetric: DL and UL have DIFFERENT requirements at our edge.
 *
 *   DL (modem→AP):
 *     - INGRESS pipe 5 already has cs_offload_en=DL (auto_ipacm_init sets
 *       it via handle_ingress_format's CHECKSUM flag). IPA HW verifies
 *       trailer csum but does NOT strip — vendor parity confirmed.
 *     - Mainline rmnet has the 8-byte trailer struct in
 *       include/linux/if_rmnet.h and strips it when port->data_format has
 *       RMNET_FLAGS_INGRESS_MAP_CKSUMV4 set. We toggle that flag from
 *       stage_post_tune via `ip link set qmapmux0.0 type rmnet`.
 *     - Therefore: WDA_DL_PROTO=7 needs NO IPA driver patch.
 *
 *   UL (AP→modem):
 *     - Modem at QMAPv3 expects a 4-byte UL csum header BEFORE the IP
 *       packet. Vendor IPA EGRESS pipe 4 for csum-enabled UL sets:
 *         hdr.hdr_len = 8
 *         cfg.cs_offload_en = IPA_ENABLE_CS_OFFLOAD_UL
 *         cfg.cs_metadata_hdr_offset = 1
 *       (lineage-sdm660-22.2/.../rmnet_ipa.c:1675-1678)
 *     - Our auto_ipacm_init Phase 4j explicitly REMOVED these for QMAPv1
 *       UL stability. Bumping WDA_UL_PROTO=7 without re-adding them →
 *       IPA HW under-headers UL packets → modem receives corrupted UL.
 *     - Therefore: WDA_UL_PROTO=7 REQUIRES IPA driver patch.
 *
 * Decision: deploy DL=7 first (no driver change, isolates the DL trailer
 * hypothesis cleanly). If DL throughput jumps multi-Mbps → confirmed,
 * iterate with driver patch + WDA_UL_PROTO=7 for UL parity.
 * If DL stays at 67 KB/s → DL trailer was not the lever, UL changes would
 * be wasted effort. */
#define WDA_DL_PROTO     7         /* QMAPv3 — mainline CKSUMV4 strips trailer */
#define WDA_UL_PROTO_V1  5         /* default — proven QMAPv1 UL */
#define WDA_UL_PROTO_V3  7         /* with --full-ul + driver qmapv3_ul_enable=1 */
#define WDA_DL_SIZE      8192
#define WDA_DL_DGRAMS    10

/* The unified bringup context — passed through every stage. */
struct vi_ctx {
	int      fd;                /* AF_QIPCRTR socket, opened once */
	uint16_t txid;              /* QMI transaction id, monotonically inc */

	/* QRTR ports discovered via qrtr_lookup. */
	uint32_t wds_port;
	uint32_t wda_port;
	uint32_t dpm_port;
	uint32_t dsd_port;

	/* Runtime state filled in by stages. */
	uint32_t bearer_pkt_data_handle;   /* from WDS_START_NETWORK */
	uint32_t bearer_ipv4;              /* host byte order */
	uint32_t bearer_gw;
	uint32_t bearer_mask;
	uint32_t bearer_dns1;
	uint32_t bearer_dns2;
	uint32_t bearer_mtu;

	/* CLI / runtime flags. */
	const char *apn;
	int         dry_run;        /* skip QMI sends, log only */
	int         skip_mm;        /* don't try to stop ModemManager */
	int         num_muxes;      /* default 1; use MUX_COUNT_VENDOR for parity test */
	int         full_ul;        /* if 1: WDA_UL_PROTO=7 QMAPv3 UL (needs driver
	                             * qmapv3_ul_enable=1 AND rmnet
	                             * egress-mapv4-checksum on, else UL breaks) */
	int         simple_wds;     /* if 1: skip 0xAF/0x4D, send minimal 2-TLV WDS_START
	                             * (APN + IP family only).
	                             * Defaults to 1 — matches proven-working
	                             * wds-bearer.c byte-for-byte. The 6-TLV LTE form
	                             * (TLV 0x31=5 ext_tech, TLV 0x39=1 profile_idx)
	                             * mirrors Android vendor capture but the
	                             * profile_idx=1 doesn't exist on PostmarketOS
	                             * mainline modem NV state → err=74
	                             * (PROFILE_NOT_FOUND). Use --full-wds to opt in. */
};

/* Each stage returns 0 on success, non-zero on failure (becomes exit code). */
typedef int (*stage_fn)(struct vi_ctx *ctx);

/* Stage prototypes — one per stage_*.c file. */
int stage_dms_online(struct vi_ctx *ctx);
int stage_nas_rat   (struct vi_ctx *ctx);
int stage_dpm_open  (struct vi_ctx *ctx);
int stage_iattach   (struct vi_ctx *ctx);
int stage_bind_mux  (struct vi_ctx *ctx);
int stage_dsd       (struct vi_ctx *ctx);
int stage_wda_set   (struct vi_ctx *ctx);
int stage_fff2      (struct vi_ctx *ctx);
int stage_wds_start (struct vi_ctx *ctx);
int stage_post_tune (struct vi_ctx *ctx);

#endif
