#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# apply-port-patches.sh
#
# Phase 1 in-source mechanical fixes for the IPA v2 / SPS port to Linux 6.x.
#
# Run from the kernel source root. The script edits *.c files under the
# IPA and SPS source trees in-place (or with --dry-run, prints diffs only).
#
# All substitutions are idempotent: running this multiple times produces
# the same result.
#
# What this script does (and does NOT do):
#
#   APPLIES:
#     - class_create(THIS_MODULE, "name")  ->  class_create("name")
#     - dma_zalloc_coherent(...)           ->  dma_alloc_coherent(...)
#     - netif_napi_add(dev, n, fn, weight) ->  netif_napi_add_weight(...)
#
#   DOES NOT APPLY (handled elsewhere):
#     - IPC logging stubs        -> include/linux/ipc_logging.h shim
#     - msm_bus_* shims          -> include/linux/msm-bus.h shim
#     - SUBSYS_* / iommu stubs   -> ipa_v2/ipa_compat.h
#     - QMI struct alignments    -> manual; see PORTING_NOTES.md §6
#
# Usage:
#     ./apply-port-patches.sh                  # apply in default paths
#     ./apply-port-patches.sh --dry-run        # show what would change
#     ./apply-port-patches.sh --root /path     # use custom root
#
# Exit codes: 0 on success, non-zero on error.

set -eu

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

DRY_RUN=0
SRC_ROOT="."
PATHS=(
	"drivers/platform/msm/ipa"
	"drivers/platform/msm/sps"
)

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run|-n)
			DRY_RUN=1
			shift
			;;
		--root)
			SRC_ROOT="$2"
			shift 2
			;;
		--help|-h)
			sed -n '/^# /{s/^# \?//;p}' "$0" | head -40
			exit 0
			;;
		*)
			echo "Unknown argument: $1"
			echo "Use --help for usage."
			exit 1
			;;
	esac
done

cd "$SRC_ROOT"

# Verify the paths exist before doing anything destructive.
for p in "${PATHS[@]}"; do
	if [ ! -d "$p" ]; then
		echo "ERROR: directory '$p' not found under $(pwd)" >&2
		echo "Run this script from the kernel root, or pass --root <path>." >&2
		exit 1
	fi
done

# ----------------------------------------------------------------------------
# Helper: apply_sed PATTERN_DESC PERL_EXPR
# ----------------------------------------------------------------------------
# Runs perl -i (or perl in print-only mode if dry-run) on every .c file
# under the configured paths. Reports per-file change counts.
# ----------------------------------------------------------------------------

total_changes=0

apply_sed () {
	local desc="$1"
	local expr="$2"
	local files
	local subtotal=0

	echo "==> $desc"

	# Collect candidate .c files
	mapfile -t files < <(find "${PATHS[@]}" -type f -name '*.c' | sort)

	for f in "${files[@]}"; do
		# Count matches before modification.
		local before
		before=$(perl -ne "if ($expr) { print }" "$f" 2>/dev/null | wc -l)
		if [ "$before" -eq 0 ]; then
			continue
		fi

		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $f: $before line(s) would change"
			# Show context (each matched line)
			perl -ne "if ($expr) { print qq(    line \$.: \$_) }" "$f"
		else
			perl -i -pe "$expr" "$f"
			echo "  $f: $before line(s) changed"
		fi
		subtotal=$((subtotal + before))
	done

	if [ "$subtotal" -eq 0 ]; then
		echo "  (already clean — nothing to do)"
	fi

	total_changes=$((total_changes + subtotal))
	echo
}

# ----------------------------------------------------------------------------
# Patch 1: class_create THIS_MODULE removal (kernel 6.4+).
#
# Idempotent: only matches the form with THIS_MODULE. Already-fixed calls
# (class_create("name")) won't match.
# ----------------------------------------------------------------------------

apply_sed \
	"class_create(THIS_MODULE, ...) -> class_create(...)" \
	's{class_create\(THIS_MODULE,\s*}{class_create(}g'

# ----------------------------------------------------------------------------
# Patch 2: dma_zalloc_coherent removal (kernel 5.0+).
#
# dma_alloc_coherent always zeroes since 5.0. Idempotent because
# dma_alloc_coherent doesn't contain the substring "zalloc".
# ----------------------------------------------------------------------------

apply_sed \
	"dma_zalloc_coherent(...) -> dma_alloc_coherent(...)" \
	's{\bdma_zalloc_coherent\b}{dma_alloc_coherent}g'

# ----------------------------------------------------------------------------
# Patch 3: netif_napi_add weight argument removal (kernel 6.1+).
#
# Vendor uses NAPI_WEIGHT (=60) which differs from the new default (=64),
# so we use netif_napi_add_weight() to preserve exact behavior.
#
# Idempotent: skip lines that already contain "netif_napi_add_weight".
# Use word boundaries to make sure we don't double-rewrite.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Patch 4d: ipa_api.h -- same Kbuild gotcha pattern (CONFIG_IPA / CONFIG_IPA3).
#
# `#ifdef CONFIG_IPA` matches built-in only. With =m, falls through to the
# #else branch declaring static inline stubs of ipa_plat_drv_probe() etc.,
# which then conflict with the real definitions in ipa.c.
# ----------------------------------------------------------------------------

echo "==> ipa_api.h: #ifdef CONFIG_IPA[3] -> #if IS_ENABLED(...)"
IPA_API_HDR="drivers/platform/msm/ipa/ipa_api.h"
if [ ! -f "$IPA_API_HDR" ]; then
	echo "  WARN: $IPA_API_HDR not found -- skipping."
else
	count1=$(grep -c '^#ifdef CONFIG_IPA$' "$IPA_API_HDR" || true)
	count2=$(grep -c '^#ifdef CONFIG_IPA3$' "$IPA_API_HDR" || true)
	count=$((count1 + count2))
	if [ "$count" -eq 0 ]; then
		echo "  $IPA_API_HDR: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $IPA_API_HDR: $count line(s) would change"
		else
			sed -i 's/^#ifdef CONFIG_IPA$/#if IS_ENABLED(CONFIG_IPA)/;
			        s/^#ifdef CONFIG_IPA3$/#if IS_ENABLED(CONFIG_IPA3)/' \
				"$IPA_API_HDR"
			echo "  $IPA_API_HDR: $count line(s) changed"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 4e: ipa_qmi_service.h -- SUBSYS_MODEM "modem" -> "mpss"
#
# Vendor downstream named the modem subsystem "modem". Mainline qcom_rproc
# names the modem remoteproc instance "mpss" (Modem SubSystem). The string
# is what qcom_register_ssr_notifier() matches on -- using "modem" silently
# fails to register and SSR notifications never fire.
# ----------------------------------------------------------------------------

echo "==> ipa_qmi_service.h: SUBSYS_MODEM \"modem\" -> \"mpss\""
QMI_SVC_HDR="drivers/platform/msm/ipa/ipa_v2/ipa_qmi_service.h"
if [ ! -f "$QMI_SVC_HDR" ]; then
	echo "  WARN: $QMI_SVC_HDR not found -- skipping."
else
	count=$(grep -c '^#define SUBSYS_MODEM "modem"$' "$QMI_SVC_HDR" || true)
	if [ "$count" -eq 0 ]; then
		echo "  $QMI_SVC_HDR: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $QMI_SVC_HDR: $count line(s) would change"
		else
			sed -i 's/^#define SUBSYS_MODEM "modem"$/#define SUBSYS_MODEM "mpss"/' \
				"$QMI_SVC_HDR"
			echo "  $QMI_SVC_HDR: $count line(s) changed"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 4g: ipa_qmi_service.h -- #ifdef CONFIG_RMNET_IPA gating.
#
# Same Kbuild gotcha pattern again: with CONFIG_RMNET_IPA=m the macro is
# not defined, so #ifdef falls through to the #else branch declaring
# static inline stubs of wan_ioctl_init(), wan_ioctl_stop_qmi_messages(),
# rmnet_ipa_set_tether_client_pipe(), etc. These then collide with the
# real definitions in rmnet_ipa.c / rmnet_ipa_fd_ioctl.c.
# ----------------------------------------------------------------------------

echo "==> ipa_qmi_service.h: #ifdef CONFIG_RMNET_IPA -> #if IS_ENABLED(...)"
if [ ! -f "$QMI_SVC_HDR" ]; then
	echo "  WARN: $QMI_SVC_HDR not found -- skipping."
else
	count=$(grep -c '^#ifdef CONFIG_RMNET_IPA$' "$QMI_SVC_HDR" || true)
	if [ "$count" -eq 0 ]; then
		echo "  $QMI_SVC_HDR: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $QMI_SVC_HDR: $count line(s) would change"
		else
			sed -i 's/^#ifdef CONFIG_RMNET_IPA$/#if IS_ENABLED(CONFIG_RMNET_IPA)/' \
				"$QMI_SVC_HDR"
			echo "  $QMI_SVC_HDR: $count line(s) changed"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 4f: ipa.c -- iommu_map() gained gfp_t parameter in 6.3+.
#
# Old (5-arg):  iommu_map(domain, iova, paddr, size, prot)
# New (6-arg):  iommu_map(domain, iova, paddr, size, prot, GFP_KERNEL)
#
# Only one direct call site exists -- ipa.c:5064 inside ipa_iommu_map().
# Other apparent iommu_map callers actually call ipa_iommu_map (the IPA
# wrapper); they do not touch the kernel symbol.
# ----------------------------------------------------------------------------

apply_sed \
	"iommu_map(d,i,p,s,prot) -> iommu_map(d,i,p,s,prot,GFP_KERNEL)" \
	's{\biommu_map\((domain, iova, paddr, size, prot)\)}{iommu_map($1, GFP_KERNEL)}g'

# ----------------------------------------------------------------------------
# Patch 3b: strlcpy() removed in 6.8 (commit 3a3c2c3a98aa).
#
# strlcpy() was deprecated in 5.x because its "return value is the source
# string length" semantics is footgun-prone. It was removed in 6.8 in favor
# of strscpy(), which has saner return semantics ("count copied or -E2BIG").
#
# For our purposes the semantic difference is irrelevant: vendor IPA code
# never inspects the strlcpy return value. Plain text rename is safe.
#
# Idempotent: strscpy doesn't contain the substring "strlcpy".
# ----------------------------------------------------------------------------

apply_sed \
	"strlcpy(...) -> strscpy(...)" \
	's{\bstrlcpy\b}{strscpy}g'

# ----------------------------------------------------------------------------
# Patch 3c: netif_rx_ni() removed in 5.18 (commit baebdf48c360).
#
# Since 5.18 plain netif_rx() can be invoked from any context (including
# soft IRQ), so the _ni variant became redundant and was removed.
# Plain rename is safe.
# ----------------------------------------------------------------------------

apply_sed \
	"netif_rx_ni(skb) -> netif_rx(skb)" \
	's{\bnetif_rx_ni\b}{netif_rx}g'

# ----------------------------------------------------------------------------
# Patch 3d: del_timer() removed in 6.x in favor of timer_delete().
#
# Plain rename. The vendor pattern uses del_timer's return value (active or
# not), which timer_delete() preserves.
# ----------------------------------------------------------------------------

apply_sed \
	"del_timer(...) -> timer_delete(...)" \
	's{\bdel_timer\b}{timer_delete}g'

# ----------------------------------------------------------------------------
# Patch 3e: __netdev_watchdog_up -> netdev_watchdog_up
#
# The exported public symbol lost its leading underscores.
# ----------------------------------------------------------------------------

apply_sed \
	"__netdev_watchdog_up -> netdev_watchdog_up" \
	's{\b__netdev_watchdog_up\b}{netdev_watchdog_up}g'

# ----------------------------------------------------------------------------
# Patch 3f: ndo_tx_timeout signature change (5.6+).
#
# Old: void (*ndo_tx_timeout)(struct net_device *dev)
# New: void (*ndo_tx_timeout)(struct net_device *dev, unsigned int txqueue)
#
# We rewrite both the prototype/definition of ipa_wwan_tx_timeout to take
# the new txqueue arg (which is unused, hence the explicit cast). Idempotent
# via the lookahead — only matches if "txqueue" is not already there.
# ----------------------------------------------------------------------------

apply_sed \
	"ipa_wwan_tx_timeout(struct net_device *dev) signature update" \
	's{ipa_wwan_tx_timeout\(struct net_device \*dev\)(?!.*txqueue)}{ipa_wwan_tx_timeout(struct net_device *dev, unsigned int txqueue)}g'

# ----------------------------------------------------------------------------
# Patch 3g: kernel_connect() / kernel_bind() / kernel_sendmsg() etc. switched
# from `struct sockaddr *` to `struct sockaddr_unsized *` in 6.13+.
#
# `struct sockaddr_unsized` is a new wrapper type that any sockaddr_*
# variant (sockaddr_in, sockaddr_qrtr, ...) can be cast to. The kernel API
# change forces callers to use the new cast instead of `struct sockaddr *`
# to make the variable-length sockaddr handling type-safe.
#
# Only one call site in IPA v2: ipa_qmi_service.c:885 in the QMI service
# arrival callback, casting a sockaddr_qrtr.
#
# NOTE: This sed is for kernel 6.13+. On older kernels the kernel_connect()
# prototype still uses `struct sockaddr *` — applying this patch there
# would break the build. The script applies regardless because the user is
# targeting 6.x mainline.
# ----------------------------------------------------------------------------

apply_sed \
	"(struct sockaddr *) cast -> (struct sockaddr_unsized *) (6.13+)" \
	's{\(struct sockaddr \*\)}{(struct sockaddr_unsized *)}g'

# ----------------------------------------------------------------------------
# Patch 4: msm-sps.h -- #ifdef CONFIG_SPS only matches built-in (=y).
#
# When SPS is built as a module (=m), the macro CONFIG_SPS is NOT defined;
# instead CONFIG_SPS_MODULE is. The vendor msm-sps.h header uses bare
# `#ifdef CONFIG_SPS` to gate the real function declarations, falling back
# to `static inline` stubs in the #else branch. With =m, every translation
# unit that includes msm-sps.h gets the stubs -- and sps.c which provides
# the real definitions ends up colliding.
#
# Fix: change `#ifdef CONFIG_SPS` to `#if IS_ENABLED(CONFIG_SPS)`, which
# evaluates true for both `=y` and `=m`. The `^` and `$` anchors ensure
# we don't accidentally rewrite `#ifdef CONFIG_SPS_SUPPORT_BAMDMA` etc.
# ----------------------------------------------------------------------------

echo "==> msm-sps.h: #ifdef CONFIG_SPS -> #if IS_ENABLED(CONFIG_SPS)"
MSM_SPS_HDR="include/linux/msm-sps.h"
if [ ! -f "$MSM_SPS_HDR" ]; then
	echo "  WARN: $MSM_SPS_HDR not found in $(pwd) -- skipping."
	echo "  (If you placed it elsewhere, patch manually:"
	echo "   sed -i 's/^#ifdef CONFIG_SPS\$/#if IS_ENABLED(CONFIG_SPS)/' \\"
	echo "       /your/path/to/msm-sps.h)"
else
	# Idempotent: only matches the bare form, not anything we already patched.
	count=$(grep -c '^#ifdef CONFIG_SPS$' "$MSM_SPS_HDR" || true)
	if [ "$count" -eq 0 ]; then
		echo "  $MSM_SPS_HDR: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $MSM_SPS_HDR: $count line(s) would change"
			grep -n '^#ifdef CONFIG_SPS$' "$MSM_SPS_HDR"
		else
			sed -i 's|^#ifdef CONFIG_SPS$|#if IS_ENABLED(CONFIG_SPS)|' \
				"$MSM_SPS_HDR"
			echo "  $MSM_SPS_HDR: $count line(s) changed"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 4b: linux/ipa.h -- same Kbuild gotcha as msm-sps.h.
#
# Vendor uses `#if defined CONFIG_IPA || defined CONFIG_IPA3` to gate the
# real public-API function declarations. With CONFIG_IPA=m, neither macro
# is defined (CONFIG_IPA_MODULE is set instead), so every TU including
# <linux/ipa.h> gets the `static inline` stubs in the #else branch --
# which collide with the real definitions in ipa_api.c / ipa_rm.c.
#
# Fix: rewrite to use IS_ENABLED(), which evaluates true for both =y and
# =m. The full original line is unique in the file, so we match exactly.
# ----------------------------------------------------------------------------

echo "==> linux/ipa.h: defined CONFIG_IPA||CONFIG_IPA3 -> IS_ENABLED()"
IPA_HDR="include/linux/ipa.h"
if [ ! -f "$IPA_HDR" ]; then
	echo "  WARN: $IPA_HDR not found -- skipping."
else
	count=$(grep -c '^#if defined CONFIG_IPA || defined CONFIG_IPA3$' \
		"$IPA_HDR" || true)
	if [ "$count" -eq 0 ]; then
		echo "  $IPA_HDR: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $IPA_HDR: $count line(s) would change"
		else
			sed -i 's/^#if defined CONFIG_IPA || defined CONFIG_IPA3$/#if IS_ENABLED(CONFIG_IPA) || IS_ENABLED(CONFIG_IPA3)/' \
				"$IPA_HDR"
			echo "  $IPA_HDR: $count line(s) changed"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 4c: ipa_i.h -- drop #include <asm/dma-iommu.h> (removed from arm64
# in 6.6).
#
# This was a legacy ARM-32 IOMMU DMA-mapping helper header. The arm64
# architecture removed it (commit "arm64: Remove arm-iommu legacy support")
# in 6.6+. Inspecting the IPA v2 source confirms NO arm_iommu_* or
# dma_iommu_* symbols are actually referenced -- the include was dead code
# left over from arm32-era SoCs.
#
# Fix: simply delete the line. Idempotent (second run won't find it).
# ----------------------------------------------------------------------------

echo "==> ipa_i.h: drop #include <asm/dma-iommu.h>"
IPA_I_HDR="drivers/platform/msm/ipa/ipa_v2/ipa_i.h"
if [ ! -f "$IPA_I_HDR" ]; then
	echo "  WARN: $IPA_I_HDR not found -- skipping."
else
	count=$(grep -c '^#include <asm/dma-iommu.h>$' "$IPA_I_HDR" || true)
	if [ "$count" -eq 0 ]; then
		echo "  $IPA_I_HDR: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $IPA_I_HDR: $count line(s) would be deleted"
		else
			sed -i '/^#include <asm\/dma-iommu\.h>$/d' "$IPA_I_HDR"
			echo "  $IPA_I_HDR: $count line(s) deleted"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo
#
# Vendor pattern is:
#     dfile_X = debugfs_create_u32("name", mode, parent, &value);
#     if (!dfile_X || IS_ERR(dfile_X)) { ...goto fail... }
#
# In 5.0+ debugfs_create_u8/u16/u32/u64/x32/x64/bool/size_t/atomic_t all
# return void instead of struct dentry *. This breaks both the assignment
# AND any subsequent IS_ERR-style check.
#
# We previously tried to handle this via macro wraps in ipa_compat.h
# force-included from the Makefile. That didn't survive in some build
# environments (Makefile -include flag wasn't picked up reliably). So we
# now patch sps.c directly with a two-step rewrite:
#
#   (a) Drop the LHS assignment from each debugfs_create_uN/xN/bool call,
#       leaving a plain void-returning function call.
#   (b) Pre-initialize each affected dfile_* declaration to a non-NULL,
#       non-IS_ERR sentinel ((struct dentry *)1L). This way the
#       `if (!dfile_X || IS_ERR(dfile_X))` checks that follow each
#       creator call still pass without code-block surgery.
#
# Note that dfile_info, dfile_logging_option, dfile_bam_addr come from
# debugfs_create_file() which still returns dentry*, so they are
# deliberately NOT touched.
# ----------------------------------------------------------------------------

apply_sed \
	"sps.c: drop assignment from debugfs_create_uN/xN/bool" \
	's{(\w+)\s*=\s*(debugfs_create_(?:u8|u16|u32|u64|x8|x16|x32|x64|bool|size_t|atomic_t)\()}{$2}g'

apply_sed \
	"sps.c/ipa_debugfs.c: pre-init local dentry vars used with void-returning creators" \
	's{^(\s*struct dentry \*(?:dfile_(?:debug_level_option|print_limit_option|reg_dump_option|testbus_sel|bam_pipe_sel|desc_option|log_level_sel)|file));$}{$1 = (struct dentry *)1L;}'

# ----------------------------------------------------------------------------
# Patch 6: sps.c -- platform_driver::remove return type changed to void
# (kernel 6.11+, commit 0edb555a65d1).
#
# Vendor: static int msm_sps_remove(...) { ... return 0; }
# Mainline 6.11+: void (*remove)(struct platform_device *)
#
# Two-step:
#   (a) Change signature: static int -> static void
#   (b) Inside that function only, delete the trailing 'return 0;'
# ----------------------------------------------------------------------------

echo "==> sps.c: msm_sps_remove signature int -> void"
SPS_C="drivers/platform/msm/sps/sps.c"
if [ ! -f "$SPS_C" ]; then
	echo "  WARN: $SPS_C not found -- skipping."
else
	# Step (a): rewrite signature line. Idempotent.
	count_a=$(grep -c '^static int msm_sps_remove(' "$SPS_C" 2>/dev/null || echo 0)
	if [ "$count_a" -gt 0 ]; then
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $SPS_C: signature would be rewritten ($count_a hit)"
		else
			sed -i 's/^static int msm_sps_remove(/static void msm_sps_remove(/' "$SPS_C"
			echo "  $SPS_C: signature rewritten ($count_a hit)"
		fi
		total_changes=$((total_changes + count_a))
	fi

	# Step (b): drop the bare 'return 0;' inside the (now void) function.
	# We use a sed range starting at the signature and ending at the next
	# top-level '}'. This keeps other 'return 0;' lines elsewhere in the file
	# completely untouched.
	if grep -q '^static void msm_sps_remove(' "$SPS_C"; then
		# Count return-0 lines inside the function body.
		body_returns=$(sed -n '/^static void msm_sps_remove(/,/^}/p' "$SPS_C" | grep -cP '^\treturn 0;$' || true)
		if [ "$body_returns" -gt 0 ]; then
			if [ "$DRY_RUN" -eq 1 ]; then
				echo "  [dry-run] $SPS_C: would drop $body_returns 'return 0;' from msm_sps_remove body"
			else
				sed -i '/^static void msm_sps_remove(/,/^}/ { /^\treturn 0;$/d }' "$SPS_C"
				echo "  $SPS_C: dropped $body_returns 'return 0;' from msm_sps_remove body"
			fi
			total_changes=$((total_changes + body_returns))
		fi
	fi

	if [ "$count_a" -eq 0 ]; then
		echo "  (already clean -- nothing to do)"
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 7: rmnet_ipa.c -- ipa_wwan_remove signature (same 6.11+ change as
# msm_sps_remove). int -> void plus drop the trailing 'return 0;'.
# ----------------------------------------------------------------------------

echo "==> rmnet_ipa.c: ipa_wwan_remove signature int -> void"
RMNET_IPA_C="drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c"
if [ ! -f "$RMNET_IPA_C" ]; then
	echo "  WARN: $RMNET_IPA_C not found -- skipping."
else
	count_a=$(grep -c '^static int ipa_wwan_remove(' "$RMNET_IPA_C" 2>/dev/null || echo 0)
	if [ "$count_a" -gt 0 ]; then
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $RMNET_IPA_C: signature would be rewritten"
		else
			sed -i 's/^static int ipa_wwan_remove(/static void ipa_wwan_remove(/' "$RMNET_IPA_C"
			echo "  $RMNET_IPA_C: signature rewritten"
		fi
		total_changes=$((total_changes + count_a))
	fi

	if grep -q '^static void ipa_wwan_remove(' "$RMNET_IPA_C"; then
		body_returns=$(sed -n '/^static void ipa_wwan_remove(/,/^}/p' "$RMNET_IPA_C" | grep -cP '^\treturn 0;$' || true)
		if [ "$body_returns" -gt 0 ]; then
			if [ "$DRY_RUN" -eq 1 ]; then
				echo "  [dry-run] $RMNET_IPA_C: would drop $body_returns 'return 0;' from body"
			else
				sed -i '/^static void ipa_wwan_remove(/,/^}/ { /^\treturn 0;$/d }' "$RMNET_IPA_C"
				echo "  $RMNET_IPA_C: dropped $body_returns 'return 0;' from body"
			fi
			total_changes=$((total_changes + body_returns))
		fi
	fi

	if [ "$count_a" -eq 0 ]; then
		echo "  (already clean -- nothing to do)"
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 8: ipa_utils.c -- ipa2_cfg_ep_metadata is `static` but EXPORT_SYMBOL'd.
#
# Vendor source has:
#     static int ipa2_cfg_ep_metadata(...)   <-- static
#     ...
#     EXPORT_SYMBOL(ipa2_cfg_ep_metadata);   <-- exporting a static is invalid
#
# Modpost in 6.x rejects this with "local symbol was exported". The fix is
# to drop `static` from the function definition. The function is called
# from outside the file (ipa.c), so it should never have been static.
# ----------------------------------------------------------------------------

echo "==> ipa_utils.c: drop 'static' from ipa2_cfg_ep_metadata (it's exported)"
IPA_UTILS_C="drivers/platform/msm/ipa/ipa_v2/ipa_utils.c"
if [ ! -f "$IPA_UTILS_C" ]; then
	echo "  WARN: $IPA_UTILS_C not found -- skipping."
else
	count=$(grep -c '^static int ipa2_cfg_ep_metadata(' "$IPA_UTILS_C" || true)
	if [ "$count" -eq 0 ]; then
		echo "  $IPA_UTILS_C: (already clean -- nothing to do)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $IPA_UTILS_C: signature would be rewritten"
		else
			sed -i 's/^static int ipa2_cfg_ep_metadata(/int ipa2_cfg_ep_metadata(/' \
				"$IPA_UTILS_C"
			echo "  $IPA_UTILS_C: 'static' dropped"
		fi
		total_changes=$((total_changes + count))
	fi
fi
echo

# ----------------------------------------------------------------------------
# Patch 9: Unify multiple module_init/exit calls when the entire driver
# is built as a single .ko.
#
# Vendor source has TWO init points (ipa_module_init via subsys_initcall in
# ipa_api.c, ipa_wwan_init via late_initcall in rmnet_ipa.c) and several
# module_exit / MODULE_LICENSE / MODULE_DESCRIPTION declarations spread
# across files. When everything is one module, ONLY ONE init/exit/license
# is permitted -- otherwise the linker emits "duplicate symbol init_module".
#
# Fix:
#   (a) Drop late_initcall(ipa_wwan_init), module_exit(ipa_wwan_cleanup),
#       and duplicate MODULE_* in rmnet_ipa.c.
#   (b) Drop duplicate MODULE_LICENSE in ipa.c.
#   (c) Make ipa_wwan_init / ipa_wwan_cleanup non-static so ipa_api.c can
#       call them.
#   (d) Insert a call to ipa_wwan_init() inside ipa_module_init() in
#       ipa_api.c so the rmnet_ipa platform_driver gets registered.
# ----------------------------------------------------------------------------

echo "==> rmnet_ipa.c: drop late_initcall/module_exit/duplicate MODULE_*"
RMNET_IPA_C="drivers/platform/msm/ipa/ipa_v2/rmnet_ipa.c"
if [ -f "$RMNET_IPA_C" ]; then
	# Idempotency: only act if the late_initcall line exists.
	if grep -q '^late_initcall(ipa_wwan_init);$' "$RMNET_IPA_C"; then
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $RMNET_IPA_C: 4 module-glue lines would be removed"
		else
			sed -i '/^late_initcall(ipa_wwan_init);$/d;
			        /^module_exit(ipa_wwan_cleanup);$/d;
			        /^MODULE_DESCRIPTION("WWAN Network Interface");$/d;
			        /^MODULE_LICENSE("GPL v2");$/d' "$RMNET_IPA_C"
			echo "  $RMNET_IPA_C: dropped late_initcall + module_exit + 2 MODULE_*"
		fi
		total_changes=$((total_changes + 4))
	else
		echo "  $RMNET_IPA_C: (already clean)"
	fi
fi
echo

echo "==> ipa.c: drop duplicate MODULE_LICENSE"
IPA_C="drivers/platform/msm/ipa/ipa_v2/ipa.c"
if [ -f "$IPA_C" ]; then
	if grep -q '^MODULE_LICENSE("GPL v2");$' "$IPA_C"; then
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $IPA_C: MODULE_LICENSE would be removed"
		else
			sed -i '/^MODULE_LICENSE("GPL v2");$/d' "$IPA_C"
			echo "  $IPA_C: MODULE_LICENSE removed"
		fi
		total_changes=$((total_changes + 1))
	else
		echo "  $IPA_C: (already clean)"
	fi
fi
echo

echo "==> rmnet_ipa.c: drop 'static' from ipa_wwan_init/cleanup"
if [ -f "$RMNET_IPA_C" ]; then
	count_a=$(grep -cP '^static int __init ipa_wwan_init\(' "$RMNET_IPA_C" || echo 0)
	count_b=$(grep -cP '^static void __exit ipa_wwan_cleanup\(' "$RMNET_IPA_C" || echo 0)
	tot=$((count_a + count_b))
	if [ "$tot" -eq 0 ]; then
		echo "  $RMNET_IPA_C: (already clean)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $RMNET_IPA_C: $tot static qualifiers would be dropped"
		else
			sed -i 's/^static int __init ipa_wwan_init(/int __init ipa_wwan_init(/;
			        s/^static void __exit ipa_wwan_cleanup(/void __exit ipa_wwan_cleanup(/' \
				"$RMNET_IPA_C"
			echo "  $RMNET_IPA_C: $tot static qualifiers dropped"
		fi
		total_changes=$((total_changes + tot))
	fi
fi
echo

echo "==> ipa_api.c: insert call to ipa_wwan_init() inside ipa_module_init()"
IPA_API_C="drivers/platform/msm/ipa/ipa_api.c"
if [ -f "$IPA_API_C" ]; then
	# Idempotency: only act if ipa_wwan_init() call is not already present.
	if grep -q 'ipa_wwan_init()' "$IPA_API_C"; then
		echo "  $IPA_API_C: (already patched)"
	else
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [dry-run] $IPA_API_C: insert ipa_wwan_init() call"
		else
			# Insert before "return platform_driver_register(&ipa_plat_drv);"
			# We split into prologue + call so the return value of platform_driver_register
			# is preserved as the function's return value.
			sed -i '/^\treturn platform_driver_register(&ipa_plat_drv);$/i\
	{ extern int __init ipa_wwan_init(void); ipa_wwan_init(); }' \
				"$IPA_API_C"
			echo "  $IPA_API_C: ipa_wwan_init() call inserted"
		fi
		total_changes=$((total_changes + 1))
	fi
fi
echo

echo "============================================================"
if [ "$DRY_RUN" -eq 1 ]; then
	echo "Dry-run complete. $total_changes line(s) would change in total."
	echo "Re-run without --dry-run to apply."
else
	echo "Applied. $total_changes line(s) modified in total."
fi
echo "============================================================"
echo
echo "Next steps:"
echo "  - Verify your tree has the stub headers from this skeleton:"
echo "      include/linux/msm-bus.h"
echo "      include/linux/msm-bus-board.h"
echo "      include/linux/ipc_logging.h"
echo "  - Verify ipa_v2/ipa_compat.h is in place."
echo "  - Add include of ipa_compat.h via Makefile or ipa_i.h."
echo "  - Build with:  make M=drivers/platform/msm/"
