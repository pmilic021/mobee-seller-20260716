#!/usr/bin/env bash

# ==========================================
# Configuration
# ==========================================
HA_URL="http://192.168.1.100:8123"                  # Replace with your Home Assistant URL
TOKEN="YOUR_LONG_LIVED_ACCESS_TOKEN_HERE"           # Replace with your token
ENTITY_ID="climate.living_room_ac"                  # Replace with your AC entity ID

# Target temperature when turning ON
DEFAULT_TEMP=22                                      # Temperature in °C or °F

# ==========================================
# Functions
# ==========================================
usage() {
    echo "Usage: $0 {start|stop|status} [temperature]"
    echo "Examples:"
    echo "  $0 start        # Turns AC on (cool mode, default temp)"
    echo "  $0 start 24     # Turns AC on at 24 degrees"
    echo "  $0 stop         # Turns AC off"
    echo "  $0 status       # Checks current AC status"
    exit 1
}

call_ha_service() {
    local service_domain="$1"
    local service_name="$2"
    local payload="$3"

    curl -s -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${HA_URL}/api/services/${service_domain}/${service_name}" > /dev/null

    if [ $? -eq 0 ]; then
        echo "Successfully sent '${service_name}' command to ${ENTITY_ID}."
    else
        echo "Error sending command to Home Assistant."
        exit 1
    fi
}

get_ac_status() {
    local response
    response=$(curl -s -H "Authorization: Bearer ${TOKEN}" "${HA_URL}/api/states/${ENTITY_ID}")
    
    if echo "$response" | grep -q "entity_not_found"; then
        echo "Error: Entity '${ENTITY_ID}' not found."
        exit 1
    fi

    local state
    local current_temp
    local target_temp

    # Extract JSON values using grep/sed (no dependency on jq)
    state=$(echo "$response" | grep -o '"state":"[^"]*"' | cut -d'"' -f4)
    target_temp=$(echo "$response" | grep -o '"temperature":[^,}]*' | head -n1 | cut -d':' -f2)
    current_temp=$(echo "$response" | grep -o '"current_temperature":[^,}]*' | head -n1 | cut -d':' -f2)

    echo "Status for ${ENTITY_ID}:"
    echo "  Power State:   ${state}"
    echo "  Target Temp:   ${target_temp}°"
    echo "  Current Temp:  ${current_temp}°"
}

# ==========================================
# Main Logic
# ==========================================
ACTION="$1"
TARGET_TEMP="${2:-$DEFAULT_TEMP}"

case "$ACTION" in
    start|on)
        echo "Starting AC..."
        call_ha_service "climate" "set_hvac_mode" \
            "{\"entity_id\": \"${ENTITY_ID}\", \"hvac_mode\": \"cool\"}"
        call_ha_service "climate" "set_temperature" \
            "{\"entity_id\": \"${ENTITY_ID}\", \"temperature\": ${TARGET_TEMP}}"
        ;;
    stop|off)
        echo "Stopping AC..."
        call_ha_service "climate" "set_hvac_mode" \
            "{\"entity_id\": \"${ENTITY_ID}\", \"hvac_mode\": \"off\"}"
        ;;
    status)
        get_ac_status
        ;;
    *)
        usage
        ;;
esac