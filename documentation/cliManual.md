# CLI manual — ROTA tooling

A comprehensive manual of the command-line tools that operate the ROTA system,
and which tool serves which use case. The use cases themselves (actors,
diagrams, rationale) are described in
[unitManagement.md](unitManagement.md#use-case-catalogue); this document is the
*how*: the exact commands, their options, and worked examples.

The tooling lives in two places, matching the trust split:

| Location | Tools | Runs |
|---|---|---|
| **Dev machine** — firmware repo `greenhouse-Controller/bin/` | `build_release.ps1`, `rota_release.py`, `rota_sim.py`, (`ota_push.py`) | Building, publishing, promoting, verifying |
| **VPS** — this repo `tools/` | `init-store.sh`, `ota-store-update.sh`, `prune-releases.sh`, `ota-store-check.sh`, `server-update.sh`, `rota-logrotate` | Store bootstrap, automatic pull/stage, retention, store lint, server deploy, log rotation |

Registry edits (unit use cases UC1–UC6) have **no dedicated CLI by design** —
they are small, auditable hand-edits to `devices.json` on the VPS; see
[Registry editing](#registry-editing-uc1uc6) below.

---

## 1. `rota_release.py` — the release toolchain (dev machine)

The central Python script (stdlib only, firmware repo `bin/rota_release.py`;
full reference: `bin/rota_release.md` in that repo). It implements the
operator's side of publishing: computing SHA-256 + size of the artefacts,
assigning the monotonic `seq`, writing `manifest-<version>.json`, and moving
channel pointers.

### One-time setup

```bash
cd greenhouse-Controller
cp bin/rota_release.env.example bin/.rota_release.env   # git-ignored, no secrets
```

Fill in `bin/.rota_release.env`:

| Key | Meaning |
|---|---|
| `ROTA_SSH` | SSH alias for the VPS (define host, user, key, pinned host key in `~/.ssh/config`) |
| `ROTA_STORE` | `ota-store` path on the VPS (default `/var/www/ota-store`) |
| `ROTA_TOKEN_FILE` | Path (in the operator's secret store) to a GitHub token with **Contents: Read and write** — needed only by `release` |
| `ROTA_UNIT_TYPE` | Default `unit_type` key (`ghc1`) |
| `ROTA_MIN_VERSION` | Anti-downgrade floor written into new manifests |
| `ROTA_BASE_URL`, `ROTA_CERT` | Optional; used to print a ready-to-run `rota_sim.py` verification command |

### Subcommands

```bash
python bin/rota_release.py release 2.2.14             # GitHub Release -> retriever stages -> soak (recommended)
python bin/rota_release.py release 2.2.14 --prerelease # staged only, soak NOT pointed
python bin/rota_release.py publish 2.2.14             # scp direct to ota-store -> soak (push deploy)
python bin/rota_release.py promote 2.2.14             # point mainstream (after a good soak)
python bin/rota_release.py status                     # what each channel offers + release list
```

| Subcommand | What it does | Transport |
|---|---|---|
| `release <v>` | Authors the manifest (next `seq` from the repo ledger), creates GitHub Release `v<v>` on the current HEAD, uploads `.bin` + `.zip` + manifest as assets. The VPS retriever then pulls, verifies, stages, and points **soak** (UC7 + UC9). `--prerelease` stages without pointing. | GitHub API (token) |
| `publish <v>` | Same manifest authoring, but uploads straight into `ota-store/releases/<v>/` and points **soak** itself. | SSH/scp (`ROTA_SSH`) |
| `promote <v>` | Points `channels/mainstream.json[unit_type]` at an already-published release (UC10). | SSH (`ROTA_SSH`) |
| `status` | Prints what `soak` and `mainstream` currently offer per unit type, plus the staged releases (UC12). | SSH (`ROTA_SSH`) |

### Common options

| Option | Applies to | Meaning |
|---|---|---|
| `--dry-run` | all | Print every planned action, change nothing. **Always dry-run first.** |
| `--yes` | all | Skip the confirmation prompt (scripting). |
| `--unit-type <t>` | all | Unit-type key (default `ghc1`) — the matrix *column* being written. |
| `--seq N` | `release`, `publish` | Override the auto-assigned `seq` (normally never needed). |
| `--min-version X` | `release`, `publish` | Anti-downgrade floor in the manifest. |
| `--prerelease` / `--draft` | `release` | Stage without pointing soak / create unpublished. |
| `--force` | `promote` | Promote a version that is **not** the current soak release (the mainstream rollback path, UC11). |
| `--local <dir>` | `publish`, `promote`, `status` | Operate on a local `ota-store/` directory instead of SSH (testing). |

### The `seq` guard

`seq` is a strictly monotonic release counter shared by the tool, the server,
and the devices. The tool assigns `max(existing) + 1` across the server's
manifests and the repo's `bin/*/manifest-*.json` master copies; re-publishing
the same version reuses its `seq` (idempotent). A publish that would not
strictly advance the current soak `seq` is **refused** (devices would reject
it as a downgrade) unless `--seq` forces it. The same guard exists
independently in the VPS retriever.

### Worked example — full release cycle

```bash
# 1. Build
bin/build_release.ps1                                   # -> bin/2.2.14/{.bin,.zip}

# 2. Publish via GitHub (pull deploy) — UC7
python bin/rota_release.py release 2.2.14 --dry-run     # preview
python bin/rota_release.py release 2.2.14               # creates tag v2.2.14 + assets

# 3. Within 10 min the VPS retriever stages it and points soak — UC9.
#    Watch it happen:
ssh ota-vps tail -f /var/log/rota-pull.log

# 4. Let the bench unit soak the release, then check what it runs — UC12
python bin/rota_release.py status

# 5. Promote to production — UC10
python bin/rota_release.py promote 2.2.14 --dry-run
python bin/rota_release.py promote 2.2.14
```

---

## 2. `rota_sim.py` — device simulator / acceptance suite (dev machine)

Exercises the server exactly like the firmware client: builds the
`X-OTA-Auth` HMAC header, pins the server certificate by SHA-256 fingerprint,
and asserts the happy path plus every negative case of wire contract v1.1.
Exit code 0 = all cases passed. Use it after any publish or server change
(the verification half of UC12).

```bash
python bin/rota_sim.py --base-url https://ota.rfsee.net \
    --cert /path/to/ota_server.pem \
    --id <full-mac-12hex> --secret-file <path>          # or --secret <hex>

# optional: assert that a pinned unit is offered exactly its pin (UC5)
    --pinned-id <mac> --pinned-secret <hex> --expect-pinned 2.2.0
```

Local end-to-end test without a VPS (real PHP server, local store):

```bash
STORE=/tmp/ota-store
python bin/rota_release.py publish 2.2.14 --local "$STORE" --yes
ROTA_STORE="$STORE" ROTA_NO_XACCEL=1 \
    php -S 127.0.0.1:8099 -t ../greenhouse-Controller-FOTA-server/public &
python bin/rota_sim.py --base-url http://127.0.0.1:8099 \
    --id a0b1c2d3e4f5 --secret <hex> --fw 2.1.3          # expect all passed
```

---

## 3. `ota_push.py` — direct LAN push (dev machine, out of band)

Not part of ROTA: pushes a build straight to a unit's local web API over the
LAN (login → upload firmware → wait for reboot → upload assets → verify).
Useful on the bench or for a NAT-bound unit during an on-site visit; it
bypasses the server, streams, and pins entirely, so nothing in the use-case
catalogue applies to it.

```bash
python bin/ota_push.py bin/2.2.14/greenhouse-controller-2.2.14.bin \
    --host 192.168.20.160 --pin 12345678
```

---

## 4. VPS-side scripts (this repo, `tools/`)

All run **on the VPS**, from the clone in the deploy user's home directory.

### `init-store.sh` — bootstrap the store (one-time)

Creates the `ota-store/` skeleton outside the webroot: `releases/`,
`channels/` (both channel files seeded `{}`), `nonce-cache/`, an empty
`devices.json` (`{}`) and `checkins.csv`, all `chmod 0750`. Idempotent —
safe to re-run; it never overwrites existing files.

```bash
tools/init-store.sh /var/www/ota-store
```

### `ota-store-update.sh` — the retriever (cron)

The pull-based deploy (UC7 staging + UC9 soak pointing). Polls the public
firmware repo's GitHub releases API with tokenless GETs, and for the newest
non-draft release carrying a `manifest-*.json` asset: downloads the manifest,
downloads the firmware + assets it names, **verifies sha256 + size before
staging**, stages atomically into `releases/<version>/`, and points
`channels/soak.json[unit_type]` — guarded so it never moves soak to a
`seq` that does not strictly advance. Mainstream is never touched. Ends by
running `prune-releases.sh` (UC8).

```bash
tools/ota-store-update.sh /var/www/ota-store                       # manual run
tools/ota-store-update.sh /var/www/ota-store --stage-prereleases   # also stage pre-releases (soak untouched)

# crontab -e  (the production configuration)
*/10 * * * * /home/<user>/greenhouse-Controller-FOTA-server/tools/ota-store-update.sh /var/www/ota-store >> /var/log/rota-pull.log 2>&1
```

Environment: `GH_TOKEN` (optional; raises the 60/hr tokenless rate limit),
`ROTA_KEEP` (retention count, default 5), `GH_API_BASE` (override the repo —
test harness), `STAGE_PRERELEASES=1` (same as the flag). Exit is always 0 on
"nothing to do" (no release, non-ROTA release, pre-release without the flag),
so a quiet cron log means idle, not broken.

### `prune-releases.sh` — retention (UC8)

Keeps the newest `KEEP` release directories (by mtime) **plus** every version
referenced by any channel file or any unit's `pinned_version` — those are
never pruned. Normally invoked by the retriever; run manually to force a
sweep or test a different retention:

```bash
tools/prune-releases.sh /var/www/ota-store        # keep 5 (default)
tools/prune-releases.sh /var/www/ota-store 3      # keep 3 + referenced
```

A pruned release is recoverable: the firmware repo's `bin/<version>/` is the
master copy — re-run `rota_release.py publish <version>` (it reuses the
original `seq`).

### `ota-store-check.sh` — store health check (UC13)

Read-only syntax + consistency lint of the whole store: `devices.json` (valid
JSON, 12-hex ids, secrets set — values never printed, channels known, pins
staged, not world-readable), `channels/*.json` (shape; pointed versions
staged with manifests), every `releases/<v>/` (manifest fields; artefact
presence, size and SHA-256; `seq` uniqueness), enabled-unit resolution, and
`checkins.csv` line format. Exit `0` = healthy (warnings allowed), `1` =
errors — cron-friendly. Never writes; never prints a secret value.

```bash
sudo -u www-data tools/ota-store-check.sh /var/www/ota-store            # full check
sudo -u www-data tools/ota-store-check.sh /var/www/ota-store --quick    # skip sha256
```

Run it after **every** registry hand-edit (UC1–UC6), after a manual stream
edit (UC11), and as the first diagnostic when units unexpectedly get 204/404
— a malformed `devices.json` fails **closed** and 204s every unit.

### `server-update.sh` — deploy the PHP server

Updates the *server code*, not the store: fast-forward `git pull` of this
repo's clone, then `rsync public/` into the webroot. Deliberately never
touches the nginx vhost (its `/* ADJUST */` values are VPS-specific), the
TLS cert/key, or `ota-store/`. Deploy target `WEBROOT` comes from the
git-ignored `.server.env` (template: `tools/server.env.example`).

```bash
tools/server-update.sh
```

### `rota-logrotate` — log rotation (config, not a script)

Logrotate policy for `/var/log/rota-pull.log` (retriever cron) and
`/var/log/rota-device.log` (check-ins + downloads): 12 weekly compressed
generations, files recreated `0664 www-data:www-data`. Install once; the
system's daily logrotate applies it automatically:

```bash
sudo install -m 0644 tools/rota-logrotate /etc/logrotate.d/rota
sudo logrotate --debug /etc/logrotate.d/rota      # dry-run: confirm it parses
```

---

## 5. Registry editing (UC1–UC6)

The unit use cases are deliberate hand-edits to
`/var/www/ota-store/devices.json` on the VPS (mode 0640, never in git).
There is no wrapper script — the file is small, the edits are one-liners, and
a human in the loop is the point. General pattern:

```bash
ssh ota-vps
sudoedit /var/www/ota-store/devices.json
# validate after every edit — a syntax error breaks auth for ALL units (UC13):
sudo -u www-data ~/greenhouse-Controller-FOTA-server/tools/ota-store-check.sh /var/www/ota-store
```

Changes take effect on each unit's next check-in; nothing needs restarting.

---

## 6. Use case → command mapping

Every use case from the
[catalogue](unitManagement.md#use-case-catalogue), the tool that serves it,
and a worked example. Each heading links to the corresponding use-case
description and diagram in unitManagement.md.

### UC1 — Add a unit

*Described in [unitManagement.md § UC1](unitManagement.md#uc1--add-a-unit).*

Tool: hand-edit + `openssl` for the secret; `rota_sim.py` to verify.

```bash
# 1. generate the per-unit secret (keep it in the operator's secret store)
openssl rand -hex 32

# 2. add the record on the VPS
sudoedit /var/www/ota-store/devices.json
```

```json
"aabbccddeeff": {
  "secret": "<the 64-hex secret>",
  "unit_type": "ghc1",
  "channel": "soak",
  "pinned_version": null,
  "enabled": true,
  "last_seen": null,
  "fw_ver": null,
  "_note": "bench unit #2, added 2026-07-14"
}
```

```bash
# 3. provision the SAME secret + server URL on the device (device console),
#    then prove the server side end-to-end without waiting for hardware:
python bin/rota_sim.py --base-url https://ota.rfsee.net --cert <pem> \
    --id aabbccddeeff --secret <the-secret>
```

### UC2 — Remove a unit (hard)

*Described in [unitManagement.md § UC2](unitManagement.md#uc2--remove-a-unit-hard).*

Tool: hand-edit. Delete the unit's whole object from `devices.json`, retire
its secret in the secret store, and — if the device is reachable — set
`ota_enable=0` on it. Validate the JSON afterwards (see §5). From then on the
id is unknown and every request gets a silent 204.

### UC3 — Enable / disable a unit (soft stop)

*Described in [unitManagement.md § UC3](unitManagement.md#uc3--enable--disable-a-unit-soft-stop).*

Tool: hand-edit. Flip one field, keep everything else:

```json
"enabled": false
```

Updates and telemetry stop on the next check-in; set back to `true` to
restore the unit exactly as it was.

### UC4 — Assign a unit to a stream

*Described in [unitManagement.md § UC4](unitManagement.md#uc4--assign-a-unit-to-a-stream).*

Tool: hand-edit. Choose the matrix *row* the unit reads:

```json
"channel": "soak"          // or "mainstream" (also the default when absent)
```

### UC5 — Pin a unit to a version

*Described in [unitManagement.md § UC5](unitManagement.md#uc5--pin-a-unit-to-a-version).*

Tool: hand-edit. The pin overrides the channel matrix entirely and protects
that release from pruning:

```json
"pinned_version": "2.2.0"
```

Verify the server now offers exactly the pin:

```bash
python bin/rota_sim.py --base-url https://ota.rfsee.net --cert <pem> \
    --id <mac> --secret-file <path> \
    --pinned-id <mac> --pinned-secret <hex> --expect-pinned 2.2.0
```

### UC6 — Unpin a unit

*Described in [unitManagement.md § UC6](unitManagement.md#uc6--unpin-a-unit).*

Tool: hand-edit. The unit resumes following its stream on the next check-in:

```json
"pinned_version": null
```

Typically done right after a UC10 promote; re-pin to the new version once it
is confirmed running (`fw_ver` in `devices.json`, UC12).

### UC7 — Add a version to the pool

*Described in [unitManagement.md § UC7](unitManagement.md#uc7--add-a-version-to-the-pool).*

Tool: `rota_release.py release` (recommended, pull deploy) or `publish`
(push deploy); the retriever `ota-store-update.sh` does the VPS half.

```bash
python bin/rota_release.py release 2.2.14 --dry-run     # always preview first
python bin/rota_release.py release 2.2.14               # GitHub Release v2.2.14
python bin/rota_release.py release 2.2.15 --prerelease  # stage only, no soak

# don't want to wait for the 10-min cron? trigger the retriever by hand:
ssh ota-vps '~/greenhouse-Controller-FOTA-server/tools/ota-store-update.sh /var/www/ota-store'

# push deploy over SSH instead (no GitHub involved):
python bin/rota_release.py publish 2.2.14
```

### UC8 — Remove a version from the pool

*Described in [unitManagement.md § UC8](unitManagement.md#uc8--remove-a-version-from-the-pool).*

Tool: `prune-releases.sh` (automatic after every retriever run); manual runs
for a forced sweep. Recovery is a re-publish.

```bash
tools/prune-releases.sh /var/www/ota-store 5            # on the VPS
python bin/rota_release.py publish 2.2.9                # recover a pruned release
```

Versions referenced by a stream or a pin are never pruned — no command can
accidentally strand a unit.

### UC9 — Point soak (automatic)

*Described in [unitManagement.md § UC9](unitManagement.md#uc9--point-soak-automatic).*

Tool: none for the operator — the retriever cron does this on every new full
release, guarded by the monotonic `seq`. Your involvement is observation:

```bash
ssh ota-vps tail -n 50 /var/log/rota-pull.log           # "pointed soak[ghc1] -> 2.2.14 (seq 40)"
python bin/rota_release.py status
```

(`publish` also points soak directly when you use the push deploy.)

### UC10 — Promote to mainstream (manual)

*Described in [unitManagement.md § UC10](unitManagement.md#uc10--promote-to-mainstream-manual).*

Tool: `rota_release.py promote` — the only thing that ever writes
`channels/mainstream.json`.

```bash
python bin/rota_release.py promote 2.2.14 --dry-run
python bin/rota_release.py promote 2.2.14
python bin/rota_release.py status                       # confirm both channels
```

Remember: a pinned production unit (UC5) still won't move until you unpin it
(UC6).

### UC11 — Force / roll back a stream

*Described in [unitManagement.md § UC11](unitManagement.md#uc11--force--roll-back-a-stream).*

Tool: `promote --force` for mainstream; hand-edit for soak; pins as the
per-unit alternative.

```bash
# roll mainstream back to a previously published release:
python bin/rota_release.py promote 2.2.12 --force       # --force: not the current soak release

# roll soak back (the retriever refuses to downgrade, so edit by hand):
ssh ota-vps
sudoedit /var/www/ota-store/channels/soak.json          # {"ghc1": {"version": "2.2.12"}}
```

Note the retriever will not re-advance soak past the hand-set version until a
release with a *higher* `seq` appears — a rollback sticks. The surgical
alternative is pinning just the affected units (UC5).

### UC12 — Inspect state (observation)

*Described in [unitManagement.md § UC12](unitManagement.md#uc12--inspect-state-observation).*

Tools: `rota_release.py status`, the VPS logs, the registry's telemetry
fields, and `rota_sim.py` as the active probe.

```bash
python bin/rota_release.py status                       # what each stream offers

ssh ota-vps
tail -f /var/log/rota-device.log                        # live: checkin id=.. fw=.. offered=..
tail -n 20 /var/log/rota-pull.log                       # retriever activity
tail -n 20 /var/www/ota-store/checkins.csv              # machine-readable check-in trail
grep -A2 '"5c88aabbccdd"' /var/www/ota-store/devices.json   # last_seen / fw_ver of one unit

python bin/rota_sim.py --base-url https://ota.rfsee.net --cert <pem> \
    --id <mac> --secret-file <path>                     # full contract check
```

### UC13 — Validate the store (observation)

*Described in [unitManagement.md § UC13](unitManagement.md#uc13--validate-the-store-observation).*

Tool: `tools/ota-store-check.sh` (VPS) — the read-only companion to UC12:
where UC12 asks *what is the system doing*, UC13 asks *is the store itself
well-formed and consistent*.

```bash
ssh ota-vps
sudo -u www-data ~/greenhouse-Controller-FOTA-server/tools/ota-store-check.sh /var/www/ota-store
# [ OK ] devices.json: valid JSON, 3 unit(s), 3 enabled
# [ OK ] soak.json [ghc1] -> 2.2.14 (staged, manifest present)
# [ OK ] releases/2.2.14: greenhouse-controller-2.2.14.bin size + sha256 match
# ...
# == summary: 0 error(s), 0 warning(s) ==            exit 0 = healthy, 1 = errors
```

Run it after every hand-edit (UC1–UC6, UC11) and as the first step of any
"units suddenly get 204/404" diagnosis; `--quick` skips the SHA-256 pass.

---

## See also

- [unitManagement.md](unitManagement.md) — the use-case catalogue, diagrams, and the channel-matrix model
- [documentation.md](documentation.md) — the operator guide (§11: procedures, §12: troubleshooting)
- [tools/bootstrap.md](../tools/bootstrap.md) — first-time VPS setup
- `greenhouse-Controller/bin/rota_release.md` — full reference of the release tool (firmware repo)
