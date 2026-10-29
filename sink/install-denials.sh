#!/bin/bash
# install-denials.sh — sink v3 installer. Run on the box as admin:
#   sudo bash install-denials.sh
# Little Snitch must be in Alert mode with the Network Monitor open (install rule of Oct 25).
set -e
RAW=https://raw.githubusercontent.com/driaz/Mini-Provision/main/sink

mkdir -p /usr/local/silo
curl -fsSL "$RAW/denials.sh" -o /usr/local/silo/denials.sh
curl -fsSL "$RAW/com.silo.denials.plist" -o /Library/LaunchDaemons/com.silo.denials.plist

chown root:wheel /usr/local/silo/denials.sh /Library/LaunchDaemons/com.silo.denials.plist
chmod 755 /usr/local/silo/denials.sh
chmod 644 /Library/LaunchDaemons/com.silo.denials.plist

launchctl bootout system/com.silo.denials 2>/dev/null || true
sleep 2
launchctl bootstrap system /Library/LaunchDaemons/com.silo.denials.plist

echo "first run:"
/usr/local/silo/denials.sh || true
tail -n 3 /usr/local/silo/denials.log 2>/dev/null || echo "(no log yet — no denials in the last 5 min is normal)"
