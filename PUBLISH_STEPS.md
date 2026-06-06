# Publishing checklist

Three steps: (1) push repo to GitHub, (2) cross-post to PostmarketOS
wiki, (3) cross-post to PostmarketOS Matrix / forum. Drafts for
(2) and (3) below.

## 1. Push repo to GitHub

The repo (this directory) is ready on `main`: pristine vendor baseline,
documented script pipeline, vendor-init, full writeup — all
hardware-re-validated (20.6 Mbps DL, 2026-06-06). Two choices for the
push:

### Option A — `gh` CLI (recommended)

```bash
# Install gh once (Alpine: apk add github-cli ; Debian: apt install gh)
# Authenticate (interactive — paste the device code into github.com/login/device):
gh auth login --web

# Create the repo and push in one shot
cd /path/to/postmarketos-x00td-cellular
gh repo create postmarketos-x00td-cellular --public --source=. --push \
   --description "Working mainline cellular bringup for Asus Zenfone Max Pro M1 (X00TD) on PostmarketOS — 20.5 Mbps DL"
```

### Option B — manual via github.com web UI

1. Create empty repo `postmarketos-x00td-cellular` on github.com
   (no README/LICENSE — we ship our own)
2. Then:
   ```bash
   cd /path/to/postmarketos-x00td-cellular
   git remote add origin https://github.com/<your-user>/postmarketos-x00td-cellular.git
   git push -u origin main
   ```

After push, replace `<your-user>` in the wiki + forum drafts below
with the actual URL.

## 2. PostmarketOS wiki edit (draft)

The X00TD device page already exists at:

  https://wiki.postmarketos.org/wiki/Asus_ZenFone_Max_Pro_M1_(asus-x00td)

Add a new section near the bottom (after existing "Status" / "Issues"
sections):

```mediawiki
== Cellular data (experimental) ==

Working mainline cellular data on the IPA v2.6L hardware has been
prototyped — ~20.5 Mbps DL sustained on Vodafone CZ LTE, via a
port of the Asus 4.19 IPA driver (shipped as a pristine vendor
baseline + a documented, idempotent script pipeline) and a small
userspace bearer-activation tool ("vendor-init") replacing
ModemManager for primary cellular.

* Repo: [https://github.com/<your-user>/postmarketos-x00td-cellular postmarketos-x00td-cellular]
* Status: experimental, out-of-tree driver, not in pmaports yet.
* What works: Vodafone CZ LTE 20.5 Mbps DL, single primary bearer.
* What does not: symmetric QMAPv3 UL (opt-in WIP), multi-PDN,
  WLAN/USB offload, NetworkManager/MM bearer activation past the
  detection step.

Anyone reproducing on the same device, different carriers, or
different SDM636/660 hardware — please report on GitHub Issues.
```

## 3. PostmarketOS Matrix / forum cross-post (draft)

The main Matrix room is `#postmarketOS:postmarketos.org`. Suggested
short post:

```
[X00TD] Mainline cellular data working — 20.5 Mbps DL Vodafone CZ LTE

After ~156h of porting+RE work I have working mainline cellular on
the Asus Zenfone Max Pro M1 (asus-x00td, SDM636). Userspace tool
("vendor-init") owns the bearer, no MM. 6.19 kernel with the IPA
v2.6L driver back-ported from the 4.19 vendor sources + a small
rmnet NETIF_F_IP_CSUM patch.

Self-contained package (writeup + vendor baseline + script
pipeline + vendor-init source):
https://github.com/<your-user>/postmarketos-x00td-cellular

Caveats: out-of-tree, only primary cellular DL is production-ready,
QMAPv3 UL is opt-in WIP. Detail in the writeup.

Feedback welcome — esp. reproductions on other SDM6xx devices.
```

For a longer-form thread (matrix doesn't have one, but you can put
this on the PostmarketOS subreddit or as a Discussion on the GitHub
repo), expand each bullet from the writeup TL;DR.
