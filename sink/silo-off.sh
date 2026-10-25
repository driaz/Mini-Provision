#!/bin/bash
# silo-off.sh — the clean shutdown path for the silo. Run as admin:
#   sudo /usr/local/silo/silo-off.sh
# Sends lifecycle=down while the network is still up, confirms the 200, then shuts down.
# Apple menu > Shut Down will produce a false absence alert (Wi-Fi drops before the daemon's SIGTERM).
#
# Exit codes: 0 = down confirmed and shutdown issued; 1 = not root; 2 = down never confirmed (no shutdown)

set -u

DATASET="silo"
HOST="silo-mini"
URL="https://api.axiom.co/v1/datasets/${DATASET}/ingest"
KEYCHAIN="/Library/Keychains/System.keychain"
TOKEN_FILE="/var/root/.axiom-ingest"
LABEL="system/com.silo.axiom-sink"
RETRIES=3

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

TOKEN="$(/usr/bin/security find-generic-password -a silo -s axiom-ingest -w "$KEYCHAIN" 2>/dev/null || true)"
[ -n "$TOKEN" ] || [ ! -r "$TOKEN_FILE" ] || TOKEN="$(/bin/cat "$TOKEN_FILE")"
[ -n "$TOKEN" ] || { echo "no ingest token found — not shutting down"; exit 2; }

# Stop the daemon first so no heartbeat (state=up) can land after our down.
/bin/launchctl bootout "$LABEL" >/dev/null 2>&1 || true

payload="$(printf '{"_time":"%s","host":"%s","kind":"lifecycle","state":"down","via":"silo-off"}' \
  "$(date -u +%FT%TZ)" "$HOST")"

for i in $(seq 1 "$RETRIES"); do
  code="$(/usr/bin/curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST "$URL" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "[$payload]" 2>/dev/null || echo 000)"
  if [ "$code" = "200" ]; then
    echo "lifecycle=down confirmed (200) — shutting down"
    printf '%s silo-off: lifecycle=down confirmed, shutdown\n' "$(date -u +%FT%TZ)" >> /var/log/axiom-sink.log
    /sbin/shutdown -h now
    exit 0
  fi
  echo "attempt $i: http $code"
  sleep 3
done

echo "down never confirmed — NOT shutting down. Restarting daemon. Check network / Little Snitch, then retry."
/bin/launchctl bootstrap system /Library/LaunchDaemons/com.silo.axiom-sink.plist >/dev/null 2>&1 || true
exit 2
