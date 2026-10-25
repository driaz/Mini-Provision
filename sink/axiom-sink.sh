#!/bin/bash
# axiom-sink.sh — silo heartbeat + lifecycle shipper.
# Runs as root under launchd (com.silo.axiom-sink). Replaces the heartbeat cron stub.
#
# Events (one JSON object each, dataset "silo"):
#   kind=lifecycle state=up     at daemon start
#   kind=heartbeat state=up     every INTERVAL seconds
#   kind=lifecycle state=down   on SIGTERM (clean shutdown) — best effort
# Every event carries "state", so the absence monitor only needs the latest event:
#   latest state == up AND latest event older than ~10 min  => alert.
# Clean shutdown disarms (last event = down). Pulled cord / cut Wi-Fi / killed daemon fires.

set -u

DATASET="silo"
HOST="silo-mini"
URL="https://api.axiom.co/v1/datasets/${DATASET}/ingest"
INTERVAL=120
KEYCHAIN="/Library/Keychains/System.keychain"
TOKEN_FILE="/var/root/.axiom-ingest"   # fallback if Keychain read fails under launchd

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

TOKEN="$(/usr/bin/security find-generic-password -a silo -s axiom-ingest -w "$KEYCHAIN" 2>/dev/null || true)"
if [ -z "$TOKEN" ] && [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(/bin/cat "$TOKEN_FILE")"
fi
if [ -z "$TOKEN" ]; then
  log "no ingest token in System keychain or $TOKEN_FILE — exiting"
  exit 1
fi

BOOT_EPOCH="$(/usr/sbin/sysctl -n kern.boottime | /usr/bin/sed -E 's/.*sec = ([0-9]+).*/\1/')"

event() { # $1=kind $2=state
  printf '{"_time":"%s","host":"%s","kind":"%s","state":"%s","boot_epoch":%s,"daemon_pid":%s,"uptime_s":%s}' \
    "$(date -u +%FT%TZ)" "$HOST" "$1" "$2" "$BOOT_EPOCH" "$$" "$SECONDS"
}

send() { # $1=json object; prints http code
  /usr/bin/curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "[$1]" 2>>/var/log/axiom-sink.log || echo "000"
}

shutdown_hook() {
  code="$(send "$(event lifecycle down)")"
  log "lifecycle=down sent (http $code)"
  exit 0
}
trap shutdown_hook TERM INT

code="$(send "$(event lifecycle up)")"
log "lifecycle=up sent (http $code)"

while :; do
  code="$(send "$(event heartbeat up)")"
  [ "$code" = "200" ] || log "heartbeat failed (http $code)"
  sleep "$INTERVAL" &
  wait $!
done
