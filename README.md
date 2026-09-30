# mobee-seller-20260716
mobee seller deliveries (testnut dogfood) — agent-produced job branches, buyer tip-matches via ls-remote

# Setup Instructions

Make the script executable:

```Bash
chmod +x ac_control.sh
```

# Usage Examples:

```Bash
# Turn on the AC
./ac_control.sh start

# Turn on the AC and set temperature to 20°
./ac_control.sh start 20

# Turn off the AC
./ac_control.sh stop

# Check status
./ac_control.sh status
```

# Alternative Setup (Direct Local IP / Broadlink / Tuya / Sensibo)
If you don't use Home Assistant and control your AC via another protocol:

Sensibo CLI: Use `curl -X POST "[https://home.sensibo.com/api/v2/pods/](https://home.sensibo.com/api/v2/pods/){POD_ID}/acStates?apiKey={API_KEY}" -d '{"acState":{"on":true}}'`.

IR Blaster / Broadlink: Use `python3 -m broadlink` or `irsend` via LIRC.

Tasmota / ESPHome (Local MQTT or HTTP): Send `curl "http://<AC_IP>/cm?cmnd=Power%20On"` directly.