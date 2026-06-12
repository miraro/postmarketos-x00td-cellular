# Symmetric QMAPv3 UL — on-device bring-up & bisection test plan

**Goal:** bring UL up in full vendor-parity QMAPv3 (UL=proto 7, IPA egress
pipe `hdr_len=8 + cs_offload_en=UL`, rmnet `egress-mapv4-checksum on`) so
the rmnet 8-byte header and the IPA pipe **match** — then determine whether
symmetric UL works, and if not, *where* the frame dies.

**Why this and not the half-on test:** you cannot half-enable symmetric.
Flipping only the rmnet `egress-mapv4-checksum` flag while the IPA egress
pipe is still `hdr_len=4` (the asymmetric default) makes the modem drop all
UL instantly (8-byte rmnet header vs 4-byte pipe), so no sustained UL flows
to observe. Both sides must change together — which is why the IPA pipe has
to be re-set up with `qmapv3_ul_enable=1`.

**What we already know (don't re-test):**
- The 4-byte UL csum header mainline rmnet produces is **byte-identical**
  to the downstream vendor tree (csum_start_offset, bit layout, complement).
  So the csum-header *content* is not the bug.
- Under normal UL TCP with `NETIF_F_IP_CSUM` on, `ip_summed ==
  CHECKSUM_PARTIAL`, so rmnet **fills** the header (does not memset-zero it).
  The memset path is therefore unlikely — but step 5 verifies it directly.

## Safety

- **SSH is over USB tether (172.16.42.x), not cellular** — breaking UL does
  NOT drop the control channel. This is what makes the test safe.
- Asymmetric (working) config is the fallback: `qmapv3_ul_enable=0` +
  re-run `vendor-init` (no `--full-ul`). Reboot returns to safe defaults.
- Module: `ipa_driver`; param at
  `/sys/module/ipa_driver/parameters/qmapv3_ul_enable`.

## The re-init problem (read first) — **reboot IS required**

The IPA egress pipe is configured in `vendor_auto_ipacm_init_fn`
(`rmnet_ipa.c:4022`), which reads `qmapv3_ul_enable`. Verified in code, the
flag flow makes this **strictly one-shot per module load**:

- `auto_ipacm_init_done` is set to `1` exactly once (`rmnet_ipa.c:4140`)
  and is **never reset to 0** anywhere (confirmed by grep).
- The work fn returns early if the flag is set (`:3982`), and the
  "re-arm" (`:4198`) is `if (!done) schedule(...)` — always false after the
  first run. **The "re-arms post-SSR" comment is wrong**: it never re-runs.

Consequences:
- **`vendor-init` does NOT reconfigure the pipe** — it only switches the
  QMI/WDA commands (ul_proto=7) and the rmnet flag. (Confirmed.)
- **Modem SSR does NOT re-run `auto_ipacm`** — the flag is never cleared.
- So the egress pipe takes `qmapv3_ul_enable` **only at module-load time.**

**Reliable path = reboot** with the param persisted:
```sh
echo "options ipa_driver qmapv3_ul_enable=1" | sudo tee /etc/modprobe.d/ipa-symmetric.conf
sudo reboot
```
Revert also needs a reboot (remove the file first), since the pipe is
one-shot.

**No-reboot alternative (more work, optional):** there is a *second* pipe
config path — `handle_egress_format` (`rmnet_ipa.c:1805`), invoked by the
legacy `RMNET_IOCTL_SET_EGRESS_DATA_FORMAT` ioctl on `rmnet_ipa0`. It
re-creates the egress pipe with `hdr_len=8` **live**. Nothing in the port
calls it (vendor-init uses QMI, post_tune uses netlink). A tiny C tool that
issues that extended ioctl (data flag `RMNET_IOCTL_EGRESS_FORMAT_CHECKSUM |
…_AGGREGATION`) would reconfigure the pipe without a reboot — but it is its
own code path with its own risk; treat as a follow-up, not the first try.

## Procedure

### 0. Baseline (asymmetric, working)
```sh
ethtool -k qmapmux0.0 | grep tx-checksum-ipv4         # expect off (prod)
cat /sys/module/ipa_driver/parameters/qmapv3_ul_enable # expect 0
# quick UL sanity (tele2 PUT) — note the ~65 KB/s baseline
```

### 1. Enable the kernel side (persist + reboot — see "re-init problem")
```sh
echo "options ipa_driver qmapv3_ul_enable=1" | sudo tee /etc/modprobe.d/ipa-symmetric.conf
sudo reboot      # the egress pipe takes the param ONLY at module load
```
(Live `echo 1 > /sys/module/.../qmapv3_ul_enable` does NOT rebuild the
pipe — one-shot. Skip the reboot only if you implement the legacy-ioctl
tool from the "no-reboot alternative" above.)

### 2. After boot: bring up the bearer in full-ul mode (QMI/WDA + rmnet flag)
```sh
sudo vendor-init --full-ul        # WDA ul_proto=7 + post_tune egress-mapv4-checksum on
```

### 3. **VERIFY the pipe actually became hdr_len=8 — do NOT test blind**
This is the gate that the whole session failed to clear before. Confirm:
```sh
# IPA endpoint config dump (find the apps_to_ipa / EGRESS pipe; check hdr_len, cs_offload)
sudo cat /sys/kernel/debug/ipa/ep_reg_dump 2>/dev/null | less   # or ipa/ep_cfg, exact node TBD on-device
# rmnet side:
ethtool -k qmapmux0.0 | grep tx-checksum-ipv4         # MUST be on (else memset path)
# state file written by vendor-init:
cat /run/vendor-init/state | grep -E 'wda_ul_proto|rmnet_data_format'   # ul_proto=7, EGRESS_MAP_CKSUMV4
```
If the egress pipe is **not** hdr_len=8 → re-init didn't take → escalate
(SSR, then reboot). Testing UL before this gate passes is meaningless.

### 4. Functional test
```sh
# does UL work at all now?
curl -T 5mb.bin http://speedtest.tele2.net/upload.php   # throughput, or 100% loss?
ping -c5 8.8.8.8
```
- **Works** → measure UL throughput; compare to asymmetric ~65 KB/s. Done.
- **100% loss** → go to step 5 (bisection).

### 5. Bisection (only if 100% loss)
Capture the framed UL on the **parent** `rmnet_ipa0` (frames there already
carry `[QMAP(4)][csum(4)][IP]`), on a *sustained* UL flow (now possible
because the pipe matches, so frames actually go out):
```sh
sudo tcpdump -i rmnet_ipa0 -nn -x -w /tmp/ul.pcap 'len > 100' &
curl -T 5mb.bin http://speedtest.tele2.net/upload.php & sleep 4; pkill tcpdump
sudo tcpdump -r /tmp/ul.pcap -nn -x | head
```
Check, in order:
1. **csum header (bytes 4-7)** filled (`00 14 8x xx`) vs zeroed
   (`00 00 00 00`). Zeroed ⇒ memset path ⇒ `ip_summed`/feature problem.
2. **QMAP map header (bytes 0-3)** — pad/ctrl, mux_id=1, length field
   (does length include the csum header? off-by-N here = modem drop).
3. **IPA drop / error stats** and dmesg for `ipa`/`rmnet` errors during the
   flow.
4. **modem QMI** data-format response (vendor-init `wda_set` echo) — did the
   modem actually accept ul_proto=7 with csum?
5. If all of the above look correct → diff the on-wire frame byte-for-byte
   against a **vendor-ROM capture** of the same upload (the only remaining
   way to find a subtle framing/aggregation difference).

### 6. Revert (always)
```sh
echo 0 | sudo tee /sys/module/ipa_driver/parameters/qmapv3_ul_enable
sudo vendor-init                 # asymmetric bring-up (UL=5)
ethtool -k qmapmux0.0 | grep tx-checksum-ipv4   # back to off
ping -c3 8.8.8.8                 # UL recovered
# if wedged: reboot returns to safe defaults
```

## Risks
- UL down for the duration; **control plane safe (USB SSH)**.
- Modem SSR / wedged UL pipe may need a reboot to recover — acceptable, the
  asymmetric default is restored on boot.
- Do step 3 (verify pipe) before every functional test — the recurring
  lesson from this port: never measure against an unverified state.
