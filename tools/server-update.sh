#!/usr/bin/env bash
# ROTA server update -- runs ON the VPS, from the clone in $HOME.
#
# Deployment model (R-T07): this repo is cloned in the VPS user's home
# directory and DEPLOYED FROM THERE -- a fast-forward `git pull` followed by a
# copy of public/ into the webroot. nginx never serves the clone itself; only
# the copied public/ files are web-reachable, so .git/, tools/, nginx/ stay
# private.
#
# This script deploys ONLY the PHP endpoints (public/). The nginx vhost is a
# one-time setup (see tools/bootstrap.md) whose /* ADJUST */ values (server_name,
# cert/key, php-fpm socket, roots) are VPS-specific -- so this script must NOT
# re-copy nginx/ota.rfsee.net, or it would clobber those live values. When the
# vhost genuinely changes, copy it + `sudo nginx -t && sudo systemctl reload
# nginx` by hand.
#
# Deploy target comes from the git-ignored `.server.env` (tools/server.env.example)
# if present, else the standard-layout default below. Secrets and runtime state
# (cert/key, ota-store/) are never touched here.

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".server.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
: "${WEBROOT:=/var/www/ota/public}"   # override in .server.env for a non-standard VPS

echo "== fetch + fast-forward only (no local commits expected on the VPS)"
git fetch --tags origin
git merge --ff-only origin/main

echo "== deploy public/ -> ${WEBROOT}  (sudo: webroot is not owned by \$USER)"
sudo mkdir -p "$WEBROOT"
sudo rsync -a --delete public/ "${WEBROOT}/"

echo "== deployed contract version: $(git describe --tags --always)"
echo "== done. PHP is live (php-fpm picks up changed files on mtime; if opcache"
echo "   is aggressive, 'sudo systemctl reload php*-fpm'). nginx vhost untouched."
