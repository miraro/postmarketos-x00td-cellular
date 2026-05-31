# vendor-baseline-4.19/

Subset of the **Asus 4.19 vendor kernel** sources needed as the base
for our porting patch (`patches/sdm660-ipa-port-4.19-to-6.19.patch`).

The patch is a diff *from this 4.19 baseline → our sondy-stripped 6.19
state*, so a vanilla 6.19 mainline kernel needs to be overlaid with
these files first before the patch will apply cleanly.

## Source provenance

Files in this directory were taken verbatim from the official Asus
mirror at
[`MiCode/android_kernel_asus_sdm660`](https://github.com/MiCode/android_kernel_asus_sdm660),
specifically the X00TD product branch. Asus released this kernel
under **GPL-2.0** as a downstream of Qualcomm CodeAurora `msm-4.19`.
No changes were made to the files here — they are byte-identical to
the upstream Asus release.

`*.bak.*`, `*.before-*`, `*.rej`, `*.orig`, and `*.patched` working
files from session work were intentionally excluded.

## Layout

```
vendor-baseline-4.19/
├── drivers/platform/msm/
│   ├── ipa/                            (14 files — parent IPA dir:
│   │                                     ipa_api.*, ipa_common_i.h,
│   │                                     ipa_rm.c + 6 ipa_rm_*,
│   │                                     ipa_uc_offload_common_i.h,
│   │                                     Makefile)
│   ├── ipa/ipa_v2/                     (31 files — vendor IPA v2.6L driver)
│   └── sps/                            (13 files — BAM/SPS framework)
├── include/
│   ├── linux/
│   │   ├── msm-bus.h, msm-bus-board.h, ipc_logging.h
│   │   ├── msm_gsi.h, msm-sps.h, ipa_wdi3.h
│   │   └── ipa.h                       (vendor IPA UAPI extras)
│   └── uapi/linux/
│       ├── msm_ipa.h                   (vendor msm_ipa UAPI)
│       └── ipa_qmi_service_v01.h       (QMI service struct defs)
└── README.md                           (this file)
```

67 files / ~2.2 MB / ~55 000 LoC total.

**NO rmnet.** Vanilla mainline 6.19 already has the upstream rmnet
driver (`drivers/net/ethernet/qualcomm/rmnet/`); our work uses that
unchanged with the tiny `rmnet-netif-csum.patch` applied on top.
Asus 4.19 ships its own downstream rmnet which we do NOT want.

## How to use

From the package root, two-step apply to your mainline 6.19 tree:

```bash
# Step 1: overlay this 4.19 baseline onto your 6.19 tree
KERNEL_TREE=/path/to/your/qcom-sdm660-6.19-kernel
cp -rT vendor-baseline-4.19/ "$KERNEL_TREE"/

# Step 2: apply the porting patch
cd "$KERNEL_TREE"
patch -p1 < /path/to/postmarketos-x00td-cellular/patches/sdm660-ipa-port-4.19-to-6.19.patch
chmod +x drivers/platform/msm/ipa/ipa_v2/apply-port-patches.sh
```

After `patch` finishes with no "FAILED" lines, the kernel is ready
to configure (see required `CONFIG_*` flags in the writeup) and
build.

## Why bundle this

Three reasons:

1. **Self-contained.** Works offline, works if the Asus mirror goes
   away, works without needing `git` set up to clone a 5 GB Android
   kernel tree just to extract a 1 MB subset.
2. **Pinned.** No risk of Asus pushing a different commit to that
   path and breaking the patch.
3. **Reviewable.** The exact bytes of the baseline are in the diff
   history of *this* repo, so a reader can audit what got brought in.

GPL-2.0 explicitly permits redistribution of these files with our
changes alongside, so the legal side is clean.

## What this does NOT bundle

- The rest of the kernel tree. You still need a mainline 6.19 base
  to overlay onto.
- Out-of-tree drivers (WLAN firmware, etc.) — same as any port.
- The `drivers/net/ipa/` mainline upstream IPA 3 driver — vanilla
  6.19 already has it and we don't touch it.
