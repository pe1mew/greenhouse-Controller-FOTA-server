#!/usr/bin/env bash
# ROTA server update — runs ON the VPS, from the clone in $HOME.
#
# Deployment model (R-T07): this repo is cloned in the VPS user's home
# directory and DEPLOYED FROM THERE — a fast-forward `git pull` followed by
# a local copy of public/ into the webroot and the nginx fragment into the
# nginx config dir. nginx never serves the clone itself; only the copied
# public/ files are web-reachable, so .git/, tools/, nginx/ stay private.
#
# Local deploy targets come from the git-ignored `.server.env` in the clone
# root (see tools/server.env.example). Secrets and runtime state (cert/key,
# ota-store/) are never touched by this script.

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".server.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE missing — copy tools/server.env.example and fill it in." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${WEBROOT:?set in .server.env}"          # e.g. /var/www/ota/public
: "${NGINX_CONF_DIR:?set in .server.env}"   # e.g. /etc/nginx/sites-available or snippets dir

echo "== fetch + fast-forward only (no local commits expected on the VPS)"
git fetch --tags origin
git merge --ff-only origin/main

echo "== deploy public/ -> ${WEBROOT}"
mkdir -p "$WEBROOT"
rsync -a --delete public/ "${WEBROOT}/"

echo "== stage nginx fragment -> ${NGINX_CONF_DIR}/ota.conf"
cp nginx/ota.conf "${NGINX_CONF_DIR}/ota.conf"

if command -v nginx >/dev/null 2>&1; then
    echo "== nginx config test + reload"
    sudo nginx -t
    sudo systemctl reload nginx
else
    echo "   nginx not found in PATH — test/reload manually"
fi

echo "== deployed contract version: $(git describe --tags --always)"
echo "== done"
