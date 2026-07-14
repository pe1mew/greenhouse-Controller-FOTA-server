<?php
/**
 * ROTA server shared library — wire contract v1.1 (rota-contract-v1.1).
 *
 * Included by public/manifest.php and public/download.php via require.
 * Not an HTTP entry point: nginx serves only the two endpoint scripts
 * (location = exact match; everything else 404s). This guard is defence in
 * depth in case that config is ever wrong.
 */

if (basename($_SERVER['SCRIPT_FILENAME'] ?? '') === 'rota_lib.php') {
    http_response_code(404);
    exit;
}

/* ── Configuration ──────────────────────────────────────────────────────
 * ROTA_STORE: absolute path to ota-store/ (OUTSIDE the webroot). Set via
 *   fastcgi_param ROTA_STORE "/var/www/ota-store";
 * in the nginx PHP location, or a PHP-FPM pool env. Dev default below.
 * ROTA_NO_XACCEL: when set, download.php streams the file directly instead
 *   of using nginx X-Accel-Redirect (for `php -S` local testing).
 */
const ROTA_SKEW_S      = 300;   // ±5 min clock-skew window (§4.2)
const ROTA_NONCE_TTL_S = 600;   // 10 min replay-cache window (§4.2)

function rota_store(): string {
    $s = getenv('ROTA_STORE');
    if ($s === false || $s === '') {
        $s = $_SERVER['ROTA_STORE'] ?? '/var/www/ota-store';
    }
    return rtrim($s, '/');
}

/* ── Response helpers ───────────────────────────────────────────────────*/

/** Failed authentication: silent drop. 204 is reserved for this (§4.1). */
function rota_204(): void {
    http_response_code(204);
    exit;
}

function rota_json(int $code, array $body): void {
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}

function rota_read_json(string $path): ?array {
    if (!is_file($path)) return null;
    $raw = file_get_contents($path);
    if ($raw === false) return null;
    $d = json_decode($raw, true);
    return is_array($d) ? $d : null;
}

/** SemVer-ish token used for versions and unit-type-derived filenames. */
function rota_valid_version(string $v): bool {
    return $v !== ''
        && strlen($v) <= 32
        && preg_match('/^[0-9A-Za-z.\-]+$/', $v) === 1
        && strpos($v, '..') === false;
}

/* ── Registry (devices.json), atomic updates ────────────────────────────*/

function rota_registry_path(): string {
    return rota_store() . '/devices.json';
}

function rota_load_registry(): array {
    return rota_read_json(rota_registry_path()) ?? [];
}

/**
 * Merge $fields into the device record under an exclusive lock, then replace
 * the registry atomically (tmp + rename). Best-effort: a missing registry or
 * lock failure silently skips the telemetry update (never blocks a request).
 */
function rota_update_device(string $id, array $fields): void {
    $path = rota_registry_path();
    $lock = @fopen($path . '.lock', 'c');
    if ($lock === false) return;
    if (!flock($lock, LOCK_EX)) { fclose($lock); return; }
    $reg = rota_read_json($path) ?? [];
    if (isset($reg[$id]) && is_array($reg[$id])) {
        $reg[$id] = array_merge($reg[$id], $fields);
        $tmp = $path . '.tmp';
        if (file_put_contents($tmp,
                json_encode($reg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)) !== false) {
            rename($tmp, $path);   // atomic on POSIX
        }
    }
    flock($lock, LOCK_UN);
    fclose($lock);
}

function rota_record_checkin(string $id, string $fw, string $res): void {
    $line = sprintf("%s,%s,%s,%s\n",
        gmdate('c'), $id,
        preg_replace('/[^0-9A-Za-z.\-]/', '', $fw),   // sanitise reported version
        preg_replace('/[^0-9.]/', '', $res));         // sanitise "a.b" audit pair
    @file_put_contents(rota_store() . '/checkins.csv', $line, FILE_APPEND | LOCK_EX);
}

/**
 * Append a timestamped line to the human-readable device-activity log
 * (check-ins + downloads). Best-effort: a missing/unwritable log never blocks
 * the response. Path from $ROTA_DEVICE_LOG (default /var/log/rota-device.log);
 * control characters are stripped to prevent log injection from GET params.
 */
function rota_device_log(string $msg): void {
    $path = getenv('ROTA_DEVICE_LOG');
    if ($path === false || $path === '') {
        $path = '/var/log/rota-device.log';
    }
    $msg = preg_replace('/[[:cntrl:]]+/', ' ', $msg);
    @file_put_contents($path, gmdate('c') . ' ' . $msg . "\n", FILE_APPEND | LOCK_EX);
}

/* ── Nonce replay cache (flat-file, self-pruning) ───────────────────────*/

function rota_nonce_first_use(string $nonce): bool {
    $dir = rota_store() . '/nonce-cache';
    if (!is_dir($dir)) @mkdir($dir, 0750, true);
    $now = time();
    foreach (glob($dir . '/*') ?: [] as $f) {          // prune > TTL
        if (($now - (int)@filemtime($f)) > ROTA_NONCE_TTL_S) @unlink($f);
    }
    $fp = @fopen($dir . '/' . $nonce, 'x');            // atomic create-if-absent
    if ($fp === false) return false;                   // seen before → replay
    fclose($fp);
    return true;
}

/* ── Authentication (§4.2) ──────────────────────────────────────────────
 * On any failure emits 204 and exits. On success returns [id, device-record].
 */
function rota_authenticate(): array {
    $parts = explode(':', $_SERVER['HTTP_X_OTA_AUTH'] ?? '');
    if (count($parts) !== 4) rota_204();
    [$id, $ts, $nonce, $mac] = $parts;

    // Cheap shape checks before any I/O.
    if (!preg_match('/^[0-9a-f]{12}$/',  $id))    rota_204();
    if (!preg_match('/^[0-9]{1,20}$/',   $ts))    rota_204();
    if (!preg_match('/^[0-9a-f]{16}$/',  $nonce)) rota_204();
    if (!preg_match('/^[0-9a-f]{64}$/',  $mac))   rota_204();

    if (abs(time() - (int)$ts) > ROTA_SKEW_S) rota_204();

    $dev = rota_load_registry()[$id] ?? null;
    if (!is_array($dev) || empty($dev['enabled']) || empty($dev['secret'])) rota_204();

    $uri  = $_SERVER['REQUEST_URI'] ?? '';
    $msg  = $id . '|' . $ts . '|' . $nonce . '|' . $uri;
    $calc = hash_hmac('sha256', $msg, (string)$dev['secret']);
    if (!hash_equals($calc, $mac)) rota_204();

    if (!rota_nonce_first_use($nonce)) rota_204();      // replay

    return [$id, $dev];
}
