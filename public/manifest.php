<?php
/**
 * ROTA manifest endpoint — wire contract v1.0 (rota-contract-v1.0).
 *
 * GET /hbwv/ota/manifest.php?fw=<running-version>[&res=<a>.<b>]
 *   Auth: X-OTA-Auth: <id>:<ts>:<nonce>:<mac>
 *         mac = HMAC-SHA256(ota_secret, id|ts|nonce|request_uri)
 *         id = full WiFi MAC, 12 lowercase hex; ts = unix s; nonce = 16 hex.
 *   On authenticated request:
 *     - resolve unit -> pinned_version, else channels/<unit_type>.json
 *     - ALWAYS return HTTP 200 + full manifest JSON (client decides newness)
 *     - append check-in (unit, ts, fw=, res=) to checkins.csv
 *   Failed auth -> HTTP 204, empty body (204 is reserved for auth failure).
 *   Server checks: |skew| <= 300 s, nonce unseen for 10 min, hash_equals().
 *
 * Scaffold (task 0.2): not yet implemented — Phase 1, task 1.1.
 */

http_response_code(501);
header('Content-Type: text/plain');
echo "Not Implemented\n";
