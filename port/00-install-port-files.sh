#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# 00-install-port-files.sh
#
# Step 0 of the IPA v2.6L port: install the whole-file artefacts that the
# port adds to (or substitutes wholesale in) the kernel tree. Run from the
# kernel source root AFTER overlaying vendor-baseline-4.19/ onto it.
#
# What gets installed (all from the files/ directory next to this script):
#
#   NEW files of our authorship:
#     drivers/platform/msm/Kconfig                     minimal (sources sps+ipa only;
#                                                      vendor's 270-line version refs
#                                                      many MSM drivers we don't ship)
#     drivers/platform/msm/Makefile                    minimal (sps/ + ipa/)
#     drivers/platform/msm/{ipa,ipa/ipa_v2,sps}/Kconfig new Kconfig trio
#     drivers/platform/msm/ipa/ipa_v2/ipa_compat.h     6.x compat shim (force-included)
#     drivers/platform/msm/ipa/ipa_v2/ipa_disabled_stubs.c  __weak stubs for disabled
#                                                      offload engines (WDI/NTN/MHI/teth)
#     drivers/platform/msm/ipa/ipa_v2/msm_bus_compat.c msm_bus_scale_* -> icc translator
#     drivers/platform/msm/ipa/ipa_v2/PORTING_NOTES.md break catalog (in-tree reference)
#
#   REPLACED vendor files (monolithic ipa-driver.ko build):
#     drivers/platform/msm/ipa/Makefile                single-module build
#     drivers/platform/msm/ipa/ipa_v2/Makefile         emptied (parent owns objs)
#     drivers/platform/msm/sps/Makefile                msm_sps.ko build
#
#   REPLACED vendor headers (shrunk to shims/stubs — see each file's header
#   comment for the why):
#     include/linux/ipc_logging.h      no-op stubs (downstream-only facility)
#     include/linux/msm-bus.h          API kept, backed by msm_bus_compat.c/icc
#     include/linux/msm-bus-board.h    just the MASTER/SLAVE ids the code reads
#     include/linux/msm_gsi.h          minimal types (GSI is IPA v3+; v2 uses BAM)
#     include/linux/ipa_wdi3.h         forward decls only (WDI3 is v3+)
#     include/linux/ipa_wigig.h        empty stub (WIGIG disabled)
#     include/net/rmnet_config.h       just RMNET_MAP_GET_CD_BIT
#     include/soc/qcom/subsystem_notif.h    empty (ipa_compat.h shims the API)
#     include/soc/qcom/subsystem_restart.h  empty (ditto)
#
# Idempotent: plain file copies — re-running gives the same tree.
#
# Usage:
#     ./00-install-port-files.sh [--root /path/to/kernel]

set -eu

SRC_ROOT="."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

while [ $# -gt 0 ]; do
	case "$1" in
		--root) SRC_ROOT="$2"; shift 2 ;;
		--help|-h) sed -n '/^# /{s/^# \?//;p}' "$0" | head -50; exit 0 ;;
		*) echo "Unknown argument: $1"; exit 1 ;;
	esac
done

if [ ! -d "$FILES_DIR" ]; then
	echo "ERROR: $FILES_DIR not found (must sit next to this script)" >&2
	exit 1
fi
if [ ! -d "$SRC_ROOT/drivers/platform/msm/ipa/ipa_v2" ]; then
	echo "ERROR: $SRC_ROOT does not look like a kernel tree with the" >&2
	echo "       vendor-baseline-4.19 overlay applied (no ipa_v2/)." >&2
	exit 1
fi

count=0
# arch/ board files (DTS, defconfig) are handled by 05-integrate-mainline-
# tree.sh which edits an existing in-tree DTS instead of overwriting it
# (postmarketOS 6.19 already ships sdm636-asus-x00td.dts).
while IFS= read -r -d '' f; do
	rel="${f#"$FILES_DIR"/}"
	case "$rel" in arch/*) continue ;; esac
	mkdir -p "$SRC_ROOT/$(dirname "$rel")"
	cp "$f" "$SRC_ROOT/$rel"
	echo "  install: $rel"
	count=$((count + 1))
done < <(find "$FILES_DIR" -type f -print0 | sort -z)

echo "============================================================"
echo "Installed $count file(s) into $SRC_ROOT"
echo "Next: ./10-apply-port-patches.sh --root $SRC_ROOT"
