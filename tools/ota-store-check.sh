#!/usr/bin/env bash
# ota-store-check.sh -- read-only health/syntax check of the ROTA ota-store.
#
# Validates the operator-edited config files and the staged releases:
#
#   devices.json       valid JSON; object keyed by 12-lowercase-hex device ids;
#                      per entry: secret set (value NEVER printed), enabled a
#                      bool, unit_type set, channel known, pinned_version null
#                      or a valid + staged version; file not world-accessible
#   channels/*.json    valid JSON; { "<unit_type>": {"version": "<v>"} }; every
#                      pointed version staged with a readable manifest
#   releases/<v>/      manifest-<v>.json valid JSON; required fields present;
#                      version agrees with dir + filename; artefacts exist;
#                      sizes match; sha256 match (skip with --quick); seq
#                      unique across releases
#   checkins.csv       4-field CSV lines with an ISO timestamp first
#   nonce-cache/       present (created on demand by the server -- info only)
#
# Why: a malformed devices.json fails CLOSED on the server -- every unit gets
# 204 and it looks like an auth failure. This script catches that BEFORE a
# unit does (see the firmware repo's memory/gotcha-log.md, 2026-07-13).
#
# Usage:   ota-store-check.sh [STORE] [--quick]
#            STORE    store root (default /var/www/ota-store)
#            --quick  skip sha256 verification of artefacts (sizes still checked)
#          Run as a user that can read the store, e.g.:
#            sudo -u www-data tools/ota-store-check.sh /var/www/ota-store
#
# Exit:    0 = no errors (warnings allowed) | 1 = errors found | 3 = cannot run
#
# Read-only. Never writes to the store, never prints secret values.

set -u

STORE=/var/www/ota-store
QUICK=0
for a in "$@"; do
    case "$a" in
        --quick)   QUICK=1 ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         STORE="${a%/}" ;;
    esac
done

ERR=0; WRN=0
ok()   { printf '[ OK ] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; WRN=$((WRN+1)); }
fail() { printf '[FAIL] %s\n' "$1"; ERR=$((ERR+1)); }
info() { printf '[info] %s\n' "$1"; }

command -v php >/dev/null 2>&1       || { echo "ERROR: php not found" >&2; exit 3; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum not found" >&2; exit 3; }
[ -d "$STORE" ] || { echo "ERROR: store not found: $STORE" >&2; exit 3; }
[ -r "$STORE" ] || { echo "ERROR: store not readable -- run as e.g.: sudo -u www-data $0 $STORE" >&2; exit 3; }

echo "== ota-store-check: $STORE $( [ "$QUICK" = 1 ] && echo '(--quick: sha256 skipped)' ) =="

# ---------------------------------------------------------------- devices.json
# The PHP emits pipe-separated machine lines; messages never contain '|' and
# never contain secret values.
read -r -d '' PHP_DEVICES <<'EOF' || true
$reg = json_decode(@file_get_contents($argv[1]), true);
if (!is_array($reg)) { echo "E|devices.json: INVALID JSON -- server fails closed, EVERY unit gets 204\n"; exit(0); }
$n = 0; $en = 0;
foreach ($reg as $id => $d) {
    $n++;
    $w = "devices.json [" . $id . "]";
    if (!preg_match('/^[0-9a-f]{12}$/', (string)$id))
        echo "E|$w: key is not a 12-lowercase-hex device id\n";
    if (!is_array($d)) { echo "E|$w: entry is not an object\n"; continue; }
    if (!isset($d['secret']) || !is_string($d['secret']) || $d['secret'] === '')
        echo "E|$w: secret missing/empty -- unit will get 204\n";
    elseif (strlen($d['secret']) < 16)
        echo "W|$w: secret shorter than 16 chars (unit-side minimum is 16)\n";
    if (!array_key_exists('enabled', $d))
        echo "W|$w: enabled missing -- unit is treated as DISABLED (204)\n";
    elseif (!is_bool($d['enabled']))
        echo "W|$w: enabled is not a JSON bool (true/false)\n";
    if (!empty($d['enabled'])) $en++;
    $ut = isset($d['unit_type']) && is_string($d['unit_type']) ? $d['unit_type'] : '';
    if ($ut === '')
        echo "W|$w: unit_type missing/empty -- channel lookup will miss (404 no_release)\n";
    $ch = isset($d['channel']) && is_string($d['channel']) ? $d['channel'] : 'mainstream';
    if (!in_array($ch, array('soak', 'mainstream'), true))
        echo "W|$w: channel '$ch' is not soak/mainstream -- needs channels/$ch.json\n";
    $pv = array_key_exists('pinned_version', $d) ? $d['pinned_version'] : null;
    if ($pv !== null) {
        if (!is_string($pv) || $pv === '' || strlen($pv) > 32 ||
            !preg_match('#^[0-9A-Za-z.\-]+$#', $pv) || strpos($pv, '..') !== false)
            echo "E|$w: pinned_version is not a valid version token\n";
        else
            echo "PIN|$id|$pv\n";
    } elseif (!empty($d['enabled'])) {
        echo "RES|$id|$ch|$ut\n";      /* enabled + unpinned: resolves via channel */
    }
}
echo "I|devices.json: valid JSON, $n unit(s), $en enabled\n";
EOF

DEV="$STORE/devices.json"
PINS=""    # "id version" per line
RESOLVES="" # "id channel unit_type" per line
if [ ! -f "$DEV" ]; then
    fail "devices.json missing -- server fails closed: EVERY unit gets 204"
elif [ ! -r "$DEV" ]; then
    fail "devices.json not readable by this user"
else
    mode=$(stat -c %a "$DEV" 2>/dev/null || echo "")
    case "$mode" in
        *[1-7]) warn "devices.json mode $mode is world-accessible -- it holds per-unit secrets (expected 0640)" ;;
    esac
    while IFS='|' read -r t f2 f3 f4; do
        case "$t" in
            E)   fail "$f2" ;;
            W)   warn "$f2" ;;
            I)   ok   "$f2" ;;
            PIN) PINS="$PINS$f2 $f3
" ;;
            RES) RESOLVES="$RESOLVES$f2 $f3 $f4
" ;;
        esac
    done < <(php -r "$PHP_DEVICES" "$DEV")
fi

# --------------------------------------------------------------- channels/*.json
read -r -d '' PHP_CHANNEL <<'EOF' || true
$c = json_decode(@file_get_contents($argv[1]), true);
$name = basename($argv[1]);
if (!is_array($c)) { echo "E|$name: INVALID JSON -- units on this channel get 404 no_release\n"; exit(0); }
if (count($c) === 0) { echo "I|$name: valid JSON, no pointer yet ({})\n"; exit(0); }
foreach ($c as $ut => $e) {
    $w = "$name [" . $ut . "]";
    if (!is_array($e) || !isset($e['version']) || !is_string($e['version'])) {
        echo "E|$w: entry must be {\"version\": \"<v>\"} (version nested one level down)\n"; continue;
    }
    $v = $e['version'];
    if ($v === '' || strlen($v) > 32 || !preg_match('#^[0-9A-Za-z.\-]+$#', $v) || strpos($v, '..') !== false) {
        echo "E|$w: version is not a valid token\n"; continue;
    }
    echo "V|$name|$ut|$v\n";
}
EOF

CHANPTR=""  # "file unit_type version" per line
if [ -d "$STORE/channels" ]; then
    found=0
    for cf in "$STORE"/channels/*.json; do
        [ -f "$cf" ] || continue
        found=1
        while IFS='|' read -r t f2 f3 f4; do
            case "$t" in
                E) fail "$f2" ;;
                W) warn "$f2" ;;
                I) ok   "$f2" ;;
                V) CHANPTR="$CHANPTR$(basename "$cf") $f3 $f4
"
                   if [ -r "$STORE/releases/$f4/manifest-$f4.json" ]; then
                       ok "$f2 [$f3] -> $f4 (staged, manifest present)"
                   else
                       fail "$f2 [$f3] -> $f4 but releases/$f4/manifest-$f4.json is missing -- units get 404 manifest_missing"
                   fi ;;
            esac
        done < <(php -r "$PHP_CHANNEL" "$cf")
    done
    [ "$found" = 1 ] || warn "channels/ contains no .json files"
    for want in soak mainstream; do
        [ -f "$STORE/channels/$want.json" ] || warn "channels/$want.json missing"
    done
else
    fail "channels/ directory missing"
fi

# ------------------------------------------------------------------- releases/
read -r -d '' PHP_MANIFEST <<'EOF' || true
$m = json_decode(@file_get_contents($argv[1]), true);
$v = $argv[2];
$w = "releases/$v";
if (!is_array($m)) { echo "E|$w: manifest-$v.json is INVALID JSON\n"; exit(0); }
$req = array('version','seq','unit_type','fw_file','fw_sha256','fw_size',
             'assets_file','assets_sha256','assets_size');
$miss = array();
foreach ($req as $k) if (!array_key_exists($k, $m)) $miss[] = $k;
if ($miss) { echo "E|$w: manifest missing required field(s): " . implode(', ', $miss) . "\n"; exit(0); }
foreach (array('min_version','key_id','released_at') as $k)
    if (!array_key_exists($k, $m)) echo "W|$w: manifest lacks optional field '$k'\n";
if ((string)$m['version'] !== $v)
    echo "E|$w: manifest version '" . $m['version'] . "' does not match directory name\n";
if (!is_int($m['seq']) || $m['seq'] < 1)
    echo "E|$w: seq must be a positive integer\n";
else
    echo "SEQ|" . $m['seq'] . "\n";
foreach (array('fw','assets') as $p) {
    $f = (string)$m[$p . '_file']; $h = strtolower((string)$m[$p . '_sha256']); $s = $m[$p . '_size'];
    if ($f === '' || strpbrk($f, "/\\") !== false)
        { echo "E|$w: {$p}_file '" . $f . "' empty or contains a path separator\n"; continue; }
    if (!preg_match('/^[0-9a-f]{64}$/', $h))
        { echo "E|$w: {$p}_sha256 is not 64 hex chars\n"; continue; }
    if (!is_int($s) || $s <= 0)
        { echo "E|$w: {$p}_size must be a positive integer\n"; continue; }
    echo "F|$p|$f|$h|$s\n";
}
EOF

if [ -d "$STORE/releases" ]; then
    nrel=0
    SEQLIST=""
    for dir in "$STORE"/releases/*/; do
        [ -d "$dir" ] || continue
        v=$(basename "$dir")
        case "$v" in
            .staging-*) warn "releases/$v: leftover staging directory (interrupted retriever run?)"; continue ;;
        esac
        nrel=$((nrel+1))
        man="$dir/manifest-$v.json"
        if [ ! -f "$man" ]; then
            fail "releases/$v: manifest-$v.json missing"
            continue
        fi
        manifest_ok=1
        while IFS='|' read -r t f2 f3 f4 f5; do
            case "$t" in
                E) fail "$f2"; manifest_ok=0 ;;
                W) warn "$f2" ;;
                SEQ)
                    case " $SEQLIST " in
                        *" $f2 "*) fail "releases/$v: seq $f2 DUPLICATES another release (anti-downgrade breaks)" ;;
                        *) SEQLIST="$SEQLIST $f2" ;;
                    esac ;;
                F)
                    kind=$f2; fname=$f3; want_sha=$f4; want_size=$f5
                    disk="$dir$fname"
                    if [ ! -f "$disk" ]; then
                        fail "releases/$v: $kind artefact '$fname' missing on disk"
                        continue
                    fi
                    got_size=$(stat -c %s "$disk" 2>/dev/null || echo -1)
                    if [ "$got_size" != "$want_size" ]; then
                        fail "releases/$v: $fname size $got_size != manifest $want_size"
                        continue
                    fi
                    if [ "$QUICK" = 1 ]; then
                        ok "releases/$v: $fname size matches (sha256 skipped)"
                    else
                        got_sha=$(sha256sum "$disk" | cut -d' ' -f1)
                        if [ "$got_sha" = "$want_sha" ]; then
                            ok "releases/$v: $fname size + sha256 match"
                        else
                            fail "releases/$v: $fname sha256 MISMATCH vs manifest"
                        fi
                    fi ;;
            esac
        done < <(php -r "$PHP_MANIFEST" "$man" "$v")
        [ "$manifest_ok" = 1 ] && ok "releases/$v: manifest valid"
    done
    if [ "$nrel" = 0 ]; then
        warn "releases/ contains no staged releases"
    else
        info "releases/: $nrel staged release(s)"
    fi
else
    fail "releases/ directory missing"
fi

# --------------------------------------- cross-checks from devices.json content
if [ -n "$PINS" ]; then
    while read -r id pv; do
        [ -n "$id" ] || continue
        if [ -r "$STORE/releases/$pv/manifest-$pv.json" ]; then
            ok "pin: unit $id -> $pv (staged)"
        else
            fail "pin: unit $id pinned to $pv but it is not staged -- unit gets 404 manifest_missing"
        fi
    done <<< "$PINS"
fi
if [ -n "$RESOLVES" ]; then
    while read -r id ch ut; do
        [ -n "$id" ] || continue
        hit=0
        while read -r cfile cut cver; do
            [ -n "$cfile" ] || continue
            [ "$cfile" = "$ch.json" ] && [ "$cut" = "$ut" ] && hit=1
        done <<< "$CHANPTR"
        if [ "$hit" = 1 ]; then
            ok "resolve: enabled unit $id ($ch/$ut) is offered a release"
        else
            warn "resolve: enabled unit $id ($ch/$ut) resolves to NOTHING -- it gets 404 no_release"
        fi
    done <<< "$RESOLVES"
fi

# ---------------------------------------------------------------- checkins.csv
CSV="$STORE/checkins.csv"
if [ -f "$CSV" ]; then
    badlines=$(awk -F, '$0 != "" && (NF != 4 || $1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) { print NR }' "$CSV" | head -5)
    if [ -z "$badlines" ]; then
        ok "checkins.csv: all lines are 4-field CSV with ISO timestamps ($(grep -c . "$CSV" 2>/dev/null || echo 0) rows)"
    else
        warn "checkins.csv: malformed line(s) at: $(echo "$badlines" | tr '\n' ' ')"
    fi
else
    warn "checkins.csv missing (created by init-store.sh; harmless if the store is new)"
fi

# ----------------------------------------------------------------- nonce-cache
if [ -d "$STORE/nonce-cache" ]; then
    ok "nonce-cache/ present"
else
    info "nonce-cache/ absent (the server creates it on first authenticated request)"
fi

# --------------------------------------------------------------------- summary
echo ""
echo "== summary: $ERR error(s), $WRN warning(s) =="
[ "$ERR" -eq 0 ] && exit 0 || exit 1
