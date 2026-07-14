# Wire contract
The wire contract is the frozen interface between the firmware and this server — §4 of `design/rota_tds.md` in the firmware repo, tagged `rota-contract-v1.1` in both repositories. Here's the full picture.

## What it is and why it's frozen

The contract is the *normative* definition of everything that crosses the wire between a greenhouse controller and `ota.rfsee.net`: the endpoints, the authentication header, the manifest JSON schema, the HTTP status semantics, the audit codes, and the store layout the server must maintain. It's explicitly frozen (TDS requirement R-T06): because firmware in the field and the server deploy independently, neither side can change the interface unilaterally. Any change requires a new contract version and *coordinated* updates in both repos — which is why this repo's changelog is versioned by contract tag rather than by its own release number, as came up when we updated the changelog.

The version history illustrates the discipline: **v1.0** (tagged 2026-07-13) placed the endpoints under a `hbwv/ota/` prefix on the status site. Before anything deployed, the endpoints moved to the root of a dedicated `ota.rfsee.net` vhost. That looks like a mere URL change, but the request path is *inside the signed data* (see below) — so moving it invalidated every HMAC a v1.0 client would compute, and the contract was re-tagged **v1.1** rather than silently edited. v1.0 was superseded without ever being deployed.

## Where lives the contract?

The wire contract lives in the **firmware repository** — `greenhouse-Controller` (`pe1mew/greenhouse-Controller`), on branch **`rota`**:

- **`design/rota_tds.md` §4** is the contract, **frozen** and tagged **`rota-contract-v1.1`**. It defines the endpoints (`manifest.php`, `download.php`), the `X-OTA-Auth` header, the manifest JSON schema, the audit codes, and the store layout.

The **FOTA-server repo** (`greenhouse-Controller-FOTA-server`) is the *consumer*, not the owner — it **implements** the contract and **pins** the version/commit it targets (TDS requirement **R-T06**); its README points back to "§4 of `design/rota_tds.md` in the firmware repository." The device-side (T16) implements the same §4 on its end.

So it's a single source of truth in the firmware repo, referenced by both sides. Practical consequence (also R-T06): a contract change means a **new contract version** in `design/rota_tds.md` **plus** a coordinated update in the server repo — never change one side's wire behavior unilaterally against the frozen tag.

## The two endpoints

- `GET /manifest.php?fw=<running-version>[&res=<a>.<b>]` — check-in. The server authenticates, records telemetry (the reported running version, plus `res` = the last audit outcome pair, e.g. `24.0` meaning "apply committed"), resolves the unit to its offered release (pin, else channel matrix), and returns the **full stored manifest with HTTP 200**.
- `GET /download.php?file=fw|assets&v=<version>` — artefact fetch. The server looks up the *exact* filename from that release's stored manifest (never guessed, path-separator-rejected) and streams it via nginx `X-Accel-Redirect`, so PHP does the auth but nginx moves the bytes.

Two semantic choices here are load-bearing. First, **"no newer version" is not an HTTP condition** — the manifest is always returned and the *client* decides whether it's newer. That keeps the server dumb (it never needs to parse or compare versions) and makes check-ins idempotent telemetry events. Second, **204 is reserved exclusively for failed authentication** (R-A08): any auth failure — unknown id, bad MAC, stale timestamp, replayed nonce, disabled unit — gets an identical, empty, silent 204. An attacker probing the endpoint can't distinguish "wrong secret" from "unknown device" from "this isn't even an OTA server." Authenticated requests get honest answers: 200, 404 (`no_release`, `unknown_version`, `artefact_missing`, …), or 500.

## The authentication header

```
X-OTA-Auth: <id>:<ts>:<nonce>:<mac>
mac = HMAC-SHA256(ota_secret, id + "|" + ts + "|" + nonce + "|" + request_uri)
```

Each field earns its place. The `id` is the unit's full WiFi MAC (12 lowercase hex chars) — the registry key in `devices.json`. The `ts` (Unix seconds) is checked against a ±300 s window, which bounds how long a captured request stays valid and forces devices to keep reasonable clocks. The `nonce` (16 hex chars) goes into a 10-minute replay cache — [rota_nonce_first_use()](public/lib/rota_lib.php:123) creates a flag file atomically, so even within the timestamp window a sniffed request can't be replayed. And critically, the **entire `request_uri` including the query string is signed** — so an attacker can't take a valid check-in and rewrite it into a download request, change the requested version, or (as the v1.0→v1.1 bump shows) relocate the endpoint. Verification uses `hash_equals` (constant-time) to avoid timing side channels.

Transport sits underneath this: the device pins the server's exact certificate by fingerprint (R-A02/03/04) — a self-signed cert is fine *because* it's pinned; a MITM with a "valid" CA-issued cert gets nowhere. The HMAC then authenticates the device to the server, giving mutual authentication without client certificates (mTLS is an explicit upgrade path, kept open but out of scope).

## The manifest schema (§4.3)

The JSON returned by `manifest.php` and shipped as a GitHub release asset — the same document, byte-for-byte, authored once by `rota_release.py` and returned verbatim by the server:

| Field | Role |
|---|---|
| `version` | The release identity (SemVer-ish token). |
| `seq` | Strictly monotonic release counter — the anti-downgrade backbone (R-V01/02). A device rejects any manifest whose `seq` doesn't exceed its NVS high-water mark; the release tool and the VPS retriever enforce the same monotonicity independently. |
| `unit_type` | Which hardware this is for (`ghc1`) — the matrix column. |
| `min_version` | A floor: a device running older than this must not jump directly to this release. |
| `key_id` | Reserved, empty — the hook for future manifest/firmware signing (R-A10) without a contract break. |
| `fw_file` / `fw_sha256` / `fw_size` | The firmware artefact and its integrity pair — verified by the retriever before staging and by the device before applying. |
| `assets_file` / `assets_sha256` / `assets_size` | Same for the web-assets zip. |
| `released_at` | ISO 8601 UTC timestamp. |

## The feedback loop: audit codes (§4.4)

The `res=<a>.<b>` parameter closes the loop. The device logs three OTA events locally (`LOG_SYSTEM` codes): **22** check outcome (0 no update … 4 auth failure), **23** download/verify outcome (0 ok, 1 TLS/pin fail, 2 SHA/size mismatch, 3 seq rejected, 4 min_version refusal), **24** apply outcome (0 committed, 1 deferred by the night window, 2 failed). On its next check-in it reports the last pair, which lands in `checkins.csv` and `rota-device.log` — so the operator sees not just *what* a unit runs but *how the last update attempt went*, without any inbound path to the device.

## What's deliberately outside the contract

The store layout (§4.5) is part of the contract only in shape — `releases/<v>/`, `channels/`, `devices.json`, `checkins.csv` — but everything *about* it is server-side policy the device never sees: channels, pins, unit records, the soak/mainstream split, retention. That's why we could document the whole use-case catalogue without touching contract territory, and why a management GUI (your earlier question) would be contract-neutral. Explicitly deferred: signing (`key_id` reserved), mTLS, NVS encryption, and device-initiated secret rotation.

Compliance is testable: `rota_sim.py` is the contract's acceptance suite — it exercises the happy path and every negative case (bad MAC, replay, skew, pin mismatch, resolution) against a real deployment, and the server is "done" precisely when that suite passes.