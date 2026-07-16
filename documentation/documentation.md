# ROTA — Remote pull-OTA for the Greenhouse Controller

Operator & administrator reference for **ROTA**, the internet-pull firmware-update
system for the greenhouse ventilation controller. This document describes the
whole chain — how a release travels from a developer's machine to a field unit,
who the actors are, the security model, how to set it up, how to run it day to
day, and how to manage units.

- **Wire contract:** v1.1, frozen as tag `rota-contract-v1.1`. The normative spec
  is `design/rota_tds.md` §4 in the firmware repo (`pe1mew/greenhouse-Controller`);
  this document is the operator-facing companion, not a substitute for the TDS.
- **Server side (this repository):** the PHP server behind nginx on the VPS —
  `public/manifest.php`, `public/download.php`, and the store tooling in `tools/`.
- **Firmware side (separate repo `pe1mew/greenhouse-Controller`):** task **T16**,
  `firmware/src/ota_client/ota_client.cpp` (from release **2.2.0**).
- **Scope note:** ROTA is *pull* only — units reach out to the server; the server
  never connects to a unit. Firmware and web assets are always applied **as a
  pair**.

---

## Table of contents

1. [What ROTA is](#1-what-rota-is)
2. [The delivery chain](#2-the-delivery-chain)
3. [Actors and responsibilities](#3-actors-and-responsibilities)
4. [The three-repository split](#4-the-three-repository-split)
5. [The wire contract — how a check-in works](#5-the-wire-contract--how-a-check-in-works)
6. [Security model](#6-security-model)
7. [Channels and version resolution](#7-channels-and-version-resolution)
8. [The configuration files](#8-the-configuration-files)
9. [Setting it up](#9-setting-it-up)
10. [Daily operation — publishing and promoting releases](#10-daily-operation--publishing-and-promoting-releases)
11. [Managing units — add, assign, pin, disable, remove](#11-managing-units--add-assign-pin-disable-remove)
12. [Device-side behaviour](#12-device-side-behaviour)
13. [Verifying and troubleshooting](#13-verifying-and-troubleshooting)
14. [Reference](#14-reference)

---

## 1. What ROTA is

The controller has always supported **local push-OTA**: someone on the same LAN
runs `bin/ota_push.py`, which POSTs a firmware image to the unit's
`/api/ota/firmware` endpoint. That path still exists and is the recovery route,
but it needs a person on the network.

**ROTA adds a pull path.** Each unit, on its own schedule, makes an authenticated
HTTPS request to a central server and asks "is there a newer release for me?" If
so it downloads, verifies, and installs it — during a night-time window, only
when the greenhouse is idle. Nothing has to reach *into* the unit, so a unit
behind NAT (like production **5C88**) can still be updated once the pull path is
enabled.

Two channels stage every rollout: a release goes to **soak** first (the bench/dev
unit pulls and runs it), and only after a human is satisfied is it **promoted**
to **mainstream** (production). A per-unit **pin** can freeze any unit on a
specific version regardless of the channel.

### Field units and their roles

| Unit | Role | ROTA channel |
|---|---|---|
| **FDA4** | ROTA dev / test / **soak** bench unit | `soak` |
| **5C88** | **Production** (Herenboeren Willemshoeve, Soest); behind NAT, on-site updates only until a remote path is enabled | `mainstream`, usually **pinned** |
| **2344** | Plant-model training soak — **MUST NEVER run ROTA firmware** | *(excluded — no registry row, ROTA disabled)* |

Current addresses/access routes live in the operator's records, not in this repo.
The one hard safety rule: **2344 is off-limits to ROTA firmware.**

---

## 2. The delivery chain

The recommended path is **pull-based via GitHub Releases** — the developer never
pushes to the VPS, and no VPS-write credential is ever placed on GitHub.

```
 Developer / operator  (dev machine, firmware repo)
   |  1. bin/build_release.ps1            -> bin/<version>/{.bin, .zip}
   |  2. python bin/rota_release.py release <version>
   v
 GitHub Releases   (pe1mew/greenhouse-Controller, PUBLIC)
   |  tag v<version>; assets: greenhouse-controller-<version>.bin,
   |                          web-assets-<version>.zip,
   |                          manifest-<version>.json
   |  3. VPS cron pulls it (tokenless HTTPS GET)
   v
 FOTA server VPS   (ota.rfsee.net)
   |  tools/ota-store-update.sh:  verify sha256 + size  ->  stage into
   |     ota-store/releases/<version>/  ->  point channels/soak.json
   |  store:  /var/www/ota-store/  (releases, channels, devices.json,
   |                                checkins.csv, nonce-cache/)
   |  4. device checks in over HTTPS (cert-pinned) with X-OTA-Auth HMAC
   v
 Field device   (ESP32-S3, task T16)
   |  GET /manifest.php?fw=<running>  ->  200 manifest (server resolves the
   |     offer from pinned_version | channel[unit_type])
   |  GET /download.php?file=fw   + file=assets  ->  verify sha256 (both)
   |  flash inactive bank  ->  apply inside night window AND quiet gate
   |  reboot  ->  confirm fw_ver == asset_version
   v
 Running the new paired release
```

There is also a **direct push** variant: `rota_release.py publish` scp's the
release straight into `ota-store/` and points soak, skipping GitHub. Use it for a
local store or when GitHub is not in the loop; the GitHub `release` path is
preferred because it keeps write credentials off the VPS.

---

## 3. Actors and responsibilities

| Actor | Where it runs | Responsibility |
|---|---|---|
| **Operator / developer** | Dev machine (firmware repo) | Builds releases, runs `rota_release.py`, edits the device registry, promotes soak→mainstream, provisions units. |
| **`rota_release.py`** | Dev machine | Computes SHA-256 + size, assigns the next `seq`, writes `manifest-<version>.json`, and either creates a GitHub Release (`release`) or scp's to the store (`publish`); `promote` points mainstream; `status` prints channels. |
| **GitHub Releases** | github.com (public repo) | Neutral, tokenless distribution point. The tag `v<version>` on `main`/`rota` carries the three assets. |
| **Retriever** (`ota-store-update.sh`) | VPS, cron `*/10` | Pulls the newest GitHub Release, checks it is a ROTA release (has a `manifest-*.json` asset), verifies sha256+size, stages atomically, and points `channels/soak.json` (never mainstream). |
| **FOTA server** (`manifest.php`, `download.php`) | VPS, PHP-FPM behind nginx | Authenticates each request, resolves which release a unit is offered, records check-ins, and streams artefacts via nginx `X-Accel-Redirect`. Never initiates contact. |
| **Field device** (task **T16**) | ESP32-S3 in the greenhouse | On a schedule: authenticates, checks the manifest, downloads + verifies, and applies inside the night window when idle. Owns the anti-downgrade high-water mark. |

Trust boundary: **the only instructions a unit acts on are a correctly-signed,
newer, integrity-checked manifest it fetched itself.** Everything else — the
GitHub Release, the store on disk, the channel files — is upstream plumbing that
cannot make a unit install anything without a valid manifest + artefacts that
pass the device's own checks.

---

## 4. The three-repository split

ROTA is deliberately spread across three repos so that no secret ever lives
beside code (TDS **R-T06**, **R-T07**):

| Repo | Contents | Public? |
|---|---|---|
| **`greenhouse-Controller`** (firmware) | Firmware (T16 client), `bin/rota_release.py`, the TDS/wire contract, release master copies in `bin/<version>/`. | Public |
| **`greenhouse-Controller-FOTA-server`** (this repo) | The PHP server, nginx vhost, store tooling (`init-store.sh`, `ota-store-update.sh`, `prune-releases.sh`), bootstrap docs. **No secrets, no `devices.json`, no artefacts** — `.gitignore` + CI enforce this. | Public |
| **Operator's secret store** (private) | Per-unit `ota_secret`s, the server TLS cert/key, GitHub tokens, VPS deploy key. Referenced by *path* only. | Private |

The wire contract (`design/rota_tds.md` §4) is the interface between the firmware
and server repos; the server repo pins the contract version it implements.

---

## 5. The wire contract — how a check-in works

Base URL: **`https://ota.rfsee.net/`** (a dedicated vhost, separate from the
status site). Two endpoints, both `GET`, both require the `X-OTA-Auth` header.

| Request | Purpose |
|---|---|
| `GET /manifest.php?fw=<running-version>[&res=<a>.<b>]` | Check-in. `fw` = the version the unit is running; optional `res` = its last audit outcome (`value_a.value_b`). Returns the **full resolved manifest** at HTTP 200 — the server does *not* decide "newer"; the device does. |
| `GET /download.php?file=fw\|assets&v=<version>` | Fetch one artefact of a release. The filename is taken from that release's manifest, never from the client. |

### The `X-OTA-Auth` header

```
X-OTA-Auth: <id>:<ts>:<nonce>:<mac>
```

| Field | Form | Meaning |
|---|---|---|
| `id` | 12 lowercase hex | The unit's full WiFi-STA MAC, no separators (e.g. `a0b1c2d3e4f5`). This is the ROTA identity **and** the registry key. |
| `ts` | Unix seconds (decimal) | Request time. The device refuses to build the header before its clock is SNTP-synced. |
| `nonce` | 16 lowercase hex | 8 random bytes, fresh per request. |
| `mac` | 64 lowercase hex | `HMAC-SHA256(secret, "id\|ts\|nonce\|request_uri")` where `request_uri` is the exact path+query, e.g. `/manifest.php?fw=2.2.0`. |

Server verification (in `rota_lib.php → rota_authenticate()`):

1. Header splits into exactly 4 colon-separated parts of the right shape, or → **204**.
2. Clock skew `|now − ts|` must be ≤ **300 s**, or → **204**.
3. The unit must exist in `devices.json`, be `enabled: true`, and have a `secret`, or → **204**.
4. `hash_equals(HMAC(secret, "id|ts|nonce|uri"), mac)` — constant-time, or → **204**.
5. The `nonce` must be first-seen within the **600 s** replay window, or → **204**.

### Response codes

| Code | Meaning |
|---|---|
| **200** | Authenticated. `manifest.php` returns the resolved manifest verbatim; `download.php` streams the artefact. |
| **204** | **Authentication failed** — empty body, silent drop (R-A08). A wrong secret, bad clock, replayed nonce, disabled/unknown unit all look identical: nothing. A valid client never receives 204. |
| **404** | Authenticated but nothing to serve: `no_release` (no channel/pin resolves), `manifest_missing`, `bad_request`, `unknown_version`, `artefact_missing`. |

The silent-204 posture means a prober learns nothing — it cannot distinguish "wrong
secret" from "unknown unit" from "clock skew".

### The manifest

`manifest.php` returns the release's stored `manifest-<version>.json` unchanged:

```json
{
  "version": "2.2.12",
  "seq": 38,
  "unit_type": "ghc1",
  "min_version": "2.1.0",
  "key_id": "",
  "fw_file": "greenhouse-controller-2.2.12.bin",
  "fw_sha256": "…64 hex…",
  "fw_size": 1360544,
  "assets_file": "web-assets-2.2.12.zip",
  "assets_sha256": "…64 hex…",
  "assets_size": 108073,
  "released_at": "2026-07-14T12:00:00Z"
}
```

| Field | Meaning |
|---|---|
| `version` | Offered release (SemVer). |
| `seq` | **Strictly-monotonic** release counter — the anti-downgrade high-water value. |
| `unit_type` | Selects the channel pointer (e.g. `ghc1`). |
| `min_version` | Floor: a unit running older than this refuses the jump and asks for a manual step. |
| `key_id` | Reserved for future firmware signing (empty today). |
| `fw_file` / `fw_sha256` / `fw_size` | Firmware artefact name, hash, byte size. |
| `assets_file` / `assets_sha256` / `assets_size` | Web-assets ZIP name, hash, byte size. |
| `released_at` | ISO-8601 UTC release time. |

---

## 6. Security model

ROTA's security rests on four legs — **transport**, **request authentication**,
**payload integrity**, and **isolation** — plus a reserved hook for future
signing.

**Transport — pinned TLS (R-A02/03/04).** The device trusts exactly one
certificate, pinned on the unit; it does not use a CA bundle. A **self-signed**
cert is fine *because* it is pinned — a MITM presenting a "valid" public-CA cert
for the same hostname is rejected. The cert is a PEM (device store limit ~2 KB),
either the firmware's embedded default (`OTA_DEFAULT_CERT_PEM`) or one uploaded
through the admin GUI.

**Request authentication — per-unit HMAC (R-A05/06/07).** Every request carries
`X-OTA-Auth` (see §5). The key is a dedicated per-unit **`ota_secret`** (16–64
chars), independent of the status-site secret. The ±300 s skew window and the
600 s nonce cache together stop replay; `hash_equals` stops timing attacks.

**Payload integrity + anti-downgrade (R-C05, R-V01/02/03).** The device downloads
both artefacts fully into PSRAM and checks **size and SHA-256** against the
manifest *before any flash write*. It then applies two independent version gates:

- the offered `version` must be strictly newer than what it runs (SemVer), **and**
- the manifest `seq` must be strictly greater than the persisted high-water mark
  (NVS `fw_hiwater`), which is written *before* reboot — so a previously-installed
  or replayed manifest is refused even after a power cycle, and even if the version
  string were tampered with.
- `min_version` is a separate floor gate for jumps that need an intermediate step.

**Isolation (R-S02/05/07).** The store lives **outside the webroot**; only the two
PHP scripts are reachable, and artefact bytes are served by nginx via
`X-Accel-Redirect` after PHP authenticates (PHP never streams the file). Registry
writes are atomic (`flock` + tmp-write + `rename`), so a killed writer never
corrupts `devices.json`. On the pull side, the VPS fetches from GitHub with
read-only access — **no VPS-write key is ever on GitHub**.

**Secret hygiene (R-A09).** Secrets and private keys never appear in logs, status
JSON, GUI read-back, or the SD audit. The device GET endpoints report only
booleans — `secret_set`, `cert_custom` — never the values. `devices.json` (which
*does* hold the secrets) is git-ignored and lives only on the VPS at mode 0640.

**Reserved: firmware signing (R-A10).** `key_id` is carried in the manifest but
not yet verified. Until signing lands, **write access to a GitHub Release equals
the ability to ship firmware to the soak bench** — so protect the release/tag
path, and never auto-point mainstream.

---

## 7. Channels and version resolution

A unit's offered version is resolved **entirely on the server**, from the unit's
registry row and the channel files. The device sends only its running version and
its identity — it does not know or report its channel.

```
offer =  devices.json[id].pinned_version            if that is a valid version
         else  channels/<channel>.json[unit_type].version    (channel defaults to "mainstream")
```

- **`soak`** — the staging channel. The retriever points it automatically when a
  full GitHub Release lands. The bench unit (FDA4) sits here.
- **`mainstream`** — production. Only the manual `promote` step points it. A soak
  release never changes mainstream implicitly.
- **`pinned_version`** — a per-unit override that ignores the channel entirely.
  Production (5C88) stays pinned to a known-good version and is only unpinned
  on-site after a good soak cycle (R-T05).

If neither a pin nor a channel entry resolves, the unit gets **404 `no_release`** —
harmless; it just keeps running what it has.

---

## 8. The configuration files

There are five kinds of config. Two live on the **device** (NVS), three live on
the **VPS** (in the store or as env files). The per-unit secret lives in **two
places at once** and the two copies must match: as `secret` in the server's
`devices.json`, and as `ota_secret` in the device's NVS.

### 8.1 `devices.json` — the device registry (VPS: `ota-store/devices.json`)

The most important file to get right. A **JSON object keyed by the 12-hex MAC**
(there is no `id` field — the key *is* the id). Mode 0640, www-data-readable,
git-ignored, VPS-only.

```json
{
  "a0b1c2d3e4f5": {
    "secret": "…64 hex chars…",
    "unit_type": "ghc1",
    "channel": "soak",
    "pinned_version": null,
    "enabled": true,
    "last_seen": null,
    "fw_ver": null,
    "_note": "FDA4 soak bench"
  }
}
```

| Field | Who writes it | Notes |
|---|---|---|
| *(object key)* | operator | 12 lowercase hex, the unit's full MAC. |
| `secret` | operator | The per-unit HMAC key. **Field name is `secret`, not `ota_secret`.** Must equal the device's NVS `ota_secret`. Auth fails if empty/absent. |
| `unit_type` | operator | e.g. `ghc1`; indexes the channel file. |
| `channel` | operator | `soak` or `mainstream`. Absent ⇒ defaults to `mainstream`. |
| `pinned_version` | operator | A version string to pin, or `null` to follow the channel. Overrides the channel when set. |
| `enabled` | operator | **Required.** `false` ⇒ the unit is silently rejected (204) and offered nothing. |
| `last_seen` | **server** | ISO-8601 UTC of the last check-in. Seed as `null`. |
| `fw_ver` | **server** | Last-reported running version. Seed as `null`. |
| `_note` | operator | Free-text (underscore-prefixed). Ignored by code. |

The server only ever merges `last_seen` and `fw_ver`; every other field is yours
to maintain. See §11 for safe editing.

### 8.2 `channels/soak.json` and `channels/mainstream.json` (VPS: `ota-store/channels/`)

An object keyed by `unit_type`, whose value is an object with a `version` key —
the version is **one level down**, not a bare string:

```json
{
  "ghc1": { "version": "2.2.12" }
}
```

`soak.json` is written by the retriever; `mainstream.json` by `rota_release.py
promote`. Both are seeded `{}` by `init-store.sh`. You rarely edit these by hand
(the tooling does), but you can, to force a channel.

### 8.3 `manifest-<version>.json` (VPS: `ota-store/releases/<version>/`)

Authored by `rota_release.py` (schema in §5). It is the authority for a release's
filenames, hashes, sizes, and `seq`. The master copy is also committed to the
firmware repo at `bin/<version>/manifest-<version>.json`, which is how `seq`
stays monotonic across machines.

### 8.4 Device NVS config (namespace `system`, set via `POST /api/ota/config`)

Admin-only; the farmer role gets 403. GET returns everything except the secret
(reported as `secret_set`) and the cert (reported as `cert_custom`).

| Key | Default | Range | Meaning |
|---|---|---|---|
| `ota_enable` | `0` | 0/1 | Master switch. `0` = behaves exactly like pre-ROTA firmware (no server contact). |
| `ota_check_h` | `24` | 1–168 | Hours between checks (±10 % jitter applied). |
| `ota_url` | `""` | `https://` only, ≤128 | Server base URL, e.g. `https://ota.rfsee.net`. |
| `ota_secret` | `""` | 16–64 chars | Per-unit HMAC key; must equal `devices.json[id].secret`. Write-only (never read back). |
| `ota_win_lo` | `2` | 0–23 | Night-window start hour (local). |
| `ota_win_hi` | `4` | 0–23 | Night-window end hour (local). `lo == hi` disables the window (apply any hour). |
| `ota_cert` | *(embedded)* | PEM ≤ ~2 KB | Pinned server cert; falls back to the firmware's embedded default. (TDS quotes ≤ 4 KB; the device store limit is ~2 KB.) |

`fw_hiwater` (also namespace `system`) is the anti-downgrade high-water `seq`,
managed by the firmware — not an operator setting.

### 8.5 VPS env / tooling config

| File | Repo | Purpose |
|---|---|---|
| `bin/.rota_release.env` | firmware (git-ignored) | `rota_release.py` connection details: `ROTA_TOKEN_FILE` (path to the GitHub **Contents:Read+write** token in the secret store), `ROTA_SSH` (ssh alias), `ROTA_STORE`, `ROTA_UNIT_TYPE` (default `ghc1`), `ROTA_MIN_VERSION`. **No secrets in this file — paths only.** |
| `.server.env` | this repo (git-ignored, optional) | Overrides `WEBROOT` for `server-update.sh` (defaults to `/var/www/ota/public`). |
| `nginx/ota.rfsee.net` | this repo | The vhost: pinned TLS, PHP-FPM pass, and the `internal` `X-Accel-Redirect` location aliased to `/var/www/ota-store/`. One-time setup; `server-update.sh` never re-copies it. |

---

## 9. Setting it up

### 9.1 Server (one-time) — see [`tools/bootstrap.md`](../tools/bootstrap.md)

1. **Deploy key.** Create an SSH key on the VPS, register it as a **read-only**
   deploy key on this repo, pin GitHub's host key.
2. **Clone in `$HOME`** (not the webroot): `git clone …/greenhouse-Controller-FOTA-server`.
3. **Runtime state + secrets**, created outside the clone and the webroot:
   `/var/www/ota-store/` (via `tools/init-store.sh`), and the pinned cert/key at
   `/etc/ssl/rota/` (copied once, out of band from the secret store). Make the
   store www-data-writable; `devices.json` mode 0640.
4. **nginx vhost.** Adjust the `/* ADJUST */` values in `nginx/ota.rfsee.net`
   (server_name, cert/key paths, `root`=WEBROOT, the internal alias, the PHP-FPM
   socket), enable it, `nginx -t && systemctl reload nginx`.
5. **Deploy the PHP:** `tools/server-update.sh` (fast-forward + `sudo rsync
   public/` into the webroot).
6. **Retriever cron** (soak pull), as www-data:
   ```
   */10 * * * * /home/<user>/greenhouse-Controller-FOTA-server/tools/ota-store-update.sh /var/www/ota-store >> /var/log/rota-pull.log 2>&1
   ```
7. **Log rotation:** install `tools/rota-logrotate` to `/etc/logrotate.d/rota`
   (see bootstrap.md §7).

### 9.2 Provisioning a unit (target: ≤ 10 min, R-T03)

A unit needs matching config in **two** places — the device and the registry.

1. **Pick the identity.** The id is the unit's full MAC — the 12-hex form. Read it
   on the device from `GET /api/ota/check` (admin; it reports the full MAC as
   `id`), or from `/var/log/rota-device.log` once the unit has checked in. Note
   that `/api/status` shows only the short 4-hex `unit_id`, **not** the ROTA id.
   Generate a fresh `ota_secret` (16–64 chars; a 64-hex string is convenient).
2. **On the device** (admin session), `POST /api/ota/config`:
   `url = https://ota.rfsee.net`, `secret = <the secret>`, optionally upload the
   pinned `cert` if not using the embedded default, set the night window, then
   `enable = 1`.
3. **On the server**, add a `devices.json` row keyed by that MAC with the **same**
   `secret`, `unit_type: "ghc1"`, `channel` (`soak` for a bench unit, `mainstream`
   for production), `pinned_version` (a version for production, else `null`),
   `enabled: true`, `last_seen: null`, `fw_ver: null` (see §11.1).
4. **Verify:** trigger a check (`POST /api/ota/check`) and confirm a `checkin`
   line for that id appears in `/var/log/rota-device.log`.

**Never provision 2344.**

---

## 10. Daily operation — publishing and promoting releases

All commands run from the firmware repo on the dev machine. **Always `--dry-run`
first.**

```bash
# 1. Build
powershell -ExecutionPolicy Bypass -File bin/build_release.ps1     # -> bin/<version>/{.bin,.zip}

# 2. Publish to soak via a GitHub Release (recommended pull path)
python bin/rota_release.py release 2.2.13 --dry-run                # preview, no token/network
python bin/rota_release.py release 2.2.13                          # creates tag v2.2.13 + assets; retriever points soak

#    (prerelease: stage the bytes but do NOT point soak)
python bin/rota_release.py release 2.2.13 --prerelease

#    (direct-scp alternative, skips GitHub)
python bin/rota_release.py publish 2.2.13

# 3. Soak on FDA4 — let it pull, then verify BOTH versions (see §13)

# 4. Promote to production after a good soak
python bin/rota_release.py promote 2.2.13                          # points channels/mainstream.json

# Inspect what each channel currently offers
python bin/rota_release.py status
```

Useful flags: `--seq N` (override the auto seq — rarely needed), `--min-version
X` (set the anti-downgrade floor), `--unit-type ghc1`, `--yes` (skip the prompt).

**`seq` is assigned automatically** as `max(existing) + 1`, taking the maximum
across both the server's manifests and the repo's `bin/*/manifest-*.json` copies,
so it stays monotonic no matter where you publish from. Re-publishing the same
version reuses its `seq` (idempotent).

**The paired-commit rule.** Firmware and assets ship together. After any push,
confirm **both** `fw_ver` *and* `asset_version` on the target — one alone is not
proof (see §13). Feature releases bump the **minor** version; patch is bug-fix-only.

**Production (5C88) is not remotely pushable today** — it is behind NAT with no
inbound path. `promote` updates the mainstream pointer, but 5C88 only picks it up
on a site visit (unpin on-site). That remote path is a separate future project.

### Reading the logs (on the VPS)

| Log | What's in it |
|---|---|
| `/var/log/rota-device.log` | One timestamped line per authenticated check-in and per artefact download (`checkin id=… fw=… offered=…`, `download id=… file=fw v=…`). Auth failures write nothing. |
| `/var/log/rota-pull.log` | The retriever's cron output — what it pulled/verified/staged/pointed. |
| `ota-store/checkins.csv` | Append-only `ts,id,fw,res` audit of every check-in. |

---

## 11. Managing units — add, assign, pin, disable, remove

Unit management is editing `devices.json` on the VPS. There is no CLI for it yet
(a pin/unpin helper is envisioned in R-T02 but currently manual). The file is
`www-data`-owned, mode 0640, so edit it with `sudo` and **validate the JSON before
saving** — a malformed registry fails closed and every unit gets 204.

### 11.1 Safe editing recipe

```bash
STORE=/var/www/ota-store
# edit as root; validate; the server merges last_seen/fw_ver under a lock, so keep the edit quick
sudo cp "$STORE/devices.json" /tmp/devices.json.bak
sudoedit "$STORE/devices.json"          # or: sudo nano
# validate before trusting it (JSON syntax + pins/channels/releases cross-checks):
sudo -u www-data ~/greenhouse-Controller-FOTA-server/tools/ota-store-check.sh "$STORE"
```

If it reports `[FAIL]` lines, restore the backup and try again. Because the server
also writes `last_seen`/`fw_ver` atomically, avoid holding a stale copy open for
long; editing when the target unit is not mid-check-in avoids any race.

### 11.2 The operations

| Task | Edit |
|---|---|
| **Add a unit** | Add a new object keyed by the MAC with `secret`, `unit_type`, `channel`, `pinned_version` (`null` or a version), `enabled: true`, `last_seen: null`, `fw_ver: null`, `_note`. Set the **same** `secret` + `url` + `enable=1` on the device (§9.2). |
| **Assign / change channel** | Set `"channel": "soak"` or `"mainstream"`. Takes effect on the unit's next check-in. |
| **Pin to a version** | Set `"pinned_version": "2.2.12"`. The unit is offered exactly that (overrides the channel), and only that release must be retained. |
| **Unpin** | Set `"pinned_version": null`. The unit resumes following its channel. |
| **Disable (soft stop)** | Set `"enabled": false`. The unit is silently rejected (204) and offered nothing — updates stop immediately, telemetry stops. |
| **Remove (hard)** | Delete the unit's object from `devices.json`. Also set `ota_enable=0` on the device if reachable, and retire its `ota_secret`. The unit then gets 204 forever (unknown id). |

### 11.3 Retention interaction

`prune-releases.sh` (run by the retriever, keep = `ROTA_KEEP`, default 5) never
prunes a release that any channel points to **or** any unit's `pinned_version`
names. So pinning a production unit to an old version keeps that release on the
server automatically. The firmware repo's `bin/<version>/` is the master copy, so
a pruned release is recoverable by re-publishing.

---

## 12. Device-side behaviour

Task **T16** (`firmware/src/ota_client/ota_client.cpp`) drives the whole
device-side flow.

**When it checks.** 30 s after boot (to let WiFi + SNTP settle), then every
`ota_check_h` hours (default 24, ±10 % jitter), but only when all preconditions
hold: `ota_enable=1`, `ota_url` set, WiFi connected, SNTP synced, no OTA already
in progress. An admin `POST /api/ota/check` (or any `/api/ota/config` write)
wakes it immediately. On an unreachable server it backs off 1 h → 2 h → 4 h … →
24 h and resets on success.

**Check → download → verify (any hour).** It GETs the manifest, treats it as an
update only if the offered version is strictly newer, then downloads **both**
artefacts into PSRAM and verifies size + SHA-256 on each. All of this happens at
any time of day; nothing is flashed yet.

**Apply (gated).** Flashing the inactive bank and rebooting happen only when the
local hour is inside the **night window** (`ota_win_lo`–`ota_win_hi`, default
02–04) **and** the **quiet gate** is clear. The quiet gate blocks the apply if
**any** of these is true:

- a window/louvre channel is moving,
- a wind override is active,
- a motor alarm is set,
- a calibration is running,
- a web session is active,
- an LCD PIN session is active.

The gate is re-checked within 5 s of the actual reboot; if activity resumed, the
apply aborts and the old bank keeps running.

**If the apply is deferred** (window closed or gate blocked), the unit releases
the OTA state — the old firmware keeps running, nothing is committed — and retries
(every 5 min while in-window-but-gated, otherwise at the next window). **Known
limitation (gh#41):** the verified image is *not* cached across a deferral, so
each retry re-downloads and re-verifies both artefacts (~1.5 MB), and an
operator's own live web session counts as "activity" that blocks the apply they
just triggered.

**After reboot** it confirms `fw_ver == asset_version` and reports the result on
its next status post.

**What the device knows vs. what the server knows.** The device knows its
`ota_enable`, `ota_check_h`, `ota_url`, `ota_secret`, night window, and pinned
cert (all in NVS), and derives its MAC id from eFuse (survives factory reset). It
does **not** know its `unit_type`, its channel, or any pin — those exist only in
the server registry. A unit cannot report or change its own channel.

---

## 13. Verifying and troubleshooting

### The definitive post-update check — the paired-commit invariant

Firmware alone is **not** proof of a good update; the asset partition can be left
behind. Read **both** from the unit's `/api/status`:

```bash
# both must match the target version
curl -s http://<unit-ip>/api/status | python -c "import sys,json;s=json.load(sys.stdin)['system'];print('fw_ver',s['fw_ver'],'asset_version',s['asset_version'])"
```

`fw_ver == asset_version == <target>` ⇒ the paired commit is intact. A mismatch
means firmware installed but assets did not — investigate before trusting the unit.

### Where to look

| Symptom | Look at | Likely cause |
|---|---|---|
| Unit never gets offered an update | `/var/log/rota-device.log` — is there a `checkin` line at all? | If **no** line: auth failing (204) — wrong `secret`, `enabled:false`, clock skew, or unknown id. If a line shows `offered=<old>`: wrong channel/pin, or the retriever hasn't pointed soak. |
| `offered=` shows the wrong version | `devices.json` `channel`/`pinned_version`; `channels/<channel>.json` | Unit on `mainstream` when you meant `soak`, or a stale pin. |
| Downloads but never installs | device `GET /api/ota/check` (`apply` field); `/api/status` `rota_update_pending` | Outside the night window, or the quiet gate is blocked (incl. **your own** web session — gh#41). |
| Retriever not staging a release | `/var/log/rota-pull.log` | Release has no `manifest-*.json` asset (looks non-ROTA), or it is a prerelease and cron runs without `--stage-prereleases`, or a sha256/size mismatch. |
| Everything "looks" fine but no update | Confirm `seq` advanced | A non-monotonic `seq` is refused (downgrade). Check `bin/*/manifest-*.json` vs. the server. |

### Device audit codes (SD log / `logparser.py`)

| `value_a` | Event | `value_b` |
|---|---|---|
| **22** | Check | 0 up-to-date · 1 update available · 2 unreachable/HTTP error · 3 skipped (preconditions) · 4 auth fail |
| **23** | Download/verify | 0 ok · 1 TLS/pin fail · 2 SHA/size mismatch · 3 downgrade/seq rejected · 4 min_version refusal |
| **24** | Apply | 0 committed/reboot scheduled · 1 deferred (window/quiet gate) · 2 apply failed |

Any change to these codes must be taught to `log/logparser.py` in the same
changeset (repo hard rule R-O02).

---

## 14. Reference

### Command cheat-sheet (dev machine)

```bash
python bin/rota_release.py release <version>            # -> GitHub Release -> soak (pull deploy)
python bin/rota_release.py release <version> --prerelease  # staged, soak NOT pointed
python bin/rota_release.py publish <version>            # scp -> ota-store -> soak (push deploy)
python bin/rota_release.py promote <version>            # soak -> mainstream
python bin/rota_release.py status                       # what each channel offers
python bin/ota_push.py bin/<version>/greenhouse-controller-<version>.bin --host <ip>   # local push (recovery path)
```

### Key paths

| What | Path |
|---|---|
| Wire contract (normative) | `design/rota_tds.md` §4 — *firmware repo* |
| Device client (T16) | `firmware/src/ota_client/ota_client.cpp` — *firmware repo* |
| Release tool + its docs | `bin/rota_release.py`, `bin/rota_release.md` — *firmware repo* |
| Release master copies | `bin/<version>/` (bin, zip, `manifest-<version>.json`) — *firmware repo* |
| Server endpoints | `public/manifest.php`, `public/download.php`, `public/lib/rota_lib.php` — *this repo* |
| Retriever + store tools | `tools/ota-store-update.sh`, `init-store.sh`, `prune-releases.sh` — *this repo* |
| Server bootstrap | `tools/bootstrap.md` — *this repo* |
| Store (VPS, outside webroot) | `/var/www/ota-store/` — `releases/`, `channels/`, `devices.json`, `checkins.csv`, `nonce-cache/` |
| Device-activity + pull logs | `/var/log/rota-device.log`, `/var/log/rota-pull.log` |

### Glossary

- **Soak** — the staging channel; the bench unit (FDA4) runs a release here before promotion.
- **Mainstream** — the production channel; only `promote` points it.
- **Pin** — a per-unit `pinned_version` that overrides the channel.
- **Quiet gate** — the set of "greenhouse is idle" conditions a unit requires before applying an update.
- **`seq`** — the strictly-monotonic release counter that is the primary anti-downgrade defence.
- **Paired commit** — firmware and web assets are always installed together; verify both `fw_ver` and `asset_version`.

---

*This document describes wire contract **v1.1** (`rota-contract-v1.1`). If the
contract changes, both the firmware and server repos change together and this
document must be updated alongside `design/rota_tds.md` in the firmware repo.*
