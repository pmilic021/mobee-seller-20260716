# QUESTIONS

Rules: answered entries stay. Never delete an entry, and never ask the same question twice. Add new entries at the end. Each entry has a status: **asked (OPEN)** or **answered**, and names who answered it.

---

## Turn 1

Nothing blocked the work in turn 1. `plan.md` was complete for that turn. For each question below, the turn-1 plan used the stated assumption. Q1 to Q4 were answered by the buyer before turn 2. Q5, Q6, and Q7 were decisions by the agent. Those entries stay.

### Q1: Standalone dashboard or native Home Assistant dashboard?
- **Status:** answered by the human (buyer), between turn 1 and turn 2.
- **Question:** "Use only Home Assistant" could mean two things. It could mean "the dashboard talks only to the HA REST API, like the script". Or it could mean "build the dashboard inside HA (Lovelace), with no separate program".
- **Assumption taken:** the first meaning. The plan builds a standalone dashboard: a small Python standard-library backend plus a static page, and its only outside system is the HA REST API (Option C in plan.md §3). Option A (a native Lovelace dashboard) is compared there. A different plan would be needed if the buyer wants Option A.
- **Answer (the exact words of the buyer):** "standalone"
- **Result:** The dashboard is a standalone program, not a dashboard inside Home Assistant. Q3 and Q8 change the plan more: the dashboard must not use Home Assistant at all.
- **Turn 2 note (agent):** The standalone shape is now `plan.md` §3.1 (a backend and a static page). The outside system is the Sensibo cloud API (Q9), not the Home Assistant REST API. The old "Option C" heading is gone.

### Q2: Who may open the dashboard?
- **Status:** answered by the human (buyer), between turn 1 and turn 2.
- **Assumption taken:** only the local machine by default (the backend listens on `127.0.0.1`). The owner can turn on LAN access, but only together with a dashboard password. The plan does not allow access from the internet (plan.md §4.2).
- **Answer (the exact words of the buyer):** "default is ok"
- **Result:** The assumption stays. By default, only the local computer can open the dashboard. LAN access needs a dashboard password. The plan does not permit access from the internet.

### Q3: A dedicated non-admin HA user for the token?
- **Status:** answered by the human (buyer), between turn 1 and turn 2.
- **Assumption taken:** the owner creates a dedicated non-admin HA user and makes a long-lived token for that user. Stage 3 checks that this token works for `/api/`, `/api/config`, `/api/states/<id>`, and the two `climate` services.
- **Answer (the exact words of the buyer):** "irrelevant since we are not using HA"
- **Clarification:** The buyer's agent asked the buyer what "not using HA" means. The buyer selected this option: "No Home Assistant at all". The dashboard must control the AC without Home Assistant.
- **Result:** The dashboard does not use Home Assistant, the Home Assistant REST API, or a Home Assistant token. The plan must use a different control method. See Q8.

### Q4: Keep the script's two separate calls for start?
- **Status:** answered by the human (buyer), between turn 1 and turn 2.
- **Assumption taken:** yes. The dashboard does start like the script: `set_hvac_mode` with `cool`, then `set_temperature`. If the second call fails, the dashboard reports it clearly (`partial_start`). The plan does not use one `set_temperature` call with `hvac_mode`, because some integrations handle that call differently.
- **Answer (the exact words of the buyer):** "yes"
- **Note from the buyer's agent:** The buyer gave this answer before the Q3 clarification. For start, keep the order of the script: first the mode `cool`, then the target temperature. If the new control method sends the full state in one command, record how the plan applies this answer.
- **Turn 2 note (agent):** Sensibo can set the whole AC state in one POST. The plan does not do that for start. Start sends the mode `cool` first (`PATCH` `mode`, and `PATCH` `on` to true first when the pod is off), then the target temperature (`PATCH` `targetTemperature`). If the temperature update fails after the mode step, the error is `partial_start`. See Q9 and `plan.md` §2.1 and §3.4.

### Q5: The unit of DEFAULT_TEMP
- **Status:** answered by the agent (a decision, not a blocker). The buyer can override it.
- **Decision:** as in the script, `DEFAULT_TEMP=22` uses HA's unit. The dashboard does not convert it. If 22 is outside the entity's `min_temp`/`max_temp` range (for example, HA uses °F), the dashboard shows an inline range error. The owner must then set `DEFAULT_TEMP` for their unit.
- **Turn 2 note (agent):** Home Assistant is no longer the control path (Q3, Q8). Q10 applies this same "do not convert" decision to the Sensibo pod's unit.

### Q6: Script file name (work-script.sh or ac_control.sh)
- **Status:** answered by the agent (a decision, not a blocker).
- **Decision:** they are the same script. The plan uses `work-script.sh`, because that is the file in the repository. This turn the rules do not allow changes to `README.md`, so the name mismatch is listed as defect D15 in plan.md §1.3.

### Q7: Features beyond the script (heat mode, fan speed, several entities)
- **Status:** answered by the agent (a decision, not a blocker).
- **Decision:** out of scope. The dashboard does only the script's three actions: start, stop, and status (with a richer status view). plan.md §7 lists other features only as possible later work.

---

## Between turn 1 and turn 2

The buyer answered Q1 to Q4. The buyer's agent asked the buyer one more question: Q8.

### Q8: Control method for the AC without Home Assistant
- **Status:** answered by the human (buyer), between turn 1 and turn 2.
- **Asked by:** the buyer's agent, after the Q3 clarification.
- **Question:** Without Home Assistant, how must the dashboard control the AC? The options were the methods in `README.md`: the Sensibo cloud API, a Broadlink IR blaster (or LIRC `irsend`), and Tasmota or ESPHome (local HTTP or MQTT).
- **Answer:** The buyer selected this option: "Agent compares and selects".
- **Result:** The turn-2 agent compares the methods in `README.md` and selects one method for the first version. The agent records the selection as a new entry with the status asked (OPEN), so that the buyer can confirm it.

---

## Turn 2

Q1, Q2, Q3, Q4, and Q8 were already answered. This turn removes Home Assistant from sections 2 to 8 of `plan.md` and selects the Sensibo cloud API. Q9 asks the buyer to confirm that selection. Q10 is a decision about the temperature unit. Nothing else blocked the work.

### Q9: First-version control method — the Sensibo cloud API
- **Status:** answered by the human (buyer), after turn 2.
- **Asked by:** the turn-2 agent, carrying out Q8.
- **Question:** The first version controls the AC with the Sensibo cloud API (`https://home.sensibo.com/api/v2`). Start sets the mode `cool` first, then the target temperature, as two Sensibo property updates. Broadlink, LIRC `irsend`, Tasmota, and ESPHome are not in the first version. Is Sensibo the method to build?
- **Assumption taken:** yes. `plan.md` §3 compares the three methods in `README.md` and selects Sensibo. Sections 2 to 8 are written for that method. Later stages follow the plan as written until the buyer answers.
- **Why it stays open:** Q8 asked for a selection the buyer can confirm. A different answer means one of the other methods in `README.md`, and a rewrite of the Sensibo-specific parts of sections 3 to 8. Section 1 stays as it is.
- **Answer (the exact words of the buyer):** "default"
- **Result:** The assumption stays. The first version uses the Sensibo cloud API.

### Q10: Unit of DEFAULT_TEMP on Sensibo
- **Status:** answered by the agent (a decision, not a blocker). The buyer can override it.
- **Decision:** `DEFAULT_TEMP` is not converted. It is a number in the pod's `acState.temperatureUnit` (`C` or `F`). If 22 is not one of the cool mode's allowed values for that unit, Start shows a range error, and the owner sets `DEFAULT_TEMP` for that unit. This carries the Q5 decision onto the Sensibo path.

---

## After turn 2

The buyer answered Q9. No entry is open now.
