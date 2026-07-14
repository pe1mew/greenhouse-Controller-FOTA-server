<?php
/**
 * ROTA artefact download endpoint — wire contract v1.1 (rota-contract-v1.1).
 *
 * GET /download.php?file=fw|assets&v=<version>
 *   Auth: X-OTA-Auth (see rota_lib.php / TDS §4.2).
 *   - authenticate (failure → 204)
 *   - resolve file+version → the exact artefact named in that release manifest
 *   - stream via nginx X-Accel-Redirect (PHP authenticates, nginx sends the
 *     bytes). With ROTA_NO_XACCEL set, stream directly (php -S testing).
 *   - 404 for unknown version / file / missing artefact.
 */

require __DIR__ . '/lib/rota_lib.php';

[$id, $dev] = rota_authenticate();

$file = (string)($_GET['file'] ?? '');
$v    = (string)($_GET['v']    ?? '');
if (!in_array($file, ['fw', 'assets'], true) || !rota_valid_version($v)) {
    rota_json(404, ['error' => 'bad_request']);
}

/* The exact filename comes from the release manifest — never guessed, and
 * rejected if it contains a path separator (traversal guard). */
$manifest = rota_read_json(rota_store() . "/releases/{$v}/manifest-{$v}.json");
if ($manifest === null) {
    rota_json(404, ['error' => 'unknown_version']);
}
$name = $file === 'fw'
    ? (string)($manifest['fw_file']     ?? '')
    : (string)($manifest['assets_file'] ?? '');
if ($name === '' || strpbrk($name, "/\\") !== false) {
    rota_json(404, ['error' => 'no_artefact']);
}

$disk = rota_store() . "/releases/{$v}/{$name}";
if (!is_file($disk)) {
    rota_json(404, ['error' => 'artefact_missing']);
}

rota_device_log("download id=$id file=$file v=$v name=$name");

header('Content-Type: application/octet-stream');
header('Content-Disposition: attachment; filename="' . $name . '"');

if (getenv('ROTA_NO_XACCEL')) {
    /* Dev/test path — nginx X-Accel-Redirect not available under php -S. */
    header('Content-Length: ' . filesize($disk));
    $fp = fopen($disk, 'rb');
    fpassthru($fp);
    fclose($fp);
    exit;
}

/* Production path — nginx streams from the internal location (see ota.conf). */
header('X-Accel-Redirect: /ota-store-internal/releases/'
       . rawurlencode($v) . '/' . rawurlencode($name));
exit;
