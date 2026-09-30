# Plan: turn the AC control script into a web dashboard

Status: plan only (turn 2). This turn writes no application code. `work-script.sh` and `README.md` stay unchanged.

The dashboard is a standalone program: a small Python backend and a static page (Q1). It does not use Home Assistant, the Home Assistant REST API, or a Home Assistant token (Q3). The first version controls the AC through the Sensibo cloud API. That choice is Q9 in `QUESTIONS.md`, and it is open so the buyer can confirm it. Later stages follow this plan as written.

Terms used in this plan:

- **the script**: `work-script.sh`. `README.md` calls it `ac_control.sh`. It is the same file. Section 1 describes that script as it is today.
- **the pod**: the Sensibo device that sends commands to the AC. The owner sets its id in `SENSIBO_POD_ID`.
- **backend**: the small server process that holds the Sensibo API key and serves the page (see §3).
- **fake Sensibo**: a local test double for the Sensibo HTTP API (see §8). Tests use it instead of a real pod or a real AC.

Answered questions and the open choice are in `QUESTIONS.md`. Q1, Q2, Q3, Q4, and Q8 are answered. Q5, Q6, Q7, and Q10 are decisions already taken. Q9 is open.

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

The dashboard is one web page with a **Status panel** and a **Controls panel**. The backend is the only program that talks to Sensibo. The browser talks only to the backend.

### 2.1 Mapping from script actions

The script's three actions stay the whole of the product (Q7). The Sensibo calls below are the first-version method (Q9). Section 3.5 says how a later method replaces them without changing this page.

| Script action | Dashboard control or view | Sensibo calls (made by the backend) |
|---|---|---|
| `start` / `on` | **Start (cool)** button. It uses the **Target temperature** input, prefilled with `DEFAULT_TEMP` (22). | Read the pod. Then the mode step, then the temperature step, in that order (Q4). Mode step: if the pod is off, `PATCH …/acStates/on` with `true`, then `PATCH …/acStates/mode` with `cool`. Temperature step: `PATCH …/acStates/targetTemperature` with `<T>`. |
| `start <T>` | Type `<T>` in the **Target temperature** input, then press **Start (cool)**. The input is a number limited to the cool mode's allowed values, with step `temp_step`. | Same as above. |
| `stop` / `off` | **Stop** button. | Read the pod, then `PATCH …/acStates/on` with `false`, then read the pod again. |
| `status` | **Status panel**. It is always visible. It refreshes on its own (default every 15 s), right after every action, and when the user presses **Refresh**. | `GET /api/v2/pods/<pod id>` with the fields in §3.4. |
| usage / unknown action | The page has only valid controls. | — |

Sensibo can also set power, mode, and temperature in one `POST …/acStates` body. This plan does not use that POST for start. Two property updates keep the script's order, and a failed temperature update can still be reported as `partial_start` (Q4).

### 2.2 Status panel content

Each item comes from the pod read in §3.4:

- **Power**: `On` when `acState.on` is true, otherwise `Off`.
- **Mode**: `off` when the pod is off, otherwise `acState.mode` (for example `cool`). Sensibo often keeps the last mode while the pod is off. The panel still shows Mode as `off` then, so it matches the script's status line.
- **Action**: hidden for this method. Sensibo does not report whether the unit is cooling or idle. A later control method may fill this in (§3.5). The field in the API is `null` until then.
- **Target temperature**: `acState.targetTemperature` plus the unit (`22 °C` or `72 °F`). A missing or `null` value shows as `—`.
- **Current temperature**: `measurements.temperature` plus the unit. This is the pod's own room sensor. A missing or `null` value shows as `—`.
- Room name (`room.name`) and pod id.
- "Last updated": `measurements.time` when Sensibo sends it, and the time of the dashboard's last successful poll.

### 2.3 Control behavior

- While a request is running, both buttons are disabled and show a spinner. The page does not send a second command until the first one finishes.
- **Start** is disabled, with a short reason beside it, when the pod is offline or when `cool` is not in the pod's modes.
- After a command, the page shows a short success line (for example "AC started: cool, 22 °C") and reloads the status.
- Other modes, fan speed, swing, and more than one pod are out of scope. Section 7 lists them as later work only.

---

## 3. Architecture

### 3.1 Standalone program

Q1 is answered: the dashboard is a standalone program, not a page inside another product. Shape:

- One backend process. It serves the static page and three actions: status, start, stop.
- One static page (HTML, CSS, and JS). It has no build step.
- The backend is the only component that holds the Sensibo API key and the only component that calls Sensibo.

The browser never calls Sensibo and never sees the API key.

### 3.2 Control methods in the README

`README.md` names three ways to control the AC without the script's current server. This section compares them and selects one for the first version (Q8).

| | Sensibo cloud API | Broadlink IR blaster, or LIRC `irsend` | Tasmota or ESPHome |
|---|---|---|---|
| What the README shows | `POST https://home.sensibo.com/api/v2/pods/{POD_ID}/acStates?apiKey={API_KEY}` with `{"acState":{"on":true}}` | `python3 -m broadlink`, or `irsend` via LIRC | `curl "http://<AC_IP>/cm?cmnd=Power%20On"` (Tasmota HTTP). ESPHome is named together with Tasmota as local HTTP or MQTT. |
| Start: cool, then a target temperature | Yes. `PATCH …/acStates/mode` and then `PATCH …/acStates/targetTemperature`. Power is a separate `on` property, sent in the mode step when the pod is off (§2.1). | No structured climate command. Broadlink sends a learned IR packet. `irsend` sends a named button. A typical AC IR frame packs power, mode, and temperature into one burst, so the two script steps are not two independent sends. | The README command switches power only. It has no cool mode and no target temperature. Tasmota's separate `IRhvac` command can send one full IR state, and that is still one burst. ESPHome climate is not that HTTP command. |
| Stop | `PATCH …/acStates/on` with `false`. | A learned "off" packet, or an `irsend` key. | `Power Off` on Tasmota. ESPHome would be a different call. |
| Status: power, target, current temperature | Yes. `GET /pods/{id}` returns `acState` (on, mode, target, unit) and `measurements.temperature` from the pod's sensor. | No. IR does not answer. The dashboard would have to remember the last send. Current room temperature is not available from the blaster. | Tasmota answers with its own relay or IR-bridge state, not the AC's mode and target, and not the room temperature, unless another sensor is added. ESPHome IR climate has the same one-way limit unless a separate sensor is configured. |
| Extra software | The Sensibo API is HTTPS and JSON. Python's standard library can call it. The owner needs a Sensibo pod and an API key. | `python3 -m broadlink` needs the third-party `broadlink` package, a device on the LAN, and a learned packet for each state. LIRC needs the `lircd` daemon and a remote definition installed on the machine. | Tasmota is a local HTTP device. A full climate command needs IRHVAC firmware and a vendor profile, which the README command does not include. ESPHome's climate path is its native API or MQTT, so an MQTT broker is another process to run. |
| Tests with no real AC | A small HTTP server can pretend to be Sensibo (§8). | An honest test needs either a hardware device or a binary IR protocol. A subprocess fake does not show that an AC changed. | Tasmota HTTP can be faked, but the README command cannot represent cool-plus-temperature, so the fake would be testing a different product than the script. |
| Credential | An account API key in the query string (`apiKey`). The key can control every pod on the account. Section 4 keeps it in the backend. | The Broadlink device key, or no secret at all for a local `irsend`. | Often a device password on the Tasmota URL, or MQTT credentials. |

### 3.3 Decision for the first version: Sensibo cloud API

The first version uses the Sensibo cloud API. Q9 records this for the buyer to confirm. Reasons:

1. It is the only method in the README that can do all three script actions with data that comes back from the device: set cool, set a target temperature, turn off, and read power, target temperature, and current temperature.
2. The mode and the temperature are two different Sensibo properties. The backend can send them in the script's order and can report `partial_start` when the second one fails (Q4).
3. The call is HTTPS JSON. The backend stays on the Python standard library, the same "no extra packages" idea as a small shell script. Tests use a fake HTTP server on `127.0.0.1` and do not need a pod, an IR blaster, or an AC.
4. Broadlink and LIRC `irsend` cannot read the AC back, so the status panel would be a local guess, and current temperature would be missing. They also need a third-party package or a system daemon, plus a learned code per state.
5. The Tasmota command in the README only switches power. ESPHome is a different product (native API or MQTT) grouped into the same README line. Neither one, as documented there, accepts "cool" and then a target temperature and then returns the room temperature.

Costs of this choice, accepted for the first version:

- The owner needs a Sensibo account, a pod, and an API key. The key is account-wide. Sensibo does not issue a key for a single pod.
- The backend must reach `home.sensibo.com` on the internet. If that host is down, the dashboard cannot change the AC.
- The API key is a query parameter. Section 4 says how the backend keeps it out of logs, errors, and the browser.
- Sensibo answers HTTP 429 when the call rate is too high. Polling is slow on purpose (§5), and §6 backs off on 429.

The README's one-line Sensibo example only sends `{"acState":{"on":true}}`. That turns the pod on. It does not set cool and it does not set a temperature. The first version uses the single-property PATCH documented by Sensibo, not that one-line POST.

### 3.4 Design

```
Browser ──HTTP──▶ backend (dashboard/server.py) ──HTTPS + apiKey query──▶ Sensibo
          /           static page                         GET and PATCH /api/v2/pods/…
          /api/status GET
          /api/start  POST {"temperature": number|null}
          /api/stop   POST {}
```

Outbound calls use `https://home.sensibo.com/api/v2` unless `SENSIBO_API_BASE` points the tests at the fake (§5). The dashboard's own listener stays on localhost (§4.2). Outbound HTTPS to Sensibo is required. Inbound access from the internet is not.

Planned file layout. All of it is new. None of it is created this turn:

```
dashboard/
  __init__.py
  config.py         # read and validate configuration (§5)
  errors.py         # DashboardError used by the controller and the service
  sensibo_client.py # Sensibo HTTP only: get_pod, set_property, timeouts, redaction
  controller.py     # AcController: read_status, set_cool_mode, set_target_temperature, turn_off
  service.py        # status/start/stop, validation, lock, partial_start (§2.1, §3.5)
  server.py         # HTTP server, routing, auth, static files; entry point `python3 -m dashboard`
  __main__.py
  static/
    index.html
    app.js
    style.css
tests/
  __init__.py
  fake_sensibo.py   # fake Sensibo (§8)
  test_config.py
  test_fake_sensibo.py
  test_sensibo_client.py
  test_service.py
  test_server.py
DASHBOARD.md        # how to run and configure (stage 9). README.md stays unchanged.
```

`service.py` does not import the Sensibo client. It calls `AcController` only. `SensiboController` in `controller.py` is the first implementation. That split is what a later method replaces (§3.5).

Sensibo HTTP contract (the client and the fake both follow this):

- Base: `{SENSIBO_API_BASE}` which defaults to `https://home.sensibo.com/api/v2`.
- Every call puts the API key in the query string as `apiKey`. There is no `Authorization` header.
- `GET /pods/{pod_id}?fields=id,room,acState,measurements,connectionStatus,remoteCapabilities&apiKey=…`
  - Success HTTP 200: `{"status":"success","result":{…pod…}}`.
  - The pod object uses `id`, `room.name`, `connectionStatus.isAlive`, `acState` (`on`, `mode`, `targetTemperature`, `temperatureUnit`, `fanLevel`, `swing`), `measurements` (`temperature`, `time`), and `remoteCapabilities.modes.<mode>.temperatures.<C|F>.values` (a list of numbers).
- `PATCH /pods/{pod_id}/acStates/{property}?apiKey=…` with JSON `{"newValue": <value>, "currentAcState": {…last acState…}}`.
  - `property` is `on` (JSON boolean), `mode` (JSON string), or `targetTemperature` (JSON number).
  - Success HTTP 200: `{"status":"success","result":{"acState":{…}}}`.
- Errors use HTTP 400, 401, 403, 404, 429, or 5xx and a JSON body `{"status":"failure","reason":"…"}` when Sensibo sends JSON. The client also treats HTTP 200 with `"status":"failure"` as an error.
- Sources for the agent who writes the client and the fake. Put these URLs in a comment at the top of `tests/fake_sensibo.py` and `dashboard/sensibo_client.py`:
  - PATCH one property: `https://support.sensibo.com/api/operations/podsdevice_idacstatesproperty/`
  - Full-state POST (not used for start): `https://support.sensibo.com/api/operations/podsdevice_idacstates/post/`
  - Device read: `GET /api/v2/pods/{id}` on `https://home.sensibo.com/api/v2`, response wrapper `status` + `result`.
- Assumed, and recorded in that same comment: the exact `reason` strings, the `remoteCapabilities` temperature lists, and sending `currentAcState` next to `newValue`. The public PATCH page requires `newValue`. Working clients also send `currentAcState`. The fake requires `newValue` and accepts `currentAcState` without checking that it matches the stored state.

Backend API contract (the page and the tests depend on this):

- `GET /api/status` → `200`
  ```json
  {"pod_id":"abc123pod","name":"Living Room",
   "power":"on","hvac_mode":"cool","hvac_action":null,
   "target_temperature":22,"current_temperature":25.5,"unit":"°C",
   "min_temp":16,"max_temp":30,"temp_step":1,
   "hvac_modes":["off","cool","heat"],
   "available":true,"can_start":true,
   "last_updated":"2026-09-30T12:00:00Z",
   "default_temperature":22}
  ```
- `POST /api/start` with `{"temperature": 24}` or `{"temperature": null}` (`null` means `DEFAULT_TEMP`) → `200 {"ok":true,"status":{…same shape as /api/status…}}`.
- `POST /api/stop` with `{}` → `200 {"ok":true,"status":{…}}`.
- `GET /api/ui-config` → `200 {"poll_interval":15,"default_temperature":22}`.
- Every error → a non-2xx status and this JSON body (§6):
  `{"ok":false,"error":{"code":"<code>","message":"<text for the user>","detail":"<optional>","step":"<optional>"}}`.
  `step` for a start failure is `on`, `mode`, or `targetTemperature`.

Field rules for the status object:

- `power` is `on` or `off` from `acState.on`.
- `hvac_mode` is `off` when `acState.on` is false. Otherwise it is `acState.mode`.
- `unit` is `°C` when `temperatureUnit` is `C`, and `°F` when it is `F`.
- `min_temp` and `max_temp` are the minimum and maximum of `remoteCapabilities.modes.cool.temperatures[<unit>].values`. `temp_step` is 1 when those values are consecutive integers. Otherwise it is the smallest positive gap. If that capabilities object is missing, use 16…30 step 1 for `C` and 61…86 step 1 for `F`, and still allow start. The fake always sends capabilities. One config-free unit test covers the fallback.
- `available` is true only when `connectionStatus.isAlive` is true.
- `can_start` is true only when `available` is true and `cool` is one of the modes.
- `hvac_action` is JSON `null` for Sensibo.
- The backend builds every JSON body with `json.dumps`. It never inserts user text into JSON source.

Behavior rules:

- **start**: (1) Read the pod. (2) Validate: the pod exists, it is online, `cool` is supported, and `T` is a finite number in the cool mode's allowed values for the pod's unit. `null` temperature means `DEFAULT_TEMP`. (3) Mode step: if `acState.on` is not true, PATCH `on` to `true`, then PATCH `mode` to `cool`. If it is already on, PATCH `mode` to `cool` only. (4) Temperature step: PATCH `targetTemperature` to `T`. (5) Read the pod again and return it. If any call in this sequence has succeeded and a later call fails, return `partial_start` and do not continue. This is the script's order (Q4): mode first, temperature second. The extra `on` PATCH runs only when the pod is off, and it runs inside the mode step, before `mode`, and before any temperature PATCH.
- The service does those two reads. `set_cool_mode`, `set_target_temperature`, and `turn_off` do not send their own GET. The controller keeps the last `acState` (from the read, or from the PATCH response) and sends it as `currentAcState`. After PATCH `on` to true, the PATCH `mode` that follows sends `currentAcState` with `on` true. Stage 4's log is therefore one GET, then the PATCH calls, then one GET.
- **stop**: Read the pod, PATCH `on` to `false`, read the pod again. Send the PATCH even when the pod is already off.
- **status**: Read the pod and map the fields above. Do not change the pod.
- The backend runs only one start or stop at a time (a lock). A second command gets `busy`. A status poll may run during a command.
- Sensibo request timeout: default 10 s.
- Fan level and swing are never sent. Sensibo keeps the pod's previous values.

### 3.5 Replacing Sensibo later

`service.py` depends on four operations, not on Sensibo URLs:

| Operation | Sensibo implementation in v1 | What start/stop does with it |
|---|---|---|
| `read_status()` | `GET` the pod and map §3.4 | Used before validation and after every command |
| `set_cool_mode()` | PATCH `on` to true when the pod is off, then PATCH `mode` to `cool` | First command of start |
| `set_target_temperature(t)` | PATCH `targetTemperature` | Second command of start |
| `turn_off()` | PATCH `on` to false | The command of stop |

A later method adds one new module, for example `dashboard/broadlink_controller.py` or `dashboard/tasmota_controller.py`, with those four operations. It adds its own configuration variables and its own fake under `tests/`. It does not change the page, the `/api/status`, `/api/start`, and `/api/stop` bodies, the error JSON shape, or the access rules in §4.2. One function, `build_controller(config)`, is the only place that constructs the controller. In v1 that function always returns `SensiboController`. v1 has no `AC_CONTROL` switch and does not ship the other controllers.

What the new controller must provide:

- The same status fields the page already shows. `hvac_action` may stay `null`.
- `set_cool_mode` and `set_target_temperature` as two separate operations, so `partial_start` still has a meaning.
- Its own fake, so the tests still need no real AC.

If that method can only send one combined command (a single AC infrared frame, or one Tasmota `IRhvac` JSON object), apply Q4 this way: `set_cool_mode()` records the mode and does not send yet, and `set_target_temperature()` sends one command that contains cool and the temperature. The service still calls the two operations in that order. `partial_start` then means the combined send failed after the mode was accepted in memory. Write that down in the new module's docstring so the next agent does not fold the two service calls into one.

---

## 4. Security

### 4.1 Where the dashboard keeps the Sensibo API key

- The key is only in the **backend process memory**. The backend reads it at start from the file named by `SENSIBO_API_KEY_FILE` (preferred), or from the `SENSIBO_API_KEY` environment variable (§5).
- The key file is outside the repository (for example `~/.config/ac-dashboard/sensibo-api-key`). Mode `0600`. The backend prints a warning at start if the file is readable by group or others, and it refuses to start if the file is empty.
- Sensibo keys are account-wide. A key can control every pod on that account. The backend calls only the configured pod id. It never calls `/users/me/pods`. The owner should treat the key like a password. Sensibo does not offer a key that is limited to one pod. Revoking the key is done in the Sensibo account, then the owner updates the file and restarts the dashboard.
- The key is a query parameter on every Sensibo URL (`apiKey=`). The backend therefore:
  - builds the URL with `urllib.parse` and never logs a URL, a query string, or a request line that could contain the key;
  - logs only the HTTP method, the path without a query, the status code, and the elapsed milliseconds;
  - replaces the key with `<redacted>` in any exception text before that text is logged or placed in `error.detail`;
  - never puts the key in an API response, an error message, a static file, or a command line (`ps` must not show it).
- A test uses a distinctive key and checks that no response body, response header, or captured log contains it (stage 3 and stage 5).
- The Sensibo connection is HTTPS. Certificate checks stay on. `SENSIBO_CA_FILE` is an optional private CA. Plain `http` to Sensibo is a configuration error, except when the host is `127.0.0.1` or `localhost` (the fake in §8).
- After HTTP 401, the backend stops automatic polling until the user presses **Retry** or the process restarts. Repeating a bad key does not help. After HTTP 429, polling continues with the backoff in §6.

### 4.2 Who can open the dashboard

- **Default: only the local machine.** The backend listens on `127.0.0.1:8080`. It checks the `Host` header (it must be `127.0.0.1:<port>` or `localhost:<port>`) to block DNS-rebinding attacks.
- **LAN access is off unless the owner turns it on.** Set `DASHBOARD_BIND=0.0.0.0` (or a LAN IP address). The backend **refuses to start** on a non-loopback address unless `DASHBOARD_PASSWORD_FILE` is set. With a password:
  - The page shows a login form. `POST /login` checks the password (constant-time compare) and sets a random session cookie (`HttpOnly`, `SameSite=Strict`, plus `Secure` when TLS is used). Sessions are kept in memory and expire after 12 h. After 5 wrong passwords, logins from that address are blocked for 1 minute.
  - Without a valid session, every `/api/*` call returns `401` with the error code `dashboard_login_required`.
  - `DASHBOARD_ALLOWED_HOSTS` (a comma-separated list) sets the accepted `Host` values.
- **No internet exposure.** `DASHBOARD.md` will say this. The backend makes outbound HTTPS calls to Sensibo. That is separate from who may open the page. For access to the page from outside the LAN, use a VPN, not port forwarding. If the owner wants TLS on the LAN, put a reverse proxy (for example Caddy or nginx) in front of the backend. That proxy is not part of this project.
- **CSRF**: `POST /api/*` requires `Content-Type: application/json` and a header `X-AC-Dashboard: 1`, and it rejects requests whose `Origin` header does not match the host. A cross-site form cannot send these.
- **Page hardening**: responses set `Content-Security-Policy: default-src 'self'`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and `X-Frame-Options: DENY`. The page puts all text from Sensibo into the page with `textContent`, never `innerHTML` (Sensibo error text and room names are untrusted).
- **Fixed scope**: the browser cannot choose the pod id or which Sensibo property is sent. Those are fixed in the backend (§3.3).

Q2 is answered: these access rules stay. The default is localhost only. LAN access requires the dashboard password. The plan does not permit access from the internet.

---

## 5. Configuration

The backend reads only **environment variables**, once, at start. It does not read a config file from the repository. The API key is never committed.

| Variable | Required | Default | Meaning and validation |
|---|---|---|---|
| `SENSIBO_API_BASE` | no | `https://home.sensibo.com/api/v2` | Base URL, with no query and no userinfo. A single trailing `/` is removed. Scheme `https` is required, except that `http` is allowed when the host is `127.0.0.1` or `localhost` (the fake). |
| `SENSIBO_API_KEY_FILE` | one of these two | — | Path to a file that holds only the key. Whitespace at the ends is removed. The file must exist and must not be empty. Preferred over `SENSIBO_API_KEY`. |
| `SENSIBO_API_KEY` | one of these two | — | The key itself. Use it only when a file is not possible. If both are set, the backend uses the file and logs a warning that does not contain the key. |
| `SENSIBO_POD_ID` | yes | — | The pod id. It must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`. |
| `DEFAULT_TEMP` | no | `22` | Used when Start is given no temperature. It is a finite number in the pod's unit (`C` or `F`). The backend does not convert it (Q5, Q10). |
| `SENSIBO_TIMEOUT` | no | `10` | Seconds for each Sensibo request, from 1 to 60. |
| `SENSIBO_CA_FILE` | no | — | Optional CA bundle. If set, the file must exist. |
| `POLL_INTERVAL` | no | `15` | Seconds between status refreshes in the browser, from 10 to 300. The minimum is 10 so a normal poll stays well under Sensibo's rate limit. The backend sends this value to the page. |
| `DASHBOARD_BIND` | no | `127.0.0.1` | Listen address. |
| `DASHBOARD_PORT` | no | `8080` | Listen port, from 1 to 65535. |
| `DASHBOARD_PASSWORD_FILE` | yes if the bind address is not loopback | — | A file with the dashboard password. Loopback means `127.0.0.1`, the same default as §4.2. Any other bind address requires this file. |
| `DASHBOARD_ALLOWED_HOSTS` | no | derived from the bind address and port | Accepted `Host` header values. |

Rules:

- If a value is missing or invalid, the backend exits with code 2 and one line per problem, for example `config error: SENSIBO_POD_ID must match the pod id pattern`. The line never contains the API key. A bad base URL that uses `http` for a non-loopback host is a config error.
- The base URL, the key, and the pod id are **server-side only**. The page learns the pod id, the default temperature, and the poll interval from `/api/status` and `/api/ui-config`. The page cannot change them.
- A check at start, which logs and does not stop the process: one `GET` of the pod. Sensibo can be down when the dashboard starts. The dashboard still starts, and the page shows the error (§6). The log line is the result class (`ok`, `unauthorized`, `pod_not_found`, `unreachable`), never the URL and never the key.
- Only `DEFAULT_TEMP` carries over from the script. The dashboard has its own base URL, API key, and pod id. `DASHBOARD.md` tells the owner to create a key in the Sensibo account and to copy the pod id from the Sensibo app (or from one manual `GET /api/v2/users/me/pods` done in a shell). The running dashboard never calls that list endpoint.
- `DEFAULT_TEMP` is checked against the pod's allowed values when the user presses Start, not at process start, because the allowed list comes from the pod (Q10).

---

## 6. Errors

### 6.1 How errors are shown on the page

- **Banner** (top of the page, `role="alert"`): connection and system errors. It stays until the next successful call, then it clears.
- **Inline message** (under the temperature input): validation errors.
- **Action result** (next to the buttons): success or failure of the last Start or Stop.
- **Stale status**: when a refresh fails, the Status panel keeps the last good values, greyed out, with the text "Last known at 12:03:10". It does not show blanks as if they were live.
- Each message says what happened, what that means for the AC, and what to do next. The HTTP code and Sensibo's `reason` go in a "Details" section the user can open. Text from Sensibo is inserted with `textContent`. The API key is never shown.

### 6.2 Error catalogue

The client classifies transport failures. The controller maps them to the codes below. The page switches on `error.code` only.

| Situation | How it is detected | HTTP status and `error.code` | What the page shows | Controls |
|---|---|---|---|---|
| **The browser cannot reach the backend** | `fetch()` rejects | none (the error is in the browser) | Banner: "Can't reach the dashboard server. Check that it is running. Retrying…" Polling backs off: start at the poll interval, double it, and do not wait longer than 60 s. | Disabled |
| **The backend cannot reach Sensibo** (DNS, connection refused, TLS failure) | `URLError` / `OSError` / `ssl.SSLError`, after the key is redacted | `502 sensibo_unreachable` | Banner: "Can't reach Sensibo. The AC state is unknown." Details: the reason, with the key removed (for example "connection refused"). Polling backs off. | Disabled |
| **Timeout** talking to Sensibo | timeout after `SENSIBO_TIMEOUT` | `504 sensibo_timeout` | Banner: "Sensibo did not answer within 10 s." For a command: "The command may or may not have reached the AC. Check the status." The page then refreshes once. If the mode step already succeeded, a timeout on the temperature step is `partial_start` instead. | Disabled during backoff |
| **Bad or revoked API key** | HTTP 401, or a failure reason that the client maps from 401 | `502 sensibo_unauthorized` | Banner: "Sensibo rejected the API key. Ask the owner to update SENSIBO_API_KEY_FILE and restart the dashboard." Automatic polling **stops**. A **Retry** button is shown. | Disabled |
| **Forbidden** | HTTP 403 | `502 sensibo_forbidden` | Banner: "Sensibo refused this request (HTTP 403)." | Disabled |
| **Rate limited** | HTTP 429 | `502 sensibo_rate_limited` | Banner: "Sensibo is rate-limiting the dashboard. Waiting before the next refresh." Polling backs off to at least 60 s. Commands are not retried automatically. | Enabled after the backoff |
| **Sensibo rejected the value** | HTTP 400, or HTTP 200 with `"status":"failure"` on a PATCH | `502 sensibo_rejected` (plus `step`) | Action result: "Sensibo rejected the temperature: \<reason\>." The reason is Sensibo's `reason` field when the body is JSON. | Enabled |
| **Sensibo server error**, or a body that is not JSON when JSON is required | HTTP 5xx, or an unreadable body | `502 sensibo_error` | Banner: "Sensibo returned an error (HTTP 500). Try again later." Details: the first 200 characters, with the key removed. | Status can be retried. Commands stay available. |
| **No such pod** | `GET` or `PATCH` returns HTTP 404 | `404 pod_not_found` | The Status panel is replaced with: "Sensibo has no pod `<id>`. Check SENSIBO_POD_ID." | Hidden |
| **Pod offline** | `connectionStatus.isAlive` is false | `/api/status` returns `200` with `available:false`. A command returns `409 pod_offline`. The backend does not send a PATCH in this case. | Yellow warning: "The Sensibo pod is offline. The AC was not changed." Values that are missing show as `—`. | Disabled |
| **Cool is not supported** | `cool` is not in `remoteCapabilities.modes` | status `can_start:false`. Start returns `409 mode_not_supported`. | Next to Start: "This AC does not support cool mode. Modes: heat, fan." | Start disabled. Stop enabled. |
| **Invalid temperature** | not a finite number, or not in the cool mode's allowed values for the pod's unit | `422 invalid_temperature` | Inline: "Enter a temperature the AC allows (16 to 30 °C)." The page checks this before sending, using `min_temp`, `max_temp`, and `temp_step` from the status. The backend checks the real values list. | Enabled |
| **Partial start** | a later start call failed after an earlier one in that start returned success | `502 partial_start` (inner code in `detail`, `step` set) | Action result: "The AC was set to cool, but the target temperature was not set (\<reason\>). It may still be at the previous target." If the failure is the mode PATCH after `on` succeeded, the text says the pod was switched on and cool mode was not set. The status refreshes. | Enabled |
| **Another command is running** | the lock is held | `409 busy` | "Another command is still running. Try again in a moment." | Enabled when the other command ends |
| **Dashboard login required** | no session, or an expired session, in password mode | `401 dashboard_login_required` | The page shows the login form. | — |
| **Unexpected backend bug** | an unhandled exception | `500 internal_error` | Banner: "The dashboard hit an internal error." The log gets a stack trace with the key redacted. | Enabled |

---

## 7. Stages

Rules for every stage:

- Each stage is small enough for a different agent, in a later turn, in the order below.
- A stage creates only the files it names. It must not change `work-script.sh` or `README.md`.
- "Done when" is the proof. All earlier tests still pass: `python3 -m unittest discover -s tests -v` exits 0.
- Target: Python 3.9 or newer, standard library only. The page is HTML, CSS, and JS (ES2019), with no build step and no CDN.
- No stage needs a real AC, a real Sensibo pod, or a call to `home.sensibo.com`. The fake listens on `127.0.0.1`.
- Each stage updates `QUESTIONS.md` under the job rules. Q9 stays open until the buyer answers it. Do not re-ask Q1 to Q8 or Q10.

### Stage 1: Project skeleton and configuration

- Create `dashboard/__init__.py`, `dashboard/config.py`, `dashboard/__main__.py` (load config, print a summary that omits the API key, exit), and `tests/test_config.py`.
- `load_config(env) -> Config` is a frozen dataclass. It raises `ConfigError` with a list of messages. It implements every rule in §5, including the `0600` warning, the file-over-environment key rule, the loopback-only `http` rule, and the password required for a non-loopback bind.
- **Done when**: tests cover each variable, valid and invalid (missing pod id, bad pod id, both key sources set, empty key file, `http://home.sensibo.com/api/v2` rejected, `http://127.0.0.1:9/api/v2` accepted, `0.0.0.0` without a password rejected, defaults). `SENSIBO_API_BASE=x python3 -m dashboard` exits 2 with clear lines. A test shows the key text is absent from every error message and from the printed summary.

### Stage 2: Fake Sensibo

- Create an empty `tests/__init__.py`, `tests/fake_sensibo.py` as in §8.2, and `tests/test_fake_sensibo.py`. The CLI is `python3 -m tests.fake_sensibo --port 8765 --scenario normal`.
- The comment at the top lists the Sensibo documentation URLs from §3.4 and the behaviors that are assumed (error `reason` text, capabilities shape, `currentAcState` accepted and not compared).
- **Done when**: `test_fake_sensibo.py` passes, driving the fake with `urllib` for every scenario. A hand check `curl "http://127.0.0.1:8765/api/v2/pods/abc123pod?fields=acState&apiKey=test-key"` returns the pod JSON. `curl` output in notes must not be copied from a machine that used a real key.

### Stage 3: Sensibo client

- Create `dashboard/sensibo_client.py` and `tests/test_sensibo_client.py`.
- `SensiboClient(base_url, api_key, pod_id, timeout, ca_file)` with `get_pod()` and `set_property(property, new_value, current_ac_state)`. It raises `SensiboError(code, message, http_status, detail)` using the transport codes in §6.2: `sensibo_unreachable`, `sensibo_timeout`, `sensibo_unauthorized`, `sensibo_forbidden`, `sensibo_rate_limited`, `sensibo_rejected`, `sensibo_error`, `pod_not_found`.
- Paths, the `fields` query, and JSON bodies match §3.4. `set_property` sends `newValue` and `currentAcState`.
- **Done when**: tests run against the fake for every scenario, plus a closed port and a `slow` scenario with `timeout=0.5`. They check the path, the property, and `newValue` from the fake's log. They check that the key is not stored in the log's string form and is not present in any `SensiboError` field. No test contacts `home.sensibo.com`.

### Stage 4: Controller and service

- Create `dashboard/errors.py` (`DashboardError`), `dashboard/controller.py` (`AcController` and `SensiboController`), `dashboard/service.py`, and `tests/test_service.py`.
- `SensiboController` implements the four operations in §3.5 and maps `SensiboError` to `DashboardError`. `set_cool_mode` raises `partial_start` with `step` `mode` when the `on` PATCH succeeded and the `mode` PATCH failed.
- `service.py` implements `status()`, `start(temperature)`, and `stop()` with the rules in §3.4: validation, the mode step before the temperature step, `partial_start` when the temperature step fails, the lock, and `busy`. It does not import `sensibo_client`.
- **Done when**: for a pod that is already on, the fake log for start is `GET`, `PATCH mode cool`, `PATCH targetTemperature`, `GET`. For a pod that is off, the log is `GET`, `PATCH on true`, `PATCH mode cool`, `PATCH targetTemperature`, `GET`. Stop's log is `GET`, `PATCH on false`, `GET`. Tests cover every backend row of §6.2 (not the browser-only row and not the login row), including `partial_start` for `fail_set_temperature` (pod starts on) and for `fail_set_mode` (pod starts off, the `on` PATCH succeeds, the `mode` PATCH returns 500), `pod_offline` with no PATCH sent, and `invalid_temperature` for `DEFAULT_TEMP` 22 on the fahrenheit scenario (Q10).

### Stage 5: HTTP server and security

- Create `dashboard/server.py`, change `dashboard/__main__.py` so it serves, and create `tests/test_server.py`.
- Use `ThreadingHTTPServer`. Routes: `GET /`, `GET /static/…`, `GET /api/ui-config`, `GET /api/status`, `POST /api/start`, `POST /api/stop`, and `GET`/`POST /login` plus `POST /logout` when a password is set. Include the Host check, CSRF checks, security headers, session cookie, and login rate limit from §4.2, and the error JSON from §3.4.
- The static page at this stage is a placeholder `dashboard/static/index.html` that says "dashboard".
- **Done when**: tests bind the server on a free port against the fake and check:
  - the HTTP status and `error.code` for each route and scenario;
  - 403 for a bad `Host`, a bad `Origin`, or a missing `X-AC-Dashboard` header;
  - 401 with no session in password mode;
  - the process refuses `0.0.0.0` without a password;
  - the security headers are present;
  - the API key is in no response body, no response header, and no captured log.
  `curl -s localhost:8080/api/status` against a running fake returns the JSON in §3.4.

### Stage 6: Page with the Status panel

- Create `dashboard/static/index.html`, `app.js`, and `style.css`.
- The Status panel (§2.2), polling (`POLL_INTERVAL` from `/api/ui-config`), **Refresh**, the stale-value display, and banners for `sensibo_unreachable`, `sensibo_timeout`, `sensibo_unauthorized` (polling stops, Retry shown), `sensibo_rate_limited`, `pod_not_found`, and `pod_offline`. Action is hidden when `hvac_action` is null. All text uses `textContent`. The page works under the CSP (no inline script or style).
- Put the pure logic (API response → view model, error code → message) in functions in `app.js` that do not touch the DOM, so §8.4 can test them.
- **Done when**: the fake and the dashboard are running and the page shows the fake's values. Changing the scenario (§8.2) changes the banner or the panel within one poll interval. The status rows of the §8.5 checklist pass.

### Stage 7: Controls

- Add the Controls panel: temperature input (prefilled with `default_temperature`, limited by `min_temp`, `max_temp`, and `temp_step`), **Start (cool)**, and **Stop**. Buttons are disabled while a request runs. Add action-result text, inline validation, and `can_start`.
- **Done when**: against the fake, Start with an empty input ends at cool / 22, Start with 24 ends at cool / 24, and Stop ends at off. The Status panel shows that after the click. The fake log matches the sequences in stage 4. The control rows of §8.5 pass.

### Stage 8: Remaining errors and the login form

- Show every row of §6.2, including the browser network error with backoff, `partial_start`, `busy`, `invalid_temperature`, `mode_not_supported`, and the login form.
- **Done when**: every row of §8.5 passes against the fake. If Playwright is available (§8.4), the automated browser tests for those rows pass.

### Stage 9: Documentation

- Create `DASHBOARD.md`: how to run, the configuration table, where the API key file lives, the outbound-versus-inbound note, "do not expose the page to the internet", and how the owner gets a pod id. State that only `DEFAULT_TEMP` carries over from the script.
- **Done when**: all tests pass, and a new user can follow `DASHBOARD.md` from an empty shell to a dashboard running against the fake. The documented commands use `test-key` and the fake. They do not call `home.sensibo.com`.

### Possible later work (not in this plan; only if the owner asks)

- A second `AcController` as in §3.5 (Broadlink, LIRC `irsend`, Tasmota, or ESPHome).
- Heat mode, fan speed, swing, or more than one pod.
- `Accept-Encoding: gzip` on Sensibo requests, which Sensibo documents as raising the rate limit.
- A systemd unit file.

---

## 8. Tests without a real AC

Tests never call `home.sensibo.com`, never use a real API key, and never need a pod, an IR blaster, or an AC. They talk to the fake on `127.0.0.1`.

### 8.1 Levels

| Level | Tool | What it covers |
|---|---|---|
| Unit | `unittest` | `config.py`, error mapping, capabilities fallback, and the view-model functions |
| Integration | `unittest` plus the fake Sensibo over HTTP on `127.0.0.1` | the client, the controller, the service, and the server |
| Browser | the manual checklist in §8.5 (required). Playwright is optional. | the page shows each state and each error |

Command: `python3 -m unittest discover -s tests -v`. It needs no network path to Sensibo and no pip packages.

The shell script is not a test double and is not executed by these tests. It stays unchanged. Parity with the script is the call **order** in §3.4: mode step, then temperature step. Stage 4 asserts that order on the fake's log.

### 8.2 The fake Sensibo (`tests/fake_sensibo.py`)

- A `ThreadingHTTPServer` on `127.0.0.1`, port 0 in tests (a free port). `with FakeSensibo(scenario="normal") as fake:` exposes `fake.base_url` (it ends with `/api/v2`), `fake.requests`, and `fake.state`.
- The accepted key is `test-key`. Any other or missing `apiKey` returns HTTP 401 and `{"status":"failure","reason":"Invalid API key"}`.
- The pod id is `abc123pod`. Any other id returns HTTP 404 and `{"status":"failure","reason":"Pod not found"}`.
- Endpoints:
  - `GET /api/v2/pods/abc123pod` → `{"status":"success","result":{…}}` using the shape in §3.4.
  - `PATCH /api/v2/pods/abc123pod/acStates/on`, `…/mode`, and `…/targetTemperature` update the in-memory `acState` and return `{"status":"success","result":{"acState":{…}}}`.
  - A mode that is not in capabilities, or a target temperature that is not in the values list, returns HTTP 400 and `{"status":"failure","reason":"…"}`.
  - Any other property returns HTTP 400.
- The request log stores method, path, property, `new_value`, and `api_key_match`. It does not store the query string or the key. Its string form must not contain `test-key`.
- **Scenarios**, set in the constructor or with `POST /__fake/scenario` and body `{"scenario":"<name>"}` (this path is on the fake's host, not under `/api/v2`):
  - `normal` — on, cool, target 22, unit C, current 25.5, alive, room "Living Room", cool and heat, C values 16…30
  - `off` — `on` false, last mode still `cool`, target 22
  - `bad_key` — every request is 401, even with `test-key`
  - `forbidden` — 403
  - `pod_missing` — 404 on GET and PATCH
  - `offline` — `isAlive` false, otherwise like `normal`
  - `heat_only` — modes are `heat` only
  - `fahrenheit` — unit F, target 72, current 78, F values 61…86
  - `server_error` — 500
  - `bad_json` — HTTP 200 with a body that is not JSON
  - `slow` — sleeps longer than the client timeout
  - `drop` — closes the connection
  - `fail_set_temperature` — starts like `normal` (`on` true). `mode` succeeds, `targetTemperature` returns 500
  - `fail_set_mode` — starts like `off` (`on` false). The `on` PATCH succeeds, the `mode` PATCH returns 500
  - `null_measurements` — `measurements.temperature` is JSON `null`
  - `rate_limited` — 429
- Connection-refused is tested without the fake: bind a port, close it, and point `SENSIBO_API_BASE` at `http://127.0.0.1:<that port>/api/v2`.

### 8.3 What each test file checks

- `test_config.py`: §5 (stage 1).
- `test_fake_sensibo.py`: the fake's own routes and scenarios (stage 2).
- `test_sensibo_client.py`: each scenario maps to the right `SensiboError` code, the path and body are right, the timeout works, and the key never appears (stage 3).
- `test_service.py`: the exact order of Sensibo calls for status, start, and stop, validation, both `partial_start` cases, `busy`, `pod_offline` with no PATCH, and the fahrenheit default (stage 4).
- `test_server.py`: routes, error JSON, the §4.2 checks, and the key never appearing (stage 5).

### 8.4 Browser tests

- **Required**: the checklist in §8.5. The agent who runs it writes pass or fail for each row in that turn's notes.
- **Optional**, when it can be installed under `$HOME` (`pip install --user playwright` and `python3 -m playwright install chromium`): `tests/browser/test_ui.py` runs the §8.5 rows. Skip it when Playwright is absent, so the main test command stays free of dependencies.
- **Optional**: if Node.js is present, test the DOM-free functions in `app.js` with `node --test`. Skip that when Node.js is absent.

### 8.5 Manual checklist (fake Sensibo and the dashboard on localhost)

Start the fake:

`python3 -m tests.fake_sensibo --port 8765 --scenario normal`

Start the dashboard:

`SENSIBO_API_BASE=http://127.0.0.1:8765/api/v2 SENSIBO_API_KEY=test-key SENSIBO_POD_ID=abc123pod python3 -m dashboard`

Open `http://127.0.0.1:8080`. Change the scenario with:

`curl -s -X POST 127.0.0.1:8765/__fake/scenario -H 'Content-Type: application/json' -d '{"scenario":"<name>"}'`

| # | Scenario / action | Expected |
|---|---|---|
| 1 | `normal`, open the page | Power On, Mode cool, Target 22 °C, Current 25.5 °C. No Action row. |
| 2 | `off` | Power Off, Mode off |
| 3 | Start with the input empty | Success, then Mode cool, Target 22 |
| 4 | Start with 24 | Target 24 |
| 5 | Start with 99 | Inline range message, no PATCH in the fake log |
| 6 | Stop | Power Off |
| 7 | Stop the fake process | Banner "Can't reach Sensibo", stale values, controls disabled. Start the fake again: the banner clears on its own. |
| 8 | Stop the dashboard process | Banner "Can't reach the dashboard server", with backoff |
| 9 | `bad_key` | API-key banner, polling stops, Retry button |
| 10 | `pod_missing` | Pod-not-found panel, controls hidden |
| 11 | `offline` | Yellow offline warning, controls disabled, no PATCH sent |
| 12 | `heat_only` | Start disabled with a reason, Stop works |
| 13 | `server_error` | Error banner with HTTP 500 in Details |
| 14 | `slow` | Timeout banner after `SENSIBO_TIMEOUT` |
| 15 | `fail_set_temperature`, then Start | Partial-start message |
| 16 | `fahrenheit` | Unit °F. Start with the default 22 shows an inline out-of-range message (Q10). |
| 17 | `null_measurements` | Current temperature shows `—` |
| 18 | `rate_limited` | Rate-limit banner, polling slows down |
| 19 | Password mode (`DASHBOARD_BIND=0.0.0.0` and a password file) | Login form. A wrong password is rejected. After login, the dashboard works. |
