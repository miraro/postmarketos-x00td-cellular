#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 05-integrate-mainline-tree.sh
#
# Step 1 of the IPA v2.6L port: wire the overlaid drivers/platform/msm/
# subtree into the upstream kernel build system and prepare the X00TD
# board files. Replaces the former platform-enable-msm.patch and
# rmnet-netif-csum.patch — script form survives upstream context drift
# (e.g. postmarketOS 6.19 already ships an X00TD DTS and part of the
# rmnet csum change).
#
# What it does (each step skipped when already present):
#   1. drivers/platform/Kconfig   += source "drivers/platform/msm/Kconfig"
#   2. drivers/platform/Makefile  += obj-$(CONFIG_ARCH_QCOM) += msm/
#   3. arch/arm64/boot/dts/qcom/Makefile += sdm636-asus-x00td.dtb
#   4. X00TD device tree:
#        a. file missing entirely  -> install the full reference DTS
#        b. file present (pmOS)    -> add regulator-always-on to vreg_l16a
#                                     (RF front-end rail must not collapse)
#                                     and append the IPA/SPS/rmnet &soc block
#   5. arch/arm64/configs/X00TD_defconfig — install if absent
#   6. upstream rmnet (drivers/net/ethernet/qualcomm/rmnet/rmnet_vnd.c):
#        a. NETIF_F_IP_CSUM|IPV6_CSUM into hw_features  (vanilla mainline
#           lacks it; pmOS 6.19 already has it -> skipped there)
#        b. NETIF_F_GRO_HW + default-enable the csum features — without
#           this, enabling EGRESS_MAP_CKSUMV4 makes rmnet memset-zero the
#           UL csum header and the modem silently drops all UL traffic
#
# Usage:  ./05-integrate-mainline-tree.sh [--root /path/to/kernel]

set -eu

SRC_ROOT="."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
while [ $# -gt 0 ]; do
	case "$1" in
		--root) SRC_ROOT="$2"; shift 2 ;;
		--help|-h) sed -n '/^# /{s/^# \?//;p}' "$0" | head -40; exit 0 ;;
		*) echo "Unknown argument: $1"; exit 1 ;;
	esac
done

append_line() {  # $1=file $2=guard-grep $3=line $4=desc
	local f="$SRC_ROOT/$1"
	[ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
	if grep -qF -- "$2" "$f"; then
		echo "  [skip] $4"
	else
		printf '%s\n' "$3" >> "$f"
		echo "  [ok]   $4"
	fi
}

echo "==> Build-system wiring for drivers/platform/msm/"
append_line drivers/platform/Kconfig \
	'drivers/platform/msm/Kconfig' \
	'source "drivers/platform/msm/Kconfig"' \
	"drivers/platform/Kconfig: source msm/Kconfig"
append_line drivers/platform/Makefile \
	'+= msm/' \
	'obj-$(CONFIG_ARCH_QCOM) += msm/' \
	"drivers/platform/Makefile: descend into msm/"

echo
echo "==> X00TD board files"
DTS="$SRC_ROOT/arch/arm64/boot/dts/qcom/sdm636-asus-x00td.dts"
DTS_MAKEFILE="$SRC_ROOT/arch/arm64/boot/dts/qcom/Makefile"
if grep -qF 'sdm636-asus-x00td.dtb' "$DTS_MAKEFILE"; then
	echo "  [skip] dtb-y registration (already present)"
else
	# keep the alphabetic dtb-y ordering: insert before sdm636-bbry if present
	if grep -qF 'sdm636-bbry' "$DTS_MAKEFILE"; then
		sed -i '0,/sdm636-bbry/s//sdm636-asus-x00td.dtb\ndtb-$(CONFIG_ARCH_QCOM)\t+= sdm636-bbry/' "$DTS_MAKEFILE"
	else
		printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= sdm636-asus-x00td.dtb\n' >> "$DTS_MAKEFILE"
	fi
	echo "  [ok]   dtb-y registration"
fi

if [ ! -f "$DTS" ]; then
	mkdir -p "$(dirname "$DTS")"
	cp "$SCRIPT_DIR/files/arch/arm64/boot/dts/qcom/sdm636-asus-x00td.dts" "$DTS"
	echo "  [ok]   DTS: installed full reference sdm636-asus-x00td.dts"
else
	# 4b-1: always-on rails. Two LDOs must never collapse while the modem
	# is up, or registration drops and the bearer dies seconds later:
	#   vreg_l16a_2p7 (2.8 V) — RF front-end rail (documented in the writeup;
	#                           postmarketOS 6.19 DTS already pins it)
	#   vreg_l7a_1p2  (1.2 V) — empirical bringup rail from the proven
	#                           working tree (carried over; never isolated
	#                           which consumer needs it held)
	ensure_always_on() {  # $1=node-label  $2=human name
		if N="$1" perl -0777 -ne 'exit((($_ =~ /\Q$ENV{N}\E: [a-z0-9]+ \{[^}]*regulator-always-on/s)) ? 0 : 1)' "$DTS"; then
			echo "  [skip] DTS: $1 regulator-always-on ($2)"
		elif N="$1" perl -0777 -i -pe 's/(\Q$ENV{N}\E: [a-z0-9]+ \{[^}]*?regulator-enable-ramp-delay = <250>;)/$1\n\t\t\tregulator-always-on;/s' "$DTS" && \
		     N="$1" perl -0777 -ne 'exit((($_ =~ /\Q$ENV{N}\E: [a-z0-9]+ \{[^}]*regulator-always-on/s)) ? 0 : 1)' "$DTS"; then
			echo "  [ok]   DTS: $1 regulator-always-on ($2)"
		else
			echo "ERROR: regulator node $1 not found in $DTS" >&2; exit 1
		fi
	}
	ensure_always_on vreg_l16a_2p7 "RF front-end rail"
	ensure_always_on vreg_l7a_1p2 "empirical bringup rail"
	# 4b-2: the IPA/SPS/rmnet &soc block.
	if grep -qF 'ipa@14780000' "$DTS"; then
		echo "  [skip] DTS: IPA/SPS/rmnet &soc block"
	else
		cat >> "$DTS" <<'PORT_EOF'

&soc {
    qcom_sps: qcom,sps {
		compatible = "qcom,msm-sps-4k";
		qcom,device-type = <3>;     /* default value — no BAMDMA */
		qcom,pipe-attr-ee;
		status = "okay";
	};

	/* IPA hardware (chip core + BAM-DMA at +0x4000) */
	ipa: ipa@14780000 {
		compatible = "qcom,ipa";

		/* Two separate register ranges: IPA core + BAM-DMA */
		reg = <0x14780000 0x4000>,
		      <0x14784000 0x3C000>;
		reg-names = "ipa-base", "bam-base";

		qcom,ipa-hw-ver = <6>;
		qcom,ipa-hw-mode = <0>;            /* IPA_MODE_NORMAL */
		qcom,ee = <0>;
		qcom,wan-rx-ring-size = <0xc0>;    /* matches Android 4.19 */
		qcom,lan-rx-ring-size = <0xc0>;
		qcom,rx-polling-sleep-ms = <1>;
		qcom,ipa-polling-iteration = <40>;
		/* __ipa_arm_smmu_patch__ - required for SMMU CB child node probe */
		qcom,arm-smmu;
		qcom,smmu-s1-bypass;
		qcom,smmu-disable-htw;
		qcom,modem-cfg-emb-pipe-flt;        /* CRITICAL: modem handles internal filter install */
		qcom,use-dma-zone;                   /* DMA-capable mem for descriptors */
		qcom,use-ipa-tethering-bridge;       /* tethering paths */
		qcom,ipa-wdi2;                       /* WDI 2.0 capability advertise */
		/* IPA_HW_v2_6L */

		/* Routing/pipe configuration from MASTER V7 vendor config */
		qcom,pipe-wan = <5>;
		qcom,rt-idx-wan = <8>;
		qcom,rt-idx-default = <7>;

		interrupts = <GIC_SPI 333 IRQ_TYPE_LEVEL_HIGH>,    /* IPA - matches Android (was EDGE_RISING) */
			     <GIC_SPI 432 IRQ_TYPE_LEVEL_HIGH>;     /* BAM */
		interrupt-names = "ipa-irq", "bam-irq";

		clocks = <&rpmcc RPM_SMD_IPA_CLK>,
			 <&rpmcc RPM_SMD_AGGR2_NOC_CLK>;
		clock-names = "core_clk", "smmu_clk";

        /* Force RPM clock vote at probe time regardless of driver bugs */
        assigned-clocks = <&rpmcc RPM_SMD_IPA_CLK>;
        assigned-clock-rates = <200000000>;       /* 200 MHz turbo */

		/* SMMU stream IDs for the IPA core itself */
		iommus = <&anoc2_smmu 0x19C0>,
			 <&anoc2_smmu 0x19C2>;

		dma-coherent;

		/* Bus interconnects (mainline-style; vendor 4.19 driver
		 * ignores these but they don't hurt) */
		interconnects = <&a2noc MASTER_IPA &bimc SLAVE_EBI>,
				<&a2noc MASTER_IPA &snoc SLAVE_IMEM>,
				<&gnoc MASTER_APSS_PROC &snoc SLAVE_IPA>;
		interconnect-names = "ipa-mem", "ipa-imem", "cpu-cfg";

		modem-remoteproc = <&remoteproc_mss>;

		status = "okay";

		/* Children: SMMU context banks parsed by ipa_smmu_*_cb_probe() */
		qcom,ipa-smmu-ap-cb {
			compatible = "qcom,ipa-smmu-ap-cb";
			iommus = <&anoc2_smmu 0x19C0>;
			qcom,iova-mapping = <0x20000000 0x40000000>;
		};

		qcom,ipa-smmu-wlan-cb {
			compatible = "qcom,ipa-smmu-wlan-cb";
			iommus = <&anoc2_smmu 0x19C1>;
			qcom,iova-mapping = <0x20000000 0x40000000>;
		};

		qcom,ipa-smmu-uc-cb {
			compatible = "qcom,ipa-smmu-uc-cb";
			iommus = <&anoc2_smmu 0x19C2>;
			qcom,iova-mapping = <0x20000000 0x40000000>;
		};
	};
	rmnet_ipa {
		compatible = "qcom,rmnet-ipa";
		/* __rmnet_ipa_dt_patch__ - properties from 4.19 vendor analysis */
		qcom,rmnet-ipa-ssr;             /* enable MPSS POWERUP handshake */
		qcom,ipa-loaduC;                /* load uC firmware */
		qcom,ipa-advertise-sg-support;  /* scatter-gather support */
		qcom,ipa-napi-enable;           /* enable NAPI on pipe 5 (RX) */
		qcom,wan-rx-desc-size = <1024>;
		status = "okay";
	};
};
PORT_EOF
		echo "  [ok]   DTS: IPA/SPS/rmnet &soc block appended"
	fi
fi

DEFCONFIG="$SRC_ROOT/arch/arm64/configs/X00TD_defconfig"
if [ -f "$DEFCONFIG" ]; then
	echo "  [skip] X00TD_defconfig (already present)"
else
	cp "$SCRIPT_DIR/files/arch/arm64/configs/X00TD_defconfig" "$DEFCONFIG"
	echo "  [ok]   X00TD_defconfig installed"
fi

echo
echo "==> Upstream rmnet: UL checksum-offload feature flags"
RMNET_VND="$SRC_ROOT/drivers/net/ethernet/qualcomm/rmnet/rmnet_vnd.c"
[ -f "$RMNET_VND" ] || { echo "ERROR: $RMNET_VND not found" >&2; exit 1; }

# 6a: hw_features csum capability (vanilla mainline lacks it)
if grep -qF 'rmnet_dev->hw_features |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;' "$RMNET_VND"; then
	echo "  [skip] hw_features NETIF_F_IP_CSUM|IPV6_CSUM"
else
	perl -0777 -i -pe 's/(\trmnet_dev->hw_features = NETIF_F_RXCSUM;\n)/$1\trmnet_dev->hw_features |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;\n/' "$RMNET_VND"
	grep -qF 'hw_features |= NETIF_F_IP_CSUM' "$RMNET_VND" || { echo "ERROR: rmnet_vnd hw_features anchor not found" >&2; exit 1; }
	echo "  [ok]   hw_features NETIF_F_IP_CSUM|IPV6_CSUM"
fi

# 6b: GRO_HW capability + default-enable the csum features.
# rmnet_map_v4_checksum_uplink_packet() checks orig_dev->features (not
# hw_features) and silently memset-zeroes the UL csum header when the
# features are off -> modem drops every UL frame once EGRESS_MAP_CKSUMV4
# is enabled. Default-enable them; ethtool -K can still toggle.
if grep -qF 'rmnet_dev->features    |= NETIF_F_IP_CSUM' "$RMNET_VND"; then
	echo "  [skip] GRO_HW + default-enabled csum features"
else
	perl -0777 -i -pe 's/(\trmnet_dev->hw_features \|= NETIF_F_SG;\n)/$1\t\/* Vendor 4.19 parity: the underlying IPA HW can GRO-coalesce. *\/\n\trmnet_dev->hw_features |= NETIF_F_GRO_HW;\n\n\t\/* UL csum offload: rmnet_map_v4_checksum_uplink_packet() falls back\n\t * to memset-zeroing the UL csum header when these are not ENABLED\n\t * (it tests features, not hw_features) - the modem then silently\n\t * drops all UL traffic with EGRESS_MAP_CKSUMV4 on. Default-enable;\n\t * ethtool -K can still toggle them.\n\t *\/\n\trmnet_dev->features    |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;\n/' "$RMNET_VND"
	grep -qF 'NETIF_F_GRO_HW' "$RMNET_VND" || { echo "ERROR: rmnet_vnd SG anchor not found" >&2; exit 1; }
	echo "  [ok]   GRO_HW + default-enabled csum features"
fi

echo
echo "============================================================"
echo "Mainline-tree integration complete."
echo "============================================================"
