# Changelog

All notable changes to the **greenhouse-Controller FOTA server** are documented
in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/).

Server releases carry their own semantic version; each release states the
frozen **ROTA wire contract** it implements (§4 of `design/rota_tds.md` in the
firmware repo, https://github.com/pe1mew/greenhouse-Controller). The contract
is versioned separately: changing it requires a new contract tag and
coordinated updates in both repositories (R-T06). Early pre-release history
(before server versioning was introduced) is listed under the contract tags at
the bottom of this file.

---

## [1.0.0] — 2026-07-14 — implements wire contract v1.1

First versioned server release — the state **currently deployed and running**
at `https://ota.rfsee.net`: both wire-contract endpoints pass the
`rota_sim.py` acceptance suite, releases flow in automatically from GitHub
Releases to the soak channel, and operation is fully documented.

### Added
- **Pull-based release distribution — `tools/ota-store-update.sh`** (2026-07-14).
  Polls the firmware repo's public **GitHub Releases** and stages new releases
  into `ota-store/`: skips manifest-less / legacy releases, downloads the
  manifest + artefacts, **verifies SHA-256 and size before staging**, then points
  `channels/soak.json` for a full release. `--stage-prereleases` stages a
  pre-release **without** pointing soak; **mainstream is never auto-pointed**
  (promotion stays manual). Tokenless (public repo); runs as `www-data` from
  cron. Uses the `/releases` list (not `/releases/latest`, which excludes
  pre-releases) so `--stage-prereleases` can see them.
- **Device-activity log — `/var/log/rota-device.log`** (2026-07-14). Timestamped
  (ISO-8601 UTC), control-char-safe. `manifest.php` logs each authenticated
  check-in (device id, reported firmware, last audit outcome, offered version);
  `download.php` logs each artefact served. Failed auth (`204`) stays silent by
  design. Log path from `$ROTA_DEVICE_LOG` (default `/var/log/rota-device.log`).
- **Log rotation — `tools/rota-logrotate`** (2026-07-14). logrotate config for
  the two runtime logs: rotates `rota-pull.log` + `rota-device.log` **weekly**,
  keeps **12** compressed generations, and recreates each `0664
  www-data:www-data` so PHP and the cron keep writing. Install once to
  `/etc/logrotate.d/rota` (see `tools/bootstrap.md` §7).
- **Unit-management guide — `documentation/unitManagement.md`** (2026-07-14).
  The mental model: how a unit is managed in `devices.json`, the **streams ×
  unit-type channel matrix** (with the version pool fed from GitHub Releases),
  and check-in version resolution — with two overview SVG diagrams. Includes a
  **use-case catalogue** (12 use cases: unit registry, version pool, streams,
  observation) and a **PlantUML use-case diagram per use case** with a
  comprehensive description; `.puml` sources + rendered PNGs in
  `documentation/images/`.
- **CLI manual — `documentation/cliManual.md`** (2026-07-14). Comprehensive
  manual of the ROTA command-line tooling: the dev-machine release toolchain
  (`rota_release.py` subcommands/options/`seq` guard, `rota_sim.py`,
  `ota_push.py`) and the VPS scripts (`init-store.sh`, `ota-store-update.sh`,
  `prune-releases.sh`, `server-update.sh`, `rota-logrotate`), the registry
  hand-edit pattern (UC1–UC6), and a **use case → command mapping** with worked
  examples, cross-linked per use case to `unitManagement.md`.

### Changed
- **`tools/server-update.sh`** (2026-07-14) now deploys **only** `public/`
  (`git pull` fast-forward + `sudo rsync` into the webroot) and no longer
  re-copies the nginx vhost — its `/* ADJUST */` values (server_name, cert/key,
  PHP-FPM socket) are VPS-specific and a re-copy would clobber them. `WEBROOT`
  defaults to `/var/www/ota/public`, so `.server.env` is now optional. All
  `tools/*.sh` are marked executable so `tools/<script>.sh` runs directly.

---

## [rota-contract-v1.1] — 2026-07-13

Endpoints moved to the dedicated **`ota.rfsee.net`** vhost root (no `hbwv/ota/`
prefix), so the OTA host is fully separate from the status site. The request
path is part of the signed `request_uri`, hence the contract bump from v1.0.

### Added
- **`GET /manifest.php?fw=<running>[&res=<a.b>]`** — `X-OTA-Auth` (per-unit
  HMAC-SHA256, ±300 s skew window, nonce replay cache, constant-time compare).
  Resolves the unit to its offered release (`pinned_version`, else its channel's
  version for its `unit_type`), records the check-in (`checkins.csv` +
  `devices.json` `last_seen`/`fw_ver` telemetry), and returns the §4.3 manifest.
  `204` for auth failure (silent), `404` for no release / missing manifest.
- **`GET /download.php?file=fw|assets&v=<version>`** — `X-OTA-Auth`; streams the
  exact artefact named in that release's manifest via nginx `X-Accel-Redirect`
  (path-traversal guarded; the filename is never guessed). `ROTA_NO_XACCEL`
  streams directly for `php -S` testing.
- **Self-contained nginx server block** (`nginx/ota.rfsee.net`): pinned
  self-signed TLS, PHP-FPM pass, and the `internal` `X-Accel-Redirect` location
  for the out-of-webroot `ota-store/` (2026-07-13).
- On-disk store layout served: `releases/<version>/manifest-<version>.json`
  (+ the `.bin`/`.zip` artefacts), `channels/<channel>.json`, `devices.json`,
  append-only `checkins.csv`, and `nonce-cache/`.

---

## [rota-contract-v1.0] — 2026-07-13  (superseded, never deployed)

Initial scaffold per the ROTA implementation plan (task 0.2): repository
structure, endpoint stubs, `tools/` (`init-store.sh`, `prune-releases.sh`,
`bootstrap.md`), and a `.gitignore` + CI (PHP lint + R-T07 credential scan) that
keep secrets, `devices.json`, check-in logs, and release artefacts out of the
repo. Superseded by v1.1 before deployment.
