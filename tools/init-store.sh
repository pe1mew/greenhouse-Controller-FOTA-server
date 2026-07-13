#!/usr/bin/env bash
# Create the ota-store/ skeleton on the VPS (OUTSIDE the webroot). Idempotent.
# Usage: tools/init-store.sh /var/www/ota-store
set -euo pipefail
STORE="${1:?usage: init-store.sh /path/to/ota-store}"

mkdir -p "$STORE"/releases "$STORE"/channels "$STORE"/nonce-cache
[ -f "$STORE/devices.json" ]             || echo '{}' > "$STORE/devices.json"
[ -f "$STORE/channels/mainstream.json" ] || echo '{}' > "$STORE/channels/mainstream.json"
[ -f "$STORE/channels/soak.json" ]       || echo '{}' > "$STORE/channels/soak.json"
[ -f "$STORE/checkins.csv" ]             || : > "$STORE/checkins.csv"
chmod -R 0750 "$STORE"

echo "ota-store initialised at $STORE"
echo "Next: add device rows to devices.json (see examples/devices.example.json),"
echo "      publish a release (build_release.ps1), point channels/<channel>.json."
