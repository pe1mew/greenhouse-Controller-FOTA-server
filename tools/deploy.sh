#!/usr/bin/env bash
# ROTA server deployment — TDS R-T07:
#   - SSH public-key authentication ONLY (no passwords)
#   - StrictHostKeyChecking enforced (host key must be in known_hosts)
#   - no credentials in this repository: connection details come from the
#     git-ignored .deploy.env (see tools/deploy.env.example)
#
# Scope: syncs public/ (the two endpoints) and stages nginx/ota.conf.
# NEVER touches ota-store/ on the VPS — that is runtime state (registry,
# releases, check-ins) owned by the publish/promote tooling and the server.
# Reloading nginx is a deliberate manual step on the VPS.

set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".deploy.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE missing — copy tools/deploy.env.example and fill it in." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${DEPLOY_HOST:?set in .deploy.env}"
: "${DEPLOY_USER:?set in .deploy.env}"
: "${DEPLOY_KEY:?set in .deploy.env}"
: "${REMOTE_WEBROOT:?set in .deploy.env}"      # e.g. /var/www/html/hbwv/ota
: "${REMOTE_CONF_DIR:?set in .deploy.env}"     # e.g. /etc/nginx/snippets

SSH_CMD="ssh -i ${DEPLOY_KEY} -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"

echo "== deploying endpoints -> ${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_WEBROOT}"
rsync -avz --delete -e "$SSH_CMD" public/ "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_WEBROOT}/"

echo "== staging nginx fragment -> ${REMOTE_CONF_DIR}/ota.conf (reload nginx manually)"
rsync -avz -e "$SSH_CMD" nginx/ota.conf "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_CONF_DIR}/ota.conf"

echo "== done. Manual step on VPS: nginx -t && systemctl reload nginx"
