#!/bin/bash
#
# install.sh — Install launchd service for auto-start on macOS
#
# Usage:
#   bash install.sh           # install & load
#   bash install.sh uninstall # unload & remove
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.claude.telegram-watchdog"
SWEEPER_LABEL="com.claude.orphan-sweeper"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SWEEPER_PLIST="$HOME/Library/LaunchAgents/${SWEEPER_LABEL}.plist"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
SWEEPER_INTERVAL="${SWEEPER_INTERVAL:-120}"

cmd_install() {
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BASH_BIN}</string>
        <string>${SCRIPT_DIR}/launchd-wrapper.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launchd.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.bun/bin:${HOME}/.local/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
    </dict>
</dict>
</plist>
EOF

  echo "Installed: $PLIST"

  # ── Orphan sweeper plist ──
  cat > "$SWEEPER_PLIST" <<SEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SWEEPER_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${BASH_BIN}</string>
        <string>${SCRIPT_DIR}/orphan-sweeper.sh</string>
        <string>once</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>

    <key>StartInterval</key>
    <integer>${SWEEPER_INTERVAL}</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/orphan-sweeper-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/orphan-sweeper-launchd.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.bun/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
</dict>
</plist>
SEOF

  echo "Installed: $SWEEPER_PLIST"

  # Load both agents
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"

  launchctl bootout "gui/$(id -u)/${SWEEPER_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$SWEEPER_PLIST"

  echo "Loaded. Watchdog + orphan sweeper will start automatically."
  echo ""
  echo "Manage with:"
  echo "  bash watchdog.sh status              # watchdog status"
  echo "  bash orphan-sweeper.sh status        # orphan sweeper status"
  echo "  launchctl kickstart gui/$(id -u)/${LABEL}  # force start watchdog"
  echo "  bash install.sh uninstall            # remove all"
}

cmd_uninstall() {
  # Stop watchdog first
  bash "$SCRIPT_DIR/watchdog.sh" stop 2>/dev/null || true

  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/${SWEEPER_LABEL}" 2>/dev/null || true

  for f in "$PLIST" "$SWEEPER_PLIST"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "Removed: $f"
    fi
  done

  echo "Uninstalled."
}

case "${1:-}" in
  uninstall) cmd_uninstall ;;
  *)         cmd_install ;;
esac
