#!/bin/bash
################################################################################
# idrac_fan_control.sh
# RUNS ON: Debian VM (on the R730 itself), every 5 minutes via cron
#
# Reads Inlet, CPU1 and CPU2 temps from the R730's iDRAC.
#   - Too hot, or a sensor won't read -> hand fans back to iDRAC automatic mode
#   - Everything safe                  -> manual mode, speed based on inlet temp
# After every run where the iDRAC accepts the command, it updates a heartbeat
# file. The watchdog on the Raspberry Pi checks that file and restores
# automatic fans if it goes stale.
#
# Needs: ipmitool, iputils-ping   (sudo apt install ipmitool iputils-ping)
################################################################################

# ------------------------------- CONFIG ---------------------------------------
IDRAC_IP="192.168.1.251"
IDRAC_USER="root"
IDRAC_PASSWORD="<your-idrac-password>"

INLET_TEMP_THRESHOLD=28   # Inlet at/above this -> automatic fans (C)
CPU_TEMP_THRESHOLD=75     # Either CPU at/above this -> automatic fans (C)

# Manual fan speeds (hex value = percent)
SPEED30="0x1e"
SPEED50="0x32"
SPEED80="0x50"

# iDRAC sensor IDs for the R730
INLET_SENSOR="04h"
CPU1_SENSOR="0Eh"
CPU2_SENSOR="0Fh"

MAX_SENSOR_ATTEMPTS=3     # 1 try + 2 retries
RETRY_DELAY=5             # seconds between retries

# The watchdog reads this file over SSH. Keep its path in sync with
# HEARTBEAT_FILE in fan_watchdog.sh on the Pi.
HEARTBEAT_FILE="$HOME/fan_heartbeat"
# ------------------------------------------------------------------------------

for cmd in ipmitool ping; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "--> ERROR: '$cmd' is not installed. Run: sudo apt install ipmitool iputils-ping"
    exit 1
  fi
done

# Password goes through an environment variable so it never shows up in `ps`
export IPMI_PASSWORD="$IDRAC_PASSWORD"

ipmi() {
  ipmitool -I lanplus -H "$IDRAC_IP" -U "$IDRAC_USER" -E "$@"
}

set_auto() {
  echo "--> Action: Enabling automatic (dynamic) fan control."
  ipmi raw 0x30 0x30 0x01 0x01 >/dev/null
}

set_manual() {
  local hex=$1 pct=$2
  echo "--> Action: Manual fan control, setting fans to ${pct}%."
  ipmi raw 0x30 0x30 0x01 0x00 >/dev/null && \
  ipmi raw 0x30 0x30 0x02 0xff "$hex" >/dev/null
}

# get_temp <sensor_id> <name> : prints the reading, returns 0 if it's a valid number
get_temp() {
  local sensor_id=$1 name=$2 attempt reading
  for (( attempt = 1; attempt <= MAX_SENSOR_ATTEMPTS; attempt++ )); do
    reading=$(ipmi sdr type temperature 2>/dev/null | grep "$sensor_id" | cut -d"|" -f5 | awk '{print $1}')
    if [[ "$reading" =~ ^[0-9]+$ ]]; then
      echo "$reading"
      return 0
    fi
    if (( attempt < MAX_SENSOR_ATTEMPTS )); then
      echo "--> Sensor retry: $name reading ('$reading') invalid, retrying in ${RETRY_DELAY}s ($attempt/$((MAX_SENSOR_ATTEMPTS - 1)))..." >&2
      sleep "$RETRY_DELAY"
    fi
  done
  echo "$reading"
  return 1
}

echo
echo "Processing iDRAC at $IDRAC_IP"
echo "Date: $(date +"%d-%m-%Y %H:%M:%S")"

if ! ping -c 1 -W 3 "$IDRAC_IP" &>/dev/null; then
  echo "--> ERROR: Cannot ping $IDRAC_IP. Heartbeat NOT updated."
  exit 1
fi

T_INLET=$(get_temp "$INLET_SENSOR" "Inlet"); ok_inlet=$?
T_CPU1=$(get_temp "$CPU1_SENSOR" "CPU1");    ok_cpu1=$?
T_CPU2=$(get_temp "$CPU2_SENSOR" "CPU2");    ok_cpu2=$?

echo "--> Inlet Temp : ${T_INLET:-?} C"
echo "--> CPU1  Temp : ${T_CPU1:-?} C"
echo "--> CPU2  Temp : ${T_CPU2:-?} C"

if (( ok_inlet != 0 || ok_cpu1 != 0 || ok_cpu2 != 0 )); then
  echo "--> Reason: One or more sensors returned an invalid reading."
  set_auto; result=$?
elif (( T_INLET >= INLET_TEMP_THRESHOLD )); then
  echo "--> Reason: Inlet ($T_INLET C) is at/above $INLET_TEMP_THRESHOLD C."
  set_auto; result=$?
elif (( T_CPU1 >= CPU_TEMP_THRESHOLD || T_CPU2 >= CPU_TEMP_THRESHOLD )); then
  echo "--> Reason: A CPU is at/above $CPU_TEMP_THRESHOLD C."
  set_auto; result=$?
elif (( T_INLET < 1 )); then
  echo "--> Reason: Inlet ($T_INLET C) is implausibly low, not trusting it."
  set_auto; result=$?
elif (( T_INLET <= 24 )); then
  echo "--> Reason: All temps safe, inlet between 1 and 24 C."
  set_manual "$SPEED30" 30; result=$?
elif (( T_INLET <= 26 )); then
  echo "--> Reason: All temps safe, inlet between 25 and 26 C."
  set_manual "$SPEED50" 50; result=$?
else
  echo "--> Reason: All temps safe, inlet at 27 C."
  set_manual "$SPEED80" 80; result=$?
fi

# Only check in with the watchdog if the iDRAC accepted our commands
if (( result == 0 )); then
  touch "$HEARTBEAT_FILE"
  echo "--> Heartbeat updated."
else
  echo "--> ERROR: ipmitool command failed. Heartbeat NOT updated."
  exit 1
fi
