#!/bin/bash
# denials.sh — sink v3: ship Little Snitch DENIED connections to Axiom.
# Runs as root via launchd (com.silo.denials) every 60 s.
# Reads traffic history since the last cursor, keeps rows with denied_new > 0, posts NDJSON.
#
# log-traffic CSV columns (observed 2026-10-29):
#  1 timestamp(UTC Z) 2 direction 3 uid 4 ip 5 hostname 6 proto 7 port
#  8 allowed_new 9 denied_new 10 bytes_in 11 bytes_out 12 "process" 13 "parent"
# -b/-e take LOCAL time; row timestamps are UTC.

set -u

LS="/Applications/Little Snitch.app/Contents/Components/littlesnitch"
DIR=/usr/local/silo
CURSOR=$DIR/denials.cursor
LOG=$DIR/denials.log
DATASET=silo
TOKEN_SERVICE=silo   # <-- set to the SAME keychain service name axiom-sink.sh uses

now=$(date "+%Y-%m-%d %H:%M:%S")
if [ -s "$CURSOR" ]; then
  from=$(cat "$CURSOR")
else
  from=$(date -v-5M "+%Y-%m-%d %H:%M:%S")
fi

token=$(security find-generic-password -s "$TOKEN_SERVICE" -w /Library/Keychains/System.keychain 2>/dev/null) || {
  echo "$now token missing (service=$TOKEN_SERVICE)" >> "$LOG"; exit 1; }

rows=$("$LS" log-traffic -b "$from" -e "$now" 2>>"$LOG" | awk -F',' '($9+0) > 0')

if [ -z "$rows" ]; then
  echo "$now" > "$CURSOR"
  exit 0
fi

body=$(printf '%s\n' "$rows" | awk -F',' '{
  p=$12; q=$13; gsub(/"/,"",p); gsub(/"/,"",q);
  printf "{\"_time\":\"%s\",\"kind\":\"denial\",\"direction\":\"%s\",\"uid\":%d,\"ip\":\"%s\",\"host\":\"%s\",\"proto\":%d,\"port\":%d,\"denied\":%d,\"process\":\"%s\",\"parent\":\"%s\"}\n",
  $1,$2,$3,$4,$5,$6,$7,$9,p,q }')

code=$(printf '%s' "$body" | curl -s -o /dev/null -w '%{http_code}' -m 20 \
  -X POST "https://api.axiom.co/v1/datasets/$DATASET/ingest" \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @-)
curl_exit=$?

n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
if [ "$code" = "200" ]; then
  echo "$now" > "$CURSOR"
  echo "$now shipped $n denial rows" >> "$LOG"
else
  # cursor NOT advanced — rows are retried next run
  echo "$now ingest failed http=$code curl_exit=$curl_exit rows=$n" >> "$LOG"
  exit 1
fi
