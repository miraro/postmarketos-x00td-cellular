# Power-save patch — on-device validation plan

Validates `patches/sdm660-ipa-port-6.19-powersave.patch` (+ the DT pin
drop) on a real X00TD. This is the procedure that produced the measured
result below; keep it for re-validation after kernel bumps.

> ## ✅ Measured result (X00TD, 2026-06-08)
> Ran on hardware. Outcome:
> - **Clock scaling works and is dynamic** — `/sys/kernel/debug/clk/ipa_clk`
>   gates at idle and runs SVS (75 MHz) when active. (Watch `ipa_clk`, **not**
>   `ipa_a_clk` — the latter is the deviceless RPM vote handle and reads
>   `2147483647`/INT_MAX, not a real rate.)
> - **The active RM vote is [150, 250) Mbps**, higher than the ~100 first
>   assumed. Sweeping thresholds confirmed all three states: turbo=150 →
>   active TURBO(200); turbo=250 → active NOMINAL(150); nominal>250 →
>   active SVS(75). Throughput **identical (2.51 MB/s ≈ 20 Mbps) at all
>   three** — the cell is the bottleneck, not the IPA core clock.
> - **SVS (75 MHz) sustains the full link**: 100 MB DL at SVS = 2.51 MB/s,
>   **73 Mbps peak**. Latency under load ~37 ms vs ~31 ms at NOMINAL (~+5 ms,
>   partly cellular jitter). Cold first ping after idle ~43 ms vs ~22 ms warm.
> - No floor-clamp (verified in code: RM resources created with
>   `floor_voltage=0`/UNSPECIFIED), so thresholds fully control the state and
>   active-SVS is reachable.
>
> **Default shipped: `nominal=600, turbo=1000` (vendor values, kept) →
> idle gated, active SVS (75 MHz) — the deepest power-save.** NOMINAL/TURBO
> are unreachable on cellular. To trade ~5 ms latency back for half the
> active power, set `nominal=50` (active → NOMINAL 150 MHz) live.

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
- `clock_scaling_bw_threshold_nominal_mbps = 600`
- `clock_scaling_bw_threshold_turbo_mbps  = 1000`
- clk node `…/ipa_clk` printing a real rate (75/150/200 MHz). If it instead
  reports `2147483647` it matched `ipa_a_clk` — the RPM vote handle; the
  script prefers `ipa_clk` and skips that placeholder.

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

**Pass:** DL completes at ~20 Mbps (≈2.5 MB/s) with shell A showing the
clock at **SVS (75 MHz)** for the duration — that is the shipped default
(`nominal=600`) and the whole point: SVS sustains the link (measured
73 Mbps peak), so the DL is *not* throttled despite the low clock.

**Fail modes & fix (live, no rebuild):**
| Symptom in shell A during DL | Meaning | Fix |
|---|---|---|
| at **SVS (75 MHz)**, DL ~20 Mbps | correct (shipped default) | ✓ continue |
| at **SVS (75 MHz)**, DL **≈ half** | SVS genuinely throttling *this* link | `set 50 1000` → active NOMINAL(150); re-test. If that fixes it, ship `nominal=50` instead. |
| at **NOMINAL/TURBO** | thresholds were lowered below the [150,250) vote | expected only if you ran `set`; `set 600 1000` to restore default |

UL check (aggregate, 4 streams):
```bash
for i in 1 2 3 4; do curl -X POST --data-binary @50mb.bin \
  https://httpbin.org/post -o /dev/null & done; wait
```
**Pass:** ~4 Mbps aggregate (same as baseline), clock at SVS.

---

## 3. Scaling proof — the clock actually drops

```
# shell A
/tmp/powersave-validate.sh watch 60
# shell B: do nothing — leave the bearer up and idle
```

**Expect** the clock sits at **SVS (75 MHz)** whenever active and drops to
**gated** (`active_clients = 0`, rate stale/0) when fully idle. This is the
saving the patch buys — under the base port it would pin NOMINAL (150 MHz)
whenever active, never dropping to SVS.

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

**Judge:** compare cold TTFB / cold-ping RTT at the SVS default against a
NOMINAL-active run (same measurements after `set 50 1000` — see §5). A
small bump (tens of ms) on the first cold packet is expected and fine.
Measured: warm-under-load ~37 ms at SVS vs ~31 ms at NOMINAL. If cold web
page loads feel *stuttery* at SVS, bias up:
- `set 50 1000` → active parks at NOMINAL (150 MHz) instead of SVS (keeps
  idle gating). This is the conservative middle ground; ship `nominal=50`
  if you prefer it.

---

## 5. A/B between the candidate defaults (no reflash)

The live knobs let you compare all three active states without rebuilding:

```bash
# active = SVS (75 MHz) — the shipped default:
/tmp/powersave-validate.sh set 600 1000
# active = NOMINAL (150 MHz) — the conservative alternative:
/tmp/powersave-validate.sh set 50 1000
# active = TURBO (200 MHz) — for reference only:
/tmp/powersave-validate.sh set 50 150
# ... run §4 cold/warm measurements at each ...
# restore the shipped default:
/tmp/powersave-validate.sh set 600 1000
```

**Measured decision (2026-06-08):** throughput identical at all three
(2.51 MB/s ≈ 20 Mbps); SVS adds only ~5 ms warm latency for half the active
core-clock power → **shipped `nominal=600/turbo=1000` (active = SVS)**.
Re-run this on your own link if you want to re-pick:
- SVS cold/warm latency acceptable → keep the default (deepest saving).
- SVS feels stuttery, NOMINAL fixes it → ship `nominal=50` (active NOMINAL).
- any bulk-throughput regression thresholds can't fix → the RM vote
  plumbing needs a look first.

---

## Threshold decision tree (first-principles, correct)

`needed = TURBO if bw≥turbo_thr; NOMINAL if bw≥nominal_thr; else SVS`

- **Leave SVS sooner / less stutter** → **lower** `nominal_thr`.
- **Reach TURBO under load** → **lower** `turbo_thr` below the RM active
  vote (measured [150, 250) Mbps).
- **Deeper idle saving** → **raise** `nominal_thr` (bigger SVS region).

Measured-vote consequence: the active vote is [150, 250) Mbps. So
`nominal_thr` **above 250** (shipped default 600) parks active at **SVS**;
`nominal=50, turbo=1000` parks it at **NOMINAL**; `turbo` **below 150**
sends it to **TURBO**. Throughput is identical at all three — SVS is the
shipped default because it is the deepest saving at no throughput cost.

---

## Report back

Paste me: §1 config dump, the §2 watch table during DL + the DL Mbps,
the §4 cold-vs-warm RTT/TTFB pairs, and your §5 A/B numbers. That's
enough to pick the default and flip the doc from "not hardware-tested"
to a measured result.
