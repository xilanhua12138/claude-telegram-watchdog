#!/bin/bash
#
# orphan-sweeper.sh — Kill orphaned bun processes from Claude Code plugins
#
# Problem: Each Claude Code session spawns MCP server child processes (bun server.ts, etc).
#          When a session exits abnormally, these children become orphans (PPID=1) and eat CPU.
#          The watchdog only cleans up telegram-related orphans; other plugins are missed.
#
# Solution: Scan all PPID=1 bun processes, check if they belong to .claude/plugins/,
#           verify they're not owned by any active Claude session, then kill them.
#
# Usage:
#   bash orphan-sweeper.sh              # single sweep
#   bash orphan-sweeper.sh status       # report without killing
#   bash orphan-sweeper.sh dry-run      # report what would be killed
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ────────────────────────────────────────
load_env() {
  local env_file="${DOTENV_FILE:-$SCRIPT_DIR/.env}"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}
load_env

# ── Config ───────────────────────────────────────────
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${LOG_DIR}/orphan-sweeper.log"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"  # 2MB
DRY_RUN=false

# ── Utilities ────────────────────────────────────────
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" >> "$LOG_FILE"
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$LOG_MAX_BYTES" ]]; then
      mv "$LOG_FILE" "${LOG_FILE}.1"
      log "Log rotated (>${LOG_MAX_BYTES} bytes)"
    fi
  fi
}

# Get cwd of a single process (precise extraction)
get_cwd() {
  local pid=$1
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}'
}

# Get all active claude process PIDs
get_active_claude_pids() {
  pgrep -f "claude" 2>/dev/null | sort -u
}

# Check if a process is owned by an active claude session (walk PPID chain)
is_owned_by_claude() {
  local pid=$1
  local claude_pids=$2
  local current=$pid
  local depth=0

  while (( current > 1 && depth < 20 )); do
    local ppid
    ppid=$(ps -p "$current" -o ppid= 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" ]] && return 1
    if echo "$claude_pids" | grep -qw "$ppid"; then
      return 0
    fi
    current=$ppid
    (( depth++ ))
  done
  return 1
}

# Check if a bun process belongs to a Claude plugin
is_claude_plugin_bun() {
  local pid=$1
  local args
  args=$(ps -p "$pid" -o args= 2>/dev/null)

  # Command line contains .claude/ path
  if [[ "$args" == *".claude/"* ]]; then
    return 0
  fi

  # CWD is under .claude/
  local cwd
  cwd=$(get_cwd "$pid")
  if [[ "$cwd" == *".claude/"* ]]; then
    return 0
  fi

  return 1
}

# ── Core: find orphan bun processes ──────────────────
find_orphan_buns() {
  local claude_pids
  claude_pids=$(get_active_claude_pids)

  # Match only actual bun executables (exclude powerd.bundle etc.)
  local bun_pids
  bun_pids=$(ps -eo pid,comm= 2>/dev/null | awk '$2 ~ /^(bun|\/.*\/bun)$/' | awk '{print $1}')

  [[ -z "$bun_pids" ]] && return

  echo "$bun_pids" | while read -r pid; do
    [[ -z "$pid" ]] && continue

    local ppid
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" ]] && continue

    # Case 1: direct orphan (PPID=1) from a claude plugin
    if [[ "$ppid" == "1" ]]; then
      if is_claude_plugin_bun "$pid"; then
        local args cwd
        args=$(ps -p "$pid" -o args= 2>/dev/null)
        cwd=$(get_cwd "$pid")
        echo "$pid|orphan|${cwd:-unknown}|$args"
      fi
      continue
    fi

    # Case 2: child of an orphan bun (grandparent PPID=1)
    local grandppid
    grandppid=$(ps -p "$ppid" -o ppid= 2>/dev/null | tr -d ' ')
    if [[ "$grandppid" == "1" ]]; then
      local parent_comm
      parent_comm=$(ps -p "$ppid" -o comm= 2>/dev/null)
      if [[ "$parent_comm" == *"bun"* ]]; then
        if ! is_owned_by_claude "$pid" "$claude_pids"; then
          if is_claude_plugin_bun "$pid" || is_claude_plugin_bun "$ppid"; then
            local args cwd
            args=$(ps -p "$pid" -o args= 2>/dev/null)
            cwd=$(get_cwd "$pid")
            echo "$pid|child-orphan|${cwd:-unknown}|$args"
            # Also output the parent
            local parent_args parent_cwd
            parent_args=$(ps -p "$ppid" -o args= 2>/dev/null)
            parent_cwd=$(get_cwd "$ppid")
            echo "$ppid|parent-orphan|${parent_cwd:-unknown}|$parent_args"
          fi
        fi
      fi
    fi
  done | sort -u
}

# ── Sweep ────────────────────────────────────────────
sweep() {
  local orphans
  orphans=$(find_orphan_buns)

  [[ -z "$orphans" ]] && return 0

  local count
  count=$(echo "$orphans" | wc -l | tr -d ' ')

  if $DRY_RUN; then
    log "DRY-RUN: found ${count} orphan bun process(es):"
    echo "$orphans" | while IFS='|' read -r pid type cwd args; do
      log "  PID=$pid type=$type cmd=${args:0:80}"
      echo "  PID=$pid type=$type cwd=$cwd cmd=${args:0:80}"
    done
    return 0
  fi

  log "SWEEP: found ${count} orphan bun process(es), killing"
  echo "$orphans" | while IFS='|' read -r pid type cwd args; do
    log "  KILL PID=$pid type=$type cmd=${args:0:80}"
    kill -9 "$pid" 2>/dev/null || true
  done

  sleep 1
  log "SWEEP: done, cleaned ${count} orphan(s)"
}

# ── Status ───────────────────────────────────────────
cmd_status() {
  echo "=== Claude Plugin Orphan Sweeper ==="
  echo ""

  local orphans
  orphans=$(find_orphan_buns)

  if [[ -z "$orphans" ]]; then
    echo "No orphan bun processes found."
  else
    local count
    count=$(echo "$orphans" | wc -l | tr -d ' ')
    echo "Found ${count} orphan bun process(es):"
    echo ""
    printf "%-8s %-15s %-50s %s\n" "PID" "TYPE" "CWD" "CMD"
    printf "%-8s %-15s %-50s %s\n" "---" "----" "---" "---"
    echo "$orphans" | while IFS='|' read -r pid type cwd args; do
      printf "%-8s %-15s %-50s %s\n" "$pid" "$type" "${cwd:0:50}" "${args:0:60}"
    done
  fi

  echo ""
  echo "=== Active claude processes ==="
  ps -eo pid,ppid,pcpu,comm 2>/dev/null | grep claude | grep -v grep || echo "  (none)"
  echo ""
  echo "=== All bun processes ==="
  ps -eo pid,ppid,pcpu,comm 2>/dev/null | grep bun | grep -v grep | grep -v bundle || echo "  (none)"
}

# ── Entry ────────────────────────────────────────────
mkdir -p "$LOG_DIR"
rotate_log

case "${1:-once}" in
  once)
    sweep
    ;;
  status)
    cmd_status
    ;;
  dry-run|dryrun)
    DRY_RUN=true
    sweep
    ;;
  *)
    echo "Usage: $0 {once|status|dry-run}"
    exit 1
    ;;
esac
