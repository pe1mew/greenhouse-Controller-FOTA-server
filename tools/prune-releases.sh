#!/usr/bin/env bash
# Retention (R-S08): keep the newest N release directories per unit type,
# delete older ones. The repo's bin/<version>/ remains the master copy, so
# pruned releases are recoverable by re-publishing.
#
# Usage: tools/prune-releases.sh /var/www/ota-store [KEEP=5]
# A release still referenced by any channel or a device pinned_version is
# NEVER pruned.
set -euo pipefail
STORE="${1:?usage: prune-releases.sh /path/to/ota-store [keep]}"
KEEP="${2:-5}"

referenced() {   # versions a channel points at, or a device is pinned to
    { cat "$STORE"/channels/*.json 2>/dev/null; cat "$STORE"/devices.json 2>/dev/null; } \
        | grep -oE '"(version|pinned_version)"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | grep -oE '"[^"]+"$' | tr -d '"' | sort -u
}

mapfile -t keep_refs < <(referenced)
# Sort release dirs newest-first by mtime; keep the first KEEP plus referenced.
i=0
while IFS= read -r dir; do
    v="$(basename "$dir")"
    i=$((i+1))
    keep=0
    [ "$i" -le "$KEEP" ] && keep=1
    for r in "${keep_refs[@]:-}"; do [ "$r" = "$v" ] && keep=1; done
    if [ "$keep" -eq 0 ]; then
        echo "prune release $v"
        rm -rf -- "$dir"
    fi
done < <(ls -1dt "$STORE"/releases/*/ 2>/dev/null)

echo "retention done (kept newest $KEEP + referenced)"
