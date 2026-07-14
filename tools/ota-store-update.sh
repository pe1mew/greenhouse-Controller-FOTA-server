#!/usr/bin/env bash
# ota-store-update.sh -- pull the latest ROTA release from GitHub into ota-store.
#
# Runs ON the VPS (cron or manual), pull-based (R-T07): the public firmware repo
# is polled over HTTPS with tokenless GETs, so no VPS-write key ever lives in
# GitHub. Firmware/asset bytes are non-secret (Q5); channels + devices.json stay
# VPS-only and operator-controlled.
#
# Flow (manifest-gated, verify-before-stage):
#   GET /releases/latest        (newest NON-prerelease, NON-draft)
#     -> skip if it has no manifest-<version>.json asset  (legacy/non-ROTA release)
#     -> download the manifest; read version/unit_type/seq/fw+assets sha256+size
#     -> download fw_file + assets_file (names from the manifest, URLs from assets)
#     -> VERIFY sha256 + size of both BEFORE staging
#     -> stage atomically into releases/<version>/
#     -> point channels/soak.json[unit_type]  (full release only; monotonic guard)
#   With --stage-prereleases, prereleases are staged too but soak is NOT pointed.
#   Mainstream is NEVER pointed here -- promotion stays a manual server-side step.
#
# Deps: curl, php (already required by the server), sha256sum, coreutils.
# Config (env): GH_API_BASE (default the public repo), GH_TOKEN (optional, raises
#   the 60/hr tokenless rate limit / for a private repo), ROTA_KEEP (retention).
#
# Usage: tools/ota-store-update.sh /var/www/ota-store [--stage-prereleases]
set -euo pipefail

STORE="${1:?usage: ota-store-update.sh /path/to/ota-store [--stage-prereleases]}"
STAGE_PRE=0
[ "${2:-}" = "--stage-prereleases" ] && STAGE_PRE=1
[ "${STAGE_PRERELEASES:-0}" = "1" ] && STAGE_PRE=1

GH_API_BASE="${GH_API_BASE:-https://api.github.com/repos/pe1mew/greenhouse-Controller}"
KEEP="${ROTA_KEEP:-5}"

log() { echo "[ota-store-update] $*"; }
die() { echo "[ota-store-update] ERROR: $*" >&2; exit "${2:-1}"; }

for c in curl php sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c" 3
done
[ -d "$STORE" ] || die "ota-store not found: $STORE (run tools/init-store.sh first)" 3

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- curl helpers (tokenless unless GH_TOKEN is set) ------------------------
CURL=(curl -fsSL -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28" -H "User-Agent: ota-store-update")
[ -n "${GH_TOKEN:-}" ] && CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")

# --- JSON helpers (PHP: guaranteed on this host, robust for nested assets) --
jfield()  { php -r '$d=json_decode(stream_get_contents(STDIN),true); $v=$d[$argv[1]]??""; echo is_bool($v)?($v?"1":"0"):$v;' "$1"; }
jasset()  { php -r '$d=json_decode(stream_get_contents(STDIN),true); foreach(($d["assets"]??[]) as $a){ if(fnmatch($argv[1],$a["name"]??"")){echo $a["browser_download_url"]??""; exit;} }' "$1"; }
jchanver(){ php -r '$d=json_decode(file_get_contents($argv[1]),true); echo $d[$argv[2]]["version"]??"";' "$1" "$2" 2>/dev/null || true; }

# --- 1. pick the release to consider ---------------------------------------
# Default: /releases/latest = newest NON-prerelease, NON-draft. GitHub excludes
# pre-releases from /latest, so with --stage-prereleases fetch the /releases list
# (newest-first by created_at) and take the newest entry instead.
REL="$TMP/release.json"
if [ "$STAGE_PRE" = "1" ]; then
    if ! "${CURL[@]}" "$GH_API_BASE/releases?per_page=1" -o "$TMP/list.json" 2>/dev/null; then
        log "release list fetch failed -- nothing to do"; exit 0
    fi
    php -r '$a=json_decode(stream_get_contents(STDIN),true); if(is_array($a)&&!empty($a[0])) echo json_encode($a[0]);' \
        < "$TMP/list.json" > "$REL"
    [ -s "$REL" ] || { log "no releases found -- nothing to do"; exit 0; }
elif ! "${CURL[@]}" "$GH_API_BASE/releases/latest" -o "$REL" 2>/dev/null; then
    log "no latest release available (or fetch failed) -- nothing to do"; exit 0
fi
TAG="$(jfield tag_name < "$REL")"
PRE="$(jfield prerelease < "$REL")"
MAN_URL="$(jasset 'manifest-*.json' < "$REL")"

if [ -z "$MAN_URL" ]; then
    log "release '$TAG' has no manifest-*.json asset -> not a ROTA release, skipping"; exit 0
fi
if [ "$PRE" = "1" ] && [ "$STAGE_PRE" != "1" ]; then
    log "release '$TAG' is a pre-release (--stage-prereleases not set), skipping"; exit 0
fi

# --- 2. manifest is authoritative for identity + integrity -----------------
"${CURL[@]}" "$MAN_URL" -o "$TMP/manifest.json" || die "manifest download failed: $MAN_URL" 4
VER="$(jfield version       < "$TMP/manifest.json")"
UT="$( jfield unit_type     < "$TMP/manifest.json")"
SEQ="$(jfield seq           < "$TMP/manifest.json")"
FWF="$(jfield fw_file       < "$TMP/manifest.json")"
FWS="$(jfield fw_sha256     < "$TMP/manifest.json")"
FWZ="$(jfield fw_size       < "$TMP/manifest.json")"
ASF="$(jfield assets_file   < "$TMP/manifest.json")"
ASS="$(jfield assets_sha256 < "$TMP/manifest.json")"
ASZ="$(jfield assets_size   < "$TMP/manifest.json")"
[ -n "$VER" ] && [ -n "$UT" ] && [ -n "$SEQ" ] && [ -n "$FWF" ] && [ -n "$ASF" ] \
    || die "manifest for '$TAG' is missing required fields" 4
case "$VER$UT" in *[!0-9A-Za-z._-]*) die "manifest version/unit_type has unsafe characters" 4;; esac
log "candidate: tag=$TAG version=$VER unit_type=$UT seq=$SEQ prerelease=$PRE"

DEST="$STORE/releases/$VER"

# --- 3. stage (download + verify) unless this exact seq is already present --
NEED_STAGE=1
if [ -f "$DEST/manifest-$VER.json" ] && [ "$(jfield seq < "$DEST/manifest-$VER.json")" = "$SEQ" ]; then
    NEED_STAGE=0
    log "version $VER (seq $SEQ) already staged"
fi

if [ "$NEED_STAGE" = "1" ]; then
    FW_URL="$(jasset "$FWF" < "$REL")"
    AS_URL="$(jasset "$ASF" < "$REL")"
    [ -n "$FW_URL" ] && [ -n "$AS_URL" ] || die "manifest names not found among release assets" 4
    "${CURL[@]}" "$FW_URL" -o "$TMP/$FWF" || die "firmware download failed" 4
    "${CURL[@]}" "$AS_URL" -o "$TMP/$ASF" || die "assets download failed" 4

    verify() {   # file expected_sha expected_size
        local got_sha got_sz
        got_sha="$(sha256sum "$1" | cut -d' ' -f1)"
        got_sz="$(wc -c < "$1" | tr -d ' ')"
        [ "$got_sha" = "$2" ] || die "sha256 mismatch on $(basename "$1"): got $got_sha want $2" 5
        [ "$got_sz" = "$3" ]  || die "size mismatch on $(basename "$1"): got $got_sz want $3" 5
    }
    verify "$TMP/$FWF" "$FWS" "$FWZ"
    verify "$TMP/$ASF" "$ASS" "$ASZ"
    log "verified sha256 + size on both artefacts"

    STAGING="$STORE/releases/.staging-$VER.$$"
    rm -rf "$STAGING"; mkdir -p "$STAGING"
    cp "$TMP/$FWF" "$TMP/$ASF" "$STAGING/"
    cp "$TMP/manifest.json" "$STAGING/manifest-$VER.json"
    rm -rf "$DEST"; mkdir -p "$STORE/releases"
    mv "$STAGING" "$DEST"
    chmod -R 0750 "$DEST"
    log "staged $VER -> $DEST"
fi

# --- 4. point soak (full release only; never downgrade; mainstream is manual)
if [ "$PRE" = "1" ]; then
    log "pre-release: staged only, soak NOT pointed"
else
    CUR_VER="$(jchanver "$STORE/channels/soak.json" "$UT")"
    if [ "$CUR_VER" = "$VER" ]; then
        log "soak[$UT] already at $VER -- nothing to point"
    else
        CUR_SEQ=""
        [ -n "$CUR_VER" ] && [ -f "$STORE/releases/$CUR_VER/manifest-$CUR_VER.json" ] \
            && CUR_SEQ="$(jfield seq < "$STORE/releases/$CUR_VER/manifest-$CUR_VER.json")"
        if [ -n "$CUR_SEQ" ] && [ "$SEQ" -le "$CUR_SEQ" ]; then
            log "WARN: candidate seq $SEQ <= soak seq $CUR_SEQ ($CUR_VER); NOT pointing soak (no downgrade)"
        else
            php -r '$f=$argv[1]; $c=is_file($f)?json_decode(file_get_contents($f),true):[]; if(!is_array($c))$c=[]; $c[$argv[2]]=["version"=>$argv[3]]; file_put_contents($f.".tmp", json_encode($c, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");' \
                "$STORE/channels/soak.json" "$UT" "$VER"
            mv "$STORE/channels/soak.json.tmp" "$STORE/channels/soak.json"
            log "pointed soak[$UT] -> $VER (seq $SEQ)"
        fi
    fi
fi

# --- 5. retention (R-S08) --------------------------------------------------
PRUNE="$(dirname "$0")/prune-releases.sh"
[ -x "$PRUNE" ] && "$PRUNE" "$STORE" "$KEEP" >/dev/null 2>&1 || true

log "done"
