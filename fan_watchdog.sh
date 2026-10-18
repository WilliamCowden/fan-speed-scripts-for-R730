#!/bin/bash
################################################################################
# fan_watchdog.sh
# RUNS ON: Raspberry Pi 5, Ubuntu Server, every 5 minutes via cron
#
# SSHes into the Debian VM and checks how old the fan script's heartbeat file
# is. If it's too old, or the VM can't be reached, it hands the R730's fans
# back to iDRAC automatic control and emails you via Mailgun. You get one
# email per outage, plus one when things recover.
#
# Needs: ipmitool, curl   (sudo apt install ipmitool curl)
#        SSH key login from this Pi to the Debian VM (ssh-copy-id)
#
# Test email only:   ./fan_watchdog.sh --test-email
################################################################################

# ------------------------------- CONFIG ---------------------------------------
IDRAC_IP="192.168.1.251"
IDRAC_USER="root"
IDRAC_PASSWORD="<your-idrac-password>"

# Debian VM that runs idrac_fan_control.sh
MAIN_HOST="<debian-user>@<debian-vm-ip>"

# Must match where the fan script writes it. If the fan script runs from
# <debian-user>'s crontab: /home/<debian-user>/fan_heartbeat
# If it runs from root's crontab: /root/fan_heartbeat
HEARTBEAT_FILE="/home/<debian-user>/fan_heartbeat"

MAX_AGE_MIN=15            # Fail safe if heartbeat is older than this

# --- Mailgun ---
MAILGUN_API_KEY="<your-mailgun-private-api-key>"
MAILGUN_DOMAIN="<your-mailgun-domain>"      # e.g. mg.yourdomain.com
ALERT_TO="<your-email-address>"
# US accounts: https://api.mailgun.net   EU accounts: https://api.eu.mailgun.net
MAILGUN_API_BASE="https://api.mailgun.net"
# ------------------------------------------------------------------------------

ALERT_FROM="R730 Fan Watchdog <watchdog@${MAILGUN_DOMAIN}>"
STATE_FILE="$HOME/.fan_watchdog_tripped"       # fans successfully set to auto
FAIL_ALERT_FILE="$HOME/.fan_watchdog_fail_sent" # "iDRAC unreachable" email sent
LOG_FILE="$HOME/fan_watchdog.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
now() { date '+%Y-%m-%d %H:%M:%S'; }

for cmd in ipmitool curl; do
  if ! command -v "$cmd" &>/dev/null; then
    log "ERROR: '$cmd' is not installed. Run: sudo apt install ipmitool curl"
    exit 1
  fi
done

# send_email <subject> <body>   (returns 0 on success)
send_email() {
  local subject=$1 body=$2 http_code response
  response=$(mktemp)
  http_code=$(curl -s --max-time 20 -o "$response" -w "%{http_code}" \
    --user "api:${MAILGUN_API_KEY}" \
    "${MAILGUN_API_BASE}/v3/${MAILGUN_DOMAIN}/messages" \
    -F from="${ALERT_FROM}" \
    -F to="${ALERT_TO}" \
    -F subject="${subject}" \
    -F text="${body}")
  if [[ "$http_code" == "200" ]]; then
    log "Email sent: $subject"
    rm -f "$response"
    return 0
  fi
  log "ERROR: Mailgun send failed (HTTP ${http_code:-none}): $(cat "$response" 2>/dev/null)"
  rm -f "$response"
  return 1
}

if [[ "$1" == "--test-email" ]]; then
  send_email "R730 fan watchdog: test email" \
    "If you're reading this, Mailgun alerts from the watchdog are working. Sent $(now)."
  exit $?
fi

# Age is calculated on the VM itself, so clock differences don't matter
age=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$MAIN_HOST" \
  "echo \$(( \$(date +%s) - \$(stat -c %Y '$HEARTBEAT_FILE') ))" 2>/dev/null)

# ---------------- Healthy ----------------
if [[ "$age" =~ ^[0-9]+$ ]] && (( age <= MAX_AGE_MIN * 60 )); then
  if [[ -f "$STATE_FILE" || -f "$FAIL_ALERT_FILE" ]]; then
    log "Fan script is checking in again. Watchdog reset."
    send_email "R730 fan watchdog: recovered" \
      "The fan script on $MAIN_HOST is checking in again as of $(now). It has resumed manual fan control."
    rm -f "$STATE_FILE" "$FAIL_ALERT_FILE"
  fi
  exit 0
fi

# ---------------- Unhealthy ----------------
if [[ "$age" =~ ^[0-9]+$ ]]; then
  reason="the fan script's heartbeat is $(( age / 60 )) minutes old (limit $MAX_AGE_MIN)"
else
  reason="the watchdog can't reach $MAIN_HOST or read its heartbeat file"
fi

# Already failed safe for this outage: stay quiet
[[ -f "$STATE_FILE" ]] && exit 0

log "PROBLEM: $reason. Switching $IDRAC_IP to automatic fan control."

if IPMI_PASSWORD="$IDRAC_PASSWORD" ipmitool -I lanplus -H "$IDRAC_IP" -U "$IDRAC_USER" -E \
     raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; then
  touch "$STATE_FILE"
  rm -f "$FAIL_ALERT_FILE"
  log "Automatic fan control restored."
  send_email "R730 fan watchdog: TRIPPED - fans set to automatic" \
    "Problem: $reason.

The watchdog switched iDRAC $IDRAC_IP to automatic fan control as a failsafe at $(now). The fans will stay in automatic mode until the fan script starts checking in again, and you'll get another email when it does."
else
  log "ERROR: ipmitool failed. Will retry next run."
  # Keep retrying the fan command every run, but only email about it once
  if [[ ! -f "$FAIL_ALERT_FILE" ]]; then
    send_email "R730 fan watchdog: CAN'T REACH iDRAC" \
      "Problem: $reason.

The watchdog tried to switch iDRAC $IDRAC_IP to automatic fan control at $(now), but the iDRAC didn't respond. The whole server may be off or disconnected from the network. The watchdog will keep retrying every run, and you'll get an email when things recover." \
      && touch "$FAIL_ALERT_FILE"
  fi
fi
