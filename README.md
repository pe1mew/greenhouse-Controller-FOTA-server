# greenhouse-Controller FOTA server

Pull-OTA server for the greenhouse ventilation controller. Runs as PHP behind nginx on the operator's VPS and serves firmware/asset releases to controllers that authenticate per the ROTA wire contract.

## Wire contract

This repository implements **wire contract v1.0** — frozen as **§4 of `design/rota_tds.md`** in the firmware repository, tag **`rota-contract-v1.0`**:

> https://github.com/pe1mew/greenhouse-Controller — `design/rota_tds.md` §4 at tag `rota-contract-v1.0`

The contract defines the endpoints, the `X-OTA-Auth` header (per-unit HMAC-SHA256), the manifest JSON schema, the audit codes, and the server store layout. Contract changes require a new contract version and coordinated changes in both repositories (TDS requirement R-T06).

## Repository layout

| Path | Contents |
|---|---|
| `public/` | Web-reachable endpoints: `manifest.php`, `download.php` — deployed to `/hbwv/ota/` |
| `nginx/ota.conf` | Server-block fragment: TLS with the pinned certificate, PHP-FPM pass, `internal` location for `X-Accel-Redirect` downloads |
| `tools/deploy.sh` | Deployment to the VPS — SSH public-key auth, host-key checking enforced (R-T07) |
| `tools/deploy.env.example` | Template for the git-ignored `.deploy.env` |
| `.github/workflows/lint.yml` | CI: PHP lint over all sources |

**Not in this repository, by design (R-T07):** private keys, certificates, device secrets, the live device registry (`devices.json`), check-in logs, and release artefacts. Runtime state lives in `ota-store/` on the VPS (outside the webroot); secrets live in the operator's secret store. `.gitignore` enforces this.

## Deployment

```
cp tools/deploy.env.example .deploy.env   # fill in host/user/key — stays git-ignored
tools/deploy.sh
```

`deploy.sh` uses SSH public-key authentication with `StrictHostKeyChecking=yes` and syncs `public/` to the webroot. It never touches `ota-store/` (runtime data: registry, releases, check-ins). nginx config changes are copied but reloading nginx is a deliberate manual step on the VPS.

## Acceptance testing

The server's acceptance suite is the **device simulator** in the firmware repository (`bin/rota_sim.py`, implementation-plan Phase 2): it exercises correct/incorrect HMAC, replay, clock skew, certificate pinning, and mainstream-vs-pinned version resolution against a deployed instance — no ESP32 required. The server is "done" (Phase 1 exit) when that suite passes.

## Status

**Scaffold only** (implementation-plan task 0.2). The endpoints return `501 Not Implemented`. Phase 1 (task 1.1–1.6 of `design/rotaImplementationPlan.md` in the firmware repo) fills in the implementation.
