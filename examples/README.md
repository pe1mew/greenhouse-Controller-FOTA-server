# Example ota-store data (schema reference)

These files document the on-disk schema of `ota-store/` (which itself lives on
the VPS outside the webroot and is git-ignored). They use **fake** ids, secrets,
and hashes — never real credentials.

Copy the structure onto the VPS under `ROTA_STORE` (e.g. `/var/www/ota-store`):

```
ota-store/
  devices.json                 <- devices.example.json (real secrets, mode 0640)
  channels/mainstream.json     <- channels-mainstream.example.json
  channels/soak.json
  releases/<version>/manifest-<version>.json   <- release.manifest.example.json
  releases/<version>/greenhouse-controller-<version>.bin
  releases/<version>/web-assets-<version>.zip
  checkins.csv                 (append-only, created by the server)
  nonce-cache/                 (created by the server)
```

- **devices.json** — keyed by the full-MAC identifier string (R-I02). `secret`
  is the per-unit `ota_secret`; `pinned_version` overrides the channel when set.
- **channels/<channel>.json** — keyed by `unit_type`; `version` is the release
  that channel currently offers. `build_release.ps1` points `soak`; `ota_promote`
  points `mainstream`.
- **releases/<v>/manifest-<v>.json** — the §4.3 manifest, emitted by the publish
  step; `manifest.php` returns it verbatim.

Local test with PHP's built-in server (no nginx):

```
ROTA_STORE=./examples/ota-store ROTA_NO_XACCEL=1 php -S 127.0.0.1:8080 -t public
python ../greenhouse-Controller/bin/rota_sim.py --base-url http://127.0.0.1:8080 \
    --id a0b1c2d3e4f5 --secret 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
```
