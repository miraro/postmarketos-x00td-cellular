# postmarketos-x00td-cellular

Working mainline-kernel cellular data on the Asus Zenfone Max Pro M1
(`asus-x00td`, Snapdragon 660 / SDM636) under PostmarketOS.

**Throughput result:** ~**20.5 Mbps DL** sustained over Vodafone CZ LTE.

This repo is the consolidated, community-ready output of ~156 hours of
porting / reverse-engineering work. It contains everything someone with
an X00TD should need to reproduce a working cellular bearer on a
mainline-ish kernel (6.19).

## Contents

```
.
├── POSTMARKETOS_X00TD_CELLULAR.md    ← the full writeup. START HERE.
├── patches/
│   └── sdm660-ipa-port-4.19-to-6.19.patch  ← 517 KB / 58 files
├── vendor-baseline-4.19/             ← Asus 4.19 baseline files the
│                                       patch is generated against.
│                                       Overlay onto your 6.19 tree
│                                       BEFORE applying the patch.
│                                       70 files / ~2.2 MB / GPL-2.0.
└── vendor-init/                       ← userspace bearer-activation tool
    ├── Makefile
    ├── vendor-init.{c,h}             — main / stage dispatcher
    ├── qrtr.{c,h}                    — AF_QIPCRTR helpers
    ├── qmi.{c,h}                     — TLV encode/decode
    ├── log.{c,h}                     — structured logging
    ├── state.{c,h}                   — /run/vendor-init/ state files
    └── stage_*.c                     — DMS / NAS / DPM / WDA / DSD /
                                        BIND_MUX / WDS_START / fff2 /
                                        iattach / post_tune
```

## Quick start

Two kernel steps + one userspace step:

```bash
# 1. Overlay the Asus 4.19 baseline onto your mainline 6.19 tree
KERNEL_TREE=/path/to/your/qcom-sdm660-6.19-kernel
cp -rT vendor-baseline-4.19/ "$KERNEL_TREE"/

# 2. Apply the porting patch
cd "$KERNEL_TREE"
patch -p1 < /path/to/postmarketos-x00td-cellular/patches/sdm660-ipa-port-4.19-to-6.19.patch
chmod +x drivers/platform/msm/ipa/ipa_v2/apply-port-patches.sh

# 3. Configure / build / flash with:
#    CONFIG_IPA=m, CONFIG_RMNET_IPA=m, CONFIG_SPS=m,
#    CONFIG_SPS_SUPPORT_NDP_BAM=y, CONFIG_IPA_DEBUG=y
# (full kconfig + DTS reference in POSTMARKETOS_X00TD_CELLULAR.md)
```

Then build & run `vendor-init` on the device to activate the bearer.

Full instructions, prerequisites, DTS reference, ModemManager
alternative path, throughput tuning, known caveats, and what is *not*
ported are in **`POSTMARKETOS_X00TD_CELLULAR.md`**.

## Status

- Production-OK for the **primary cellular DL path** (20.5 Mbps Vodafone CZ LTE).
- Symmetric QMAPv3 UL is **opt-in / WIP** (`qmapv3_ul_enable=0` default).
- The IPA driver itself is **out-of-tree** and **not upstream-ready**;
  it ports a 4.19 vendor blob forward, with shim layers for mainline
  subsystems it predates.
- The `vendor-init` userspace tool and the rmnet `NETIF_F_IP_CSUM`
  patch are in better shape to share standalone.

See "Known caveats" in the writeup for the long form.

## Hardware tested

- Device: Asus Zenfone Max Pro M1 (`asus-x00td`)
- SoC: Snapdragon 660 (SDM636), IPA v2.6L
- Carrier tested: Vodafone CZ (LTE)
- Userspace: PostmarketOS edge (Alpine-based)

## Reproducibility on other SDM6xx

The X00TD work *should* port to other Snapdragon 636 / 660 devices
with minor DTS adjustments. The writeup calls out four DTS gotchas
that tend to bite porters. We have not tested any other devices.

## License

- Kernel patches: **GPL-2.0** (matching surrounding files).
- `vendor-init`: **GPL-2.0**.

## Reporting back

If you reproduce this on the same device, on a different SDM6xx
device, or on a different carrier — please open a GitHub issue with
the result. Negative results are useful too.

## Acknowledgments

- Sireesh Kodali (2021 RFC) and Alejandro Tafalla (msm8953 IPA) — the
  initial ipa-legacy mainline porting work this builds on.
- aboothahir — sdm660-6.7.y-ipa branch that was the immediate starting
  point.
- libqmi project — the canonical QMI service spec used to byte-shape
  every `vendor-init` message.
- ModemManager `mm-shared-qmi.c` — clean reference for NAS RAT setup.
- Qualcomm CodeAurora `qcril-hal` open-source pieces that complement
  the closed `libril-qc-hal-qmi.so`.
- Vodafone CZ — for surviving empirical testing without cancelling the
  SIM.
