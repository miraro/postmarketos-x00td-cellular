# Mainline cellular data on Asus Zenfone Max Pro M1 (X00TD / SDM636)

**Status:** working production. 20.5 Mbps DL sustained, ~4 Mbps UL
aggregate over Vodafone CZ LTE, on mainline Linux 6.19 (PostmarketOS),
without ModemManager driving the bearer.

This document describes:

1. What was built and how it differs from the existing
   ModemManager-based bringup
2. The kernel changes required (out-of-tree IPA driver port plus a
   small upstream-rmnet feature-flag change)
3. The userspace `vendor-init` tool that replaces ModemManager's
   bearer-activation role
4. Reproducible build, deploy, and activation steps
5. Honest caveats about what is and isn't fully solved

The work targets SDM636-class IPA v2.6L modems. Most of it should
transfer to other SDM6xx devices with minor port effort.

---

## TL;DR

```
git clone https://github.com/miraro/postmarketos-x00td-cellular
# Kernel: overlay the pristine baseline + run the port pipeline on any
# mainline-ish 6.19 tree, then build via pmbootstrap as usual for X00TD:
#     cp -rT postmarketos-x00td-cellular/vendor-baseline-4.19/ $KERNEL_TREE/
#     postmarketos-x00td-cellular/port/apply-all.sh --root $KERNEL_TREE
# Build vendor-init: cd postmarketos-x00td-cellular/vendor-init && make
# Deploy vendor-init binary to /usr/local/sbin/
# On device, run:
#     systemctl stop ModemManager
#     vendor-init -v &
#     ip addr add $(cat /run/vendor-init/bearer_ipv4)/$(cat /run/vendor-init/bearer_prefix) dev qmapmux0.0
#     ip route replace default via $(cat /run/vendor-init/bearer_gw) dev qmapmux0.0
#     echo "nameserver 1.1.1.1" > /etc/resolv.conf
# Result: cellular LTE up, ~20 Mbps DL throughput
```

---

## Throughput measurement

Test environment: Vodafone CZ "internet" APN, LTE 800 MHz, X00TD
post-reboot to LTE-attached state.

| Direction | Throughput | Test method |
|---|---|---|
| DL sustained | 20.5 Mbps (2.57 MB/s) | `curl http://cachefly.cachefly.net/100mb.test` — 100 MB completed |
| UL single-flow | ~150 KB/s | `curl -X POST --data-binary @50mb.bin https://httpbin.org/post` |
| UL aggregate (4 parallel) | ~4-4.3 Mbps | 4× concurrent 50 MB POST |
| RTT to 8.8.8.8 | 23-65 ms | `ping -I qmapmux0.0` (ttl=42, real internet hops) |

Single-flow UL appears to be server-side or per-flow Vodafone shaping,
not a driver-side limit (aggregate scales linearly across streams).

---

## Hardware and software targets

- **Device:** Asus Zenfone Max Pro M1 (codename `X00TD`)
- **SoC:** Qualcomm SDM636 (Snapdragon 636)
- **Modem:** integrated Qualcomm modem, IPA HW v2.6L
- **Kernel:** mainline Linux 6.19 (PostmarketOS branch), out-of-tree
  IPA driver port
- **Distribution:** PostmarketOS edge (Alpine-based)
- **Operator tested:** Vodafone CZ (APN `internet`)
- **Modem firmware:** stock Asus / Vodafone provisioning, no NV writes
  performed

---

## Background — why this work exists

Mainline Linux on Qualcomm IPA-based phones traditionally relies on:

1. The mainline IPA 3.x driver (`drivers/net/ipa/`) — does not support
   IPA v2.x hardware found in SDM6xx/SDM660/SDM636.
2. ModemManager + libqmi for QMI bringup. Works for activation but
   leaves throughput on the table because some Qualcomm-vendor-specific
   handshake steps aren't part of MM's vendor-neutral QMI flow.

Empirically on X00TD we observed:

- With ModemManager + stock mainline rmnet + working IPA v2 driver
  port, throughput capped at roughly 67 KB/s downlink — far below
  what the hardware and the carrier can actually deliver.
- The cap could not be fixed with rate-limit / QoS / DL aggregation
  tweaks alone; we tried many.
- Reverse-engineering the Android Lineage 22 stack revealed that
  vendor `netmgrd` negotiates QMAPv3 framing on the modem-to-AP DL
  path. With QMAPv3, every DL packet has an extra 8-byte checksum
  trailer the mainline rmnet driver needs to strip; otherwise the
  trailer corrupts TCP payloads on the IP layer and you get ICMP that
  works but TCP that doesn't.
- The trailer handling is in mainline rmnet via the
  `INGRESS_MAP_CKSUMV4` flag, but it has to be enabled on the
  per-mux netdev *and* the modem has to be negotiated into QMAPv3
  via WDA SET\_DATA\_FORMAT — neither of which ModemManager does by
  default.

`vendor-init` is a small static userspace tool that performs the
exact byte sequence Android vendor `netmgrd` + `qcrild` do to bring
up a QMAPv3-capable bearer. It then configures the rmnet child
device to strip the trailer and routes are set up by the user. The
result is 20.5 Mbps DL sustained on the same SIM/APN where MM
delivered 67 KB/s.

The DL throughput unlock is the headline result. The
`vendor-init` itself is also a useful artifact: a clean,
ModemManager-free path to a working cellular bearer on this class
of hardware.

---

## Components

### A. Kernel — IPA v2.6L driver port

Out-of-tree port of the Qualcomm `ipa_v2` driver from
Lineage 4.19 (`lineage-sdm660-22.2`) to mainline 6.19. This is
the large piece: roughly 5000+ lines of `drivers/platform/msm/ipa/ipa_v2/`
adapted for current mainline APIs (dmaengine, IRQ chip, regmap, etc.).

The port ships in this package in fully reproducible form: a pristine
vendor-source baseline (`vendor-baseline-4.19/`) plus the `port/`
script pipeline that transforms it (see *The port as a script
pipeline* below). It is not yet ready for upstream submission — too
many vendor-specific heuristics and disabled features — but it is
functional and stable on X00TD.

The key changes the port introduces, on top of the vendor baseline:

- `rmnet_vnd`: default-enable IP_CSUM features so UL csum offload
  works **for the QMAPv3-UL path** — but see **Section C.1**: in the
  default asymmetric production config (`EGRESS_MAP_CKSUMV4` off) this
  unconditional enable is *harmful* and should be gated
- `rmnet_ipa`: opt-in QMAPv3 UL via the `qmapv3_ul_enable` module param
- `rmnet_ipa`: query per-interface `ext_props` for `mux_id` + `rt_tbl_idx`
- `rmnet/ipa2`: Phase 3 IPACM expansion — GRO_HW, 6-spec QMI,
  FILTER_INSTALLED_NOTIF
- `ipa2/rmnet_ipa`: vendor `max_mtu` parity + IPACM Phase 1+2 port

The first of these (the `rmnet_vnd` default-enable change) is small
and self-contained and could be considered for upstream review
independently — see Section C below.

### B. Userspace — `vendor-init` utility

Standalone 8-stage cellular bringup binary. Statically linked (no
glibc dependency on device), about 676 KB ARM aarch64.

Source: `vendor-init/` in this repo. About 1900 LoC of
C (built `-std=gnu11`), single dependency on `linux/qrtr.h` for
`AF_QIPCRTR`.

Pipeline:

```
1. dms_online   — DMS_GET_OPERATING_MODE, ensure modem is ONLINE
2. nas_rat      — NAS_GET_SERVING_SYSTEM; if not LTE, fire
                  SET_SYSTEM_SELECTION_PREFERENCE + INITIATE_NETWORK_REGISTER
3. dpm_open     — DPM_OPEN_PORT_REQ on Data Port Mapper service
4. wda_set      — WDA SET_DATA_FORMAT QMAPv3 + 10 TLVs byte-exact vendor
5. dsd          — DSD service lookup (no register sent)
6. bind_mux     — WDS_BIND_MUX_DATA_PORT, persistent socket
7. wds_start    — minimal 2-TLV WDS_START_NETWORK (APN + IP family)
                  followed by WDS_GET_CURRENT_SETTINGS to read IP/GW/DNS/MTU
8. post_tune    — auto-create qmapmux0.0 child netdev with mux_id 1
                  + ingress-deaggregation + ingress-mapv4-checksum on,
                  set MTU to the modem-advertised value, plus sysctl
                  knobs (netdev_max_backlog, disable TCP cubic hystart)
```

Each stage opens its own QRTR socket (per-service modem state isolation
empirically required). The `bind_mux` stage keeps its socket open for
the lifetime of the bearer — closing it tears the bearer down, which
is how `vendor-init` runs in the foreground holding the bearer up.

Output: each stage writes state files under `/run/vendor-init/`:

```
/run/vendor-init/state           READY or FAILED_<stage>
/run/vendor-init/bearer_pdh      packet data handle from modem (hex)
/run/vendor-init/bearer_ipv4     assigned IPv4
/run/vendor-init/bearer_gw       gateway
/run/vendor-init/bearer_prefix   subnet prefix length (auto-computed)
/run/vendor-init/bearer_mtu      modem-advertised MTU
/run/vendor-init/wda_dl_proto    7 if QMAPv3 DL accepted
```

User uses these to set up IP and routes after `vendor-init` runs.

### C. Kernel — rmnet IP_CSUM features fix

`drivers/net/ethernet/qualcomm/rmnet/rmnet_vnd.c` currently sets
`hw_features` (capabilities the hardware can do) but leaves
`features` (what is actually enabled) at zero for the per-mux
rmnet child device.

This breaks UL checksum offload when `RMNET_FLAGS_EGRESS_MAP_CKSUMV4`
is enabled on the port. The offload code in `rmnet_map_data.c`:

```c
static void rmnet_map_v4_checksum_uplink_packet(struct sk_buff *skb,
                                                struct net_device *orig_dev)
{
    ...
    if (unlikely(!(orig_dev->features &
                 (NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM))))
        goto sw_csum;
    ...
sw_csum:
    memset(ul_header, 0, sizeof(*ul_header));
    ...
}
```

When neither feature is set, the code silently zeros the 4-byte UL
csum header and sends the frame. The modem receives a malformed UL
frame and drops it — silently. Symptom: 100 % packet loss on UL once
you enable `EGRESS_MAP_CKSUMV4`, with no kernel error message.

The change (applied by `port/05-integrate-mainline-tree.sh`):

```diff
--- a/drivers/net/ethernet/qualcomm/rmnet/rmnet_vnd.c
+++ b/drivers/net/ethernet/qualcomm/rmnet/rmnet_vnd.c
@@ -314,6 +314,15 @@ int rmnet_vnd_newlink(u32 id, struct net_device *rmnet_dev,
 	rmnet_dev->hw_features  = NETIF_F_RXCSUM;
 	rmnet_dev->hw_features |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;
 	rmnet_dev->hw_features |= NETIF_F_SG;
+	rmnet_dev->hw_features |= NETIF_F_GRO_HW;
+
+	/* The UL csum-offload code in rmnet_map_v4_checksum_uplink_packet
+	 * falls back to memset-zero of the UL header when neither
+	 * NETIF_F_IP_CSUM nor NETIF_F_IPV6_CSUM is enabled. Enable both
+	 * by default so EGRESS_MAP_CKSUMV4 actually does the right thing
+	 * when activated; ethtool -K can still toggle these. */
+	rmnet_dev->features |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;
```

This is small, self-contained, and arguably an upstream bug — the
fallback `sw_csum` path silently produces invalid frames if features
weren't enabled. A safer behavior would be to refuse to set
`EGRESS_MAP_CKSUMV4` in the first place when features are off, but
defaulting features on is a one-line fix that lets things work as
expected.

This change is **necessary if you want UL QMAPv3 (symmetric
config)**. For the asymmetric DL-only QMAPv3 production config —
which is what we recommend — it's not strictly required.

#### C.1 — Critical correction (2026-06-12): the unconditional `features` enable is *harmful* in the production config

Re-verified end-to-end against the downstream tree
(`android_kernel_qcom_sdm660`) and the mainline rmnet sources. The
"not strictly required" framing above was too soft. In the
**default asymmetric production config (UL = QMAPv1,
`EGRESS_MAP_CKSUMV4` OFF)** the `features |= NETIF_F_IP_CSUM |
NETIF_F_IPV6_CSUM` line (`rmnet_vnd.c:326`) is **actively harmful**,
and is the prime suspect for the UL TLS corruption (`bad_record_mac`
at the peer; DL is byte-perfect, plain-TCP tolerates it, TLS does
not).

Two *independent* checksum layers were being conflated:

1. **rmnet `EGRESS_MAP_CKSUMV4` data_format flag** — controls whether
   rmnet inserts the 4-byte UL csum header and runs
   `rmnet_map_v4_checksum_uplink_packet()`. The `memset`-zero
   fallback (the bug Section C originally describes) only ever runs
   **when this flag is on** — `rmnet_map_checksum_uplink_packet()` is
   gated by `if (csum_type)` in `rmnet_handlers.c:143-158`. In the
   production config this flag is **OFF**, so that path is dormant.

2. **`NETIF_F_IP_CSUM` netdev feature** (`= tx-checksum-ipv4: on` in
   `ethtool -k`) — independent of the flag above. When it is in
   `dev->features`, the Linux stack emits UL TCP/UDP skbs as
   `CHECKSUM_PARTIAL` (L4 checksum *deferred to the device*). But
   with `EGRESS_MAP_CKSUMV4` OFF, rmnet's egress handler never
   completes the checksum, and the IPA egress pipe (UL = QMAPv1, no
   `cs_offload_en`) does not either. The frame leaves with an
   **incomplete L4 checksum** → corrupted uplink.

So the original change put `NETIF_F_IP_CSUM` into `features`
**unconditionally**, which is correct *only* when
`EGRESS_MAP_CKSUMV4` is also active. In the default config (flag OFF)
it should stay **out of `features`** (keep it in `hw_features` so
`ethtool -K` can still turn it on for the QMAPv3-UL path).

**Fix options:**

- **Kernel (correct fix):** gate line 326 — only OR
  `NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM` into `features` when the port
  will run `EGRESS_MAP_CKSUMV4`/`V5`. Keep them in `hw_features`
  always.
- **Userspace (zero-rebuild) — implemented:**
  `vendor-init/stage_post_tune.c` now disables UL tx-checksum in the
  non-`full_ul` branch
  (`ethtool -K qmapmux0.0 tx-checksum-ipv4 off tx-checksum-ipv6 off`,
  plus the parent `rmnet_ipa0` best-effort), so the stack computes a
  correct SW checksum. The `--full-ul` branch leaves it on (QMAPv3 UL
  needs the offload). Confirm on-device with
  `ethtool -k qmapmux0.0 | grep tx-checksum-ipv4` (must read `off`),
  then re-test HTTPS upload.

**`vendor-init` itself is clean — no bug there.** It correctly keeps
`full_ul = 0` by default (only `-U`/`--full-ul` sets it), sends
`WDA ul_data_agg_proto = 5` (QMAPv1), and does **not** set
`egress-mapv4-checksum` in the default branch
(`stage_post_tune.c:135-150`, well-commented). The `tx-checksum-ipv4:
on` observed on-device originates **solely** from the kernel
`rmnet_vnd.c:326` line, a different layer than anything vendor-init
configures.

---

## How to reproduce

### Prerequisites

- A Linux host with `pmbootstrap` installed and configured
- Asus Zenfone Max Pro M1 (X00TD) with unlocked bootloader and
  PostmarketOS userspace already installed
- Working SSH access to the device

This is currently a research-grade port; expect to be hands-on with
both kernel and userspace builds.

### Build the kernel

Produce the tree yourself from any mainline-ish 6.19 kernel with this
package's script pipeline (see *The port as a script pipeline* below):

```bash
# Start from any mainline-ish 6.19 SDM660 tree, e.g. sdm660-mainline:
cd ~/pmbootstrap/linux
git clone -b qcom-sdm660-6.19.y https://github.com/sdm660-mainline/linux.git qcom-sdm660-6.19.y

# Overlay the pristine vendor baseline + run the port pipeline:
cp -rT /path/to/postmarketos-x00td-cellular/vendor-baseline-4.19/ qcom-sdm660-6.19.y/
/path/to/postmarketos-x00td-cellular/port/apply-all.sh --root qcom-sdm660-6.19.y
cd qcom-sdm660-6.19.y

# Build via pmbootstrap envkernel as usual
source ~/pmbootstrap/helpers/envkernel.sh
make X00TD_defconfig
make -j$(nproc)

# Then flash via pmbootstrap as you would any other postmarketOS kernel:
pmbootstrap install
```

Required kernel configuration:

```
CONFIG_SPS=m                    # BAM/SPS DMA framework (built-in or module)
CONFIG_SPS_SUPPORT_NDP_BAM=y    # NDP-BAM extensions used by SDM660 IPA
CONFIG_IPA=m                    # IPA v2.6L monolithic driver
CONFIG_RMNET_IPA=m              # rmnet/QMI handlers (link into IPA module)
CONFIG_IPA_DEBUG=y              # debugfs nodes — recommended for bringup
```

Runtime knobs:

- `qmapv3_ul_enable=0` (`ipa-driver` module param, default off) — opt-in UL
  QMAPv3 EGRESS pipe 4 reconfiguration. Leave at 0 for production; only
  flip on if you are debugging symmetric UL QMAPv3 (still WIP, see
  "Known caveats").

### Required DTS regulators (always-on rails)

The IPA / modem-RF chain on SDM636 needs the PMIC LDO16 rail kept on
to power the antenna front-end. Without `regulator-always-on` the rail
collapses when no consumer is currently active, and the modem then sees
no RF input — registration drops and the bearer dies seconds later.

Inside the `pmi8950_rpm_regulators` (or your board's corresponding RPM
regulator node) block:

```dts
vreg_l16a_2p7: l16 {
    regulator-min-microvolt = <2800000>;
    regulator-max-microvolt = <2800000>;
    regulator-enable-ramp-delay = <250>;
    regulator-always-on;
};
```

One more rail, **`vreg_l7a_1p2` (1.2 V), also needs
`regulator-always-on`**. This one is an empirical bringup carry-over
from the proven-working tree — it was never isolated which consumer
needs it held, but the working 20.5 Mbps configuration has it pinned,
so the port keeps it. Both rails are handled automatically by
`port/05-integrate-mainline-tree.sh`; mirror them onto other SDM6xx
boards if you are adapting this port.

### Required DTS nodes (SPS / IPA / rmnet)

Three sibling nodes under `&soc` together describe the BAM/SPS DMA
framework, the IPA core, and the rmnet platform driver that builds
the `rmnet_ipa0` netdev.

```dts
&soc {
    qcom_sps: qcom,sps {
        compatible = "qcom,msm-sps-4k";
        qcom,device-type = <3>;     /* default — no BAMDMA */
        qcom,pipe-attr-ee;
        status = "okay";
    };

    /* IPA hardware: chip core at +0x0, BAM-DMA at +0x4000 */
    ipa: ipa@14780000 {
        compatible = "qcom,ipa";
        reg = <0x14780000 0x4000>,
              <0x14784000 0x3C000>;
        reg-names = "ipa-base", "bam-base";

        qcom,ipa-hw-ver = <6>;              /* IPA_HW_v2_6L */
        qcom,ipa-hw-mode = <0>;             /* IPA_MODE_NORMAL */
        qcom,ee = <0>;
        qcom,wan-rx-ring-size = <0xc0>;     /* matches Android 4.19 */
        qcom,lan-rx-ring-size = <0xc0>;
        qcom,rx-polling-sleep-ms = <1>;
        qcom,ipa-polling-iteration = <40>;

        qcom,arm-smmu;
        qcom,smmu-s1-bypass;
        qcom,modem-cfg-emb-pipe-flt;        /* CRITICAL: modem handles
                                               internal filter install */
        qcom,use-dma-zone;
        qcom,use-ipa-tethering-bridge;
        qcom,ipa-wdi2;

        interrupts = <GIC_SPI 333 IRQ_TYPE_LEVEL_HIGH>,    /* IPA */
                     <GIC_SPI 432 IRQ_TYPE_LEVEL_HIGH>;    /* BAM */
        interrupt-names = "ipa-irq", "bam-irq";

        clocks = <&rpmcc RPM_SMD_IPA_CLK>,
                 <&rpmcc RPM_SMD_AGGR2_NOC_CLK>;
        clock-names = "core_clk", "smmu_clk";

        /* Force RPM clock vote at probe — driver clk-scaling is bypassed */
        assigned-clocks = <&rpmcc RPM_SMD_IPA_CLK>;
        assigned-clock-rates = <200000000>;  /* 200 MHz turbo */

        iommus = <&anoc2_smmu 0x19C0>,
                 <&anoc2_smmu 0x19C2>;
        dma-coherent;

        interconnects =
            <&a2noc MASTER_IPA &bimc SLAVE_EBI>,
            <&a2noc MASTER_IPA &snoc SLAVE_IMEM>,
            <&gnoc MASTER_APSS_PROC &snoc SLAVE_IPA>;
        interconnect-names = "ipa-mem", "ipa-imem", "cpu-cfg";

        status = "okay";

        /* SMMU context-bank children — required for SMMU CB probe.
         * Each CB accepts optional qcom,smmu-s1-bypass and
         * qcom,iommu-fast-map booleans (the 6.x replacement for the
         * removed iommu_domain_get_attr() side-channel); S1 bypass
         * falls back to the top-level qcom,smmu-s1-bypass above. */
        qcom,ipa-smmu-ap-cb {
            compatible = "qcom,ipa-smmu-ap-cb";
            iommus = <&anoc2_smmu 0x19C0>;
            qcom,iommu-dma-addr-pool = <0x20000000 0x40000000>;
        };
        qcom,ipa-smmu-wlan-cb {
            compatible = "qcom,ipa-smmu-wlan-cb";
            iommus = <&anoc2_smmu 0x19C1>;
            qcom,iommu-dma-addr-pool = <0x20000000 0x40000000>;
        };
        qcom,ipa-smmu-uc-cb {
            compatible = "qcom,ipa-smmu-uc-cb";
            iommus = <&anoc2_smmu 0x19C2>;
            qcom,iommu-dma-addr-pool = <0x20000000 0x40000000>;
        };
    };

    /* rmnet platform driver — sibling of ipa@..., builds rmnet_ipa0 */
    rmnet_ipa {
        compatible = "qcom,rmnet-ipa";
        qcom,rmnet-ipa-ssr;                 /* MPSS POWERUP handshake */
        qcom,ipa-loaduC;                    /* load uC firmware */
        qcom,ipa-advertise-sg-support;
        qcom,ipa-napi-enable;               /* NAPI on pipe 5 (RX) */
        qcom,wan-rx-desc-size = <1024>;
        status = "okay";
    };
};
```

Key non-obvious bits other porters trip over:

- **`reg-names = "ipa-base", "bam-base"`** — the vendor driver expects
  exactly these names. The mainline `drivers/net/ipa/` driver expects
  `"ipa-reg", "ipa-shared", "bam-base"` and a different base address
  (0x147c0000); do **not** mix them.
- **IPA interrupt 333 must be LEVEL_HIGH**, not EDGE_RISING. The Asus
  4.19 source had EDGE_RISING; that misses interrupts when probe is
  slow and the QMI handshake silently never finishes.
- **`qcom,modem-cfg-emb-pipe-flt`** — without this the AP-side driver
  tries to install WAN filter rules and conflicts with the modem,
  which installs them itself on v2.6L. DL stays at 0 pps.
- **Property names matter:** the CB sub-nodes use
  `qcom,iommu-dma-addr-pool` — that is the name the driver reads. An
  earlier revision shipped `qcom,iova-mapping`, which the driver
  silently ignored (harmless under S1 bypass, but misleading).
  Similarly, `qcom,pipe-wan` / `qcom,rt-idx-*` /
  `qcom,smmu-disable-htw` / `modem-remoteproc` were dropped from the
  DTS — nothing in this driver reads them (the WAN pipe 5 and
  rt-table 8/7 values are driver/auto-IPACM constants, and the htw
  attribute died with the old IOMMU attr API).
- **`assigned-clock-rates = <200000000>`** pins IPA core_clk at the
  turbo 200 MHz rate. In the **base** port the driver's clk-scaling is
  disabled, so the rate has to come from DT or you get the boot-default
  ~75 MHz and a higher *IPA-internal* processing latency. (Note: the
  power-save work later measured that 75 MHz costs only ~+5 ms *end-to-end*
  RTT and **no throughput** on this ~20 Mbps link — the radio dominates, so
  the internal-latency penalty barely surfaces. See **Power-save** below.)
  If you apply the optional power-save patch + overlay (see **Power-save:
  dynamic IPA clock scaling** below), the driver owns the rate instead and
  this pin should be dropped.

The full block is in
`port/files/arch/arm64/boot/dts/qcom/sdm636-asus-x00td.dts` (the
`&soc` section at the end) — `05-integrate-mainline-tree.sh` appends
it to an existing in-tree X00TD DTS, or installs the whole reference
file when the tree has none.

### The port as a script pipeline

The port ships as a pristine vendor-source baseline plus a pipeline of
idempotent, self-documenting shell scripts — every transformation is
visible, grep-able, and explained in place:

```bash
# 1. Get a mainline 6.19 kernel tree (linux.git, pmOS 6.19.y, …).
KERNEL_TREE=/path/to/your/qcom-sdm660-6.19-kernel

# 2. Overlay the pristine 4.19 baseline (76 vendor files, byte-identical
#    to lineage-sdm660-22.2 — provenance in vendor-baseline-4.19/README.md).
cp -rT vendor-baseline-4.19/ "$KERNEL_TREE"/

# 3. Run the pipeline.
./port/apply-all.sh --root "$KERNEL_TREE"
```

The pipeline stages:

| Script | What it does |
|---|---|
| `00-install-port-files.sh` | installs the new/replaced whole files: minimal Kconfig/Makefile set, `ipa_compat.h` shim, `ipa_disabled_stubs.c`, `msm_bus_compat.c` (msm_bus→icc translator), stub headers |
| `05-integrate-mainline-tree.sh` | wires `drivers/platform/msm/` into the upstream build system, prepares the X00TD DTS (appends the IPA/SPS/rmnet `&soc` block to an existing in-tree DTS — postmarketOS 6.19 already ships one — or installs the full reference), installs `X00TD_defconfig`, and adds the rmnet UL-csum feature flags |
| `10-apply-port-patches.sh` | the mechanical 4.19→6.x API conversion (class_create, dma_zalloc, strlcpy, IS_ENABLED gating, …) |
| `20-apply-port-fixes.sh` | bringup-correctness fixes: clock/IRQ probe fixes, wakelock neutralization, TX-event handling, ModemManager integration, SSR robustness, plus the modern-kbuild hard-error fixes (missing prototypes, fortify-safe copy guards, …) |
| `30-apply-port-features.sh` | the throughput features: in-kernel IPACM emulation, Q6 filter-rule install fixes, the `qmapv3_ul_enable` knob, icc bandwidth voting, A/B datapath knobs |
| `90-apply-diag-sondy.sh` | **optional** — the curated bringup-diagnostics set; see *Debug instrumentation (sondy)* |

Each edit is guarded: already-applied changes are skipped (the whole
pipeline is idempotent), and any unexpected tree state aborts with a
clear message instead of silently mis-applying. The pipeline output —
pristine baseline + scripts — compiles warning-free against the modern
kbuild default-error set and was re-validated on the device on
2026-06-06: 20.6 Mbps DL sustained (`curl` against cachefly over
`qmapmux0.0`, Vodafone CZ LTE), matching the original bringup figure.

One practical note from that re-validation: right after boot the modem
may camp on GSM for a while (DL ~15 KB/s). The selection preference
already lists LTE first — just wait for the LTE attach (watch
`qmicli -d qrtr://0 --nas-get-serving-system`) before judging
throughput.

### Build vendor-init

```bash
cd vendor-init
make
# Produces ./vendor-init — ARM aarch64 static binary, ~676 KB
```

The Makefile cross-compiles with the standard
`aarch64-linux-gnu-gcc` toolchain. No external dependencies — only
`<linux/qrtr.h>` is consumed from kernel UAPI.

### Deploy

```bash
# Push to device
scp vendor-init root@<device>:/usr/local/sbin/

# Optionally, push the systemd unit (see Appendix A)
```

### Activate cellular bearer

On the device, with the new kernel running and modem fully booted
(typically 5-15 seconds after power-on; modem may auto-attach to
LTE within that window):

```bash
# Stop ModemManager — vendor-init will own the bearer
sudo systemctl stop ModemManager
sleep 2

# Run vendor-init in the foreground. It holds the QRTR socket open
# which is what keeps the bearer alive. Ctrl-C tears the bearer down.
sudo vendor-init -v 2>&1 | tee /tmp/vi.log &

# Wait a couple of seconds, then set up IP and routes from the state
# files vendor-init populates:
IP=$(cat /run/vendor-init/bearer_ipv4)
GW=$(cat /run/vendor-init/bearer_gw)
PREFIX=$(cat /run/vendor-init/bearer_prefix)

sudo ip addr flush dev qmapmux0.0
sudo ip addr add ${IP}/${PREFIX} dev qmapmux0.0
sudo ip route replace default via ${GW} dev qmapmux0.0
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf

# Verify
ping -c 5 -I qmapmux0.0 8.8.8.8     # expect 25-100 ms LTE RTT
```

If your operator gives a `/29`, `/30`, or `/31` cellular subnet,
`bearer_prefix` is computed automatically from the modem-advertised
mask — no manual edit needed.

### Activation as a systemd service (optional)

See Appendix A at the end of this document.

---

## Throughput tuning (already automatic)

`vendor-init` `post_tune` stage automatically:

1. Creates `qmapmux0.0` with `mux_id 1`, `ingress-deaggregation on`,
   `ingress-mapv4-checksum on` flags
2. Sets the rmnet child MTU to the modem-advertised MTU
3. Brings the interface up
4. Toggles `tcp_no_metrics_save=1`, `netdev_max_backlog=10000`,
   disables TCP cubic hystart (better cellular slow-start behavior)
5. Enables GRO on `rmnet_ipa0`

The critical piece is the `ingress-mapv4-checksum` flag — without it
the modem-emitted QMAPv3 trailer is not stripped, TCP segments get
corrupted, and you see ~67 KB/s.

### Where the ceiling actually is (offloads, NAPI, AGG)

A fair question is whether 20.5 Mbps is a driver-imposed ceiling.
What we know:

- **The arithmetic.** 20 Mbps at ~1400 B/packet is ~1.8 kpps — far
  below where softirq overhead or NAPI batching starts to matter.
  The NAPI weight is the vendor's 60 (vs. the kernel default 64);
  at these packet rates the difference is noise.
- **DL checksums never touch the CPU.** IPA HW emits the QMAPv3
  csum trailer, upstream rmnet's `INGRESS_MAP_CKSUMV4` validates it
  and marks `CHECKSUM_UNNECESSARY` on `qmapmux0.0`.
- **GRO runs where it should.** Upstream rmnet delivers child-device
  RX through `gro_cells`, so software GRO aggregates on
  `qmapmux0.0` regardless of parent-device flags; `vendor-init`
  additionally enables GRO/`NETIF_F_GRO_HW` knobs in `post_tune`.
- **Scatter-gather.** The IPA TX path supports non-linear skbs
  (per-frag BAM descriptors in `ipa2_tx_dp()`), and the port now
  advertises `NETIF_F_SG` on `rmnet_ipa0` when the DT sets
  `qcom,ipa-advertise-sg-support`. It is a capability
  (`hw_features`), not default-on — enable with
  `ethtool -K rmnet_ipa0 sg on` if you want to avoid UL linearize
  copies. UL is carrier-shaped on our test SIM, so this was not the
  bottleneck.
- **AGG is QMAP's "TSO".** There is no TSO engine on v2.6L; bulk
  efficiency comes from IPA HW aggregation (6 KB / 10 pkt / 1 ms
  windows, both directions). We empirically probed larger AGG
  windows during bringup (phases 4m/4n: 16 K/20) — **no throughput
  change**, the cap at the test site was carrier-side, not AP-side.
- **DL deaggregation is *software*, not a HW DEAGGR engine.** A
  common mental model — "IPA's `IPA_ENDP_INIT_DEAGGR` engine
  (`aggr_type = QCMAP`) splits one BAM frame into N skbs in
  hardware" — is **not** how the WAN_CONS RX path works on v2.6L
  (verified in `android_kernel_qcom_sdm660/.../ipa_v2`). What
  actually happens:
  - The RX endpoint uses **GENERIC aggregation**
    (`aggr_en = IPA_ENABLE_AGGR`, `aggr = IPA_GENERIC`; `ipa_dp.c`
    `ipa2_cfg_ep_*` defaults). The HW only *packs* incoming packets
    into one buffer up to the byte/pkt/time limit and closes it on
    EOF — it does **not** parse QMAP sub-frame boundaries.
  - QMAP-level splitting is done in **software**, in one of two
    modes selected by `ipa_client_apps_wan_cons_agg_gro`:
    - **GRO mode** (flag true, set when the modem negotiates
      `RMNET_IOCTL_INGRESS_FORMAT_AGG_DATA`): the whole closed
      aggregate is handed straight up via
      `client_notify(IPA_RECEIVE, skb)` (`ipa_dp.c`
      `ipa_wan_rx_pyld_hdlr`) and rmnet/`gro_cells` splits the QMAP
      sub-frames. IPA per-packet status is **disabled**
      (`status_en = false`) in this mode.
    - **Status mode** (flag false): IPA HW writes an
      `ipa_hw_pkt_status` descriptor before each QMAP frame and the
      kernel parses them in the `ipa_wan_rx_pyld_hdlr` while-loop
      (reads `pkt_len` from the big-endian QMAP header, handles the
      csum trailer).
  - `ipa2_disable_apps_wan_cons_deaggr()` is **misleadingly named**:
    it configures no HW deaggregation — it just validates
    `agg_size/agg_count` against the IPA limits and sets the
    `agg_gro` flag to pick GRO mode.
  - **Why this matters here:** this whole path is **DL/RX** and is
    *proven working* (20.5 Mbps, md5-verified). Aggregation is **not**
    the broken layer. The open UL issue lives on the **egress/TX**
    side (checksum offload — see Section C.1), an entirely separate
    code path.
- **The known AP-side wart** is the ~1 Hz SPS EOT interrupt on the
  WAN RX pipe, worked around by NAPI re-polling; the
  `ipa_wan_busypoll` knob exists for experiments on other devices.

So on Vodafone CZ LTE800 the measured 20.5 Mbps tracked the carrier,
not the driver. On a fatter cell the first things to look at are the
EOT IRQ workaround and AGG window sizing — the probes from
`90-apply-diag-sondy.sh` give you the visibility for both.

---

## Power-save: dynamic IPA clock scaling (optional)

By default the port runs the IPA core clock at a fixed rate (DT-pinned
200 MHz, driver-nominal 150 MHz) — `enable_clock_scaling` is 0 and the
IPA Resource Manager, although fully compiled and wired (see *What's NOT
ported §3*), never moves the clock. This is the simplest, known-good
configuration and is what the 20.5 Mbps DL figure was measured on.

Two opt-in artefacts re-enable dynamic clock scaling so the core clock
runs low whenever the modem path is not saturating it:

| Artefact | What it changes |
|---|---|
| `patches/sdm660-ipa-port-6.19-powersave.patch` | `ipa_v2/ipa.c`: `enable_clock_scaling = 1`, thresholds kept at the vendor values (nominal 600 / turbo 1000 Mbps, set explicitly). The static cellular RM vote never reaches them, so **active data runs at SVS = 75 MHz** — hardware-proven to sustain the full link. Boot stays at TURBO for the Q6 handshake. |
| `dts/sdm636-asus-x00td-ipa-powersave.dtso` | DT **overlay** dropping the `assigned-clocks` / `assigned-clock-rates = <200000000>` pin from `&ipa`, handing the rate to the driver. Clocks and interconnects inherited unchanged. |
| `patches/sdm636-asus-x00td-ipa-powersave-dtbo.patch` | Drops the `.dtso` into `arch/arm64/boot/dts/qcom/` and registers it as a `.dtbo` build target in the qcom Makefile (for overlay-capable boot chains). |
| `patches/sdm636-asus-x00td-ipa-powersave-dts.patch` | The same pin removal as a **direct patch** to `sdm636-asus-x00td.dts`, for boot chains that cannot apply overlays. |

Pick the DT side **one** way: the direct DTS patch *or* the overlay
(`.dtso` + `.dtbo` registration) — not both.

**Why thresholds stay high (active = SVS).** The base port *disabled*
scaling because it feared the vendor thresholds (nominal 600 / turbo 1000
Mbps, sized for gigabit WLAN-offload) would make *every* check "fall
through to SVS = 75 MHz even under data load" and throttle the link.
**Hardware measurement (X00TD, 2026-06-08) proved that fear unfounded —
and turned it into the feature.** The aggregate cellular RM vote measured
**[150, 250) Mbps**, far below the 600 nominal threshold, so active data
does ride SVS — and SVS *sustains the whole link*: a 100 MB DL ran
**2.51 MB/s (~20 Mbps) with a 73 Mbps peak at SVS, identical to NOMINAL
and TURBO**. The cell, not the 75 MHz IPA core clock, is the bottleneck.
So the patch keeps the thresholds high on purpose: active = SVS halves the
active core-clock power for **zero throughput cost** (the only measurable
price is ~+5 ms latency under sustained load, partly cellular jitter).

**Resulting behaviour** *(hardware-measured, X00TD, 2026-06-08)*

| State | IPA core_clk |
|---|---|
| fully idle | gated off (active-clients refcount — already, unchanged) |
| **active data** (RM vote [150,250) « 600) | **SVS 75 MHz** *(the saving)* |
| > 600 Mbps | NOMINAL 150 MHz *(never on cellular)* |
| > 1000 Mbps | TURBO 200 MHz *(never on cellular)* |

**Apply**

```bash
# on top of the base port (after port/apply-all.sh)
patch -p1 < patches/sdm660-ipa-port-6.19-powersave.patch
# then drop the DT clock pin — pick ONE:
#   (a) direct DTS patch (simplest, works everywhere):
patch -p1 < patches/sdm636-asus-x00td-ipa-powersave-dts.patch
#   (b) or the overlay route (overlay-capable boot): register + build the
#       .dtbo, then fdtoverlay it onto the base .dtb at package time:
patch -p1 < patches/sdm636-asus-x00td-ipa-powersave-dtbo.patch
#       (the base .dtb must be built with symbols — add
#        "DTC_FLAGS_sdm636-asus-x00td += -@" to the qcom Makefile)
```

**Caveats**

- **Hardware-tested (X00TD, 2026-06-08).** DL unchanged at ~20 Mbps at
  **SVS (75 MHz)** under load (73 Mbps peak — IPA is never the bottleneck),
  no perceptible stutter. The clock node to watch is
  `/sys/kernel/debug/clk/`**`ipa_clk`** — *not* `ipa_a_clk`, which is the
  deviceless RPM active-vote handle and reads `2147483647` (INT_MAX), not a
  real rate. **Power vs latency knob:** active = SVS is the deepest saving;
  to trade ~half the active core-clock power back for ~5 ms lower latency
  under load, **lower** `clock_scaling_bw_threshold_nominal` below the
  [150,250) vote (e.g. to 50) to park active at NOMINAL (150 MHz) instead —
  measured to give no throughput change either way.
- **⚠ Validated for ~20 Mbps cellular — fast links need a check.** SVS was
  measured to pass *at least* 73 Mbps (a burst peak), but its true ceiling
  above that is **untested**. And because scaling is coarse (see below) the
  clock **does not auto-bump for a faster link** — it stays at SVS no matter
  the actual rate. So on a fast link (good signal + carrier aggregation can
  reach 100+ Mbps on this modem) SVS-active could cap throughput at roughly
  its ceiling. If your link regularly exceeds ~70 Mbps, either **verify**
  with `powersave-validate.sh` + a real DL, **set `nominal=50`** to park
  active at NOMINAL (150 MHz — about double the SVS headroom), or **skip the
  patch** (keep the 200 MHz DT pin) for guaranteed full bandwidth. The
  shipped SVS default is tuned for the typical X00TD cellular case, not for
  a saturated fast link.
- **Idle→burst latency — measured OK.** Because idle and active are *both*
  SVS, there is no SVS→higher ramp on the first packet of a burst (simpler
  than a NOMINAL default). Measured cold first ping after idle **~43 ms vs
  ~22 ms warm** (a one-packet bump), cold HTTPS TTFB a stable
  **0.27–0.29 s** — no micro-stutter. Latency under sustained load was
  **~37 ms at SVS vs ~31 ms at NOMINAL** (~+5 ms, partly cellular jitter).
  All three knobs are **live-tunable via debugfs** (no rebuild):
  `…/enable_clock_scaling`, `…/clock_scaling_bw_threshold_nominal_mbps`,
  `…/clock_scaling_bw_threshold_turbo_mbps`, so A/B between SVS-active and
  NOMINAL-active takes minutes (`patches/powersave-validate.sh` automates
  the sampling).
- **Coarse, not finely load-following.** The RM perf profile is static, so
  scaling is effectively **binary — gated at idle vs SVS when active**,
  not throughput-proportional. True proportional scaling would need
  IPACM/QMI to update the RM perf profiles at runtime.
- Leaving the DT pin in place does *not* break the patch (the driver still
  scales via `clk_set_rate`), but the rail won't drop at idle and the pin
  is misleading — hence the overlay.
- **Rail power saving (mW) is unmeasured — future work.** Only the
  clock-domain behaviour (idle gating + SVS-active) and throughput/latency
  were validated on HW; the *absolute* draw delta on the battery rail was
  not. Measuring it needs the device **discharging** (USB/charger off, so a
  WiFi shell) plus a long `qcom-battery/current_now` average per clock state,
  and the IPA core-clock delta on a single IP block may sit near the
  fuel-gauge noise floor. Treat the DT-pin drop as **opt-in for real
  deployment**; it is not required for the validated clock/throughput
  behaviour above.

---

## Known caveats

### TLS/HTTPS handshake fails intermittently — the cellular path mishandles the large post-quantum ClientHello (NOT the port)

**ROOT CAUSE (2026-06-12, on-device): only the large post-quantum
ClientHello fails, and only over cellular.** OpenSSL 3.5 (shipped in the
rootfs) offers `X25519MLKEM768` by default; its ML-KEM key_share makes the
ClientHello ~1521 B, which spans **two TCP segments** (≈1388 + ≈133). The
cellular path intermittently mishandles delivery of that two-segment
ClientHello, so the server gets a malformed/incomplete record and replies
`decode_error` (or the record layer fails). Clean, interleaved on-device
tests (python `ssl`, same IP, controls for time):

| ClientHello | result |
|---|---|
| TLS 1.3 default = **post-quantum, ~1521 B, 2 segments** | 34/40 (and 20/25) — **~15 % fail** |
| TLS 1.2 = **classical, ~250 B, 1 segment** | **40/40, 25/25 — 0 fail** |
| reverse-tether (non-cellular) with PQ large CH | **50/50 — 0 fail** |

Protocol/server matrix (cellular, handshake-only): **only Cloudflare HTTPS
fails (21/25); google / seznam / httpbin HTTPS and all plain HTTP are
25/25** — because those servers don't negotiate the PQ hybrid, so their
ClientHello stays small/single-segment.

**This resolves the "why no mass outage" paradox:** post-quantum key
exchange is brand new (2024+) and rarely used, so this never showed up as
generic TLS breakage. It is **not** a carrier-wide TLS corruptor and
**not** the driver/port (the data plane is byte-perfect; the captured
ClientHello *leaving* the device is valid; the issue is the cellular
delivery of the specific large 2-segment handshake packet).

**Workarounds (pick one):**
- **Force classical key exchange / disable the PQ hybrid** → small
  single-segment ClientHello → 100 % reliable. System-wide via OpenSSL
  config (`/etc/ssl/openssl.cnf`, `[system_default_sect]` →
  `Groups = x25519:secp256r1:x448:...` without `MLKEM`), or per-app
  (`curl --curves X25519`). Minor tradeoff: drops quantum-resistant KEX
  (almost nothing depends on it yet).
- **Retry** on handshake failure (intermittent → ~99 % after 1-2 retries).
- **VPN** (encapsulates the handshake; reverse-tether proved this works).

**Still open (low prio):** exact culprit on the cellular path (modem UL
segmentation vs a carrier TCP normaliser) for the 2-segment CH — would
need stock-ROM / other-phone A/B. The USB-tether A/B already proves it is
the cellular path, not the device.

---

#### Supporting evidence & how the cause was narrowed

The symptom: HTTPS handshakes fail intermittently with `decode_error` /
`bad_record_mac`, while plain HTTP and bulk transfers are byte-perfect
**both directions**. The tests below excluded every data-plane / device
cause and led to the post-quantum-ClientHello root cause above.

**What was EXCLUDED (each by direct test):**

| test | result | excludes |
|---|---|---|
| `ethtool -K … tx-checksum off` | still fails | UL csum offload |
| `ethtool -K … rx off` (SW-verify DL) | still fails | DL csum masking |
| `ethtool -K … gro/rx-gro-hw off` | still fails | DL receive-coalescing |
| 10 MB random file downloaded ×2 | md5 identical | **DL byte corruption** |
| 40× 20 KB random binary HTTP POST → httpbin (base64 reflect), md5 | **40/40 match** | **UL+DL byte corruption** (p(0/40 \| 15 %)≈0.0015) |
| TLS handshake loop on `:443` vs `:2053` vs `:8443` | all fail ~similar | a 443-only middlebox |
| `tcpdump` of failing handshakes | both dirs TCP-clean, no retransmit | packet loss / TCP rewrite |

So **neither direction corrupts bytes** (40/40 connections byte-perfect),
the handshake TCP stream is intact, yet TLS fails on every port. It is
**not** checksum, aggregation, GRO, filter rules, byte corruption, or
port-specific.

**Capture detail (corroborates the PQ root cause).** A failing handshake
captured at `qmapmux0.0` showed the device *sends* a complete, valid
ClientHello (record `16 03 01 05 ec`, len 1516 → **1521 B total = the
large PQ CH**), split across **two TCP segments**. The server ACKs all
1521 bytes but returns `decode_error` with no ServerHello → it parsed a
malformed/incomplete ClientHello. The bytes *leaving* the device are
valid and plain HTTP/random binary are byte-perfect (100+/100), so the
mishandling is **downstream on the cellular path and specific to the large
two-segment handshake packet** — not byte corruption, not the driver.

**Reverse-tether A/B (2026-06-12).** Same phone, same TLS
stack, same target (`104.16.133.229`, SNI `cloudflare.com`), same 50×
loop — only the egress path differs:

| egress path | result |
|---|---|
| reverse USB-tether → host's home internet (**bypasses modem+cellular**) | **50/50 OK, 0 fail** |
| cellular (`qmapmux0.0`) | 47/50 OK, **3 fail** (`record layer failure`) |

Identical device + TLS, perfect off-cellular vs ~6 % broken on cellular →
the ClientHello rewrite is **definitively in the cellular data path
(modem firmware or Vodafone), not the device/driver.** (The USB path
bypasses *both* modem and carrier, so it confirms "cellular path" but does
not by itself separate modem from carrier — that still needs a stock-ROM /
other-phone test on the same SIM.)

**Impact: low.** Established connections, throughput (20 Mbps), data
integrity, and all non-TLS traffic are unaffected; only ~6-15 % of *new*
TLS handshakes fail and almost everything retries (→ ~99 % effective).

**Remaining open (low priority): modem vs carrier.** Confirm on stock ROM
/ another phone on the same SIM+APN, or via a VPN (tunneling hides the
ClientHello — should be reliable). Workarounds if it ever matters: VPN,
different APN, or TLS ECH.

> **Retracted dead-end (kept as a warning):** an earlier pass concluded
> the UL path "strips `0x0D` (CR) bytes." That was a **measurement
> artifact of `tcpbin.com`**, which is a *line-oriented* echo service that
> normalizes/strips CR itself — verified by running the same CR echo from
> a wired host (CR also stripped there, off-cellular). **Do not use
> `tcpbin.com` for binary integrity tests.** Use httpbin's base64
> reflection (`http://httpbin.org/post`, field `data` =
> `data:…;base64,…`) instead. The `NETIF_F_IP_CSUM` theory (Section C.1)
> was likewise disproven.

**Still-open leads (byte-clean ⇒ TLS-path-specific):**
- **Port-443-specific middlebox?** Compare handshake failure rate on
  `:443` vs an alternate TLS port (`cloudflare.com:2053` / `:8443`). If
  alt ports are reliable and `:443` is not → a 443-only middlebox
  (carrier DPI / "optimizer"). If all ports fail equally → packet-pattern
  / handshake-timing issue independent of port.
- **Handshake packet pattern.** Both directions clean for bulk; only the
  sparse request/response burst of a handshake fails — points at
  timing/pattern handling somewhere in IPA/modem, not data integrity.
- Disambiguate device-vs-carrier by repeating on the **stock/vendor ROM**
  or another phone on the same SIM/APN.

**Binary-clean UL reproducer (no tcpbin):**
```sh
python3 - <<'EOF'
import urllib.request,os,json,base64,hashlib
d=os.urandom(40000)
r=urllib.request.urlopen(urllib.request.Request("http://httpbin.org/post",
    data=d,headers={"Content-Type":"application/octet-stream"}),timeout=25)
g=base64.b64decode(json.loads(r.read())["data"].split(",",1)[1])
print("UL clean:", hashlib.md5(g).hexdigest()==hashlib.md5(d).hexdigest())
EOF
```

### Symmetric QMAPv3 UL is not fully working

Vendor Android negotiates `ul_proto=7` (QMAPv3 UL). We can do the
same with `vendor-init --full-ul` plus the kernel knob
`qmapv3_ul_enable=1`, and the WDA negotiation succeeds. But UL data
traffic gets 100 % packet loss after that. The path that bites us:

- mainline rmnet emits a 4-byte UL csum header before the IP packet
- IPA EGRESS pipe 4 with `hdr_len=8 + cs_offload_en=UL +
  cs_metadata_hdr_offset=1` (matching vendor) appears to expect a
  byte layout the mainline rmnet doesn't produce exactly the same
  way
- Net result: modem rejects all UL frames silently

We narrowed this down to *one* necessary precondition (NETIF\_F\_IP\_CSUM
default-enabled, see Section C above) but it isn't sufficient. The
remaining gap is probably in the relationship between mainline rmnet's
`rmnet_map_ul_csum_header` layout and what IPA HW expects from
`cs_metadata_hdr_offset` units. Vendor `netmgrd` may also do some
additional per-mux UL config we haven't reproduced.

Production recommendation: **asymmetric** (DL=7, UL=5). DL gets full
20.5 Mbps. UL stays at QMAPv1, which aggregates to ~4 Mbps across
multiple TCP flows — plenty for normal cellular use.

The kernel and `vendor-init` opt-in machinery is in place if anyone
wants to dig further.

**Refuted hypothesis — it is *not* a BAM 4-byte DMA-padding problem.**
A tempting theory is that the QMAPv3 csum header makes `skb->len`
non-divisible-by-4, so the BAM TX engine sends a truncated burst the
modem can't decode. The code refutes this two ways: (1) mainline QMAP
pads *every* frame to a 4-byte boundary regardless of version —
`rmnet_map_data.c` does `padding = ALIGN(map_datalen, 4) - map_datalen`
and records the count in `map_header->flags` — and the UL csum header is
a fixed 4 bytes (`skb_push(sizeof(struct rmnet_map_ul_csum_header))`),
so the frame tail stays 4-aligned in both v1 and v3; (2) the IPA TX path
(`ipa_dp.c` → `sps_transfer_one()`) passes the length as-is, with no
`% 4` / burst-length check anywhere. The clincher: **QMAPv1 (working)
goes through the *same* `ALIGN(…,4)` padding path as v3**, so alignment
cannot be what distinguishes them. The real gap is the csum-header byte
layout vs. `cs_metadata_hdr_offset` semantics — the modem rejects an
*under-headered* frame, it is not decoding a *truncated* one. Don't
re-chase the padding angle.

### UL throughput depends on parallelism

Single-flow UL caps at ~150 KB/s, but 4 parallel streams aggregate to
~4 Mbps. This is consistent with server-side or per-flow Vodafone
shaping — cloud-sync apps (Google Photos, Nextcloud, Syncthing) use
multiple parallel streams and reach the aggregate rate. Single
`curl` / `scp` will feel slow on UL.

We have not benchmarked UL on Android Lineage 22 on the same SIM as
a ground-truth comparison. If vendor noticeably exceeds 4 Mbps
aggregate, the symmetric QMAPv3 work above becomes worth picking up.

### TX-stall recovery is incomplete (the watchdog is inert)

The UL datapath has no working recovery from a TX queue stall, so a lost
BAM EOT interrupt or a hung modem can freeze uplink **permanently** until
SSR or a reboot. The mechanics:

- The WAN netdev (`rmnet_ipa0`) *does* register a watchdog —
  `.ndo_tx_timeout = ipa_wwan_tx_timeout` with `watchdog_timeo = 1000`
  (`rmnet_ipa.c`) — **but the handler is a no-op**: it only logs
  `"data stall in UL"` and returns. It never wakes the queue, resets the
  outstanding counter, or kicks SPS. The watchdog *detects* a stall but
  does not *recover* from it.
- The rmnet VND netdevs (`qmapmux0.0`) have **no watchdog at all** —
  `rmnet_vnd_ops` sets no `.ndo_tx_timeout` and `watchdog_timeo = 0`.
- Queue wake depends **solely** on the TX-complete callback
  (`apps_ipa_tx_complete_notify`): `netif_wake_queue()` fires only when
  `outstanding_pkts` drops below the low watermark. If that callback
  stops arriving (lost EOT, modem hang, stuck SPS), the queue —
  `netif_stop_queue()`'d at the high watermark — never reopens.

In practice this is rare (the modem/SPS path is mechanically stable —
see the 0% ping loss and sustained throughput measurements), which is
why it has not bitten production. But it is a real robustness gap.

Note this caveat describes the **default pipeline output** — the base
port (what `apply-all.sh` produces) still ships the inert handler above.

**A recovery implementation now exists as an opt-in patch:**
`patches/ipa-tx-stall-recovery.patch` (design rationale in
`patches/ipa-tx-stall-recovery.DESIGN.md`). It is *not* in the default
pipeline — apply it deliberately. The naive fix (just calling
`netif_wake_queue()`) is wrong: blindly waking without reconciling
`outstanding_pkts` against the real BAM ring state risks descriptor
leaks / double-frees. Instead the patch re-runs the completion *harvest*
(`ipa2_tx_dp_kick_stalled_pipe()` re-arms the SPS poll the lost EOT
would have triggered), which is XPU-safe (it touches only the AP's own
BAM FIFO) and self-degrading (a genuine modem hang simply finds nothing
to harvest). It keeps the `is_ssr` guard so it stands down during an
SSR. **Status: written and patch-verified, not yet hardware-tested** —
a `tx_stall_kick` debug knob (`ipa-tx-stall-recovery-debugknob.patch`)
is provided to exercise the kick path on-device before trusting it.

### Service-startup timing

`vendor-init` opens raw QRTR sockets and discovers service ports
dynamically. The modem reassigns QRTR port numbers across boots —
this is normal QRTR behavior, the tool re-discovers them every run.

If the modem hasn't finished booting when you run `vendor-init`, the
NAS service lookup may fail. Wait until `qmicli -d qrtr://0
--nas-get-serving-system` reports `registered` + `Radio interfaces:
'lte'` before running.

### Out-of-tree kernel

The IPA v2.6L driver port is out-of-tree and not upstream-ready.
Upstreaming it would need significant cleanup. The rmnet feature
change (Section C) is a small standalone candidate.

#### Upstreaming roadmap: runtime PM conversion

The single biggest idiomatic gap for mainline review is power
management. The driver does NOT leak power at idle — the vendor
active-clients machinery is a complete hand-rolled runtime-PM
equivalent (refcount in `ipa2_inc_client_enable_clks()` /
`ipa2_dec_client_disable_clks()`; at count 0 the clocks are gated off
via `ipa_disable_clks()` after a TAG flush, and atomic contexts use
`ipa2_inc_client_enable_clks_no_block()` + workqueue deferral). But
mainline wants this expressed through the `pm_runtime` framework, and
a converter should know:

1. **Chokepoints, not call sites.** All ~166 `IPA_ACTIVE_CLIENTS_*`
   uses funnel into three functions in `ipa.c`. The conversion lands
   there: `runtime_resume` ≈ `ipa_enable_clks()`, `runtime_suspend` ≈
   `ipa_disable_clks()` (+ the TAG-flush as a `runtime_idle`/drain
   step), sync paths become `pm_runtime_get_sync()` /
   `pm_runtime_put_autosuspend()`.
2. **The resume path sleeps** (`clk_prepare_enable`, interconnect
   votes), so `pm_runtime_irq_safe()` is not an option. The atomic
   TX/RX paths must keep the existing pattern — `pm_runtime_get()`
   (async) plus the already-present workqueue deferral — which is
   exactly what `..._no_block()` implements today.
3. **Autosuspend delay** replaces the manual delayed-release dance in
   the SPS PM code (`ipa_sps_process_irq_schedule_rel`).
4. Net power gain on v2.6L: **zero** (gating behavior is identical);
   the gain is framework integration and review-ability. Do it with a
   device in the loop — this path is hot and the 20.6 Mbps figure is
   easy to regress.

The actual battery lever that exists today is the optional power-save
patch (SVS at idle-ish, see *Power-save: dynamic IPA clock scaling*),
which is orthogonal to the framework question.

#### Upstreaming roadmap: vendor-cruft inventory

Measured against the usual vendor-code stereotypes, this CAF source is
cleaner than its reputation — but a checkpatch sweep of the whole
driver (58 files) gives the concrete TODO list:

- **`typedef struct` / custom alloc wrappers: zero.** The classic
  `ipa_config_t` / `IPA_MEM_ALLOC()`-style offenses do not exist in
  this codebase; structs are plain-tagged and allocations are direct
  `kzalloc`/`kcalloc` calls.
- **47 CamelCase `struct IpaHw*_t` tags** — the uC (microcontroller)
  firmware ABI definitions. They mirror Qualcomm's firmware interface
  documentation; upstream will want them renamed to kernel style,
  which is mechanical but must keep the layouts byte-identical.
- **checkpatch totals: 2 ERRORs, ~120 WARNINGs** — dominated by
  `BLOCK_COMMENT_STYLE` (47) and `AVOID_EXTERNS` in .c files (44),
  i.e. cosmetic vendor formatting. (The findings that were in *our*
  port-added code — a `strncpy`, an `else`-after-brace, two bare
  `unsigned` — are already fixed.)
- **`devm_*` conversion:** probe-path allocations are raw (`ipa.c`
  alone has ~25 `k*alloc` calls, zero `devm_`). Converting the probe
  path to managed allocations would simplify the error/teardown
  paths, but every site needs an audit against the existing manual
  frees — do it together with the runtime-PM conversion, with a
  device in the loop.
- One deprecated-API note: `idr_init` → `xa_init` (vendor NAT code).

#### Upstreaming roadmap: SPS/BAM notes

Audit results for the DMA/IRQ/teardown layer (the usual vendor-port
trouble spots):

- **Descriptor rings are dma-mapping clean** on the cellular path:
  `ipa2_setup_sys_pipe()` allocates every descriptor FIFO with
  `dma_alloc_coherent()` and handles the SMMU iova→phys split. The
  vendor's custom `ipa_pipe_mem_alloc()` allocator exists in tree but
  is dead on this target — no `qcom,ipa-pipe-mem` DT region, and its
  only caller is the low-level `ipa2_connect()` used by the disabled
  USB/WDI/teth clients.
- **Latent bug for non-bypass SMMU configs:** the desc-FIFO free
  paths pass `connect.desc.phys_base` to `dma_free_coherent()`. Under
  S1 bypass (X00TD) phys == dma handle, so it is correct here — but
  with S1 translation enabled `phys_base` is the *translated*
  address, not the dma handle, and the free would corrupt. Fix before
  running any non-bypass platform.
- **IRQ architecture:** both the IPA and BAM ISRs are plain hardirq
  handlers registered with `IRQF_TRIGGER_RISING` *in code*, while the
  DT (per the bringup finding) declares both interrupts LEVEL_HIGH —
  in-code trigger flags override DT, which deserves a clean
  resolution (pass 0 and let DT govern) **with a device in the loop**,
  since the current combination is what was validated. The handlers
  themselves are short — the heavy lifting is deferred to NAPI /
  workqueues, so threaded-IRQ conversion is an idiom step, not a
  latency fix (WAN RX is NAPI-polled anyway because of the ~1 Hz EOT
  quirk).
- **Pipe teardown:** modem SSR runs `ipa_q6_pre_shutdown_cleanup()`
  (Q6 pipe + table cleanup) and survived a real modem crash once
  (validated single-restart; repeated-crash behavior is a known
  caveat). A ModemManager restart does not touch the pipes at all
  (QMI-level only). **Module unload (`rmmod`) cleanup is untested**
  — stale BAM descriptors on re-insert are exactly the classic
  failure mode to test for there.

---

## Debug instrumentation (sondy)

The bringup was carried by ~130 in-tree probes (called "sondy" — Czech
for *probes*). The production tree ships **clean** — all of them now
live in the opt-in script **`port/90-apply-diag-sondy.sh`**, curated
for one purpose: porting this driver to *other* SDM6xx devices. Apply
it on top of the full pipeline; never ship a production build with it
(the per-packet probes collapse throughput and even the rare-event ones
spam dmesg).

The probes are organised into **three tiers**, gated differently
because their overhead differs by orders of magnitude.

### Tier 1 — `IPA_SONDA()` macro (ftrace sink, default ON)

Installed into `ipa_i.h`:

```c
extern int ipa_rev_eng_active;     /* module param, default 1 */

#define IPA_SONDA(fmt, ...) \
	do { \
		if (ipa_rev_eng_active) \
			trace_printk("[IPA_SONDA] %s: " fmt, \
				     __func__, ##__VA_ARGS__); \
	} while (0)
```

- Sink: **ftrace ring buffer**, not dmesg. Cheap; no console
  serialization.
- For low-volume semantic events — sprinkle your own calls while
  bringing up a new device.
- Toggle live: `/sys/module/<ipa module>/parameters/ipa_rev_eng_active`.

Reading them:

```bash
sudo cat /sys/kernel/debug/tracing/trace_pipe | grep IPA_SONDA
```

### Tier 2 — `IPA_SONDA_DBG()` / `ipa_sonda_dbg` param (dmesg, default OFF)

For per-packet hot-path probes (the script gates `[WAN_RX_IOV]` and
`[IRQ_STTS_DIAG]` on it). Throughput collapses from 20 Mbps to
single-digit Mbps when on, so only enable for short windows:

```bash
echo 1 | sudo tee /sys/module/<ipa module>/parameters/ipa_sonda_dbg
```

### Tier 3 — always-on tagged one-shots (rate-bounded)

The bulk of the script: `pr_err`/`pr_info` probes on rare paths that
fire at most a handful of times per attach. Families installed:

| Tags | What they show |
|---|---|
| `[QMI_DIAG]` `[AP_READY]` `[INIT_DRV_DIAG]` `[GOLDEN_DATA]` | the whole QMI handshake: service discovery, INIT_DRIVER memory map, INIT_COMPLETE_IND paths, TLV 0x12 echo |
| `[QMI_FILTER_DIAG]` `[INSTALL_WIRE]` `[FLT_INSTALL]` `[GOLDEN_FLT]` `[GOLDEN_RT]` `[DUMP_RT_*]` | what really lands in the IPA HW filter/routing tables, wire-level |
| `[SETUP_PIPE_DIAG]` `[INGRESS_DIAG]` `[NUM_Q6_DIAG]` `[EMB_PIPE_DIAG]` `[TX_EXCP]` `[EMPTY_RT_DIAG]` `[NO_AGG]` | pipe setup and datapath decisions |
| `[AUTO_IPACM]` `[ICMP_RULE]` `[MCAST_BCAST]` `[WAN_DL_QMI]` `[WAN_DL_NOTIF]` | step-by-step progress of the in-kernel IPACM emulation |
| `[IRQ_STTS_DIAG]` `[BAM_DIAG]` | raw HW state — the BAM_DIAG wake-test answers "is the BAM clocked/powered at all?" on a new board |

Not carried over (originals preserved in the project's history
archive): the per-packet SPS/NAPI/RX-sequence sondas tied to a
pre-cleanup tree state — rewrite those via `IPA_SONDA_DBG()` as needed
— and the init-time SRAM zero-table hexdumps (the commit-time
`[DUMP_RT_*]` probes answer the same question with live content).

---

## What's NOT ported (and how we work without it)

This port is deliberately the minimum-viable IPA stack for a single
cellular bearer. Several major vendor components are intentionally
left out — each accompanied by what replaces them or why their
absence is OK.

### 1. `ipa_v3/` driver (30 C files)

Vendor ships a parallel IPA v3 driver for newer chips (SDM845+).
SDM660/636 only have IPA v2.6L, so this is genuinely out of scope —
no replacement needed. The compile dispatch layer `ipa_api.c` /
`ipa_common_i.h` that picks between v2 and v3 is also dropped; we
build `ipa_v2` directly.

### 2. `ipa_clients/` offload paths (9 C files)

Vendor offers a family of "client" drivers that plug various
non-cellular flows into the IPA HW accelerator:

| File | What it does | Replacement |
|---|---|---|
| `ecm_ipa.c`, `rndis_ipa.c` | USB Ethernet (CDC-ECM, RNDIS) offload to IPA | Not used — phone is not a USB Ethernet gadget |
| `odu_bridge.c` | Open Data Unit bridge (tethering data plane) | Not used — no tethering in our target use case |
| `ipa_gsb.c` | Generic Software Bridge for cross-IPA-pipe forwarding | Not used |
| `ipa_mhi_client.c` | Modem-Host Interface (MHI) integration | Not used — MHI is for PCIe-attached modems; ours is QRTR-attached |
| `ipa_uc_offload.c` | uC microcode client API | Stubbed (`ipa_disabled_stubs.c`) |
| `ipa_usb.c` | USB framework hook into IPA | Not used |
| `ipa_wdi3.c`, `ipa_wigig.c` | WLAN offload (WDI 3.0, WiGig) | Stubbed — WLAN doesn't traverse IPA on our config |

The external API surface every other subsystem might call into
these from is satisfied by `ipa_v2/ipa_disabled_stubs.c`, which
returns `-ENOTSUPP` or no-ops as appropriate. The build still links
clean and the rest of the kernel can use IPA exports without
discovering missing symbols.

### 3. `ipa_rm.c` + 5 `ipa_rm_*` files (~3 200 LoC) — compiled and wired

> **Correction (power-save work, 2026-06).** An earlier revision of this
> note claimed the IPA Resource Manager was stubbed in
> `ipa_disabled_stubs.c`. That is **not** true. All five `ipa_rm*.o` are
> compiled into `ipa-driver.ko` (parent `Makefile`) and the graph is wired
> at runtime: `q6_initialize_rm()` creates `Q6_PROD`/`Q6_CONS` (perf
> profile 100 Mbps), `ipa_create_apps_resource()` creates `APPS_CONS`, and
> the rmnet TX path requests `WWAN_0_PROD` via the inactivity timer.
> `ipa_rm.c` aggregates the per-resource perf profiles and calls
> `ipa2_set_required_perf_profile()`. `ipa_disabled_stubs.c` stubs only the
> offload engines (WDI / NTN / MHI / teth-bridge) — no `ipa_rm_*` symbols.

Vendor's **IPA Resource Manager** tracks producer/consumer dependencies
between IPA endpoints and arbitrates power/clock state across them. In this
port it is functional but was **clock-inert**: the base port set
`enable_clock_scaling = 0`, so `ipa2_set_required_perf_profile()` always
returned NOMINAL (150 MHz) and the RM bandwidth votes never moved the core
clock. (The SDM660 v2.6L modem manages its own side of the link, so
*modem-facing* RM enforcement is irrelevant — but the *AP-side* RM votes
that scale the local IPA core clock are real.)

`patches/sdm660-ipa-port-6.19-powersave.patch` re-couples the RM graph to
the core clock with a single change — `enable_clock_scaling = 1`. The
vendor thresholds (nominal 600 / turbo 1000 Mbps) are kept, so the static
cellular vote (hardware-measured at an aggregate [150, 250) Mbps — the
per-resource 100 Mbps profiles sum across the active producers/consumers)
never reaches them and active data rides SVS (75 MHz), which measurement
proved sustains the full link. See **Power-save: dynamic IPA clock
scaling** below.

If you later need WLAN/USB offload through IPA, the dependency-graph
traversal in `ipa_rm_dependency_graph.c` and the reference-counted resource
machinery in `ipa_rm_resource.c` are already in tree to build on.

### 4. NAT userspace management

Vendor relies on the IPACM daemon to refresh modem-side HW NAT cache
entries via QMI (`IPACM_ConntrackClient::UpdateUDPTimeStamp`,
~every 20 s). Without it, idle UDP flows age out of the modem's NAT
cache and the first packets on a new flow get exception-looped to
the AP — visible as bursty connection setup latency.

Mainline workarounds:
- `qmapv3_ul_enable=0` (default) — uses IPA HW exception loopback
  for cache miss; first few packets slow, rest fine
- Userspace ping keepalive every 5 s on the bearer (`ping -i 5
  $gateway &`) keeps the cache warm

Neither is as nice as the vendor refresh; both are good enough for
production traffic.

### 5. WAN tethering bridge / SSR cleanup paths

`teth_bridge.c` is ported but never exercised — tethering is out of
scope. Its `connect` path is a stub and full USB tethering *hardware*
offload is not portable as a quick win — see the feasibility breakdown
under "USB tethering hardware offload" in the IPACM section. SSR
(Subsystem Restart) handling is wired through
`qcom,rmnet-ipa-ssr` but the recovery paths assume single-modem-
restart and may need work for repeated crashes; we hit this once in
session 29 (see project history).

### 6. ipa_v2 selftests (`drivers/platform/msm/ipa/test/`)

Vendor self-tests are not ported. They depend on the userspace
ioctl tool tree and would need their own porting effort. Not
required for production.

---

## IPACM — what it is, what we use instead

IPACM ("IPA Config Manager") is a userspace C++ daemon
(~25 k LoC, source in `data-ipa-cfg-mgr/`) that complements the
vendor kernel driver. Its responsibilities, roughly (file references
verified against the source now in `data-ipa-cfg-mgr/ipacm/`):

1. Install **filter rules** (`IPA_IOC_ADD_FLT_RULE` via
   `IPACM_Filtering.cpp`) per interface (WAN, embedded, LAN) to steer
   packets between modem, AP, and any WLAN/USB clients
2. Subscribe to **conntrack** netlink and run `UpdateUDPTimeStamp`
   (`IPACM_ConntrackClient.cpp` / `IPACM_Conntrack_NATApp.cpp`) to keep
   modem-side HW NAT cache entries fresh
3. Listen to **`RTM_NEWLINK`/`NEWADDR`/`NEWROUTE`** (`IPACM_Netlink.cpp`)
   and dynamically install/remove rules as interfaces come up
4. Run **routing-table** install/sync into IPA HW (`IPACM_Routing.cpp`,
   `IPACM_Wan.cpp` `query_ext_prop()` + default-route rules)
5. Manage **WLAN/tethering offload** (`IPACM_OffloadManager.cpp`,
   `IPACM_Wlan.cpp`, `IPACM_LanToLan.cpp`)

What IPACM does **not** do — verified, zero hits across the whole tree:
it does **not** issue the datapath-bringup ioctls
(`RMNET_IOCTL_SET_*_DATA_FORMAT`, `ADD_MUX_CHANNEL`). Those are
**netmgrd's** job on stock Android; IPACM only starts reacting *after*
the `rmnet_data*` interfaces already exist. So the in-kernel auto-init
hook below actually stands in for **two** userspace daemons — netmgrd
(the datapath/mux ioctls) and a thin slice of IPACM (the one WAN
route/filter shape) — not IPACM alone.

Why we don't need either on our target:

| Userspace responsibility (daemon) | Why we get away without it |
|---|---|
| Datapath setup (**netmgrd**) | Three ioctls — `SET_EGRESS=0x06`, `SET_INGRESS=0x3e`, `ADD_MUX mux=1` — done **once** by the in-kernel **`vendor_auto_ipacm_init_fn()`** hook in `rmnet_ipa.c`, fired automatically off `ipa_q6_handshake_complete()` with a 3 s delay. After that, the datapath stays up indefinitely. |
| Filter rules (**IPACM**) | v2.6L modem installs its own filter rules via the `qcom,modem-cfg-emb-pipe-flt` DT property — AP-side filter install is a no-op. |
| NAT timestamp refresh (**IPACM**) | Userspace `ping -i 5 $gw` keepalive as documented above. Not pretty but functional. |
| Netlink-driven dynamic rules (**IPACM**) | Single static bearer; no dynamic events to react to. |
| Route install/sync (**IPACM**) | We program one default route via `ip route add`; the modem already owns the one WAN route table. |
| WLAN/tethering offload (**IPACM**) | Not in scope. |

The components — kernel driver, `vendor-init`, in-kernel
**auto-IPACM** init — together cover what a `netmgrd + IPA driver +
qcrild (RIL) + IPACM` stack covers on stock Android (Android has no
ModemManager; `vendor-init` is what stands in for it on our pmOS
side), but with one bearer instead of many and no offload paths.

### Hardwired assumptions (single-bearer by design)

The emulation bakes in the single-primary-bearer shape end to end:
the ADD_MUX step registers exactly one channel with `mux_id = 1`
(`qmapmux0.0`), and the DL-acceleration QMI specs carry `mux_id = 1`
with `rt_tbl_idx = 8` (= `ipa_dflt_wan_rt`) — the per-interface
`ext_props` query refines those two when the interface is registered,
but there is still only *one* of everything. `vendor-init` matches:
one WDS bind, one bearer, one rmnet child.

This is the right trade-off for primary cellular data, and it is
also the hard boundary: **VoLTE (IMS bearer), MMS, or any
multi-PDN setup will not work by tweaking constants** — they need
multiple mux channels, per-bearer filter/route policy, dedicated
QoS bearers (for IMS), and a second WDS session in userspace. That
is IPACM's actual job.

The single-bearer constants are **hardcoded literals**, not just
defaults: `mux_id = 1` appears in `ADD_MUX_CHANNEL` and in all six QMI
filter specs, `rt_tbl_idx = 8` (`ipa_dflt_wan_rt`) in seven code
locations, the aggregation limits (`6`/`10`/`1`) and
`vchannel_name = "qmapmux0.0"` likewise — all in `rmnet_ipa.c`'s
`vendor_auto_ipacm_init_fn()`. There is **no runtime tuning surface**
for them (only the `qmapv3_ul_enable` module param exists; debugfs is
read-only).

**Future work — a sysfs/debugfs knob for `mux_id` / `rt_tbl_idx`** would
let the *single-bearer* shape be retargeted to another operator without
a recompile, building on the partial per-interface `ext_props` query
that already exists. Worth doing for portability — but be clear about
the scope: **this does *not* unlock multi-PDN / VoLTE.** A tunable
`mux_id` still describes *one* bearer; data+IMS needs *several* mux
channels, per-bearer policy, and a second userspace WDS session, as
above. The knob is operator-portability for the one-bearer case, nothing
more.

### When you would need the real IPACM

Reach for the full daemon if you need any of:

- Multiple simultaneous bearers (multi-PDN) with per-bearer
  filter/route policy — VoLTE/IMS and MMS land here
- WLAN AP offload (data through IPA HW instead of the CPU)
- USB tethering offload (see the feasibility breakdown below — the
  IPA half is reachable but the USB-BAM/DWC3-GSI half is absent in
  mainline; netfilter flowtable is the pragmatic alternative)
- Carrier-grade NAT timeout precision
- iOS-style "low data mode" / per-app firewalling via IPA rules

For the PostmarketOS X00TD primary-cellular target, none of those
apply — the auto-IPACM hook is sufficient.

### Bootstrap order

```
power-on
  └─ kernel init
       └─ ipa_v2 probe (DT "qcom,ipa")
            └─ QMI handshake completes (modem booted)
                 └─ ipa_q6_handshake_complete() fires
                      └─ schedule_delayed_work(3s, auto_ipacm_init)
                           └─ 3 ioctls → datapath ready
                                └─ MM detects modem, registers
                                     └─ vendor-init activates bearer
                                          └─ ip addr + route → done
```

`vendor-init` and the auto-IPACM hook are independent: auto-IPACM
runs whether or not `vendor-init` exists; `vendor-init` works whether
or not auto-IPACM ran (it would just fail on first packet). They
compose into the working stack.

### USB tethering hardware offload — feasibility ("the Holy Grail")

The dream: USB tethering where traffic between the gadget `usb0`
(ConfigFS/RNDIS) and the modem netdev (`qmapmux0.0`) flows
**BAM-to-BAM through IPA, bypassing the CPU** — the SoC sets up the
first packet and then the IP Accelerator DMAs the flow modem↔USB on
its own. On today's mainline port that traffic instead goes the normal
Linux way: `usb0 → netfilter forward + conntrack → qmapmux0.0`, every
packet through the CPU. At higher download rates the CPU spins, heats,
and throttles.

**This was assessed against the actual tree and is not portable as a
quick win.** The tempting approach — a `register_netdevice_notifier`
hook that spots `usb0` and fills in the `teth_bridge.c` connect stub —
**sits on the wrong layer and cannot deliver hardware offload.** A
netdev notifier reports an L3 event ("`usb0` came up"); it gives you no
handle on the USB endpoint or its DMA. The standard ConfigFS RNDIS
datapath is `u_ether`'s USB-request queue, where **the CPU copies skbs
to/from the USB endpoint** (`eth_start_xmit` / `rx_complete`). The
downstream `rndis_ipa.c` / `ipa_usb` glue is **not** vendor cruft to be
discarded — replacing that datapath so the USB endpoint feeds IPA pipes
instead of the CPU **is the offload mechanism itself**. Without it the
endpoint is still serviced by the CPU; a notifier could at most drive a
*software* bridge, which is what we already have.

What real BAM-to-BAM offload requires, and what this tree has:

| Piece | Role | State in tree |
|---|---|---|
| **A. USB datapath on IPA pipes** | a gadget function that owns the USB endpoints and hands them to IPA (`rndis_ipa`/`ipa_usb`) | **absent** — zero hits for `rndis_ipa`/`ecm_ipa`/`ipa_usb` |
| **B. USB-BAM bridge** | bridges the USB controller's endpoints to the IPA BAM (`usb_bam.c`, `qcom,usb-bam`) | **absent** — the only `bam_dmux` present (`drivers/net/wwan/qcom_bam_dmux.c`) is the *modem* control channel, not USB |
| **C. DWC3 GSI/BAM endpoints** | SDM660 USB is DWC3; an endpoint must run in BAM/GSI mode to attach to a BAM | **absent** — mainline DWC3 here has no GSI/BAM endpoint support |
| **D. IPA HW routing/NAT/filter rules** | so IPA forwards USB↔Q6 in HW, someone must install routing/NAT/filter rules into the IPA tables | **absent** — this is IPACM's job (no daemon on pmOS); no in-kernel flow-offload-into-IPA path |
| E. teth_bridge RM deps | clock/voltage dependencies `USB_PROD↔Q6_CONS` / `Q6_PROD↔USB_CONS` | ✅ real (`ipa2_teth_bridge_init()`) |
| F. `ipa2_teth_bridge_connect()` | wire the pipe handles | **stub** (`return 0`) — but small *once A–D exist* |

The IPA half is genuinely reachable from the kernel —
`ipa2_connect(IPA_CLIENT_USB_PROD/CONS)` (`ipa_v2/ipa_client.c`) is real
and returns the SPS params for a BAM-to-BAM `sps_connect()`. **The
blocker is the USB half (B+C):** on SDM660 the USB controller is DWC3,
and for DMA to flow "straight into the modem's pipes outside the CPU"
the DWC3 endpoint must run in BAM/GSI mode and be bridged via `usb_bam`
to the IPA BAM. Neither exists in mainline — DWC3 here only does
ordinary CPU-serviced transfer requests. Bringing up the real path
means porting `dwc3-msm` GSI support + `usb_bam` + `rndis_ipa` + an
IPACM-equivalent rule installer: thousands of lines of downstream
infrastructure, not "fill one stub." **Out of scope; logged here as
long-term research so the notifier dead-end isn't re-attempted.**

**The pragmatic 80%-win alternative: netfilter flowtable.** The
mainline source for it (`nf_flow_table_*`, `nft_flow_offload`) is
in-tree, but the X00TD defconfig ships it **disabled**
(`# CONFIG_NF_FLOW_TABLE is not set`, and `CONFIG_NFT_FLOW_OFFLOAD`
likewise unset) — enabling it is a two-line defconfig change plus a
kernel rebuild/reflash, but **no new code**. The flowtable is a
mainline software (optionally HW) fast-path: after the first packet of a
conntrack-ESTABLISHED flow, subsequent packets take a **softirq
shortcut** that skips the full iptables/nftables traversal and the heavy
conntrack lookup — exactly the "CPU sets up the first packet then mostly
forgets the flow" shape, in software. It is not zero-CPU like
BAM-to-BAM, but it cuts the per-packet cost by an order of magnitude
(and thus the throttling/heat). It is a few lines of nftables
(`flowtable f { hook ingress … devices = { usb0, qmapmux0.0 } }` plus a
`flow add @f` rule) — no new kernel code and no IPA-driver rebuild
(only the two flowtable configs enabled). **Measure first:**
on the ~20 Mbps link this port reaches, plain CPU forwarding may not
heat the CPU at all, in which case the whole offload solves a
non-problem. Reach for the flowtable only if `top`/`/proc/interrupts`
under a real tethering load shows the CPU actually saturating; reach for
true IPA BAM-to-BAM only if the target is 100+ Mbps tethering, which is
above this link's ceiling.

Unlike the BAM-to-BAM path, this option *is* actionable today: it needs
**no new kernel code** — just the two flowtable Kconfig symbols enabled
in the defconfig and a rebuild/reflash, then the nftables ruleset. The
concrete next step is a short
nftables flowtable ruleset bridging `usb0 ↔ qmapmux0.0` plus an
on-device A/B of CPU load (`top` / `/proc/interrupts` / thermal zone)
during a real tethering pull, with and without the flowtable, to confirm
the per-packet saving is real before committing it. That measurement,
not more analysis, is what decides whether USB tethering needs any
offload at all on this port.

---

## Running under ModemManager (alternative path, partly untested)

The default activation path documented above lets `vendor-init`
own the bearer and bypasses ModemManager entirely. There is an
alternative path where ModemManager itself drives the bearer
activation — useful if you want NetworkManager / `mmcli` / a GUI
network applet to manage the connection like on any other distro.

For this path to work the kernel driver had to make three
concessions to MM (already in our tree), and one userspace step
needs adding by the operator. The latter is currently untested.

### Driver concessions to MM detection

These were the result of a 150 h debugging arc; the full cascade is
documented in the comments around the `rmnet_ipa_driver` definition
in `rmnet_ipa.c` (installed by `20-apply-port-fixes.sh`, section
"ModemManager integration"). What ships in the port:

1. **`platform_driver.name = "ipa"`** (rmnet_ipa_driver)

   MM 1.20+ `mm-port-qmi.c` whitelists exact net-driver names —
   `"ipa"`, `"bam-dmux"`, `"qmi_wwan"`. With our original
   `name="rmnet_ipa"` MM rejected the device with:
   ```
   Unsupported QMI kernel driver for 'net/rmnet_ipa0': rmnet_ipa
   ```
   We renamed it to `"ipa"`. The main IPA core driver in `ipa.c` was
   simultaneously renamed `"ipa-core"` to avoid the duplicate-name
   conflict at `platform_driver_register()` (the platform bus
   rejects two drivers with the same name).

2. **Sysfs attribute group "modem/" with `tx_endpoint_id` +
   `rx_endpoint_id` files**

   MM `mm-port-qmi.c:1671` `dpm_open_port()` reads
   ```
   /sys/class/net/rmnet_ipa0/device/modem/tx_endpoint_id
   /sys/class/net/rmnet_ipa0/device/modem/rx_endpoint_id
   ```
   Without these MM logs *"Unable to read TX and RX endpoint IDs
   from sysfs"*, skips DPM open, falls back to CTL, and the CTL
   path fails MUX_RMNET with the misleading
   *"Multiplexing required but not supported"*. The values are
   resolved at read time through `ipa2_get_ep_mapping()` (so they
   stay correct on SoCs with a different endpoint map), with the
   SDM636/660 v2.6L ids (`tx=4` APPS_LAN_WAN_PROD, `rx=5`
   APPS_WAN_CONS) as fallback. The `.dev_groups` member of the
   `rmnet_ipa` `platform_driver` wires the sysfs files in
   automatically — no manual sysfs registration needed.

3. **DT match table consolidated under the renamed driver**

   So that probe ordering and udev's parent-walk from the netdev
   land on the right driver name.

### Userspace step (operator-supplied, untested)

MM's `77-mm-qcom-soc.rules` udev rule matches `DRIVERS=="ipa"` by
walking the parent chain from `rmnet_ipa0`. In practice the parent
visible in sysfs is the `rmnet_ipa` platform device — udev sees the
*parent's* driver. A companion udev rule is required to tag the
device for MM's qcom-soc plugin. Drop something like the following
at `/etc/udev/rules.d/89-mm-rmnet-ipa.rules`:

```udev
# Tag rmnet_ipa-driven netdevs for ModemManager's qcom-soc plugin
SUBSYSTEM=="net", DRIVERS=="rmnet_ipa", ENV{ID_MM_PHYSDEV_UID}="qcom-soc"
```

Then `mmcli -L` should list the modem and bearer activation can
proceed via `mmcli -m 0 --simple-connect=apn=internet,ip-type=ipv4`.

### Rmnet checksum flags under MM (this is the untested bit)

The 20.5 Mbps DL throughput unlock depends on the rmnet
`INGRESS_MAP_CKSUMV4` flag (bit 0x04) being set on the
`rmnet_ipa0` port. With QMAPv3 DL each packet has an 8-byte trailer
that the rmnet upstream code only strips when this flag is on. In
the `vendor-init` path our `post_tune` stage sets this flag before
traffic flows (see `vendor-init/stage_post_tune.c`).

Under MM-driven activation MM creates `qmapmux0.0` itself with the
vendor-Android-style defaults — which **do not** set
`INGRESS_MAP_CKSUMV4`. Symptom: bearer reports up, `ip route` looks
fine, ping fails because the 8-byte trailer corrupts the IP header
and the network stack drops every DL packet.

Where this needs to land in MM-mode operation:

```bash
# After MM creates qmapmux0.0, before traffic flows:
ip link set qmapmux0.0 type rmnet mux_id 1 \
    ingress-deaggregation on ingress-mapv4-checksum on
```

Possible integration points (pick one):

- A NetworkManager dispatcher script in
  `/etc/NetworkManager/dispatcher.d/89-rmnet-cksum`
- A systemd unit triggered by `BindsTo=NetworkManager-dispatcher@…`
  or a `PathChanged=/sys/class/net/qmapmux0.0` path unit
- A udev `RUN+=` rule on the `qmapmux0.0` add event
- A small patch to MM's `mm-port-qmi.c` to set the flag itself
  after `dpm_open_port` succeeds

WDA QMAPv3 negotiation is a separate dependency on this path: MM
would have to issue (the equivalent of) `qmicli
--wda-set-data-format=ul-protocol=5,dl-protocol=7,...` before
establishing the bearer so the modem actually starts sending
QMAPv3 DL. Whether the libqmi / MM version on your PostmarketOS
release does that out of the box depends on the version — current
MM does call `WDA Set Data Format` but does not request QMAPv3
unless `dl-data-aggregation-protocol` is forced.

**Status of this path on our setup:** driver concessions 1–3 are
shipped and verified (MM does detect the modem and reach bearer
activation). The udev rule and the
rmnet checksum flag step are **not exercised in CI**; we use
`vendor-init` for the production bringup. If you take the MM path,
expect to debug.

---

## Other IPA driver attempts (research-grade, NOT finished)

This package ships only the `ipa_v2/` driver under
`drivers/platform/msm/ipa/`. Our broader working tree also explored a
mainline-style alternative IPA driver, `ipa2-lite`, under
`drivers/net/`. It is **deliberately not part of this package** — it
represents an exploration path that ran into a wall below the kernel
layer.

We mention it here only so anyone continuing this work knows it
exists as a starting point; do not enable it in production.

| Driver | Path | LoC | Kconfig | Status |
|---|---|---|---|---|
| `ipa2-lite` | `drivers/net/ipa2-lite/` | ~4 200 | `CONFIG_QCOM_IPA2_LITE` | Works on 2G EDGE, blocked below kernel layer on 4G LTE |

It and the shipped vendor driver share the same physical IPA MMIO
region, so their DTS nodes (`ipa@14780000` for the vendor port,
`ipa2-lite`'s own node) are mutually exclusive — only one can be
`okay` at a time. The DTS shipped in **this package carries only the
vendor port node**; the `ipa2-lite` node lives only in our working
tree.

### `ipa2-lite`

The earliest mainline-style attempt, derived from
[`msm8953-mainline`](https://gitlab.com/msm8953-mainline) via
Sireesh Kodali's 2021 RFC and Alejandro Tafalla's 2023 forward port.
On X00TD it brings the modem all the way to a working data-plane
on 2G EDGE — first-ever ICMP echo replies through cellular came via
this driver, see project history milestone "🎉 CELLULAR DL WORKS
via ipa2-lite". On 4G LTE the modem refuses to forward responses
to new connections; the bug is below the kernel scope (modem
firmware / carrier provisioning) and not fixable from the driver.

### When you'd care about it

Almost never, for now. The shipped `ipa_v2/` port produces 20.5 Mbps
end-to-end and is the production answer. `ipa2-lite` matters only as
a cross-reference: it is the smallest, easiest-to-read mainline-style
IPA v2 implementation, useful if you want to compare a
simpler-but-incomplete impl against the shipped vendor-derived
driver.

To get it on a fresh tree you also need to add its DTS node
(`status="okay"`) and flip the vendor node to `"disabled"` — they
share the IPA MMIO region, only one can probe at a time. None of this
is wired into this package; treat it as a parallel research branch
available in our working tree, not as a supported configuration.

---

## Reverse-engineering background

The byte sequences `vendor-init` sends to the modem were derived
from two complementary sources:

1. **Live capture** of QMI traffic on Asus Lineage 22 firmware via
   `LD_PRELOAD` hook of `qcrild`, `netmgrd`, `ipacm`. About 14 794
   QMI events captured across a real bearer activation. (The capture
   tooling lives in the project's working tree, not in this package.)

2. **Static analysis** of the pulled Lineage `/vendor/lib64/libril-qc-hal-qmi.so`
   (32 MB). The library is stripped but debug log strings are
   preserved, exposing the full vendor source tree structure
   (`vendor/qcom/proprietary/qcril-hal/...`) and function-by-function
   correspondence with our `vendor-init` stages. Confirmed vendor
   uses standard `nas_set_system_selection_preference_req_msg_v01`
   struct — the same one defined in `libqmi`'s public spec.

The conclusion is that `vendor-init` is byte-for-byte equivalent to
vendor `netmgrd` + `qcrild` for the bearer-activation stages we
reproduce. DL throughput parity follows from that. UL throughput
parity is the remaining open question (see Caveats).

---

## File layout

```
vendor-init/
├── Makefile
├── vendor-init.{c,h}                — main / stage dispatcher
├── qrtr.{c,h}                       — AF_QIPCRTR helpers
├── qmi.{c,h}                        — TLV encode/decode
├── log.{c,h}                        — structured logging
├── state.{c,h}                      — /run/vendor-init/ files
├── stage_dms_online.c               — modem ONLINE check
├── stage_nas_rat.c                  — RAT preference + register
├── stage_dpm_open.c                 — DPM_OPEN_PORT_REQ
├── stage_wda_set.c                  — WDA SET_DATA_FORMAT QMAPv3
├── stage_dsd.c                      — DSD lookup (no register)
├── stage_bind_mux.c                 — persistent WDS bind
├── stage_wds_start.c                — WDS_START_NETWORK + GET_SETTINGS
├── stage_fff2.c                     — proprietary bearer-pre-setup (unused in production)
├── stage_iattach.c                  — alternate iattach (unused in production)
└── stage_post_tune.c                — rmnet/MTU/sysctl/ethtool

vendor-baseline-4.19/                 — pristine vendor 4.19 sources
port/                                 — the port pipeline (scripts + files/)
patches/*powersave*                   — optional dynamic-clock-scaling extras

In the resulting kernel tree:
drivers/platform/msm/ipa/ipa_v2/      — IPA driver port (+ stubs/shims)
drivers/platform/msm/sps/             — BAM/SPS framework port
drivers/net/ethernet/qualcomm/rmnet/  — upstream rmnet + feature-flag edit
include/linux/{msm-bus,msm-bus-board,ipc_logging,msm_gsi,
                 ipa_wdi3,ipa_wigig,msm-sps,ipa,…}.h — shim/vendor headers
include/{net,soc/qcom,uapi/linux}/…   — stub + vendor UAPI headers
```

---

## Acknowledgments

- Sireesh Kodali (RFC 2021) and Alejandro Tafalla (msm8953 IPA) for
  the initial ipa-legacy mainline porting work that this builds on.
- aboothahir for the SDM660-6.7.y ipa branch that was the immediate
  starting point.
- libqmi project for the canonical QMI service spec (NAS, WDS, DMS,
  WDA, DPM) — `vendor-init` follows those byte layouts.
- ModemManager `mm-shared-qmi.c` as a clean reference for the NAS
  RAT preference setup.
- Qualcomm CodeAurora `qcril-hal` open-source pieces that complement
  the closed `libril-qc-hal-qmi.so`.
- Vodafone CZ for surviving the empirical testing without
  cancelling the SIM.

---

## License / contribution

Kernel sources, scripts and patches: GPL-2.0 (matching surrounding
files). `vendor-init`: GPL-2.0.

Feedback, patches, or independent testing on other SDM6xx devices
welcome. The IPA driver port has lots of cleanup left before
upstreaming becomes plausible; the rmnet IP\_CSUM feature-flag change
and `vendor-init` itself are in better shape to share.

---

## Appendix A — systemd unit (optional)

If you want `vendor-init` to run automatically and hold the bearer
in place of ModemManager:

```ini
# /etc/systemd/system/vendor-init.service
[Unit]
Description=Mainline cellular bringup (vendor-init)
Conflicts=ModemManager.service
After=qrtr.service
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/vendor-init -v
ExecStartPost=/bin/sh -c 'sleep 3 && \
    IP=$(cat /run/vendor-init/bearer_ipv4) && \
    GW=$(cat /run/vendor-init/bearer_gw) && \
    PFX=$(cat /run/vendor-init/bearer_prefix) && \
    ip addr flush dev qmapmux0.0 && \
    ip addr add ${IP}/${PFX} dev qmapmux0.0 && \
    ip route replace default via ${GW} dev qmapmux0.0'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Then `systemctl disable ModemManager && systemctl enable
vendor-init` to switch over at boot.

The unit deliberately runs after the kernel modules load — IPA
driver needs to be present before `vendor-init` looks for QRTR
ports.

---

## Appendix B — DNS

Set `/etc/resolv.conf` to either:

- The DNS servers the modem advertised (read from
  `vendor-init -v` log under `DNS primary` / `DNS second`), OR
- A public resolver (`1.1.1.1`, `8.8.8.8`, `9.9.9.9`).

`vendor-init` does not currently configure DNS automatically; this
is left to the operator because resolved/dhcpcd integration varies
by distribution.
