#!/bin/bash
# axiom-sink.sh — silo heartbeat + lifecycle shipper. v2 (Oct 25)
# Runs as root under launchd (com.silo.axiom-sink). Replaces the heartbeat cron stub.
#
# Events (one JSON object each, dataset "silo"):
#   kind=lifecycle state=up     at daemon start — retried until a 200 (Wi-Fi comes up after launchd)
#   kind=heartbeat state=up     every INTERVAL seconds
#   kind=lifecycle state=down   on SIGTERM — backstop only; the clean path is silo-off.sh,
#                               because macOS drops Wi-Fi before daemons get SIGTERM at shutdown
# Every event carries "state", so the absence monitor only needs the latest event:
#   latest state == up AND latest event older than ~10 min  => alert.

set -u

DATASET="silo"
HOST="silo-mini"
URL="https://api.axiom.co/v1/datasets/${DATASET}/ingest"
INTERVAL=120
UP_RETRY_S=10
UP_MAX_S=180
KEYCHAIN="/Library/Keychains/System.keychain"
TOKEN_FILE="/var/root/.axiom-ingest"   # fallback if Keychain read fails under launchd
LOG="/var/log/axiom-sink.log"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

TOKEN="$(/usr/bin/security find-generic-password -a silo -s axiom-ingest -w "$KEYCHAIN" 2>/dev/null || true)"
if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(/bin/cat "$TOKEN_FILE")"
fi
if [ -z "$TOKEN" ]; then
  log "no ingest token in System keychain or $TOKEN_FILE — exiting"
  exit 1
fi

# kern.boottime looks like: { sec = 1761372246, usec = 123 } Sat Oct 25 ...
BOOT_EPOCH="$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/awk -F'[ ,]+' '{print $4}')"
case "$BOOT_EPOCH" in ''|*[!0-9]*) BOOT_EPOCH=0 ;; esac

event() { # $1=kind $2=state
  printf '{"_time":"%s","host":"%s","kind":"%s","state":"%s","boot_epoch":%s,"daemon_pid":%s,"uptime_s":%s}' \
    "$(date -u +%FT%TZ)" "$HOST" "$1" "$2" "$BOOT_EPOCH" "$$" "$SECONDS"
}

send() { # $1=json object; prints http code (000 on transport failure)
  local code
  code="$(/usr/bin/curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "[$1]" 2>>"$LOG")" || true
  printf '%s' "${code:-000}"
}

shutdown_hook() {
  code="$(send "$(event lifecycle down)")"
  log "lifecycle=down (backstop) sent (http $code)"
  exit 0
}
trap shutdown_hook TERM INT

# --- boot marker: retry until the network is there -------------------------
waited=0
while :; do
  code="$(send "$(event lifecycle up)")"
  if [ "$code" = "200" ]; then
    log "lifecycle=up sent after ${waited}s"
    break
  fi
  if [ "$waited" -ge "$UP_MAX_S" ]; then
    log "lifecycle=up gave up after ${waited}s (http $code); heartbeats carry state=up anyway"
    break
  fi
  sleep "$UP_RETRY_S" &
  wait $!
  waited=$((waited + UP_RETRY_S))
done

# --- heartbeat loop --------------------------------------------------------
while :; do
  code="$(send "$(event heartbeat up)")"
  [ "$code" = "200" ] || log "heartbeat failed (http $code)"
  sleep "$INTERVAL" &
  wait $!
done
