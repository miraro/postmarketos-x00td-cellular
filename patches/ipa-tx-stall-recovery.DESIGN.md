# Design: AP-local TX-stall recovery (rmnet watchdog harvest)

Status: design + initial patch (`patches/ipa-tx-stall-recovery.patch`).
Scope: SDM660 IPA v2.6L mainline port (`ipa_v2`). Opt-in.

## Problem

The UL datapath can stall **permanently** (until SSR or reboot) on a lost
or coalesced SPS EOT interrupt. The current `ipa_wwan_tx_timeout()` is a
faithful copy of the vendor handler: it only logs `"data stall in UL"` and
returns — it does not recover. (Vendor gets away with the inert watchdog
because it leans on SSR for modem-side recovery; on mainline q6v5 the SSR
notification chain is unreliable, and the port deliberately defanged the
`is_ssr` path because re-registering the single unified `ipa-driver.ko`
across SSR broke `rmnet_ipa0` netdev creation under `insmod`.)

### Exact failure mode (a self-inflicted deadlock)

```
SPS EOT on the egress pipe (APPS_LAN_WAN_PROD) is lost/coalesced
  -> ipa_sps_irq_tx_notify() never runs: curr_polling_state stays 0,
     sys->work is never queued
  -> completed descriptors sit unharvested in the BAM
  -> each packet's completion callback never fires, so
     wwan_private.outstanding_pkts is never decremented
  -> outstanding_pkts stays >= outstanding_high (64)
  -> ipa_wwan_xmit() hits the high watermark -> netif_stop_queue()
  -> no new TX -> no new EOT -> the harvest is never re-armed
  -> permanent stall; the netdev watchdog (watchdog_timeo = 1000 ms)
     fires ipa_wwan_tx_timeout()
```

The harvest only runs off an EOT interrupt, and an EOT only comes from a
new TX — but TX is stopped. `tx_timeout` is the only escape hatch.

## Key idea: re-run the harvest, do NOT reset counters

A real EOT (`ipa_sps_irq_tx_notify()`, `SPS_EVENT_EOT`) does three things:
switch the pipe to POLL mode, set `curr_polling_state = 1`, and
`queue_work(sys->wq, &sys->work)` -> `ipa_handle_tx()` ->
`ipa_handle_tx_core()` -> `sps_get_iovec()` harvest ->
`ipa_wq_write_done_common()` -> each packet's completion callback
(`apps_ipa_tx_complete_notify`) -> `atomic_dec(outstanding_pkts)` + wake.

A "lost EOT" simply means that handshake never ran. **Recovery is to run
it from the watchdog.** `outstanding_pkts` then drops *naturally*, one per
genuinely-completed descriptor — no manual counter reset, hence no
underflow/corruption risk.

## Why it is XPU-safe (respects the modem boundary)

`sps_get_iovec(sys->ep->ep_hdl, ...)` reads the **AP's own** BAM pipe
descriptor FIFO. It does not touch modem-owned IPA memory or modem pipe
state, so it cannot cross the XPU / TrustZone boundary. On this hardware,
any AP attempt to manipulate modem-owned state faults into the secure
world and triggers a **hard power-off** on a fuse-blown retail device —
that is exactly the boundary this design stays inside.

## Two cases, one safe action (no detection needed)

| Case | What `sps_get_iovec()` returns | Outcome |
|---|---|---|
| **Lost EOT (AP-side)** | the completed iovecs | harvest drains them -> `outstanding_pkts` drops -> queue wakes -> **UL resumes** |
| **Modem hang (modem-side)** | `iov.addr == 0` (nothing) | harvest finds nothing -> `outstanding_pkts` unchanged -> queue stays stopped -> **degrades gracefully, no crash** |

The same action is correct in both cases: it recovers the AP-recoverable
stall and is a harmless no-op for the unrecoverable one.

## Implementation

### `ipa_dp.c` — new in-module primitive

`int ipa2_tx_dp_kick_stalled_pipe(enum ipa_client_type dst)` replicates the
`SPS_EVENT_EOT` branch of `ipa_sps_irq_tx_notify()` for `dst`'s system
pipe:

- resolve `sys` via `ipa2_get_ep_mapping(dst)`; bail if invalid / not set up
- `IPA_ACTIVE_CLIENTS_INC_SIMPLE()` — the clock may be gated at idle when
  the watchdog fires; vote it on for the reconfig
- if `curr_polling_state` is already 1, a real EOT raced us — return 0
- `sps_get_config` -> set `SPS_O_AUTO_ENABLE | SPS_O_ACK_TRANSFERS |
  SPS_O_POLL` -> `sps_set_config`
- `atomic_set(&sys->curr_polling_state, 1)` then `queue_work(sys->wq,
  &sys->work)` — `ipa_handle_tx()` takes its own clock vote for the harvest
- `IPA_ACTIVE_CLIENTS_DEC_SIMPLE()`; return 1

Single module (`ipa-driver.ko`), so no `EXPORT_SYMBOL` — a prototype in
`ipa_i.h` is enough for `rmnet_ipa.c` to call it.

### `rmnet_ipa.c` — watchdog handler + bounded recovery

- `ipa_wwan_tx_timeout()` no longer just logs: if not in SSR and not past
  the give-up threshold, it `schedule_work(&ipa_tx_stall_work)` (the
  harvest must run out of timer context).
- `ipa_tx_stall_recover()` calls
  `ipa2_tx_dp_kick_stalled_pipe(IPA_CLIENT_APPS_LAN_WAN_PROD)` (the bulk-UL
  egress client) and tracks progress against the previous tick's
  `outstanding_pkts`:
  - count decreasing / a kick that found work -> reset the fail counter
  - no progress across ticks -> increment; past `MODEM_THRESH` log
    "looks modem-side, not AP-recoverable"; past `GIVEUP` stop kicking and
    await SSR/reboot (later: escalate to a QMI bearer re-establish uevent).
- `apps_ipa_tx_complete_notify()` clears the fail counter on any genuine
  completion (gated, so the hot path only writes when a stall was active).

### Non-goals (deliberate)

- Does **not** touch modem-owned state (XPU-safe; respects the hard-reset
  boundary).
- Does **not** reset/zero `outstanding_pkts` (no underflow; the decrement
  is driven by real completions).
- Does **not** unregister/re-register the driver or netdev (respects the
  single-module / `insmod` netdev-creation fragility that defanged SSR).
- Does **not** call SSR.

## Relationship to SSR (two independent triggers, not a sequence)

This recovery does **not** replace, wrap, or sequence with SSR. The two are
separate mechanisms on different triggers, and the SSR path
(`ssr_notifier_cb`) is left untouched by this patch:

| Mechanism | Trigger | Recovers |
|---|---|---|
| This AP-local recovery | netdev **watchdog** (`tx_timeout`, ~1 s of a stuck queue) | lost-EOT (AP-side) stall |
| SSR | **modem** subsystem-restart notifications (`SUBSYS_*`) | a real modem crash/restart |

The only coupling is in `ipa_wwan_tx_timeout()`:

- **SSR in progress** (`is_ssr` set) -> the watchdog **stands down**
  (`return`) and lets SSR own the reset. Ours yields *to* SSR, it does not
  run before it.
- **No modem crash** (the common case) -> SSR is never triggered; only this
  recovery runs. It either fixes a lost-EOT stall or, after
  `IPA_TX_STALL_GIVEUP` (~20 s) of no progress on a modem-side stall, stops
  and leaves the rest to SSR/reboot.

So the only sense in which "ours goes first" is for the AP-recoverable case:
we try for ~20 s, and only what we *cannot* fix (a genuine modem-side hang)
falls through to SSR/reboot. It is not an ordered fallback on one trigger —
each handles its own case, and ours yields where they overlap.

Caveat: on mainline q6v5 the SSR path is largely unreliable / defanged (see
the main doc — `is_ssr` was removed because it got stuck; `AFTER_POWERUP` is
not reliably emitted). In practice, for the common AP-side stall this
recovery is the only thing that actually runs; SSR as a backstop is mostly
theoretical until that path is fixed on mainline.

## Resolved implementation questions

All three were reviewed against the code; the current patch is correct and
needs no change. Kept here with the reasoning so they are not re-opened.

1. **Clock-vote window** between `queue_work` and `ipa_handle_tx` (both
   vote) — **RESOLVED: keep as-is.** `ipa_handle_tx()` takes its own
   `IPA_ACTIVE_CLIENTS_INC_SIMPLE()` (ipa_dp.c) *before* any HW access, so
   no register/SPS touch ever happens on a gated clock. The reconfig runs
   under our vote; the harvest under the work's vote. The only effect of
   the brief gap is a possibly-redundant clock flap in an already-rare
   path (and during a real stall the IPA_RM/inactivity vote tends to hold
   the clock on anyway). Our `INC`/`DEC` is balanced — no leak.
2. **Race with a real EOT notify** — **RESOLVED: the lock-free
   `curr_polling_state` atomic guard is sufficient; no `sys->spinlock`
   needed.** Verified three ways:
   - `sps_set_config()` / `sps_get_iovec()` serialize per pipe inside the
     SPS driver via `sps_bam_lock()` ->
     `spin_lock_irqsave(&bam->connection_lock)` (`drivers/platform/msm/sps/sps.c`),
     so two concurrent reconfigs cannot corrupt the pipe — the second just
     re-applies the same POLL config.
   - `sys->work` is non-reentrant (the workqueue API runs a given
     `work_struct` on only one CPU at a time), and `queue_work()` collapses
     or serializes a duplicate, so two `ipa_handle_tx()` never run
     concurrently on one pipe.
   - the `head_desc_list` pop in `ipa_wq_write_done_common()` is under
     `sys->spinlock` and in-order, so each descriptor is freed exactly once
     even if a real harvest and our kick interleave.
   This matches the vendor notify, which is also lock-free here.
3. **`netif_trans_update` after a kick** — **RESOLVED: do not touch the
   trans timestamp.** Letting the watchdog re-fire every `watchdog_timeo`
   (1 s) while stalled is the intended behaviour: it keeps re-arming the
   harvest, is bounded by `IPA_TX_STALL_GIVEUP` (~20 s) and rate-limited in
   logging, and does not mask the stall. Updating the timestamp would hide
   a genuine stall from the watchdog.

## Validation

1. **Normal traffic**: recovery never fires (`tx_stall_fails == 0`); no
   measurable perf impact on a long DL/UL.
2. **Safety test (critical)**: a temporary debug knob that calls
   `ipa2_tx_dp_kick_stalled_pipe()` during active UL must NOT cause a hard
   power-off — proving the path is AP-local.
3. **Stall injection** (proxy, since a clean lost-EOT is hard to inject):
   saturate UL, drop the bearer mid-stream (airplane mode). Observe: queue
   stops -> watchdog fires -> harvest armed -> either UL resumes (AP-side)
   or logs "modem-side" and degrades — **no kernel freeze, no reset**.
4. **A/B vs. today**: a transient AP-side stall that currently needs a
   reboot should now self-heal.
