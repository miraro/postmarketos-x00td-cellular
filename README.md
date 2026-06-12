# postmarketos-x00td-cellular

Working mainline-kernel cellular data on the Asus Zenfone Max Pro M1
(`asus-x00td`, Snapdragon 636 / SDM636) under PostmarketOS.

**Throughput result:** ~**20.5 Mbps DL** sustained over Vodafone CZ LTE.

This repo is the consolidated, community-ready output of ~156 hours of
porting / reverse-engineering work. It contains everything someone with
an X00TD should need to reproduce a working cellular bearer on a
mainline-ish kernel (6.19).

## Contents

```
.
├── POSTMARKETOS_X00TD_CELLULAR.md    ← the full writeup. START HERE.
├── vendor-baseline-4.19/             ← pristine vendor 4.19 sources the
│                                       port transforms (76 files, GPL-2.0,
│                                       byte-identical to lineage-sdm660-22.2).
│                                       Overlay onto your 6.19 tree FIRST.
├── port/                             ← the port itself, as a documented,
│   │                                   idempotent script pipeline:
│   ├── apply-all.sh                  — run everything in order
│   ├── 00-install-port-files.sh      — new/replaced whole files (files/)
│   ├── 05-integrate-mainline-tree.sh — wire msm/ into the upstream build
│   │                                   system, X00TD DTS/defconfig,
│   │                                   upstream-rmnet csum feature flags
│   ├── 10-apply-port-patches.sh      — mechanical 4.19 → 6.x API fixes
│   ├── 20-apply-port-fixes.sh        — bringup-correctness fixes
│   ├── 30-apply-port-features.sh     — datapath/throughput features
│   │                                   (in-kernel IPACM emulation, …)
│   ├── 90-apply-diag-sondy.sh        — OPT-IN bringup diagnostics for
│   │                                   porting to other SDM6xx devices
│   └── files/                        — whole-file artefacts the scripts
│                                       install (Kconfig/Makefile set,
│                                       compat shim, icc translator, stub
│                                       headers, reference DTS, defconfig)
├── patches/                          ← optional extras on top of the port:
│   ├── sdm660-ipa-port-6.19-powersave.patch       (dynamic clock scaling)
│   ├── sdm636-asus-x00td-ipa-powersave-dts.patch  (drop the DT clock pin)
│   ├── sdm636-asus-x00td-ipa-powersave-dtbo.patch (…or as a DT overlay)
│   ├── ipa-tx-stall-recovery.patch                (opt-in TX-watchdog stall
│   │                                               recovery; + .DESIGN.md and
│   │                                               -debugknob.patch companions)
│   └── *.TESTPLAN.md, powersave-validate.sh        (validation helpers)
├── dts/sdm636-asus-x00td-ipa-powersave.dtso       (the overlay source)
└── vendor-init/                       ← userspace bearer-activation tool
    ├── Makefile
    ├── vendor-init.{c,h}             — main / stage dispatcher
    ├── qrtr.{c,h}                    — AF_QIPCRTR helpers
    ├── qmi.{c,h}                     — TLV encode/decode
    ├── log.{c,h}                     — structured logging
    ├── state.{c,h}                   — /run/vendor-init/ state files
    └── stage_*.c                     — DMS / NAS / DPM / WDA / DSD /
                                        BIND_MUX / WDS_START / fff2 /
                                        iattach / post_tune
```

## Quick start

Two kernel steps + one userspace step:

```bash
# 1. Overlay the pristine vendor 4.19 baseline onto your mainline 6.19 tree
KERNEL_TREE=/path/to/your/qcom-sdm660-6.19-kernel
cp -rT vendor-baseline-4.19/ "$KERNEL_TREE"/

# 2. Run the port pipeline (idempotent — safe to re-run)
./port/apply-all.sh --root "$KERNEL_TREE"

# 3. Configure / build / flash with:
#    CONFIG_IPA=m, CONFIG_RMNET_IPA=m, CONFIG_SPS=m,
#    CONFIG_SPS_SUPPORT_NDP_BAM=y, CONFIG_IPA_DEBUG=y
# (X00TD_defconfig is installed by the pipeline; full kconfig + DTS
#  reference in POSTMARKETOS_X00TD_CELLULAR.md)
```

Then build & run `vendor-init` on the device to activate the bearer.

Every script step prints exactly what it changes and why, skips what is
already applied, and aborts loudly on unexpected tree state. The
pipeline is validated end-to-end: pristine baseline + scripts compiles
cleanly (zero warnings) with the modern kbuild default-error set, and
the resulting kernel was re-validated on the device — 20.6 Mbps DL
sustained on Vodafone CZ LTE (2026-06-06), matching the original
bringup figure.

Porting to another SDM6xx device? Apply `port/90-apply-diag-sondy.sh`
on top to get the curated diagnostic-probe set ("sondy") that carried
the original bringup — see the writeup's *Debug instrumentation*
section. Never ship a production build with it.

Full instructions, prerequisites, DTS reference, ModemManager
alternative path, throughput tuning, known caveats, and what is *not*
ported are in **`POSTMARKETOS_X00TD_CELLULAR.md`**.

## Status

- Production-OK for the **primary cellular DL path** (20.5 Mbps Vodafone CZ LTE).
- Symmetric QMAPv3 UL is **opt-in / WIP** (`qmapv3_ul_enable=0` default).
- The IPA driver itself is **out-of-tree** and **not upstream-ready**;
  it ports a 4.19 vendor blob forward, with shim layers for mainline
  subsystems it predates.
- The `vendor-init` userspace tool and the rmnet `NETIF_F_IP_CSUM`
  feature-flag change (done by `05-integrate-mainline-tree.sh`) are in
  better shape to share standalone.
- The optional power-save patches (dynamic IPA clock scaling) are
  **not hardware-tested** — re-measure throughput after applying.

See "Known caveats" in the writeup for the long form.

## Troubleshooting

### Intermittent HTTPS/TLS handshake failures (post-quantum ClientHello)

**Symptom:** a fraction of *new* HTTPS connections fail with
`decode_error` / `bad record mac` / `record layer failure`, while plain
HTTP, downloads, and already-established TLS connections are fine. Tends
to hit Cloudflare-fronted sites; `curl` without retry shows occasional
errors.

**Cause (root-caused on-device):** OpenSSL 3.5 offers the post-quantum
`X25519MLKEM768` key exchange **by default**, which inflates the TLS
ClientHello to ~1521 bytes — it no longer fits one packet and is split
across **two TCP segments** (≈1388 + ≈133). The cellular data path
intermittently mishandles that two-segment ClientHello, so the server
gets a malformed record. It is **not** a driver/data-plane bug: the data
plane is byte-perfect, and over a non-cellular path (e.g. USB reverse
tether) the *same* handshake is 100 % reliable. Servers that don't
negotiate the PQ hybrid keep a small single-packet ClientHello and are
unaffected — which is why this only surfaced recently (PQ KEX is new).
Full analysis: `POSTMARKETOS_X00TD_CELLULAR.md` → *Known caveats →
TLS/HTTPS handshake*.

**Two equally valid fixes.** The failure is *intermittent* — ~85 % of PQ
handshakes already succeed; only the two-segment split is fragile (an
interleaved test confirms a small single-segment ClientHello is 100 %
while the large one is ~85 % in the *same* window). So pick either:

#### Option A — keep post-quantum, rely on retry (recommended)

No system change, no security tradeoff: just retry a failed handshake.
85 % first-try → **~99.9 % after 1–2 retries**, and you keep
quantum-resistant key exchange (which only gets more relevant over time).
Most software already retries (browsers, `apk`/`apt`, `git`, most apps).
For your own scripts:

```sh
curl --retry 3 --retry-connrefused --retry-all-errors https://example.com/
```
or wrap the connection in a small retry loop. This is what the device
currently ships with (PQ left enabled).

#### Option B — disable the PQ hybrid system-wide

Forces a small single-packet ClientHello → **100 % first-try**, at the
cost of dropping PQ key exchange (classical X25519 / P-256 remain, and are
secure). Verified on-device: default ClientHello 1521 B / 2 segments →
517 B / 1 segment, and a 20×-loop to Cloudflare goes from ~15 % failures
to **20/20**.

1. Back up:
   ```sh
   sudo cp /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf.bak-prePQ
   ```
2. In the `[openssl_init]` section of `/etc/ssl/openssl.cnf`, add an
   `ssl_conf` line:
   ```ini
   [openssl_init]
   providers = provider_sect
   ssl_conf  = ssl_sect
   ```
3. Append to the end of the file:
   ```ini
   [ssl_sect]
   system_default = system_default_sect

   [system_default_sect]
   Groups = x25519:secp256r1:x448:secp384r1:secp521r1
   ```
   (The `Groups` list omits every `*MLKEM*` group — that is what disables
   PQ.) No service restart needed; new connections pick it up immediately.
   Revert with `sudo cp /etc/ssl/openssl.cnf.bak-prePQ /etc/ssl/openssl.cnf`.
   Per-app instead of system-wide: `curl --curves X25519 …`.

**Verify (either option):**
```sh
python3 - <<'EOF'
import socket, ssl
ip = "104.16.133.229"          # a Cloudflare edge IP
c = ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE
ok = 0
for _ in range(20):
    try:
        s = socket.create_connection((ip, 443), timeout=8)
        c.wrap_socket(s, server_hostname="cloudflare.com").close(); ok += 1
    except Exception:
        pass
print(f"{ok}/20 handshakes OK")   # ~17/20 with PQ+no-retry, 20/20 with Option B
EOF
```

> Underlying issue is in the cellular path (modem firmware or carrier
> handling of the 2-segment ClientHello), not the port. Whether it is the
> modem or Vodafone would need a stock-ROM / second-phone A/B on the same
> SIM.

## Hardware tested

- Device: Asus Zenfone Max Pro M1 (`asus-x00td`)
- SoC: Snapdragon 636 (SDM636), IPA v2.6L
- Carrier tested: Vodafone CZ (LTE)
- Userspace: PostmarketOS edge (Alpine-based)

## Reproducibility on other SDM6xx

The X00TD work *should* port to other Snapdragon 636 / 660 devices
with minor DTS adjustments. The writeup calls out the DTS gotchas
that tend to bite porters (including two regulators that must be
`regulator-always-on`). We have not tested any other devices.

## License

- Kernel sources, scripts and patches: **GPL-2.0** (matching
  surrounding files).
- `vendor-init`: **GPL-2.0**.

## Reporting back

If you reproduce this on the same device, on a different SDM6xx
device, or on a different carrier — please open a GitHub issue with
the result. Negative results are useful too.

## Acknowledgments

- Sireesh Kodali (2021 RFC) and Alejandro Tafalla (msm8953 IPA) — the
  initial ipa-legacy mainline porting work this builds on.
- aboothahir — sdm660-6.7.y-ipa branch that was the immediate starting
  point.
- libqmi project — the canonical QMI service spec used to byte-shape
  every `vendor-init` message.
- ModemManager `mm-shared-qmi.c` — clean reference for NAS RAT setup.
- Qualcomm CodeAurora `qcril-hal` open-source pieces that complement
  the closed `libril-qc-hal-qmi.so`.
- Vodafone CZ — for surviving empirical testing without cancelling the
  SIM.
