#!/bin/bash
# install-sink.sh — one-shot installer for the silo Axiom sink. Run on the box as admin:
#   curl -fsSL https://raw.githubusercontent.com/driaz/Mini-Provision/main/sink/install-sink.sh | sudo bash
# Little Snitch must be in Alert mode for this run (curl -> api.axiom.co will be new).
# Prompts for the ingest-only token, verifies it with a test event, stores it in the System keychain,
# then loads the daemon. Re-runnable.

set -euo pipefail

RAW="https://raw.githubusercontent.com/driaz/Mini-Provision/main/sink"
DATASET="silo"
URL="https://api.axiom.co/v1/datasets/${DATASET}/ingest"
DIR="/usr/local/silo"
PLIST="/Library/LaunchDaemons/com.silo.axiom-sink.plist"
KEYCHAIN="/Library/Keychains/System.keychain"
LABEL="system/com.silo.axiom-sink"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

echo "== fetching daemon + plist"
mkdir -p "$DIR"
curl -fsSL "$RAW/axiom-sink.sh" -o "$DIR/axiom-sink.sh"
curl -fsSL "$RAW/com.silo.axiom-sink.plist" -o "$PLIST"
chown root:wheel "$DIR/axiom-sink.sh" "$PLIST"
chmod 755 "$DIR/axiom-sink.sh"
chmod 644 "$PLIST"

echo "== ingest token (ingest-only, dataset '$DATASET'); input hidden"
read -rs -p "token: " TOKEN </dev/tty; echo
[ -n "$TOKEN" ] || { echo "empty token"; exit 1; }

echo "== test event -> $URL"
CODE="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST "$URL" \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "[{\"host\":\"silo-mini\",\"kind\":\"install\",\"state\":\"test\"}]")"
if [ "$CODE" != "200" ]; then
  echo "test ingest failed (http $CODE). Check: token typed right (O vs 0), token scoped to '$DATASET', Little Snitch allowed curl -> api.axiom.co:443."
  exit 1
fi
echo "test ingest ok (200)"

echo "== storing token in System keychain (service axiom-ingest, account silo)"
security delete-generic-password -a silo -s axiom-ingest "$KEYCHAIN" >/dev/null 2>&1 || true
security add-generic-password -a silo -s axiom-ingest -w "$TOKEN" -T /usr/bin/security "$KEYCHAIN"
unset TOKEN

echo "== (re)loading daemon"
launchctl bootout "$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST"
launchctl enable "$LABEL"
sleep 5
launchctl print "$LABEL" | grep -E 'state|pid' || true
echo "--- last log lines:"
tail -n 5 /var/log/axiom-sink.log 2>/dev/null || echo "(no log yet)"

echo
echo "Done. Next: in Axiom, Query dataset '$DATASET' and confirm kind=lifecycle state=up plus heartbeats every 2 min."
echo "If the daemon logged 'no ingest token', fall back to: printf '%s' TOKEN > /var/root/.axiom-ingest && chmod 600 /var/root/.axiom-ingest"
