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
cp tools/server.env.example .server.env    # fill in WEBROOT + NGINX_CONF_DIR (git-ignored)
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

```bash
cd ~/greenhouse-Controller-FOTA-server && tools/server-update.sh
```

Copies `public/` to `WEBROOT`, stages `nginx/ota.conf` (adjust its paths for
this VPS first: `root` → WEBROOT, cert/key → `/etc/ssl/rota/…`, `ota-store`
alias), installs the PHP-FPM snippet, then `sudo nginx -t && sudo systemctl
reload nginx`. Add the `ota.rfsee.net` DNS record if not yet present.

## 5. Updating later

```bash
cd ~/greenhouse-Controller-FOTA-server && tools/server-update.sh
```
