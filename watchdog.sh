#!/bin/bash
#
# watchdog.sh — Claude Code + Telegram channel keepalive daemon
#
# Usage:
#   bash watchdog.sh              # foreground
#   bash watchdog.sh stop         # stop running instance
#   bash watchdog.sh status       # show status
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

# ── Config (all overridable via .env or environment) ─
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_FAILURES="${MAX_FAILURES:-5}"
RESTART_DELAY="${RESTART_DELAY:-10}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${LOG_DIR}/watchdog.log"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"
PIDFILE="${LOG_DIR}/watchdog.pid"

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
TELEGRAM_CHANNEL="${TELEGRAM_CHANNEL:-plugin:telegram@claude-plugins-official}"
TELEGRAM_ENV_FILE="${TELEGRAM_ENV_FILE:-$HOME/.claude/channels/telegram/.env}"

CLAUDE_CMD=(
  "$CLAUDE_BIN"
  --dangerously-skip-permissions
  --channels "$TELEGRAM_CHANNEL"
)

# Append extra flags if set
if [[ -n "${CLAUDE_EXTRA_FLAGS:-}" ]]; then
  read -ra _extra <<< "$CLAUDE_EXTRA_FLAGS"
  CLAUDE_CMD+=("${_extra[@]}")
fi

# Export proxy if configured
[[ -n "${HTTP_PROXY:-}" ]]  && export http_proxy="$HTTP_PROXY"
[[ -n "${HTTPS_PROXY:-}" ]] && export https_proxy="$HTTPS_PROXY"

# Export autocompact
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="${CLAUDE_AUTOCOMPACT_PCT:-50}"

# ── Utilities ────────────────────────────────────────
# After claude starts, QUIET=1 suppresses stdout so log output
# doesn't leak into claude's TUI prompt as fake user input.
QUIET=0
log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ "$QUIET" -eq 1 ]]; then
    echo "[$ts] $*" >> "$LOG_FILE"
  else
    echo "[$ts] $*" | tee -a "$LOG_FILE"
  fi
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    # macOS stat vs GNU stat
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$LOG_MAX_BYTES" ]]; then
      mv "$LOG_FILE" "${LOG_FILE}.1"
      log "Log rotated (>${LOG_MAX_BYTES} bytes)"
    fi
  fi
}

read_bot_token() {
  if [[ ! -f "$TELEGRAM_ENV_FILE" ]]; then
    log "ERROR: $TELEGRAM_ENV_FILE not found"
    return 1
  fi
  grep -E '^TELEGRAM_BOT_TOKEN=' "$TELEGRAM_ENV_FILE" | cut -d= -f2
}

# ── Mutex lock ───────────────────────────────────────
acquire_lock() {
  if [[ -f "$PIDFILE" ]]; then
    local old_pid
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "ERROR: another watchdog is already running (PID $old_pid)"
      echo "Run '$0 stop' to stop it, or delete $PIDFILE"
      exit 1
    fi
    log "WARN: stale pidfile (PID $old_pid gone), overwriting"
  fi
  echo $$ > "$PIDFILE"
}

release_lock() {
  rm -f "$PIDFILE"
}

# ── Process cleanup ──────────────────────────────────
kill_process_tree() {
  local pid="$1"
  local sig="${2:-TERM}"

  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do
    kill_process_tree "$child" "$sig"
  done

  kill "-${sig}" "$pid" 2>/dev/null || true
}

find_telegram_bun_pids() {
  pgrep -f "bun.*server\.ts" 2>/dev/null | while read -r pid; do
    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    if ps -o command= -p "$ppid" 2>/dev/null | grep -q "telegram"; then
      echo "$pid"
      echo "$ppid"
    elif [[ "$ppid" == "1" ]]; then
      if lsof -p "$pid" -Fn 2>/dev/null | grep -q "telegram"; then
        echo "$pid"
      fi
    fi
  done
}

kill_all_telegram_orphans() {
  local sig="${1:-9}"
  local pids
  pids=$(pgrep -f "channels.*${TELEGRAM_CHANNEL}" 2>/dev/null) || true
  local bun_pids
  bun_pids=$(find_telegram_bun_pids) || true
  pids=$(printf '%s\n%s' "$pids" "$bun_pids" | grep -v '^$' | sort -u)

  if [[ -n "$pids" ]]; then
    log "Found orphan processes: $pids"
    echo "$pids" | xargs kill "-${sig}" 2>/dev/null || true
  fi
  echo "$pids"
}

# Find orphaned telegram bun processes from OTHER Claude sessions
# These are bun server.ts processes whose parent Claude session has exited (PPID=1)
find_external_orphans() {
  # Orphaned bun server.ts processes
  pgrep -f "bun.*server\.ts" 2>/dev/null | while read -r pid; do
    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    [[ "$ppid" != "1" ]] && continue

    # Primary: lsof shows telegram-related open files
    if lsof -p "$pid" -Fn 2>/dev/null | grep -q "telegram"; then
      echo "$pid"
      continue
    fi

    # Fallback: CWD is under .claude/plugins/ (covers long-running orphans
    # whose file descriptors are closed and lsof no longer shows telegram)
    local cwd
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}')
    if [[ "$cwd" == *".claude/plugins/"* ]]; then
      echo "$pid"
      continue
    fi
  done

  # Orphaned "bun run --cwd ...telegram..." parent processes
  pgrep -f "bun run.*telegram.*start" 2>/dev/null | while read -r pid; do
    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    [[ "$ppid" != "1" ]] && continue
    echo "$pid"
  done

  # Fallback: orphaned "bun run --cwd .../.claude/plugins/..." processes
  # (version-mismatched or leaked plugin runners that don't mention "telegram")
  pgrep -f "bun run.*\.claude/plugins/" 2>/dev/null | while read -r pid; do
    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    [[ "$ppid" != "1" ]] && continue
    echo "$pid"
  done
}

# Periodically sweep orphaned telegram bun processes from other Claude sessions
sweep_external_orphans() {
  local orphans
  orphans=$(find_external_orphans | sort -u)
  if [[ -n "$orphans" ]]; then
    local count
    count=$(echo "$orphans" | wc -l | tr -d ' ')
    log "SWEEP: found ${count} external orphan(s), killing: $(echo $orphans | tr '\n' ' ')"
    echo "$orphans" | xargs kill -9 2>/dev/null || true
  fi
}

kill_claude_and_children() {
  local claude_pid="$1"

  log "Cleaning process tree (root PID: $claude_pid)..."

  kill_process_tree "$claude_pid" "TERM"
  sleep 3

  if kill -0 "$claude_pid" 2>/dev/null; then
    log "Tree not fully stopped, sending SIGKILL..."
    kill_process_tree "$claude_pid" "KILL"
    sleep 2
  fi

  kill_all_telegram_orphans 9
  sleep 1

  local remaining
  remaining=$(kill_all_telegram_orphans 9)
  if [[ -n "$remaining" ]]; then
    log "WARN: force-killed remaining: $remaining"
  fi

  log "Cleanup complete"
}

# ── Health check ─────────────────────────────────────
# True if $1 is a descendant of $2 in the process tree
is_descendant_of() {
  local pid="$1" ancestor="$2"
  local cur="$pid"
  local depth=0
  while [[ -n "$cur" && "$cur" != "1" && "$cur" != "$ancestor" && $depth -lt 20 ]]; do
    cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
  [[ "$cur" == "$ancestor" ]]
}

# True if a telegram MCP bun server.ts is running under claude_pid's tree
mcp_subprocess_alive() {
  local claude_pid="$1"
  local bun_pids
  bun_pids=$(pgrep -f "bun.*server\.ts" 2>/dev/null) || true
  for p in $bun_pids; do
    is_descendant_of "$p" "$claude_pid" && return 0
  done
  return 1
}

check_health() {
  local token="$1"
  local claude_pid="$2"

  # Check 1: claude process alive?
  if ! kill -0 "$claude_pid" 2>/dev/null; then
    log "HEALTH: Claude process (PID $claude_pid) is dead"
    return 2
  fi

  # Check 2: telegram channel process exists?
  if ! pgrep -f "channels.*${TELEGRAM_CHANNEL}" >/dev/null 2>&1; then
    log "HEALTH: Telegram channel process missing"
    return 2
  fi

  # Check 3: MCP bun server.ts alive under claude's tree
  # Covers the "MCP disconnected inside session" case that checks 1/2/4 all miss.
  if ! mcp_subprocess_alive "$claude_pid"; then
    log "HEALTH: MCP bun server.ts not found under claude tree (MCP disconnected)"
    return 1
  fi

  # Check 4: Bot API getMe
  local response http_code
  response=$(curl -s -m 15 -w "\n%{http_code}" "https://api.telegram.org/bot${token}/getMe" 2>&1) || true
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if echo "$body" | grep -q '"ok":true'; then
    return 0
  fi

  if [[ "$http_code" == "000" || "$http_code" == "" ]]; then
    log "HEALTH: getMe timeout (network/proxy issue)"
    return 1
  else
    log "HEALTH: getMe failed — HTTP $http_code: $body"
    return 1
  fi
}

# ── Subcommands ──────────────────────────────────────
cmd_stop() {
  if [[ ! -f "$PIDFILE" ]]; then
    echo "Watchdog not running (no pidfile)"
    exit 0
  fi
  local pid
  pid=$(cat "$PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    echo "Stopping watchdog (PID $pid)..."
    kill "$pid"
    sleep 3
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    kill_all_telegram_orphans 9 >/dev/null 2>&1
    echo "Stopped"
  else
    echo "Watchdog process (PID $pid) already gone, cleaning pidfile"
  fi
  rm -f "$PIDFILE"
}

cmd_status() {
  echo "=== Claude Telegram Watchdog Status ==="

  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid=$(cat "$PIDFILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Watchdog:  running (PID $pid)"
    else
      echo "Watchdog:  stopped (stale pidfile PID $pid)"
    fi
  else
    echo "Watchdog:  not running"
  fi

  local claude_pids
  claude_pids=$(pgrep -f "channels.*${TELEGRAM_CHANNEL}" 2>/dev/null) || true
  if [[ -n "$claude_pids" ]]; then
    echo "Claude:    running (PID $claude_pids)"
  else
    echo "Claude:    not running"
  fi

  local tg_count
  tg_count=$(pgrep -f "channels.*${TELEGRAM_CHANNEL}" 2>/dev/null | wc -l | tr -d ' ')
  echo "Processes: ${tg_count}"

  if [[ $tg_count -gt 0 ]]; then
    echo ""
    echo "Details:"
    ps -eo pid,%cpu,%mem,etime,command | grep "channels.*telegram" | grep -v grep || true
  fi

  if [[ -f "$LOG_FILE" ]]; then
    echo ""
    echo "Recent logs:"
    tail -5 "$LOG_FILE"
  fi
}

# ── Main loop ────────────────────────────────────────
main() {
  mkdir -p "$LOG_DIR"
  acquire_lock

  local token
  token=$(read_bot_token) || exit 1

  rotate_log

  log "=== Watchdog started (PID $$) ==="
  log "Work dir: $WORK_DIR"
  log "Channel:  $TELEGRAM_CHANNEL"
  log "Interval: ${CHECK_INTERVAL}s, max failures: $MAX_FAILURES"

  log "Cleaning stale processes..."
  kill_all_telegram_orphans 9
  sleep 1

  while true; do
    cd "$WORK_DIR"
    log "Starting Claude Code..."
    "${CLAUDE_CMD[@]}" &
    local claude_pid=$!
    log "Claude Code PID: $claude_pid"

    log "Waiting 20s for MCP server startup..."
    sleep 20
    # Suppress stdout so log output doesn't leak into claude's TUI as input
    QUIET=1

    if ! kill -0 "$claude_pid" 2>/dev/null; then
      log "ERROR: Claude Code failed to start"
      kill_claude_and_children "$claude_pid"
      log "Retrying in ${RESTART_DELAY}s..."
      sleep "$RESTART_DELAY"
      continue
    fi

    log "Claude Code started, entering health check loop"

    local failure_count=0
    local sweep_counter=0
    local SWEEP_INTERVAL=5  # sweep every 5 health checks (~5 min)

    while kill -0 "$claude_pid" 2>/dev/null; do
      sleep "$CHECK_INTERVAL"
      rotate_log

      # Periodically sweep orphaned telegram bun processes from other sessions
      sweep_counter=$((sweep_counter + 1))
      if [[ $((sweep_counter % SWEEP_INTERVAL)) -eq 0 ]]; then
        sweep_external_orphans
      fi

      local health_result=0
      check_health "$token" "$claude_pid" || health_result=$?

      if [[ $health_result -eq 0 ]]; then
        if [[ $failure_count -gt 0 ]]; then
          log "HEALTH: recovered (was failing for ${failure_count} checks)"
        fi
        failure_count=0
      elif [[ $health_result -eq 2 ]]; then
        failure_count=$MAX_FAILURES
        log "HEALTH: process dead, triggering immediate restart"
      else
        failure_count=$((failure_count + 1))
        log "HEALTH: consecutive failure ${failure_count}/${MAX_FAILURES}"
      fi

      if [[ $failure_count -ge $MAX_FAILURES ]]; then
        log "=== Restarting (${failure_count} consecutive failures) ==="
        kill_claude_and_children "$claude_pid"
        QUIET=0
        log "Restarting in ${RESTART_DELAY}s..."
        sleep "$RESTART_DELAY"
        token=$(read_bot_token) || { log "FATAL: cannot read bot token"; exit 1; }
        break
      fi
    done

    if [[ $failure_count -lt $MAX_FAILURES ]]; then
      local exit_code=0
      wait "$claude_pid" 2>/dev/null || exit_code=$?
      QUIET=0
      log "Claude Code exited (code: $exit_code)"
      kill_claude_and_children "$claude_pid"
      log "Restarting in ${RESTART_DELAY}s..."
      sleep "$RESTART_DELAY"
      token=$(read_bot_token) || { log "FATAL: cannot read bot token"; exit 1; }
    fi
  done
}

# ── Signal handling ──────────────────────────────────
cleanup() {
  log "=== Watchdog shutting down ==="

  local claude_pids
  claude_pids=$(pgrep -f "channels.*${TELEGRAM_CHANNEL}" 2>/dev/null) || true
  for pid in $claude_pids; do
    kill_process_tree "$pid" "TERM"
  done
  sleep 3

  kill_all_telegram_orphans 9

  for pid in $claude_pids; do
    kill_process_tree "$pid" "KILL"
  done

  release_lock
  log "=== Watchdog stopped ==="
  exit 0
}

trap cleanup SIGINT SIGTERM

# ── Entry ────────────────────────────────────────────
case "${1:-}" in
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)      main "$@" ;;
esac
