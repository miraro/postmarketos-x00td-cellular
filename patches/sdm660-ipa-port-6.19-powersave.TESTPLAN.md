# Power-save patch — on-device validation plan

Validates `patches/sdm660-ipa-port-6.19-powersave.patch` (+ the DT pin
drop) on a real X00TD. The patch is **not hardware-tested** as shipped;
this is the procedure that closes that gap.

Instrument: `patches/powersave-validate.sh` (push to the device, run as
root). It samples the IPA core-clock state while *you* drive traffic.

What we are proving, in order:
1. **No regression** — DL still ~20 Mbps, UL still ~4 Mbps aggregate.
2. **Scaling actually moves the clock** — NOMINAL under load, SVS when
   active-but-unvoted, gated at idle.
3. **Idle→burst feel** — the real risk: first packets of a cold burst
   run at SVS (75 MHz) until the RM vote lands. Does that read as lag?

---

## 0. Build & flash

```bash
# from the package root, on a tree already prepared by port/apply-all.sh
patch -p1 < patches/sdm660-ipa-port-6.19-powersave.patch
# drop the DT 200 MHz pin — pick ONE (direct patch is simplest):
patch -p1 < patches/sdm636-asus-x00td-ipa-powersave-dts.patch
# build + flash as usual (pmbootstrap envkernel), boot, attach to LTE,
# bring the bearer up with vendor-init exactly as in the main doc.
```

Push the instrument:
```bash
scp patches/powersave-validate.sh root@<device>:/tmp/
ssh root@<device> chmod +x /tmp/powersave-validate.sh
```

---

## 1. Sanity — config landed

```bash
/tmp/powersave-validate.sh config
```

Expect:
- `enable_clock_scaling = 1`
- `clock_scaling_bw_threshold_nominal_mbps = 50`
- `clock_scaling_bw_threshold_turbo_mbps  = 150`
- a clk node found, printing a real rate

If `enable_clock_scaling = 0` → the patch didn't build in (wrong tree).
If no clk node found → tell me the output of
`grep -i ipa /sys/kernel/debug/clk/clk_summary`; I'll adjust the matcher.

---

## 2. Regression — throughput unchanged  *(must pass before anything else)*

Two shells. Shell A samples, shell B drives the load.

```
# shell A
/tmp/powersave-validate.sh watch 90
# shell B (wait until LTE-attached; see main doc note about GSM camping)
curl -o /dev/null http://cachefly.cachefly.net/100mb.test
```

**Pass:** DL completes at ~20 Mbps (≈2.5 MB/s), and shell A shows the
clock sitting at **NOMINAL (150 MHz)** for the duration of the transfer.

**Fail modes & fix (live, no rebuild):**
| Symptom in shell A during DL | Meaning | Fix |
|---|---|---|
| stuck at **SVS (75 MHz)**, DL ≈ half | RM active vote `< nominal_thr` | `set` nominal lower, e.g. `set 20 150`; re-test. If still SVS, the RM vote isn't reaching the clock — stop, tell me, it's not a threshold issue. |
| at **NOMINAL**, DL ~20 Mbps | correct | ✓ continue |
| jumps to **TURBO (200)** | vote ≥150 (won't happen on a 20 Mbps cell) | harmless |

UL check (aggregate, 4 streams):
```bash
for i in 1 2 3 4; do curl -X POST --data-binary @50mb.bin \
  https://httpbin.org/post -o /dev/null & done; wait
```
**Pass:** ~4 Mbps aggregate (same as baseline), clock at NOMINAL.

---

## 3. Scaling proof — the clock actually drops

```
# shell A
/tmp/powersave-validate.sh watch 60
# shell B: do nothing — leave the bearer up and idle
```

**Expect** over the idle window, shell A shows the rate fall away from
NOMINAL: either **gated** (`active_clients = 0`, rate stale/0) when fully
idle, or **SVS (75 MHz)** while active-but-unvoted. This is the saving the
patch buys — under the base port it would pin NOMINAL whenever active.

Optionally watch the driver's own decision log:
```bash
/tmp/powersave-validate.sh debug on
dmesg -w | grep 'setting clock rate'   # transitions print here
# ... later:
/tmp/powersave-validate.sh debug off
```

---

## 4. The thing that actually matters — idle→burst latency

Bulk curl already passed; this is about *cold-start feel*. Leave the link
idle ~30 s (so it's at SVS/gated), then measure first-byte cost.

```bash
# RTT from cold idle vs warm under load
ping -c 10 -I qmapmux0.0 8.8.8.8                       # cold (link idle)
( curl -o /dev/null http://cachefly.cachefly.net/100mb.test & \
  sleep 2; ping -c 10 -I qmapmux0.0 8.8.8.8; wait )    # warm (under load)

# time-to-first-byte on a cold connection, repeated
for i in 1 2 3; do
  sleep 20   # let it idle back down to SVS
  curl -o /dev/null -s -w 'ttfb=%{time_starttransfer}s\n' https://example.com
done
```

**Judge:** compare cold TTFB / cold-ping RTT against the fixed-NOMINAL
baseline (same measurements with `set` reverted — see §5). A small bump
(tens of ms) on the first cold packet is expected and fine. If cold web
page loads feel *stuttery*, bias out of SVS:
- `set 1 150` → effectively always ≥ NOMINAL when active/voted (keeps
  idle gating, drops the active-SVS state). This is the conservative
  middle ground between the base port and aggressive power-save.

---

## 5. A/B against the fixed-NOMINAL baseline (no reflash)

The whole point of the live knobs: you can reproduce the *base port*
behaviour without rebuilding, to compare directly.

```bash
# emulate base port (always NOMINAL when active): make NOMINAL trivial,
# TURBO unreachable
/tmp/powersave-validate.sh set 1 999999
echo 0 > /sys/kernel/debug/ipa/enable_clock_scaling   # or keep scaling but pin
# ... run §4 measurements ...
# restore power-save:
echo 1 > /sys/kernel/debug/ipa/enable_clock_scaling
/tmp/powersave-validate.sh set 50 150
```

Record both sets of cold-TTFB / cold-RTT numbers. Decision:
- power-save cold latency ≈ baseline → **ship power-save as default**.
- noticeable cold stutter, bulk fine → ship the **`set 1 150`** middle
  ground (idle gating kept, active-SVS dropped).
- any bulk-throughput regression that thresholds can't fix → **don't
  ship**; the RM vote plumbing needs a look first.

---

## Threshold decision tree (first-principles, correct)

`needed = TURBO if bw≥turbo_thr; NOMINAL if bw≥nominal_thr; else SVS`

- **Leave SVS sooner / less stutter** → **lower** `nominal_thr`.
- **Reach TURBO under load** → **lower** `turbo_thr` below the RM active
  vote (~100 Mbps).
- **Deeper idle saving** → **raise** `nominal_thr` (bigger SVS region).

(Note: the main doc's caveat phrases the first one backwards — "raise
nominal if SVS too slow". Lowering is correct. Flagged for a doc fix.)

---

## Report back

Paste me: §1 config dump, the §2 watch table during DL + the DL Mbps,
the §4 cold-vs-warm RTT/TTFB pairs, and your §5 A/B numbers. That's
enough to pick the default and flip the doc from "not hardware-tested"
to a measured result.
