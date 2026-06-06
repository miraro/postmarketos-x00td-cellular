#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# apply-all.sh — run the complete IPA v2.6L port pipeline on a kernel tree.
#
# Prerequisite: the vendor-baseline-4.19/ overlay is already copied onto a
# mainline 6.19 tree (cp -rT vendor-baseline-4.19/ $KERNEL_TREE/).
#
# Pipeline (all steps mandatory, order fixed):
#   00-install-port-files.sh    new/replaced whole files (Kconfig/Makefile,
#                               compat shim, stubs, icc translator)
#   05-integrate-mainline-tree.sh  wire msm/ into the upstream build system,
#                               X00TD DTS/defconfig, upstream-rmnet csum flags
#   10-apply-port-patches.sh    mechanical 4.19 -> 6.x API conversion
#   20-apply-port-fixes.sh      bringup-correctness fixes
#   30-apply-port-features.sh   datapath/throughput features (auto-IPACM, ...)
#
# Optional, NOT run by this script:
#   90-apply-diag-sondy.sh      bringup diagnostics for porting to other
#                               SDM6xx devices (throughput-hostile; never
#                               ship a production build with it)
#
# Every step is idempotent — apply-all.sh can be re-run safely.
#
# Usage:  ./apply-all.sh [--root /path/to/kernel]

set -eu

SRC_ROOT="."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [ $# -gt 0 ]; do
	case "$1" in
		--root) SRC_ROOT="$2"; shift 2 ;;
		--help|-h) sed -n '/^# /{s/^# \?//;p}' "$0" | head -30; exit 0 ;;
		*) echo "Unknown argument: $1"; exit 1 ;;
	esac
done

for step in 00-install-port-files.sh 05-integrate-mainline-tree.sh \
            10-apply-port-patches.sh 20-apply-port-fixes.sh \
            30-apply-port-features.sh; do
	echo
	echo "════════════════════════════════════════════════════════════"
	echo "  $step"
	echo "════════════════════════════════════════════════════════════"
	bash "$SCRIPT_DIR/$step" --root "$SRC_ROOT"
done

echo
echo "Port pipeline complete. Configure with X00TD_defconfig and build."
