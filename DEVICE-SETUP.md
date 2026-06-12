# Device setup — bringing up cellular data on the X00TD

Step-by-step for getting cellular data working on a flashed device, plus
the two opt-in tweaks discovered during bring-up: **symmetric QMAPv3 UL**
(UL ~65 KB/s → ~26 Mbit/s) and a **reliable-HTTPS** workaround. For the
*why* behind any of this, see `POSTMARKETOS_X00TD_CELLULAR.md`.

> Tip: the control channel here is SSH over the USB gadget
> (`172.16.42.1`), which is **independent of cellular** — so you can break
> and rebuild the cellular bearer without losing your shell.

---

## 0. Prerequisites

- Device flashed with the ported kernel (`CONFIG_IPA=m`, `CONFIG_RMNET_IPA=m`,
  `CONFIG_SPS=m`, `CONFIG_SPS_SUPPORT_NDP_BAM=y`) and booted into PostmarketOS.
- The `vendor-init` binary on the device (e.g. in `~` or `/usr/local/bin`),
  built from `vendor-init/` (`make`, needs `aarch64-linux-gnu-gcc`).
- `ethtool`, `iproute2`, `curl` present (default on pmOS).
- The modem firmware up: `cat /sys/class/remoteproc/remoteproc*/state` → `running`.

There is **no boot service** for the bearer — you bring it up by running
`vendor-init` yourself (one-shot, holds a socket open to keep the bearer).

---

## 1. Bring up cellular (default: asymmetric — DL ~20 Mbps, UL ~65 KB/s)

`vendor-init` negotiates the bearer over QMI and writes its parameters to
`/run/vendor-init/`; you then apply the IP/route/DNS to `qmapmux0.0`. Save
this as `~/cell-up.sh`:

```sh
#!/bin/sh
cd "$(dirname "$0")"
sudo ./vendor-init -v 2>&1 | tee /tmp/vi.log &     # holds the bearer open
for i in $(seq 1 40); do [ -f /run/vendor-init/bearer_ipv4 ] && break; sleep 1; done
IP=$(cat /run/vendor-init/bearer_ipv4)
GW=$(cat /run/vendor-init/bearer_gw)
PFX=$(cat /run/vendor-init/bearer_prefix)
sudo ip addr flush dev qmapmux0.0
sudo ip addr add "${IP}/${PFX}" dev qmapmux0.0
sudo ip route replace default via "${GW}" dev qmapmux0.0
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
ping -c4 -I qmapmux0.0 8.8.8.8
```

```sh
chmod +x ~/cell-up.sh && ~/cell-up.sh
```

Tearing down: `Ctrl-C` the held `vendor-init` (or `sudo pkill vendor-init`).

---

## 2. (Opt-in) Symmetric QMAPv3 UL — UL ~26 Mbit/s

Makes UL roughly match DL. Requires a **reboot** (the IPA egress pipe reads
the knob only when it is built at boot — it is one-shot; a runtime sysfs
write does **not** rebuild the live pipe).

```sh
# 1. enable the kernel knob at boot
sudo cp patches/ipa-symmetric.conf /etc/modprobe.d/ipa-symmetric.conf
#    (or: echo "options ipa_driver qmapv3_ul_enable=1" | sudo tee /etc/modprobe.d/ipa-symmetric.conf)
sudo reboot

# 2. after boot, bring the bearer up in full-UL mode
#    (same as cell-up.sh but with --full-ul):
cd ~ && sudo ./vendor-init -v --full-ul 2>&1 | tee /tmp/vi.log &
sleep 8
IP=$(cat /run/vendor-init/bearer_ipv4); GW=$(cat /run/vendor-init/bearer_gw); PFX=$(cat /run/vendor-init/bearer_prefix)
sudo ip addr flush dev qmapmux0.0
sudo ip addr add "${IP}/${PFX}" dev qmapmux0.0
sudo ip route replace default via "${GW}" dev qmapmux0.0
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

**Verify (all three must hold):**
```sh
cat /sys/module/ipa_driver/parameters/qmapv3_ul_enable   # → 1
cat /run/vendor-init/wda_ul_proto                        # → 7
ethtool -k qmapmux0.0 | grep tx-checksum-ipv4            # → off
```
The `tx-checksum off` is essential: the IPA UL **csum offload** is broken
on this modem (it computes wrong TCP/UDP checksums → the peer drops every
TCP/UDP packet; ICMP, which isn't offloaded, still pings). `--full-ul`'s
`stage_post_tune` turns it off so the kernel uses a correct software
checksum. The throughput win comes from QMAPv3 UL **aggregation**, not the
offload. If `tx-checksum` reads `on`, force it:
`sudo ethtool -K qmapmux0.0 tx-checksum-ipv4 off tx-checksum-ipv6 off`.

**Revert to asymmetric:**
```sh
sudo rm /etc/modprobe.d/ipa-symmetric.conf
sudo reboot          # the pipe is one-shot — reboot to rebuild it at hdr_len=4
~/cell-up.sh         # plain vendor-init (UL = QMAPv1)
```

---

## 3. (Opt-in) Reliable HTTPS — sidestep the post-quantum ClientHello

A fraction (~6-15 %) of new HTTPS handshakes fail (`decode_error` /
`bad record mac`) because OpenSSL 3.5 offers the post-quantum
`X25519MLKEM768` group by default, inflating the ClientHello to ~1521 B
across **two** TCP segments, which the cellular path occasionally
mishandles. This is a network/cellular-path issue, **not** the driver.
Plain HTTP, downloads, and established connections are unaffected.

Two equal options:

- **Keep PQ + retry (recommended, no change):** the failure is
  intermittent, so a retry succeeds ~99 %+. Most software already retries;
  for scripts use `curl --retry 3 --retry-all-errors`.
- **Disable the PQ hybrid** (small single-packet ClientHello → 100 %): add
  to `/etc/ssl/openssl.cnf` an `ssl_conf = ssl_sect` line in
  `[openssl_init]`, then append:
  ```ini
  [ssl_sect]
  system_default = system_default_sect
  [system_default_sect]
  Groups = x25519:secp256r1:x448:secp384r1:secp521r1
  ```
  (back up first: `sudo cp /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf.bak`).
  Trade-off: drops quantum-resistant KEX (nothing depends on it yet).

---

## 4. Verify the link

```sh
ping -c5 -I qmapmux0.0 8.8.8.8
# DL:
curl -4 -o /dev/null -s -w 'DL %{speed_download} B/s\n' http://cachefly.cachefly.net/100mb.test
# UL (5 MB):
head -c 5242880 /dev/urandom > /tmp/u.bin
curl -4 -o /dev/null -s -w 'UL %{speed_upload} B/s http=%{http_code}\n' -T /tmp/u.bin http://speedtest.tele2.net/upload.php
rm -f /tmp/u.bin
```
Expect ~20 Mbit/s DL in both configs; UL ~65 KB/s asymmetric vs ~26 Mbit/s
symmetric. (Throughput varies with cell load/signal.)

---

## Quick reference

| goal | action |
|---|---|
| cellular up (default) | `~/cell-up.sh` (= `vendor-init -v` + IP/route/DNS) |
| symmetric UL (~26 Mbit/s) | install `ipa-symmetric.conf`, reboot, `vendor-init --full-ul` |
| revert symmetric | remove the conf, reboot, `vendor-init -v` |
| reliable HTTPS | retry (default) or disable PQ in `openssl.cnf` |
| tear down bearer | `sudo pkill vendor-init` |
