#!/bin/sh
# powersave-validate.sh — on-device instrument for the IPA clock-scaling
# power-save patch (patches/sdm660-ipa-port-6.19-powersave.patch).
#
# It does NOT measure throughput itself — it samples the IPA core-clock
# state (rate + active-clients refcount + scaling config) so you can watch
# what the clock does while you drive traffic from another shell. Run it
# alongside the steps in sdm660-ipa-port-6.19-powersave.TESTPLAN.md.
#
# POSIX sh / busybox-ash clean (PostmarketOS / Alpine). Run as root.
#
# Usage:
#   ./powersave-validate.sh config         # one-shot: dump scaling config
#   ./powersave-validate.sh watch [secs]   # live sample table (default 60s)
#   ./powersave-validate.sh set N T        # set nominal/turbo thresholds (Mbps)
#   ./powersave-validate.sh debug on|off   # toggle the driver scaling pr_debug

IPA_DBG=/sys/kernel/debug/ipa
CLK_DBG=/sys/kernel/debug/clk

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$IPA_DBG" ] || die "no $IPA_DBG — is the ipa module loaded with CONFIG_IPA_DEBUG=y?"

# Locate the IPA *core* clock node under /sys/kernel/debug/clk.
#
# On SDM660 two ipa clocks show up:
#   ipa_clk    -> bound to 14780000.ipa as core_clk    (the real rate: 75/150/200 MHz)
#   ipa_a_clk  -> deviceless RPM active-set vote handle (rate = 2147483647 = INT_MAX,
#                 NOT a real frequency)
# The bare *ipa* glob hits ipa_a_clk first (alpha order) and reports the
# INT_MAX placeholder, so: prefer an exact ipa_clk node and reject the
# INT_MAX placeholder anywhere.
INT_MAX=2147483647
find_clk() {
	# 1) prefer the exact core-clock node name(s)
	for d in "$CLK_DBG"/ipa_clk "$CLK_DBG"/*ipa_clk; do
		[ -r "$d/clk_rate" ] || continue
		[ "$(cat "$d/clk_rate" 2>/dev/null)" = "$INT_MAX" ] && continue
		echo "$d"; return 0
	done
	# 2) any ipa dir, but skip the INT_MAX vote-handle
	for d in "$CLK_DBG"/*ipa* "$CLK_DBG"/*IPA*; do
		[ -r "$d/clk_rate" ] || continue
		[ "$(cat "$d/clk_rate" 2>/dev/null)" = "$INT_MAX" ] && continue
		echo "$d"; return 0
	done
	# 3) fall back to clk_summary -> resolve names to dirs, skip INT_MAX
	if [ -r "$CLK_DBG/clk_summary" ]; then
		for name in $(awk 'tolower($1) ~ /ipa/ {print $1}' "$CLK_DBG/clk_summary"); do
			[ -r "$CLK_DBG/$name/clk_rate" ] || continue
			[ "$(cat "$CLK_DBG/$name/clk_rate")" = "$INT_MAX" ] && continue
			echo "$CLK_DBG/$name"; return 0
		done
	fi
	return 1
}

rate_to_state() {
	case "$1" in
		200000000) echo "TURBO  (200 MHz)";;
		150000000) echo "NOMINAL(150 MHz)";;
		 75000000) echo "SVS    ( 75 MHz)";;
		        0) echo "gated/0";;
		2147483647) echo "max/unset (RPM vote handle, not core_clk)";;
		        *) echo "?(${1} Hz)";;
	esac
}

# active_clients debugfs prints a header line "Clients: N" (N = refcount).
active_cnt() {
	[ -r "$IPA_DBG/active_clients" ] || { echo "?"; return; }
	# first integer found in the file
	tr -cs '0-9' ' ' < "$IPA_DBG/active_clients" | awk '{print $1; exit}'
}

cmd_config() {
	echo "== IPA clock-scaling config =="
	for k in enable_clock_scaling \
		 clock_scaling_bw_threshold_nominal_mbps \
		 clock_scaling_bw_threshold_turbo_mbps; do
		if [ -r "$IPA_DBG/$k" ]; then
			printf '  %-42s = %s\n' "$k" "$(cat "$IPA_DBG/$k")"
		else
			printf '  %-42s = (absent)\n' "$k"
		fi
	done
	CLK=$(find_clk) && {
		r=$(cat "$CLK/clk_rate")
		printf '  %-42s = %s  [%s]\n' "clk node ($CLK)" "$r" "$(rate_to_state "$r")"
	} || echo "  clk node                                   = (not found under $CLK_DBG)"
	printf '  %-42s = %s\n' "active_clients refcount" "$(active_cnt)"
	echo
	echo "Interpretation:"
	echo "  enable_clock_scaling must be 1 (else the base-port pinned-NOMINAL behaviour)."
	echo "  Expected thresholds for this patch: nominal=50, turbo=150 (Mbps)."
}

cmd_watch() {
	secs=${1:-60}
	CLK=$(find_clk) || die "could not find the IPA clk node under $CLK_DBG"
	echo "Watching $CLK/clk_rate + active_clients for ${secs}s (Ctrl-C to stop)."
	echo "Drive traffic / idle from another shell per the test plan."
	printf '%-9s %-10s %-17s %-7s\n' "t(s)" "rate(Hz)" "state" "clients"
	i=0
	while [ "$i" -lt "$secs" ]; do
		r=$(cat "$CLK/clk_rate" 2>/dev/null)
		printf '%-9s %-10s %-17s %-7s\n' "$i" "$r" "$(rate_to_state "$r")" "$(active_cnt)"
		i=$((i + 1))
		sleep 1
	done
}

cmd_set() {
	n=$1; t=$2
	[ -n "$n" ] && [ -n "$t" ] || die "usage: $0 set <nominal_mbps> <turbo_mbps>"
	echo "$n" > "$IPA_DBG/clock_scaling_bw_threshold_nominal_mbps" \
		|| die "write nominal failed"
	echo "$t" > "$IPA_DBG/clock_scaling_bw_threshold_turbo_mbps" \
		|| die "write turbo failed"
	echo "set nominal=$n turbo=$t (Mbps). No rebuild needed — live."
	cmd_config
}

cmd_debug() {
	ctl=/sys/kernel/debug/dynamic_debug/control
	[ -w "$ctl" ] || die "no $ctl (CONFIG_DYNAMIC_DEBUG=y needed)"
	case "$1" in
		on)  echo 'file ipa.c +p' > "$ctl"
		     echo "scaling pr_debug ON — watch: dmesg -w | grep 'setting clock rate'";;
		off) echo 'file ipa.c -p' > "$ctl"; echo "scaling pr_debug OFF";;
		*)   die "usage: $0 debug on|off";;
	esac
}

case "$1" in
	config|"") cmd_config;;
	watch)     cmd_watch "$2";;
	set)       cmd_set "$2" "$3";;
	debug)     cmd_debug "$2";;
	*)         echo "usage: $0 {config|watch [secs]|set N T|debug on|off}" >&2; exit 1;;
esac
