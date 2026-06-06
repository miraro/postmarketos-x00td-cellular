# vendor-baseline-4.19/

Pristine subset of the **Qualcomm/Asus 4.19 vendor kernel** sources that
the port scripts in `../port/` transform into the working mainline-6.19
state. Overlay this onto your kernel tree first, then run the scripts.

## Source provenance

Files in this directory were taken **verbatim** from the LineageOS 22.2
`qcom-sdm660` kernel tree (`lineage-sdm660-22.2`, kernel 4.19.325), a
downstream of Qualcomm CodeAurora `msm-4.19` released under **GPL-2.0**.
No modifications were made — every file is byte-identical to that tree.

> Earlier revisions of this package shipped a baseline that (a) had a
> handful of porting-era edits accidentally baked in and (b) was missing
> nine headers the driver `#include`s. Both problems are fixed: the
> baseline is now a clean vendor snapshot and the porting edits live
> where they belong — documented, one by one, in the `../port/` scripts.

## Layout

```
vendor-baseline-4.19/
├── drivers/platform/msm/
│   ├── ipa/                (13 files + vendor Makefile — parent IPA dir:
│   │                        ipa_api.*, ipa_common_i.h, ipa_rm.c + 6 ipa_rm_*,
│   │                        ipa_uc_offload_common_i.h)
│   ├── ipa/ipa_v2/         (30 files + vendor Makefile — IPA v2.6L driver)
│   └── sps/                (12 files + vendor Makefile — BAM/SPS framework)
└── include/
    ├── linux/              (ipa.h, ipa_mhi.h, ipa_uc_offload.h, ipa_wdi3.h,
    │                        ipa_wigig.h, ipc_logging.h, msm-bus.h,
    │                        msm-bus-board.h, msm_gsi.h, msm-sps.h)
    ├── net/rmnet_config.h
    ├── soc/qcom/           (subsystem_notif.h, subsystem_restart.h)
    └── uapi/linux/         (msm_ipa.h, msm_rmnet.h, ipa_qmi_service_v01.h,
                             rmnet_ipa_fd_ioctl.h, rmnet_data.h)
```

75 vendor files / ~2.3 MB (+ this README). Several of the headers are
later **replaced wholesale** by shims/stubs (`port/files/include/...`)
and the rest of the tree is transformed by the scripts — see
`../port/apply-all.sh` for the pipeline.

**NO rmnet.** Mainline already has the upstream rmnet driver
(`drivers/net/ethernet/qualcomm/rmnet/`); the port uses it unchanged
except for the small feature-flag edit done by
`port/05-integrate-mainline-tree.sh`. The vendor downstream rmnet is
deliberately not shipped.

**NO Kconfig for msm/.** The vendor `drivers/platform/msm/Kconfig`
references dozens of MSM drivers this package does not ship; a minimal
replacement (sps + ipa only) is installed from `port/files/`.

## How to use

```bash
KERNEL_TREE=/path/to/your/qcom-sdm660-6.19-kernel
cp -rT vendor-baseline-4.19/ "$KERNEL_TREE"/
/path/to/postmarketos-x00td-cellular/port/apply-all.sh --root "$KERNEL_TREE"
```

See the top-level `README.md` for the full sequence and required
kernel configuration.

## Why bundle this

1. **Self-contained.** Works offline, works if the upstream mirror goes
   away, works without cloning a 5 GB Android kernel tree to extract a
   2 MB subset.
2. **Pinned.** No risk of an upstream branch moving and breaking the
   scripts' context matching.
3. **Reviewable.** The exact baseline bytes are in this repo's history,
   so the diff the scripts produce is fully auditable.

GPL-2.0 explicitly permits redistributing these files alongside our
changes.
