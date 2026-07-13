<?php
/**
 * ROTA manifest endpoint — wire contract v1.1 (rota-contract-v1.1).
 *
 * GET /manifest.php?fw=<running-version>[&res=<a>.<b>]
 *   Auth: X-OTA-Auth (see rota_lib.php / TDS §4.2).
 *   - authenticate (failure → 204)
 *   - record the check-in (running version + last audit outcome)
 *   - resolve the offered release: pinned_version, else the device's channel
 *     mainstream for its unit_type
 *   - return HTTP 200 + the stored release manifest (the CLIENT decides
 *     whether it is newer). 404 if nothing is offered / manifest missing.
 */

require __DIR__ . '/lib/rota_lib.php';

[$id, $dev] = rota_authenticate();

/* Check-in telemetry (best-effort; never blocks the response). */
$fw  = (string)($_GET['fw']  ?? '');
$res = (string)($_GET['res'] ?? '');
rota_record_checkin($id, $fw, $res);
rota_update_device($id, [
    'last_seen' => gmdate('c'),
    'fw_ver'    => rota_valid_version($fw) ? $fw : ($dev['fw_ver'] ?? null),
]);

/* Resolve the offered version. */
$offered = null;
if (!empty($dev['pinned_version']) && rota_valid_version((string)$dev['pinned_version'])) {
    $offered = (string)$dev['pinned_version'];
} else {
    $channel  = (string)($dev['channel']   ?? 'mainstream');
    $unitType = (string)($dev['unit_type'] ?? '');
    $chan = rota_read_json(rota_store() . "/channels/{$channel}.json");
    if ($chan !== null && isset($chan[$unitType]['version'])) {
        $offered = (string)$chan[$unitType]['version'];
    }
}
if ($offered === null || !rota_valid_version($offered)) {
    rota_json(404, ['error' => 'no_release']);
}

/* Serve the stored release manifest (built by build_release.ps1 publish). */
$manifest = rota_read_json(rota_store() . "/releases/{$offered}/manifest-{$offered}.json");
if ($manifest === null) {
    rota_json(404, ['error' => 'manifest_missing', 'version' => $offered]);
}
rota_json(200, $manifest);
