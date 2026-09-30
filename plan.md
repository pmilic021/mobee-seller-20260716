# Plan: turn the AC control script into a web dashboard

Status: plan only (turn 1). This turn writes no application code. `work-script.sh` and `README.md` stay unchanged.

Terms used in this plan:

- **the script**: `work-script.sh`. `README.md` calls it `ac_control.sh`. It is the same file.
- **HA**: the Home Assistant server. The only outside system the dashboard talks to is the HA REST API, the same as the script.
- **the entity**: the `climate.*` entity that the script controls (default `climate.living_room_ac`).
- **backend**: the small server process that the selected architecture adds (see §3).
- **fake HA**: a test double for the HA REST API (see §8).

Open decisions and the assumptions this plan uses are in `QUESTIONS.md`. The main one is Q1: this plan builds a standalone dashboard, not a native HA (Lovelace) dashboard.

---

## 1. Current behavior

### 1.1 Configuration of the script

Four values are hard-coded at the top of the file:

| Variable | Value in the file | Use |
|---|---|---|
| `HA_URL` | `http://192.168.1.100:8123` | Base URL of HA (plain HTTP) |
| `TOKEN` | placeholder | HA long-lived access token, sent as `Authorization: Bearer …` |
| `ENTITY_ID` | `climate.living_room_ac` | The AC entity |
| `DEFAULT_TEMP` | `22` | Target temperature for `start` when no argument is given. The unit is whatever unit HA uses. |

Every request uses `curl -s`. The script sets no timeout, no `-f`/`--fail`, and does not check the HTTP status code.

### 1.2 Actions

#### `start [temperature]` (alias `on`)

The script makes two HA calls, in this order. Each call is a separate request.

1. `POST {HA_URL}/api/services/climate/set_hvac_mode`
   body `{"entity_id": "<ENTITY_ID>", "hvac_mode": "cool"}`
2. `POST {HA_URL}/api/services/climate/set_temperature`
   body `{"entity_id": "<ENTITY_ID>", "temperature": <T>}`. `<T>` is `$2`, or `DEFAULT_TEMP` (22) when `$2` is not given. The script puts `<T>` into the JSON as raw text, with no quotes and no validation.

Headers on both calls: `Authorization: Bearer <TOKEN>`, `Content-Type: application/json`. The script sends the response body to `/dev/null`.

Output (stdout), exit code 0:

```
Starting AC...
Successfully sent 'set_hvac_mode' command to climate.living_room_ac.
Successfully sent 'set_temperature' command to climate.living_room_ac.
```

When curl itself fails (DNS, connection refused, and similar), the output is `Error sending command to Home Assistant.` and the exit code is 1. If call 1 fails this way, the script does not send call 2.

#### `stop` (alias `off`)

1. `POST {HA_URL}/api/services/climate/set_hvac_mode`
   body `{"entity_id": "<ENTITY_ID>", "hvac_mode": "off"}`

Output, exit code 0:

```
Stopping AC...
Successfully sent 'set_hvac_mode' command to climate.living_room_ac.
```

A curl failure gives the same error line and exit code 1 as for `start`.

#### `status`

1. `GET {HA_URL}/api/states/<ENTITY_ID>` with `Authorization: Bearer <TOKEN>`.

The script reads three values from the JSON response with `grep`/`cut` (it does not use `jq`):

- `state`: the entity state. For a `climate` entity this is the HVAC mode (`off`, `cool`, `heat`, `auto`, …, or `unavailable`/`unknown`).
- `attributes.temperature`: the target temperature.
- `attributes.current_temperature`: the measured room temperature.

Output, exit code 0:

```
Status for climate.living_room_ac:
  Power State:   cool
  Target Temp:   22°
  Current Temp:  25.5°
```

If the response contains the text `entity_not_found`, the output is `Error: Entity '<ENTITY_ID>' not found.` and the exit code is 1.

#### Anything else (no argument, unknown action)

The script prints the usage text and exits with code 1.

### 1.3 Defects

| # | Defect | Effect |
|---|---|---|
| D1 | The success check uses curl's exit code only. `curl -s` without `--fail` returns 0 for HTTP 400/401/404/500. | A wrong token (401), a rejected service call (400) or an HA server error (500) still prints "Successfully sent …". |
| D2 | `status` does not check curl's exit code or the HTTP status. | When HA cannot be reached, or when HA answers `401: Unauthorized` (plain text), the script prints empty values and exits 0. |
| D3 | The entity-not-found check looks for the text `entity_not_found`. HA answers an unknown entity with HTTP 404 and `{"message":"Entity not found."}`, which does not contain that text. (Confirm this against the HA version in use; stage 2 records it in the fake HA.) | The check most likely never matches. An unknown entity prints empty values and exits 0. |
| D4 | For an unknown entity, `start`/`stop` service calls can return HTTP 200 with an empty list (the exact result depends on the HA version). | The script reports success, but no device changed. |
| D5 | The temperature argument is not validated. The script puts it into the JSON as raw text. | `start abc` sends invalid JSON (HA answers 400, and D1 hides it). `start '22, "hvac_mode": "heat"'` injects extra fields. The script does not check the value against the entity's `min_temp`/`max_temp`. |
| D6 | `start` makes two separate calls that are not atomic. | If call 2 fails, the AC is on in cool mode at the old target temperature, and the output does not make this clear. |
| D7 | JSON is parsed with `grep`. It depends on HA's compact JSON format, and on key order and spacing. | `null` values print as `null°`. A change in the format silently breaks `status`. |
| D8 | "Power State" shows the HVAC mode, not on/off. `hvac_action` (for example, cooling or idle) is not shown. | `heat` or `fan_only` looks the same as "on". The user cannot see whether the unit is really cooling now. |
| D9 | The unit is shown as `°` only. The script does not read HA's unit (`/api/config` → `unit_system.temperature`). | `DEFAULT_TEMP=22` is wrong if HA uses °F. |
| D10 | The script does not check that `cool` is in the entity's `hvac_modes`. | On a heat-only entity, the script fails without saying why (HA answers 400, and D1 hides it). |
| D11 | curl has no timeout (`--max-time`). | If HA stops responding, the script hangs. |
| D12 | The token is hard-coded in the file and passed to curl on the command line. | Anyone who can read the file, or see the process list (`ps`), can see the token. |
| D13 | Plain HTTP by default. | The token crosses the network in cleartext. |
| D14 | Error messages go to stdout, not stderr. Usage exits 1 even for `-h`. | This is hard to use from other scripts. |
| D15 | The file name is `work-script.sh`, but `README.md` says `ac_control.sh`. | The README commands fail unless the user renames the file. |

### 1.4 Limits (by design, not bugs)

- One entity only. It is fixed in the file.
- Only one mode (`cool`) for "start". No heat, fan, or dry mode. No fan speed or swing.
- There is no way to change the temperature without also setting the mode to `cool`.
- There is no live view. `status` is a single snapshot and must be run again.
- There are no users and no access control. Anyone who can run the file controls the AC.
- It must be run from a shell on a machine that can reach HA.

---

## 2. Dashboard features

The dashboard is one web page with a **Status panel** and a **Controls panel**.

### 2.1 Mapping from script actions

| Script action | Dashboard control or view | HA calls (made by the backend) |
|---|---|---|
| `start` / `on` | **Start (cool)** button in the Controls panel. It uses the value in the **Target temperature** input, which is prefilled with `DEFAULT_TEMP` (22). | Same as the script, in the same order: `set_hvac_mode` `cool`, then `set_temperature` `<T>`. Before these calls, the backend reads the entity state (`GET /api/states/<id>`) to confirm that the entity exists and supports `cool`, and to check `<T>` against `min_temp`/`max_temp`. |
| `start <T>` | Type `<T>` in the **Target temperature** input (a number input with − / + steps of `target_temp_step`, limited to `min_temp`…`max_temp`), then press **Start (cool)**. | Same as above. |
| `stop` / `off` | **Stop** button in the Controls panel. | Pre-check `GET /api/states/<id>`, then `set_hvac_mode` `off`. |
| `status` | **Status panel**. It is always visible. It refreshes automatically (default every 10 s), right after every action, and when the user presses **Refresh**. | `GET /api/states/<id>`, and `GET /api/config` once at start (for the unit, then cached). |
| usage / unknown action | Not needed. The page has only valid controls. | — |

### 2.2 Status panel content

It shows more than the script does, and each item comes from the same `GET /api/states/<id>` response:

- **Power**: `Off` when `state == "off"`, otherwise `On`. This fixes D8.
- **Mode**: the raw `state` (for example `cool`), which is what the script printed as "Power State".
- **Action**: `hvac_action`, when the entity has it (for example `cooling` or `idle`).
- **Target temperature**: `attributes.temperature` plus the unit from HA (for example `22 °C`). A missing or `null` value shows as `—` (this fixes D7).
- **Current temperature**: `attributes.current_temperature` plus the unit.
- Entity name (`friendly_name`) and entity ID.
- "Last updated": the entity's `last_updated` from HA, and the time of the dashboard's last successful poll.

### 2.3 Control behavior

- While a request is running, both buttons are disabled and show a spinner. The page does not send a second command until the first one is done.
- The **Start** button is disabled, with a short reason shown next to it, when `cool` is not in `hvac_modes` or the entity is `unavailable`.
- After a command, the page shows a short success message (for example "AC started: cool, 22 °C") and reloads the status right away.
- New features beyond the script (other modes, fan speed, several entities) are **out of scope**. Section 7 lists them as possible later work only.

---

## 3. Architecture

### 3.1 Options

**Option A: Native HA dashboard (Lovelace).** Add a dashboard in HA with a thermostat card (status and target temperature) and two buttons. Each button calls an HA `script.*` that has the same service calls as the shell script. A custom Lovelace card in JS is a variant of this option.

**Option B: Static web page that calls HA directly from the browser.** One HTML/JS file. The browser sends REST calls to HA with a long-lived token.

**Option C: Small backend plus static page (proxy with a fixed set of actions).** A small server process holds the token and exposes only three endpoints: status, start, stop. It serves the page, and it is the only thing that talks to HA.

### 3.2 Comparison

| Criterion | A: Native HA dashboard | B: Browser calls HA directly | C: Backend + page |
|---|---|---|---|
| Where the token is | No long-lived token. HA login sessions are used. | In the browser (JS, local storage, or typed in by the user). Anyone who opens the page, or reads the file, gets a token for **all** of HA. | Only in the backend process. The browser never gets it. |
| What the page can do in HA | Whatever the logged-in HA user can do | Anything the token allows (every service, every entity) | Only status/start/stop on one entity |
| Who can open it | HA users | Anyone who can load the file. Files in HA's `/local/` (`config/www`) are served **without authentication**. | Decided by the backend: bound to localhost by default, with an optional password (see §4) |
| Extra setup in HA | Admin must edit dashboards and add scripts | Must add `http: cors_allowed_origins`, unless the page is served from HA's `/local/` (which is unauthenticated) | None. It needs only a token, like the script. |
| Extra software to run | None | A place to host a static file | One small process (Python 3 standard library only) |
| Custom error messages (§6) | No. HA's own UI shows errors in its own way. | Yes | Yes |
| Testing without a real HA server (§8) | Not possible. It needs a running HA. | Yes, with a fake HA. CORS makes it harder. | Yes, with a fake HA over HTTP. Simple. |
| Same behavior as the script (cool + 22 in one click) | Yes, with an HA script | Yes | Yes |
| Size of the work | Small | Small | Medium (the largest of the three, but still small) |

### 3.3 Decision: Option C

Reasons:

1. **The token stays on the server.** Option B gives every visitor a token that controls all of HA, which is worse than the script (D12). Option C fixes D12 instead.
2. **Least privilege.** The backend is not a general HA proxy. It allows only one entity (from server configuration) and two services (`set_hvac_mode` with `cool`/`off`, and `set_temperature`). A browser cannot change the entity ID or call any other service.
3. **It meets the task's requirements directly:** a token location (§4), configuration of the URL, token, and entity (§5), our own error messages for network, HA, and entity-not-found errors (§6), and tests without a real HA (§8). Option A cannot meet §6 or §8.
4. **It needs no changes in HA**, only a token, the same as the script today. Option A needs admin changes in HA.
5. **Small and with no dependencies.** It uses Python 3 standard library only (`http.server`, `urllib.request`, `json`, `unittest`), and a single static HTML/CSS/JS page with no build step. This keeps the script's "no extra dependencies" approach.

Option A is still a good choice if the owner accepts HA-managed UI and errors. See `QUESTIONS.md` Q1, which is open.

### 3.4 Design of Option C

```
Browser ──HTTP──▶ backend (dashboard/server.py) ──HTTPS/HTTP + Bearer token──▶ Home Assistant REST API
          /           static page
          /api/status GET
          /api/start  POST {"temperature": number|null}
          /api/stop   POST {}
```

Planned file layout. All of it is new, and none of it is created this turn:

```
dashboard/
  __init__.py
  config.py        # read and validate configuration (§5)
  ha_client.py     # HA REST calls, timeouts, error classification (§6)
  service.py       # status/start/stop logic, the same steps as the script
  server.py        # HTTP server, routing, auth, static files; entry point `python3 -m dashboard`
  __main__.py
  static/
    index.html
    app.js
    style.css
tests/
  fake_ha.py       # fake HA server (§8), can also run on its own
  test_config.py
  test_ha_client.py
  test_service.py
  test_server.py
  test_parity.py   # runs the real work-script.sh against the fake HA (§8.4)
DASHBOARD.md       # how to run and configure (stage 9). README.md stays unchanged.
```

Backend API contract (the frontend and the tests depend on this):

- `GET /api/status` → `200`
  ```json
  {"entity_id":"climate.living_room_ac","name":"Living room AC",
   "power":"on","hvac_mode":"cool","hvac_action":"cooling",
   "target_temperature":22,"current_temperature":25.5,"unit":"°C",
   "min_temp":16,"max_temp":30,"temp_step":1,"hvac_modes":["off","cool"],
   "available":true,"can_start":true,"last_updated":"2026-09-30T12:00:00+00:00",
   "default_temperature":22}
  ```
- `POST /api/start` with body `{"temperature": 24}` or `{"temperature": null}` (null means `DEFAULT_TEMP`) → `200 {"ok":true,"status":{…same as /api/status…}}`.
- `POST /api/stop` with body `{}` → `200 {"ok":true,"status":{…}}`.
- Every error → a non-2xx status and this JSON body (§6):
  `{"ok":false,"error":{"code":"<code>","message":"<text for the user>","detail":"<optional technical detail>","step":"<optional: set_hvac_mode|set_temperature>"}}`.

Behavior rules:

- **start**: (1) Read the state. (2) Validate: the entity exists, it is not `unavailable`, `cool` is in `hvac_modes`, and `T` is a finite number with `min_temp ≤ T ≤ max_temp`. (3) Call `set_hvac_mode` with `cool`. (4) Call `set_temperature` with `T`. (5) Read the state again and return it. If step 4 fails after step 3 worked, return the error code `partial_start` (fixes D6). This keeps the script's two calls and their order. Using one call (`set_temperature` with `hvac_mode`) is not done, because some integrations handle it differently. See Q4.
- **stop**: Read the state, then call `set_hvac_mode` with `off`, then read the state again.
- The backend runs only one command at a time (a lock), so a start and a stop cannot mix.
- The backend always sends JSON that it builds itself with `json.dumps`. It never builds JSON from user text (fixes D5).
- HA request timeout: default 10 s (fixes D11).

---

## 4. Security

### 4.1 Where the dashboard keeps the HA token

- The token is only in the **backend process memory**. The backend reads it at start from a file named by `HA_TOKEN_FILE` (recommended), or from the `HA_TOKEN` environment variable (see §5).
- The token file is outside the repository (for example `~/.config/ac-dashboard/token`). It must have mode `0600`. The backend prints a warning at start if the file is readable by group or others, and it refuses to start if the file is empty.
- The token is **never** sent to the browser. It is not in any API response, error message, or log line, and it is not in the static files. A test checks this (stage 5): no response body or captured log contains the token.
- The token is not on any command line, so it is not in `ps` (fixes D12). The backend uses `urllib` inside its own process.
- Recommended: create a **dedicated HA user** (not an admin) for the dashboard and make the long-lived token for that user. Then the owner can revoke it without affecting other users. Stage 3 checks that this token works for the three HA endpoints that are used.
- HA connection: `https://` is recommended. TLS certificates are checked by default. `HA_CA_FILE` allows a private CA. `http://` still works (the same as the script), but the backend logs a warning at start (D13).
- Repeated 401 answers can make HA ban the IP address (`ip_ban_enabled` / `login_attempts_threshold`). For this reason, after a 401 the backend stops automatic polling of HA until the user presses **Retry** or the backend restarts (§6).

### 4.2 Who can open the dashboard

- **Default: only the local machine.** The backend listens on `127.0.0.1:8080`. It checks the `Host` header (it must be `127.0.0.1:<port>` or `localhost:<port>`) to block DNS-rebinding attacks.
- **LAN access is off unless the owner turns it on.** Set `DASHBOARD_BIND=0.0.0.0` (or a LAN IP address). The backend **refuses to start** on a non-loopback address unless `DASHBOARD_PASSWORD_FILE` is set. With a password:
  - The page shows a login form. `POST /login` checks the password (constant-time compare) and sets a random session cookie (`HttpOnly`, `SameSite=Strict`, plus `Secure` when TLS is used). Sessions are kept in memory and expire after 12 h. After 5 wrong passwords, logins from that address are blocked for 1 minute.
  - Without a valid session, every `/api/*` call returns `401` with the error code `dashboard_login_required`.
  - `DASHBOARD_ALLOWED_HOSTS` (a comma-separated list) sets the accepted `Host` values.
- **No internet exposure.** `DASHBOARD.md` will say this. For access from outside the LAN, use a VPN or HA's own app (Option A), not port forwarding. If the owner wants TLS on the LAN, put a reverse proxy (for example Caddy or nginx) in front of the backend. That is not part of this project.
- **CSRF**: `POST /api/*` requires `Content-Type: application/json` and a header `X-AC-Dashboard: 1`, and it rejects requests whose `Origin` header does not match the host. A cross-site form cannot send these.
- **Page hardening**: responses set `Content-Security-Policy: default-src 'self'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and `X-Frame-Options: DENY`. The page puts all text from HA into the page with `textContent`, never `innerHTML` (HA error messages and friendly names are untrusted).
- **Fixed scope**: the browser cannot choose the entity or the service (§3.3, reason 2).

See Q2 (LAN access and password) and Q3 (a dedicated HA user) in `QUESTIONS.md`.

---

## 5. Configuration

The backend reads only **environment variables**. These are simple to set in a shell, a systemd unit, or a container. It does not read a config file in the repository, so no one can commit the token by mistake. It reads the values once, at start.

| Variable | Required | Default | Meaning and validation |
|---|---|---|---|
| `HA_URL` | yes | — | Base URL of HA, for example `http://192.168.1.100:8123`. It must be `http` or `https`, must have a host, and has no path, query, or trailing `/` (the backend removes a trailing `/`). |
| `HA_TOKEN_FILE` | one of these two | — | Path to a file that holds only the token. Whitespace at the start and end is removed. The file must not be empty. It is preferred over `HA_TOKEN`. |
| `HA_TOKEN` | one of these two | — | The token itself. Use it only when a file is not possible. If both are set, the backend uses `HA_TOKEN_FILE` and logs a warning. |
| `HA_ENTITY_ID` | yes | — | For example `climate.living_room_ac`. It must match `^climate\.[a-z0-9_]+$`. |
| `DEFAULT_TEMP` | no | `22` | The number used by Start when the input is empty. It is in HA's unit, the same as in the script. |
| `HA_TIMEOUT` | no | `10` | Seconds for each HA request (from 1 to 60). |
| `HA_CA_FILE` | no | — | A CA bundle for HA over `https` with a private CA. |
| `POLL_INTERVAL` | no | `10` | Seconds between status refreshes in the browser (from 2 to 300). The backend sends this value to the page. |
| `DASHBOARD_BIND` | no | `127.0.0.1` | The address to listen on. |
| `DASHBOARD_PORT` | no | `8080` | The port to listen on. |
| `DASHBOARD_PASSWORD_FILE` | yes if the bind address is not loopback | — | A file with the dashboard password. |
| `DASHBOARD_ALLOWED_HOSTS` | no | derived from the bind address and port | Accepted `Host` header values. |

Rules:

- If a value is missing or invalid, the backend stops at start with exit code 2 and one clear line for each problem, for example `config error: HA_ENTITY_ID must look like climate.<name>, got "living_room"`. The line never contains the token.
- The URL, token, and entity ID are **server-side only**. The page learns only the entity ID, the default temperature, and the poll interval, through `/api/status` and `/api/ui-config`. The page cannot change them.
- A check at start, which logs but does not stop the backend: `GET /api/` (is the token valid?) and `GET /api/states/<entity>` (does the entity exist?). The backend logs the result. HA can be down when the dashboard starts, so the dashboard still starts and shows the error in the page (§6).
- `/api/config` → `unit_system.temperature` gives the unit. The backend caches it and reads it again after a failed call.
- Migration note for `DASHBOARD.md`: the script's `HA_URL`, `TOKEN`, `ENTITY_ID`, and `DEFAULT_TEMP` map to `HA_URL`, `HA_TOKEN_FILE`/`HA_TOKEN`, `HA_ENTITY_ID`, and `DEFAULT_TEMP`.

---

## 6. Errors

### 6.1 How errors are shown on the page

- **Banner** (at the top of the page, `role="alert"`): errors about the connection or the whole system. It stays until the next successful call, then it clears by itself.
- **Inline message** (under the temperature input): input validation errors.
- **Action result** (next to the buttons): the success or failure of the last Start/Stop.
- **Stale status**: when a refresh fails, the Status panel keeps the last good values, greyed out, with the text "Last known at 12:03:10". It never shows empty values as if they were current (fixes D2).
- Each message says **what** happened, **what it means for the AC**, and **what to do next**. Technical detail (the HTTP code, HA's message) goes in a "Details" section that the user can open. Text from HA is always shown with `textContent`. The token is never shown.

### 6.2 Error catalogue

The backend classifies every failure into one code (in `ha_client.py` and `service.py`). The page chooses the display from the code only.

| Situation | How the backend detects it | HTTP status and `error.code` | What the page shows | Controls |
|---|---|---|---|---|
| **Network error: the browser cannot reach the backend** (backend stopped, Wi-Fi lost) | `fetch()` rejects in the browser | none (the error is in the browser) | Banner: "Can't reach the dashboard server. Check that it is running. Retrying…" Polling continues with backoff (10 s → 20 s → 40 s, at most 60 s). | Disabled |
| **Network error: the backend cannot reach HA** (DNS failure, connection refused, host down, TLS failure) | `urllib` `URLError`/`OSError`/`ssl.SSLError` | `502 ha_unreachable` | Banner: "Can't reach Home Assistant at `<HA_URL>`. The AC state is unknown." Details: the reason (for example "connection refused"). Polling continues with backoff. | Disabled |
| **Timeout** while talking to HA | `socket.timeout` / `TimeoutError` after `HA_TIMEOUT` | `504 ha_timeout` | Banner: "Home Assistant did not answer within 10 s." For a command: "The command may or may not have reached the AC. Check the status." After this, the page refreshes the status once. | Disabled during backoff |
| **HA error: bad or revoked token** | HA HTTP `401` (the body is plain text `401: Unauthorized`) | `502 ha_unauthorized` | Banner: "Home Assistant rejected the dashboard's access token. Ask the owner to update HA_TOKEN_FILE and restart the dashboard." Automatic polling **stops** (§4.1, IP ban). A **Retry** button appears. | Disabled |
| **HA error: forbidden** | HA `403` | `502 ha_forbidden` | Banner: "The HA user for this token is not allowed to do this." | Disabled |
| **HA error: the command was rejected** (bad value, service validation error, service not found) | HA `400`/`404` on `/api/services/...`. The backend shows HA's `message` from the JSON body when there is one. | `502 ha_rejected` (plus `step`) | Action result: "Home Assistant rejected 'set_temperature': <HA message>." | Enabled |
| **HA error: HA server error** | HA `5xx`, or a body that is not valid JSON where JSON is expected | `502 ha_error` | Banner: "Home Assistant returned an error (HTTP 500). Try again later." Details: the first 200 characters of the body. | Enabled for status, commands allowed |
| **Entity that HA cannot find** | `GET /api/states/<id>` returns `404` (body `{"message":"Entity not found."}`). The pre-check before every command catches this too, so the D4 case (a service call to an unknown entity that returns 200) cannot give a false success. | `404 entity_not_found` | The Status panel is replaced with: "Home Assistant has no entity `climate.living_room_ac`. Check HA_ENTITY_ID in the dashboard configuration." Details: HA's message. | Hidden |
| **The entity is unavailable** | `state` is `unavailable` or `unknown` | `/api/status` returns `200` with `available:false`. A command returns `409 entity_unavailable`. | Status panel: a yellow warning "The AC is unavailable in Home Assistant (device offline?)". The values show as `—`. | Disabled |
| **Cool mode is not supported** | `cool` not in `hvac_modes` | status `can_start:false`. Start returns `409 mode_not_supported`. | Next to the Start button: "This AC does not support cool mode. Modes: off, heat." | Start disabled, Stop enabled |
| **Invalid temperature** | not a finite number, or outside `min_temp`…`max_temp` | `422 invalid_temperature` | Inline message: "Enter a temperature between 16 and 30 °C." The page checks this too, before it sends the request. | Enabled |
| **Partial start** (mode set to cool, then `set_temperature` failed) | step 4 fails after step 3 worked | `502 partial_start` (with the inner code in `detail`) | Action result: "The AC was switched to cool, but the target temperature was not set (<reason>). It is running at <old target>." The status refreshes. | Enabled |
| **Another command is running** | the lock is taken | `409 busy` | Action result: "Another command is still running. Try again in a moment." | Enabled after the other command ends |
| **Dashboard login required or expired** | no session or an expired session (LAN mode) | `401 dashboard_login_required` | The page switches to the login form. | — |
| **Unexpected backend bug** | an unhandled exception | `500 internal_error` | Banner: "The dashboard hit an internal error." The backend logs a stack trace, without the token. | Enabled |

The backend logs one line for each HA call: the method, the path, the HTTP status, and the time in ms. It never logs headers.

---

## 7. Stages

Rules for every stage:

- Each stage is small and can be done by a different agent in a separate turn, in the order shown.
- A stage adds only the files it names. It must not change `work-script.sh` or `README.md`.
- "Done when" gives the proof of completion: commands that the next agent can run. **All earlier tests must still pass** (`python3 -m unittest discover -s tests -v` exits 0).
- Target: Python 3.9 or newer, standard library only. The frontend is plain HTML/CSS/JS (ES2019), with no build step and no CDN.
- Each stage updates `QUESTIONS.md` according to the job rules.

### Stage 1: Project skeleton and configuration

- Create `dashboard/__init__.py`, `dashboard/config.py`, `dashboard/__main__.py` (it only loads the configuration and prints a summary without the token, then exits), and `tests/test_config.py`.
- `config.py`: `load_config(env: Mapping[str,str]) -> Config` (a frozen dataclass). It raises `ConfigError` with a list of messages. It uses the rules in §5, including the token-file warning about mode 0600 and the rule that a non-loopback bind needs a password.
- **Done when**: the tests cover each variable, both valid and invalid (missing `HA_URL`, a bad entity ID, `HA_TOKEN` and `HA_TOKEN_FILE` both set, an empty token file, `0.0.0.0` without a password, and the defaults). `HA_URL=x python3 -m dashboard` exits 2 with clear lines. A test shows that the token text is in no error message and not in the printed summary.

### Stage 2: Fake HA server

- Create `tests/fake_ha.py` as described in §8.2: scenarios, a request log, and a CLI (`python3 -m tests.fake_ha --port 8123 --scenario normal`). Also create `tests/test_fake_ha.py`, which checks the fake itself.
- The response shapes follow the HA REST API documentation (`/api/`, `/api/config`, `/api/states/<id>`, `/api/services/climate/<service>`). Add a comment block at the top of the file that lists the HA version and the documentation page used, and the places where the behavior was assumed (the 404 body, the 200-with-`[]` answer for an unknown entity).
- **Done when**: `test_fake_ha.py` passes, using `urllib` against the fake for every scenario. Running it by hand and calling `curl -H 'Authorization: Bearer test-token' localhost:8123/api/states/climate.living_room_ac` returns the entity JSON.

### Stage 3: HA client

- Create `dashboard/ha_client.py` and `tests/test_ha_client.py`.
- `HAClient(base_url, token, timeout, ca_file)` with the methods `api_check()`, `get_config()`, `get_state(entity_id)`, and `call_service(domain, service, data)`. It raises a typed `HAError(code, message, http_status, detail)` with the codes from §6.2: `ha_unreachable`, `ha_timeout`, `ha_unauthorized`, `ha_forbidden`, `ha_rejected`, `ha_error`, `entity_not_found`.
- **Done when**: the tests run against the fake HA for every scenario, plus a closed port (network error) and a slow scenario with `timeout=0.5` (timeout). They check that the `Authorization` header and the JSON bodies are exactly as expected (from the fake's request log), and that the token is in no `HAError` field. Optional: a manual check against a real HA with a non-admin token (Q3), with the results written in `QUESTIONS.md`.

### Stage 4: Service logic (status, start, stop)

- Create `dashboard/service.py` and `tests/test_service.py`.
- `status()`, `start(temperature: float|None)`, and `stop()` return the dictionaries in §3.4 and follow the behavior rules there (the pre-check, the validation, the two calls in the script's order, `partial_start`, the lock, `busy`).
- **Done when**: for each script action, a test checks the exact sequence of HA requests in the fake's log (for example: start → `GET state`, `POST set_hvac_mode {cool}`, `POST set_temperature {22}`, `GET state`). There are tests for every row in §6.2 that the backend can produce (not the browser-only row or the login row).

### Stage 5: HTTP server and security

- Create `dashboard/server.py`, update `dashboard/__main__.py` so it starts the server, and create `tests/test_server.py`.
- Use `ThreadingHTTPServer`. Routes: `GET /`, `/static/*`, `GET /api/ui-config`, `GET /api/status`, `POST /api/start`, `POST /api/stop`, and `GET`/`POST /login` plus `POST /logout` (only when a password is set). Include the Host check, the CSRF checks, the security headers, the session cookies, and the login rate limit from §4.2, and the error JSON format from §3.4.
- For now, the static page can be a placeholder `index.html` that says "dashboard".
- **Done when**: the tests start the server on a free port against the fake HA and check:
  - the HTTP status and error code for each route and scenario;
  - 403 for a bad `Host` or `Origin`, or a missing `X-AC-Dashboard` header;
  - 401 without a session in password mode;
  - that the backend refuses to start on `0.0.0.0` without a password;
  - that the security headers are present;
  - that the token is in **no** response body or header and in no captured log output.

  `curl -s localhost:8080/api/status` against a running fake HA returns the JSON in §3.4.

### Stage 6: Page with the Status panel

- Create `dashboard/static/index.html`, `app.js`, and `style.css`.
- The Status panel (§2.2), polling (`POLL_INTERVAL` from `/api/ui-config`), the **Refresh** button, the stale-value display, and the banner for `ha_unreachable`, `ha_timeout`, `ha_unauthorized` (polling stops, with a Retry button), `entity_not_found`, and `entity_unavailable`. All text is set with `textContent`. The page works with the CSP (no inline script or style).
- Put the pure logic (API response → view model; error code → message) in functions in `app.js` that do not use the DOM, so they can be tested (§8.5).
- **Done when**: `python3 -m tests.fake_ha --scenario normal` and `python3 -m dashboard` are running, and the page shows the values from the fake. When the scenario changes (§8.2 control endpoint), the page shows the right banner or panel within one poll interval. The manual checklist in §8.6 (the status rows) passes. Screenshots are optional.

### Stage 7: Controls (Start, Stop, temperature)

- Add the Controls panel to the page: the temperature input (prefilled with `default_temperature`, limited by `min_temp`/`max_temp`/`temp_step`), **Start (cool)**, and **Stop**. Buttons are disabled while a request runs. Add the action result messages, the inline validation, and `can_start` handling.
- **Done when**: against the fake HA, Start with an empty input gives `cool`/22 in the fake's state, Start with 24 gives `cool`/24, and Stop gives `off`. Each of these is visible in the Status panel right after the click, and the fake's request log shows the same calls as the script (§8.4). The manual checklist rows for the controls pass.

### Stage 8: Full error handling on the page and the login form

- Show every row of §6.2 in the page, including the browser-side network error with backoff, `partial_start`, `busy`, `invalid_temperature`, `mode_not_supported`, and the login form for `dashboard_login_required`.
- **Done when**: every row of the §8.6 manual checklist passes against the fake HA. If Playwright is available (§8.5), the automated browser tests for the same rows pass.

### Stage 9: Documentation and parity test

- Create `DASHBOARD.md` (how to run, the configuration table, the security notes, the migration from the script, and "never expose to the internet"). Create `tests/test_parity.py` (§8.4).
- **Done when**: `test_parity.py` passes (or is skipped with a clear message when `curl` or `bash` is not installed), and all tests pass. A new user can follow `DASHBOARD.md` from zero to a running dashboard against the fake HA.

### Possible later work (not planned; only if the owner asks)

- Push updates through the HA WebSocket API instead of polling.
- Other HVAC modes, fan speed, or several entities.
- A systemd unit file.

---

## 8. Tests without a real HA server

### 8.1 Levels

| Level | Tool | What it covers |
|---|---|---|
| Unit | `unittest` | `config.py`, error classification, and the view-model functions |
| Integration | `unittest` + the fake HA over real HTTP on `127.0.0.1` | `ha_client.py`, `service.py`, `server.py` |
| Parity | `unittest` + the real `work-script.sh` + the fake HA | The dashboard sends the same HA requests as the script |
| Browser | a manual checklist (required). Playwright is optional. | The page shows each state and error correctly |

Command: `python3 -m unittest discover -s tests -v`. It needs no network access, no HA, and no pip packages.

### 8.2 The fake HA (`tests/fake_ha.py`)

- A `ThreadingHTTPServer` on `127.0.0.1` with port 0 (a free port). A test starts it in a background thread with a context manager: `with FakeHA(scenario="normal") as ha: ha.url, ha.requests, ha.state`.
- It accepts only `Authorization: Bearer test-token`. Any other token gets `401` with the plain text body `401: Unauthorized`, as HA does.
- Endpoints:
  - `GET /api/` → `{"message":"API running."}`
  - `GET /api/config` → `{"unit_system":{"temperature":"°C", …},"version":"<version>"}`
  - `GET /api/states/<id>` → the entity JSON (`entity_id`, `state`, `attributes` with `hvac_modes`, `min_temp`, `max_temp`, `target_temp_step`, `temperature`, `current_temperature`, `hvac_action`, `friendly_name`, plus `last_changed` and `last_updated`), or `404 {"message":"Entity not found."}`
  - `POST /api/services/climate/set_hvac_mode` and `/set_temperature` → they change the in-memory state and return `200` with a list of changed states. Invalid data (a mode not in `hvac_modes`, a temperature that is not a number or is out of range, invalid JSON) gets `400 {"message": "..."}`.
- It **records** every request (method, path, headers, parsed body), so tests can check the exact calls.
- **Scenarios**, set in the constructor or through `POST /__fake/scenario` (the control endpoint used for manual tests):
  - `normal`
  - `off`
  - `bad_token` (every request gets 401)
  - `forbidden` (403)
  - `entity_missing` (404 for the state; service calls return `200 []`, like D4)
  - `unavailable` (state `unavailable`)
  - `heat_only` (`hvac_modes: ["off","heat"]`)
  - `fahrenheit` (unit `°F`, min 61, max 86)
  - `server_error` (500)
  - `bad_json` (200 with a body that is not JSON)
  - `slow` (sleeps longer than the client timeout)
  - `drop` (closes the connection without an answer)
  - `fail_set_temperature` (set_hvac_mode works, set_temperature returns 500, for `partial_start`)
  - `null_values` (`current_temperature: null`)
- Network errors are tested without the fake. Bind a socket to get a free port, close it, and point `HA_URL` at that port (connection refused). For DNS failure, use an unresolvable host such as `http://ha.invalid:8123` (`.invalid` is reserved and never resolves).

### 8.3 What each test file checks

- `test_config.py`: §5 rules (stage 1).
- `test_ha_client.py`: each scenario maps to the right `HAError` code, the headers and bodies are right, the timeout works, and the token is never in an error (stage 3).
- `test_service.py`: the exact order of HA requests for status/start/stop, the validation, `partial_start`, `busy`, and the D4 case (`entity_missing` gives `entity_not_found`, not a success) (stage 4).
- `test_server.py`: the routes, the error JSON, the security checks, and that the token never appears (stage 5).

### 8.4 Parity with the script (`tests/test_parity.py`)

- Copy `work-script.sh` to a temporary directory. In the **copy only**, replace the `HA_URL=`, `TOKEN=`, and `ENTITY_ID=` lines so they point to the fake HA (`test-token`). The original file stays unchanged.
- Run `bash <copy> start`, `bash <copy> start 24`, and `bash <copy> stop` against a fresh fake. Record the sequence of `POST` requests (path and parsed body) for each.
- Do the same actions through the dashboard backend (`POST /api/start` with `null` and with `24`, and `POST /api/stop`) against a fresh fake. Remove the dashboard's extra `GET` requests, then check that the `POST` sequences are **equal**.
- Also run `bash <copy> status` and check that its printed values (mode, target, current) are equal to `mode`/`target_temperature`/`current_temperature` in `/api/status`.
- Skip the test with a clear reason if `bash` or `curl` is missing.

### 8.5 Browser tests

- **Required**: the manual checklist in §8.6. The agent that runs it writes the result (pass or fail for each row) in its turn notes.
- **Optional, when it can be installed under `$HOME`** (`pip install --user playwright` and `python3 -m playwright install chromium`): `tests/browser/test_ui.py` runs each §8.6 row automatically. The test is skipped when Playwright is not installed, so the main test command stays free of dependencies.
- **Optional**: if Node.js is present, test the DOM-free functions in `app.js` with `node --test`. It is skipped when Node.js is missing.

### 8.6 Manual checklist (fake HA plus the dashboard on localhost)

Start: `python3 -m tests.fake_ha --port 8123 --scenario normal`, then `HA_URL=http://127.0.0.1:8123 HA_TOKEN=test-token HA_ENTITY_ID=climate.living_room_ac python3 -m dashboard`, then open `http://127.0.0.1:8080`. Change the scenario with `curl -X POST 127.0.0.1:8123/__fake/scenario -d '{"scenario":"<name>"}'`.

| # | Scenario / action | Expected |
|---|---|---|
| 1 | `normal`, open the page | Power On, Mode cool, Target 22 °C, Current 25.5 °C |
| 2 | `off` | Power Off |
| 3 | Start with the input empty | Success message, then Mode cool, Target 22 |
| 4 | Start with 24 | Target 24 |
| 5 | Start with 99 | Inline message: range 16–30 °C, no request sent |
| 6 | Stop | Power Off |
| 7 | Stop the fake HA process | Banner "Can't reach Home Assistant", stale values, controls disabled. Start the fake again: the banner clears by itself. |
| 8 | Stop the dashboard backend | Banner "Can't reach the dashboard server", with backoff |
| 9 | `bad_token` | Token banner, polling stops, Retry button |
| 10 | `entity_missing` | Entity-not-found panel, controls hidden |
| 11 | `unavailable` | Yellow warning, controls disabled |
| 12 | `heat_only` | Start disabled with a reason, Stop works |
| 13 | `server_error` | HA error banner with HTTP 500 in Details |
| 14 | `slow` | Timeout banner after `HA_TIMEOUT` |
| 15 | `fail_set_temperature`, then Start | Partial-start message |
| 16 | `fahrenheit` | Unit °F. Start with the default 22 gives an inline out-of-range message (see Q5). |
| 17 | `null_values` | Current temperature shows `—` |
| 18 | Password mode (`DASHBOARD_BIND=0.0.0.0` plus a password file) | Login form. A wrong password is rejected. After login, the dashboard works. |
