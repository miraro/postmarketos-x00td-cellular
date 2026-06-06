# IPA v2 → Linux 6.x — porting notes

Target: SDM636 / SDM660 (ASUS X00TD), IPA HW v2.6L, internal Q6 modem.

This document is the **break catalog**. It lists every API change between
the 4.19 source the vendor IPA v2 driver was last shipped against and
mainline 6.x — and what we do about each one.

The breaks fall into three groups by who fixes them:

| Group | Fixed by | Items |
|-------|----------|-------|
| (A) Stub headers in `include/linux/` | dropping our shim headers in place | IPC logging, msm_bus |
| (B) Compat shim `ipa_v2/ipa_compat.h` | macro / inline-fn shims, force-included via Makefile `-include` | SSR notifier, iommu attrs, dma_zalloc_coherent, debugfs_create_u8/u32/... |
| (C) In-source sed patches | running `apply-port-patches.sh` | class_create, dma_zalloc_coherent, netif_napi_add, msm-sps.h CONFIG_SPS gating |

After (A) + (B) + (C) the tree should compile. What remains beyond Phase 1:

| Phase | What | When |
|-------|------|------|
| 2 | DT bindings + first probe attempt | after compile is green |
| 3 | msm_bus → interconnect framework | when bring-up is stable |
| 4 | iommu attrs → DT properties | when SMMU CB matters |
| 5 | QMI struct alignment | when QMI handshake fails |

---

## Group A — Stub headers (drop into `include/linux/`)

### `linux/ipc_logging.h`

**Why:** `ipa_common_i.h` and `spsi.h` do an unconditional `#include
<linux/ipc_logging.h>`. Mainline never had this header.

**Fix:** Stub at `include/linux/ipc_logging.h` provides inline no-op
implementations of `ipc_log_context_create`, `ipc_log_context_destroy`,
`ipc_log_string`. All real logging continues via `pr_debug`/`pr_err` and
`trace_printk`.

### `linux/msm-bus.h` and `linux/msm-bus-board.h`

**Why:** `ipa.c` and `ipa_utils.c` do an unconditional `#include
<linux/msm-bus.h>` plus `<linux/msm-bus-board.h>`. The latter provides the
`MSM_BUS_MASTER_*` / `MSM_BUS_SLAVE_*` enum values used in static
`msm_bus_vectors[]` tables; the former provides the API.

**Fix:** The stub headers keep the vendor `struct` layouts and API
signatures, and a compat shim — `ipa_v2/msm_bus_compat.c` — **translates**
the `msm_bus_scale_*` calls onto the mainline interconnect (icc)
framework: `register_client` acquires one `icc_path` per (src,dst) pair
from the DT `interconnects`, and `update_request` issues `icc_set_bw()`
per vector. Bus voting is real, not a no-op. (The original Phase-1 plan
of inline no-op stubs was superseded — the Phase 3 "msm_bus → interconnect"
row below is effectively done.)

`msm-bus-board.h` defines the master/slave IDs as integer constants.
These **are** read: `msm_bus_compat.c::map_src_dst_to_icc_name()` switches
on them (IPA/BAM_DMA x EBI_CH0/OCIMEM) to pick the named icc path
(`"ipa-mem"` / `"ipa-imem"`). The numeric values are arbitrary but must
stay consistent with those case labels.

**Affected files (vendor source, no edits required):**
`ipa.c`, `ipa_utils.c`.

---

## Group B — Compat shim `ipa_v2/ipa_compat.h`

This header must be included before driver internal headers. Either:
- (a) add `#include "ipa_compat.h"` at the top of `ipa_i.h` (one-line edit), OR
- (b) add `ccflags-y += -include $(srctree)/$(src)/ipa_compat.h` in the
  `ipa_v2/Makefile` so it's force-included into every TU.

We recommend (a) for clarity.

### SSR notifier (`subsys_notif_*` → `qcom_register_ssr_notifier`)

**Why:** `subsys_notif_register_notifier(SUBSYS_MODEM, &nb)` is downstream;
mainline 6.x uses `qcom_register_ssr_notifier("mpss", &nb)` from
`<linux/remoteproc/qcom_rproc.h>`.

**Fix:** Inline wrapper functions in `ipa_compat.h` translate the
downstream API to mainline. The notification codes (`SUBSYS_BEFORE_*` /
`SUBSYS_AFTER_*`) are mapped to integer constants matching mainline's
`enum qcom_ssr_notify_type`.

**Affected file (vendor source, no edits):** `rmnet_ipa.c` lines 3224, 3239
(register / unregister) and the switch on the notification code in the
SSR callback.

### `iommu_domain_get_attr` (removed in 6.5)

**Why:** API and `enum iommu_attr` (containing `DOMAIN_ATTR_S1_BYPASS`,
`DOMAIN_ATTR_FAST`) were removed entirely. Replacement is per-driver via
DT or other mechanisms.

**Fix:** Macro stub `#define iommu_domain_get_attr(domain, attr, data) (0)`
in `ipa_compat.h`. The vendor source already initializes the output
variables (`int bypass = 0; int fast = 0;`) before each call, so the
no-op leaves them at safe defaults.

This means SDM660 first bring-up will run with **S1 bypass disabled, no
fast mapping**. If your hardware needs S1 bypass, fix this in Phase 4 by
reading explicit DT properties on the SMMU CB nodes.

**Affected files (vendor source, no edits):** `ipa.c` six call sites
(WLAN CB, AP CB, uC CB probes).

### `dma_zalloc_coherent` (removed in 5.0)

**Why:** `dma_alloc_coherent()` always zeroes since 5.0; the
`_z`-prefixed variant was a redundant wrapper that got removed.

**Fix:** Two layers, belt-and-braces:
1. `ipa_compat.h` defines `#define dma_zalloc_coherent(...)
   dma_alloc_coherent(...)` so untouched source compiles.
2. `apply-port-patches.sh` also rewrites the call sites for cleanliness.

Either alone would suffice; both together ensures we don't get caught
out if a TU forgets to include the shim.

### `debugfs_create_u8/u16/u32/u64/x32/x64/bool/...` return type changed (5.0)

**Why:** In commit `c23fe5d50ce5` the simple-type debugfs creators were
changed to return `void` instead of `struct dentry *`. Vendor source
(both `sps.c` and `ipa_debugfs.c`) does:

```c
file = debugfs_create_u32("name", mode, parent, &value);
if (!file || IS_ERR(file)) { ...goto fail... }
```

which in 6.x produces:
```
error: assigning to 'struct dentry *' from incompatible type 'void'
```

**Fix:** `ipa_compat.h` provides macros that wrap each void-returning
debugfs creator as a statement-expression yielding a non-NULL non-IS_ERR
sentinel pointer (`(struct dentry *)1L`). Per ISO C 6.10.3.4 the
self-named macro does NOT recurse — `debugfs_create_u32(...)` inside the
expansion resolves to the actual kernel function each time.

**Affected** (no source edits required):
- `ipa_v2/ipa_debugfs.c` lines 2081, 2249, 2256, 2264 (and others)
- `sps/sps.c` lines 545, 552, 559, 566, 573, 580, 594

The compat header is force-included into every TU via Makefile
`ccflags-y += -include $(srctree)/.../ipa_compat.h` from both `ipa_v2/`
**and** `sps/` Makefiles, so SPS code gets the wrap too.

### `#ifdef CONFIG_SPS` only matches built-in (=y) — Kbuild gotcha

**Why:** In Kbuild, `CONFIG_FOO=m` defines `CONFIG_FOO_MODULE`, not
`CONFIG_FOO`. The vendor `msm-sps.h` line 743 uses bare
`#ifdef CONFIG_SPS` to gate the real declarations, falling back to
`static inline` stubs in the `#else`. With `CONFIG_SPS=m`, every TU
sees the stubs — and `sps.c` providing the real definitions
collides with them, producing a flood of:

```
error: redefinition of 'sps_connect'
... previous definition is here  (msm-sps.h:1466 static inline)
```

**Fix:** `apply-port-patches.sh` rewrites the line
`#ifdef CONFIG_SPS` → `#if IS_ENABLED(CONFIG_SPS)`. The anchored
regex `^#ifdef CONFIG_SPS$` ensures it does not match
`#ifdef CONFIG_SPS_SUPPORT_BAMDMA` (which is bool and thus fine).

**Affected** (handled by the patch script):
- `include/linux/msm-sps.h` line 743

---

## Group C — In-source sed patches (run `./apply-port-patches.sh`)

The script applies these mechanically. All substitutions are idempotent.

### `class_create(THIS_MODULE, "name")` → `class_create("name")`

**Why:** First argument removed in 6.4 (commit `1aaba11da9`).

**Affected** (5 files, 5 lines):
- `ipa_v2/ipa.c` line 4263
- `ipa_v2/ipa_nat.c` line 167
- `ipa_v2/rmnet_ipa_fd_ioctl.c` line 366
- `ipa_v2/teth_bridge.c` line 189
- `sps/sps.c` line 2862

### `dma_zalloc_coherent` → `dma_alloc_coherent`

**Affected** (5 files, 12 lines): `ipa.c`, `ipa_flt.c`, `ipa_hdr.c`,
`ipa_rt.c`, `ipa_uc_mhi.c`. (The `ipa_compat.h` macro covers the case
even if you skip this sed.)

### `netif_napi_add(...,W)` → `netif_napi_add_weight(...,W)`

**Why:** In 6.1, `netif_napi_add()` lost its `weight` parameter. To
preserve the vendor's `NAPI_WEIGHT = 60` (different from the new default
of 64), we use `netif_napi_add_weight()`.

**Affected** (1 file, 1 line): `rmnet_ipa.c` line 2139.

---

## Manual fixes deferred to Phase 2+

### QMI handle / handler structs

`ipa_qmi_service.c` lines 1066+ uses `qmi_handle_init(handle, max_msg_len,
ops, handlers)` and `qmi_add_server(handle, svc_id, version, instance)`.
The function signatures are stable in 6.x, but `struct qmi_ops` callback
signatures and `struct qmi_msg_handler` table format have evolved.

This is too involved for sed. Treat as a Phase-5 standalone task:
read `Documentation/networking/qcom_qmi.rst` (or `Documentation/staging/`
in older kernels) and audit each callback by hand.

### `del_timer()` (deprecated)

`rmnet_ipa.c` line 2291 uses `del_timer(&netdev->watchdog_timer)`.
Mainline 6.x prefers `timer_delete_sync()`. For now this still compiles
(deprecated but functional). Fix when convenient.

### `IRQF_TRIGGER_RISING` and friends

No change in mainline. The IPA IRQ probably wants IRQF_TRIGGER_HIGH or
IRQF_TRIGGER_RISING depending on DT — leave as-is.

---

## Order of attack (phase 1)

1. Drop the source tree in place under `drivers/platform/msm/ipa/`
   (parent + `ipa_v2/`) and `drivers/platform/msm/sps/`.
2. Drop the stub headers under `include/linux/`.
3. Drop `ipa_v2/ipa_compat.h`.
4. Add Kconfig entries to `drivers/platform/msm/Kconfig` and Makefile
   to `drivers/platform/msm/Makefile`.
5. Run `./apply-port-patches.sh` from the kernel root.
6. Add `#include "ipa_compat.h"` at the top of `ipa_v2/ipa_i.h`.
7. Configure:
   ```
   CONFIG_SPS=m
   CONFIG_SPS_SUPPORT_NDP_BAM=y
   CONFIG_IPA=m
   CONFIG_RMNET_IPA=m
   CONFIG_IPA_DEBUG=y
   ```
8. `make M=drivers/platform/msm/` and chase any remaining errors.

After step 8 you have binaries. Phase 2 begins: actually probing hardware
via DT.
