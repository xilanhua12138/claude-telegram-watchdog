#!/bin/bash
#
# launchd-wrapper.sh — launchd -> tmux bridge
#
# Problem: Claude Code needs a PTY (tmux provides one),
# but launchd needs a foreground process to track lifecycle.
#
# Solution: create a tmux session, then block until it ends.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${TMUX_SESSION:-claude-telegram}"
WATCHDOG="$SCRIPT_DIR/watchdog.sh"

# If session already exists, watchdog is still running
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] tmux session '$SESSION' already exists, skipping"
  exit 0
fi

# Create detached tmux session running the watchdog
tmux new-session -d -s "$SESSION" "bash $WATCHDOG"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] tmux session '$SESSION' created"

# Block until session ends
while tmux has-session -t "$SESSION" 2>/dev/null; do
  sleep 10
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] tmux session '$SESSION' ended"
# Exit non-zero so launchd's KeepAlive.SuccessfulExit=false triggers restart
exit 1
