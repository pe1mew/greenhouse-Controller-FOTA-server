<?php
/**
 * ROTA artefact download endpoint — wire contract v1.0 (rota-contract-v1.0).
 *
 * GET /hbwv/ota/download.php?file=fw|assets&v=<version>
 *   Auth: identical X-OTA-Auth scheme as manifest.php (see there).
 *   On authenticated request:
 *     - resolve to ota-store/releases/<v>/<artefact>
 *     - serve via nginx X-Accel-Redirect (PHP authenticates, nginx streams)
 *     - 404 for unknown version/file
 *   Failed auth -> HTTP 204, empty body.
 *
 * Scaffold (task 0.2): not yet implemented — Phase 1, task 1.2.
 */

http_response_code(501);
header('Content-Type: text/plain');
echo "Not Implemented\n";
