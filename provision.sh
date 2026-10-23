#!/usr/bin/env bash
# provision.sh — silo Mac Mini build script
#
# The only way the box gets built. Run ONCE as the local admin user,
# interactively, from a fresh macOS install that is already:
#   - signed into the silo Apple ID (no iCloud sync, Keychain off, Find My on)
#   - FileVault on, recovery key in the password manager
#   - joined to the guest Wi-Fi
#   - Little Snitch installed, licensed, and locked (see Hardening page)
#
#   curl -fsSL <RAW_URL> -o provision.sh && less provision.sh && bash provision.sh
#
# Contains no secrets. Everything that needs a password or a token stays manual
# and is listed at the end. Safe to rerun; every step checks before acting.

set -euo pipefail

# ---- pins -------------------------------------------------------------------
# Pin after the first successful run: `npm view @openai/codex version`, etc.
GUEST_SSID="Verizon_60E-Guest"
AGENT_USER="agent"
NVM_VERSION="v0.40.1"
NODE_VERSION="lts/*"
CODEX_VERSION="latest"          # pin to an exact version after first run
BLENDER_CASK="blender"          # brew cask; pins via `brew install blender@X.Y` if needed

# ---- helpers ----------------------------------------------------------------
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
as_agent() { sudo -u "$AGENT_USER" -H bash -lc "$*"; }

# ---- preflight --------------------------------------------------------------
say "Preflight"
[[ "$(id -u)" -ne 0 ]]                     || die "do not run as root; run as the admin user"
[[ "$(whoami)" != "$AGENT_USER" ]]         || die "do not run as $AGENT_USER"
id -Gn | grep -qw admin                    || die "current user is not an admin"
[[ "$(uname -s)" == "Darwin" ]]            || die "macOS only"

echo "Confirm this Mac is on Wi-Fi '$GUEST_SSID' (check the menu bar). Press Enter to continue, Ctrl-C to abort."
read -r
ssid="$GUEST_SSID"

say "Admin password (interactive — never stored by this script)"
sudo -v
# keep sudo alive while the script runs
( while true; do sudo -n true; sleep 50; kill -0 "$$" || exit; done 2>/dev/null ) &

# ---- Xcode CLT + Homebrew ---------------------------------------------------
say "Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install
  until xcode-select -p >/dev/null 2>&1; do sleep 15; done
fi
ok "CLT present"

say "Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
brew analytics off
ok "brew $(brew --version | head -1)"

say "Packages"
brew list git  >/dev/null 2>&1 || brew install git
brew list --cask "$BLENDER_CASK" >/dev/null 2>&1 || brew install --cask "$BLENDER_CASK"
ok "git, Blender"

# ---- macOS hardening --------------------------------------------------------
say "macOS hardening"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
sudo $FW --setglobalstate on >/dev/null
sudo $FW --setstealthmode on >/dev/null
sudo $FW --setallowsigned off >/dev/null
sudo $FW --setallowsignedapp off >/dev/null
ok "application firewall on, stealth on"

sudo launchctl disable system/com.apple.openssh 2>/dev/null || true
sudo launchctl disable system/com.apple.screensharing 2>/dev/null || true
sudo launchctl bootout system/com.apple.screensharing 2>/dev/null || true
ok "SSH and Screen Sharing off"

sudo defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true
sudo defaults write  /Library/Preferences/com.apple.loginwindow GuestEnabled -bool false
ok "auto-login off, guest login off"

sudo softwareupdate --schedule on >/dev/null
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool true
ok "automatic updates on"

defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0
ok "immediate lock on sleep/screensaver (admin)"

# ---- agent user -------------------------------------------------------------
say "Standard user: $AGENT_USER"
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  echo "Set a local password for $AGENT_USER (goes in the password manager, nowhere else):"
  sudo sysadminctl -addUser "$AGENT_USER" -fullName "$AGENT_USER" -password -
fi
# make sure it is NOT an admin, even if created by hand earlier
sudo dseditgroup -o edit -d "$AGENT_USER" -t user admin 2>/dev/null || true
id -Gn "$AGENT_USER" | grep -qw admin && die "$AGENT_USER is still in the admin group"
ok "$AGENT_USER exists and is Standard"

say "Agent tooling (installs into $AGENT_USER's home only)"
as_agent "
  set -euo pipefail
  export NVM_DIR=\"\$HOME/.nvm\"
  if [ ! -s \"\$NVM_DIR/nvm.sh\" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
  fi
  . \"\$NVM_DIR/nvm.sh\"
  nvm install $NODE_VERSION >/dev/null
  nvm alias default $NODE_VERSION >/dev/null
  npm config set ignore-scripts true
  npm config set fund false
  npm config set audit false
  npm install -g @openai/codex@$CODEX_VERSION >/dev/null
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
  defaults write com.apple.screensaver askForPassword -int 1
  defaults write com.apple.screensaver askForPasswordDelay -int 0
"
ok "nvm/node, npm ignore-scripts, codex, uv"

# ---- heartbeat (stub until the log sink exists) -----------------------------
say "Heartbeat LaunchDaemon (stub)"
sudo mkdir -p /usr/local/silo
sudo tee /usr/local/silo/heartbeat.sh >/dev/null <<'EOF'
#!/bin/bash
# Stub: appends a local heartbeat. Replace body with the sink shipper once the
# sink account and ingest token exist (token lives in the root Keychain, not here).
printf '%s heartbeat host=%s\n' "$(date -u +%FT%TZ)" "$(scutil --get ComputerName)" >> /var/log/silo-heartbeat.log
EOF
sudo chmod 755 /usr/local/silo/heartbeat.sh
sudo tee /Library/LaunchDaemons/local.silo.heartbeat.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.silo.heartbeat</string>
  <key>ProgramArguments</key><array><string>/usr/local/silo/heartbeat.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
sudo chown root:wheel /Library/LaunchDaemons/local.silo.heartbeat.plist
sudo chmod 644 /Library/LaunchDaemons/local.silo.heartbeat.plist
sudo launchctl bootout system/local.silo.heartbeat 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/local.silo.heartbeat.plist
ok "heartbeat every 5 min → /var/log/silo-heartbeat.log"

# ---- done -------------------------------------------------------------------
say "Done. Still manual (passwords/tokens never pass through this script):"
cat <<'EOF'
  [ ] Little Snitch: verify silent-deny, allowlist v1, rules locked, agent cannot edit
  [ ] Log out of admin. Log in as agent for everything below.
  [ ] agent: codex login  (browser OAuth, authenticator on phone; keyring store)
  [ ] agent: ssh-keygen -t ed25519 -C driaz-ops ; add pubkey to driaz-ops on GitHub (from main)
             git config --global gpg.format ssh ; git config --global commit.gpgsign true
  [ ] agent: inject Fal / TTS / sink tokens into Keychain when they exist (never as files)
  [ ] Replace heartbeat stub with the sink shipper once the sink account exists
  [ ] Drills: token, kill, transfer, rebuild (time it — target 30 min)
EOF
