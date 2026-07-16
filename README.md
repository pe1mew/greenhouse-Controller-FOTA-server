# greenhouse-Controller FOTA server

Pull-OTA server for the greenhouse ventilation controller. Runs as PHP behind nginx on the operator's VPS and serves firmware/asset releases to controllers that authenticate per the ROTA wire contract.

> **Full operator & administrator guide:** [`documentation/documentation.md`](documentation/documentation.md) — the whole ROTA chain end to end (delivery, actors, security model, setup, daily operation, unit management, and every config file).

## Wire contract

This repository implements **wire contract v1.1** — frozen as **§4 of `design/rota_tds.md`** in the firmware repository, tag **`rota-contract-v1.1`**:

> https://github.com/pe1mew/greenhouse-Controller — `design/rota_tds.md` §4 at tag `rota-contract-v1.1` — endpoints at the ota.rfsee.net root, no hbwv prefix

The contract defines the endpoints, the `X-OTA-Auth` header (per-unit HMAC-SHA256), the manifest JSON schema, the audit codes, and the server store layout. Contract changes require a new contract version and coordinated changes in both repositories (TDS requirement R-T06).

## Repository layout

| Path | Contents |
|---|---|
| `public/` | Web-reachable endpoints: `manifest.php`, `download.php` — nginx `root` points here |
| `nginx/ota.rfsee.net` | Server-block fragment: TLS with the pinned certificate, PHP-FPM pass, `internal` location for `X-Accel-Redirect` downloads |
| `tools/bootstrap.md` | One-time VPS setup: read-only deploy key, clone outside webroot, runtime dirs |
| `tools/server-update.sh` | Runs on the VPS: `git pull` (fast-forward) + `sudo rsync` of `public/` into the webroot (PHP only; the nginx vhost is a one-time setup) |
| `tools/ota-store-update.sh` | Runs on the VPS (cron): pulls the latest GitHub Release, verifies SHA-256, stages it into `ota-store/`, and points the soak channel |
| `tools/ota-store-check.sh` | Read-only store lint: validates `devices.json`, `channels/*.json`, staged manifests + artefact sizes/SHA-256, seq uniqueness; exit 0/1 |
| `.github/workflows/lint.yml` | CI: PHP lint + R-T07 credential scan |

**Not in this repository, by design (R-T07):** private keys, certificates, device secrets, the live device registry (`devices.json`), check-in logs, and release artefacts. Runtime state lives in `ota-store/` on the VPS (outside the webroot); secrets live in the operator's secret store. `.gitignore` enforces this and CI scans for violations.

## Deployment — clone in $HOME on the VPS, deployed from there

The repository is **cloned in the VPS user's home directory on rfsee.net**;
deployment = `git pull` in the clone + a local copy of `public/` into the
webroot (`tools/server-update.sh`). No files are pushed from a developer
machine. See **[tools/bootstrap.md](tools/bootstrap.md)** for one-time setup.

- **Auth (R-T07):** the VPS authenticates to GitHub with a **read-only deploy
  key** (SSH, host key pinned). No credentials in the repo.
- **Layout:** clone at `~/greenhouse-Controller-FOTA-server`; nginx serves the
  **copied** `public/` files from `WEBROOT` (git-ignored `.server.env` sets the
  local targets). The clone itself — `.git/`, `tools/`, `nginx/` — is never
  web-reachable.
- **Update:** `cd ~/greenhouse-Controller-FOTA-server && tools/server-update.sh`
  (fetch, fast-forward, `sudo rsync` `public/` into `WEBROOT`). Deploys the PHP
  only — the nginx vhost is a one-time setup. Never touches `ota-store/`.
- **Secrets:** the pinned cert/key are placed on the VPS **once, out of band**
  from the operator secret store (20-year cert). The credentials repository is
  **not** cloned onto this internet-facing host.

## Acceptance testing

The server's acceptance suite is the **device simulator** in the firmware repository (`bin/rota_sim.py`, implementation-plan Phase 2): it exercises correct/incorrect HMAC, replay, clock skew, certificate pinning, and mainstream-vs-pinned version resolution against a deployed instance — no ESP32 required. The server is "done" (Phase 1 exit) when that suite passes.

## Status

**Live** — server release **v1.0.0**, deployed at `https://ota.rfsee.net` (implements wire contract v1.1). The endpoints are implemented and pass the `rota_sim.py` acceptance suite; a cron-driven retriever (`tools/ota-store-update.sh`) ships releases from GitHub Releases to the soak channel, and device check-ins + downloads are logged to `/var/log/rota-device.log`. See [changelog.md](changelog.md).

## License

See [license.md](license.md) for full details.

**Software** (PHP, JavaScript, CSS, all code in this repository): Source-available, non-commercial. Free to use and modify for personal/non-commercial purposes; redistribution and commercial use are not permitted.

**Documentation and design files**: Licensed under the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International License.

<a rel="license" href="https://creativecommons.org/licenses/by-nc-nd/4.0/"><img alt="Creative Commons License" style="border-width:0" src="https://i.creativecommons.org/l/by-nc-nd/4.0/88x31.png" /></a>

## Disclaimer

This project is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
