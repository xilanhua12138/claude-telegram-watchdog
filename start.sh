#!/bin/bash
#
# start.sh — Quick start/stop for watchdog + orphan sweeper
#
# Usage:
#   bash start.sh              # start watchdog in tmux + sweep orphans
#   bash start.sh stop         # stop everything
#   bash start.sh status       # show status
#   bash start.sh restart      # stop then start
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${TMUX_SESSION:-claude-telegram}"

cmd_start() {
  # Sweep orphans first
  echo "Sweeping orphan processes..."
  bash "$SCRIPT_DIR/orphan-sweeper.sh" once

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Already running (tmux session '$SESSION' exists)"
    echo "  tmux attach -t $SESSION    # attach"
    echo "  bash $0 stop               # stop"
    exit 0
  fi

  tmux new-session -d -s "$SESSION" "bash $SCRIPT_DIR/watchdog.sh"
  echo "Started watchdog in tmux session '$SESSION'"
  echo ""
  echo "Commands:"
  echo "  tmux attach -t $SESSION        # attach to session"
  echo "  bash $0 status                 # check status"
  echo "  bash $0 stop                   # stop everything"
}

cmd_stop() {
  echo "Stopping watchdog..."
  bash "$SCRIPT_DIR/watchdog.sh" stop 2>/dev/null || true

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    echo "Killed tmux session '$SESSION'"
  fi

  echo "Sweeping remaining orphans..."
  bash "$SCRIPT_DIR/orphan-sweeper.sh" once
  echo "Stopped."
}

cmd_status() {
  bash "$SCRIPT_DIR/watchdog.sh" status
  echo ""
  bash "$SCRIPT_DIR/orphan-sweeper.sh" status
}

case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 2; cmd_start ;;
  status)  cmd_status ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
