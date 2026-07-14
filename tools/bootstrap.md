# VPS bootstrap — one-time server setup

Deployment model: this repository is **cloned in the VPS user's home directory
on rfsee.net and deployed from there** — `git pull` in the clone, then a local
copy of `public/` into the webroot (`tools/server-update.sh`). nginx serves
only the copied files, never the clone, so `.git/`, `tools/`, and `nginx/`
are never web-reachable.

## 1. Read-only deploy key (R-T07)

On the VPS, create an SSH key dedicated to this repo and register it as a
**read-only deploy key** on GitHub (`greenhouse-Controller-FOTA-server` →
Settings → Deploy keys). Pin GitHub's host key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/rota_fota_deploy -N ''      # add the .pub as a deploy key
ssh-keyscan github.com >> ~/.ssh/known_hosts                # pin host key (verify fingerprint)
# ~/.ssh/config:
#   Host github-rota
#     HostName github.com
#     User git
#     IdentityFile ~/.ssh/rota_fota_deploy
#     IdentitiesOnly yes
```

## 2. Clone in $HOME

```bash
cd ~
git clone git@github-rota:pe1mew/greenhouse-Controller-FOTA-server.git
cd greenhouse-Controller-FOTA-server
# Optional — only if your webroot differs from the /var/www/ota/public default:
cp tools/server.env.example .server.env    # git-ignored; set WEBROOT
```

## 3. Runtime state and secrets (NOT in the repo — R-T07)

Create these on the VPS, outside both the clone and the webroot:

```
/var/www/ota-store/               # releases, channels, devices.json, checkins.csv (mode 0750)
/etc/ssl/rota/ota_server.pem      # pinned server cert  (from the operator secret store)
/etc/ssl/rota/ota_server.key      # server private key  (mode 0600, root only)
```

The cert/key are copied here **once, out of band** from the operator's secret
store (the certificate is valid ~20 years). Do NOT clone the credentials
repository onto this internet-facing host.

## 4. First deploy

**nginx vhost (one-time).** `nginx/ota.rfsee.net` is a **self-contained server
block** — adjust its `/* ADJUST */` values (server_name, cert/key paths,
`root`=WEBROOT, `$rota_store` + the internal alias, and the **PHP-FPM socket** —
match your version, e.g. `/run/php/php8.2-fpm.sock`), then symlink it into
`sites-enabled/` (or copy it to your conf dir) and
`sudo nginx -t && sudo systemctl reload nginx`. Ensure `ota.rfsee.net` resolves
to this VPS. `server-update.sh` never re-copies this file, so your adjusted
values are safe across deploys.

**Deploy the PHP:**

```bash
cd ~/greenhouse-Controller-FOTA-server && tools/server-update.sh
```

This fast-forwards the clone and `sudo rsync`s `public/` into `WEBROOT` — the PHP
endpoints only (the nginx vhost is the manual step above).

## 5. Updating later

```bash
cd ~/greenhouse-Controller-FOTA-server && tools/server-update.sh
```

## 6. Automated release pull (ROTA soak)

`tools/ota-store-update.sh` polls the firmware repo's **GitHub Releases** and
pulls the latest one into `ota-store/` — the pull half of the release toolchain
(the firmware repo's `bin/rota_release.py release` is the push half). The repo
is public, so fetches are tokenless: **no VPS-write key ever goes to GitHub**
(R-T07). Deps: `curl`, `php` (already required by the server), `sha256sum`.

It skips releases with no `manifest-<version>.json` asset (legacy / non-ROTA),
downloads the manifest + artefacts, **verifies sha256 + size before staging**,
stages atomically into `releases/<version>/`, then points `channels/soak.json`
at a **full** release. A GitHub **pre-release** is staged *without* pointing
soak. **Mainstream is never pointed here** — promotion stays a manual step
(`rota_release.py promote`). Then it runs `prune-releases.sh` (R-S08).

Run it once by hand, then schedule it (10 min is fine — apply happens in the
device's night window, so pull latency is irrelevant):

```bash
tools/ota-store-update.sh /var/www/ota-store            # manual

# crontab -e
*/10 * * * * /home/<user>/greenhouse-Controller-FOTA-server/tools/ota-store-update.sh /var/www/ota-store >> /var/log/rota-pull.log 2>&1
```

Optional env: `GH_TOKEN` (raises the 60/hr tokenless rate limit), `ROTA_KEEP`
(releases retained, default 5), `--stage-prereleases` (also stage prereleases),
`GH_API_BASE` (override the repo/base — used by the test harness).

## 7. Log rotation

`tools/rota-logrotate` rotates the two runtime logs — the retriever's cron log
(`/var/log/rota-pull.log`) and the device-activity log
(`/var/log/rota-device.log`). Install it once:

```bash
sudo install -m 0644 tools/rota-logrotate /etc/logrotate.d/rota
sudo logrotate --debug /etc/logrotate.d/rota      # dry-run: confirm it parses
```

Both logs are written by **www-data** (the PHP endpoints and the cron), so the
config recreates each one `0664 www-data:www-data` after rotation — the writers
open per-write, so there is no lost-handle problem and no `copytruncate`. It
keeps **12 weekly** compressed generations. The system's daily `logrotate` run
(`logrotate.timer` / `cron.daily`) applies it automatically — nothing to enable.
