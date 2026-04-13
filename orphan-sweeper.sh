#!/bin/bash
#
# orphan-sweeper.sh — Kill stale bun processes from Claude Code plugins
#
# Two kinds of staleness are handled:
#
#   1. ORPHANS — PPID=1 bun processes (or their direct children) whose parent
#      Claude session is gone. These leak after abnormal session exits.
#
#   2. VERSION MISMATCH — bun processes pinned to a plugin version (via
#      `--cwd .../cache/<marketplace>/<plugin>/<version>`) that no longer
#      matches the installed version in installed_plugins.json. These
#      happen after `claude plugin update`: old bun keeps running under a
#      live shell, new sessions launch the new version, and both end up
#      polling the same external API (e.g. Telegram bot token → 409 Conflict).
#      Version-aware cleanup catches this case even when the process has
#      a live parent (so plain orphan detection would miss it).
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
INSTALLED_PLUGINS_JSON="${INSTALLED_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}"
# Set SKIP_VERSION_CHECK=1 to disable the version-mismatch sweep
SKIP_VERSION_CHECK="${SKIP_VERSION_CHECK:-0}"
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

  # Fallback: orphan bun server.ts with no recoverable CWD info
  # bun server.ts is the MCP server entrypoint for Claude plugins;
  # if PPID=1 and we can't confirm otherwise, treat as plugin process.
  local ppid
  ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  if [[ "$ppid" == "1" ]] && [[ "$args" == *"bun server.ts"* || "$args" == *"/bun server.ts"* ]]; then
    return 0
  fi

  return 1
}

# ── Version-mismatch detection ───────────────────────
# Map plugin cache path → currently installed version, emitted as
# "<marketplace>/<plugin> <version>" lines. Returns empty if the
# manifest is missing/unreadable or python3 is unavailable.
read_installed_plugin_versions() {
  [[ -f "$INSTALLED_PLUGINS_JSON" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$INSTALLED_PLUGINS_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

for key, entries in (data.get("plugins") or {}).items():
    # key format: "<plugin-name>@<marketplace>"
    if "@" not in key:
        continue
    plugin, marketplace = key.split("@", 1)
    for entry in entries or []:
        version = entry.get("version")
        if not version or version == "unknown":
            continue
        print(f"{marketplace}/{plugin} {version}")
PY
}

# Extract marketplace, plugin name, and version from a bun command line
# that pins a plugin via `--cwd .../cache/<marketplace>/<plugin>/<version>`.
# Emits "marketplace|plugin|version" or nothing.
extract_plugin_version() {
  local args=$1
  # Use `#` as sed delimiter so `|` can be used as field separator
  # shellcheck disable=SC2001
  echo "$args" | sed -n 's#.*\.claude/plugins/cache/\([^/]*\)/\([^/]*\)/\([^/ ]*\).*#\1|\2|\3#p'
}

# Find bun processes whose pinned plugin version differs from the currently
# installed version. Outputs "pid|stale-version|cwd|args" for each stale proc.
find_stale_version_buns() {
  [[ "$SKIP_VERSION_CHECK" == "1" ]] && return 0

  local installed
  installed=$(read_installed_plugin_versions)
  [[ -z "$installed" ]] && return 0

  # Match only actual bun executables
  local bun_pids
  bun_pids=$(ps -eo pid,comm= 2>/dev/null | awk '$2 ~ /^(bun|\/.*\/bun)$/' | awk '{print $1}')
  [[ -z "$bun_pids" ]] && return 0

  echo "$bun_pids" | while read -r pid; do
    [[ -z "$pid" ]] && continue
    local args
    args=$(ps -p "$pid" -o args= 2>/dev/null)
    [[ -z "$args" ]] && continue

    local triple
    triple=$(extract_plugin_version "$args")
    [[ -z "$triple" ]] && continue

    local marketplace plugin proc_version
    IFS='|' read -r marketplace plugin proc_version <<< "$triple"
    [[ -z "$marketplace" || -z "$plugin" || -z "$proc_version" ]] && continue

    local installed_version
    installed_version=$(echo "$installed" \
      | awk -v k="${marketplace}/${plugin}" '$1==k {print $2; exit}')
    [[ -z "$installed_version" ]] && continue

    if [[ "$proc_version" != "$installed_version" ]]; then
      local cwd
      cwd=$(get_cwd "$pid")
      echo "$pid|stale-version:${marketplace}/${plugin}@${proc_version}→${installed_version}|${cwd:-unknown}|$args"
    fi
  done | sort -u
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
  local orphans stale
  orphans=$(find_orphan_buns)
  stale=$(find_stale_version_buns)

  # Merge both sources, dedupe by PID (first field), preserve order of input
  local combined
  combined=$(printf '%s\n%s\n' "$orphans" "$stale" \
    | awk -F'\\|' 'NF>=2 && !seen[$1]++')

  [[ -z "$combined" ]] && return 0

  local count
  count=$(echo "$combined" | wc -l | tr -d ' ')

  if $DRY_RUN; then
    log "DRY-RUN: found ${count} stale bun process(es):"
    echo "$combined" | while IFS='|' read -r pid type cwd args; do
      log "  PID=$pid type=$type cmd=${args:0:80}"
      echo "  PID=$pid type=$type cwd=$cwd cmd=${args:0:80}"
    done
    return 0
  fi

  log "SWEEP: found ${count} stale bun process(es), killing"
  echo "$combined" | while IFS='|' read -r pid type cwd args; do
    log "  KILL PID=$pid type=$type cmd=${args:0:80}"
    kill -9 "$pid" 2>/dev/null || true
  done

  sleep 1
  log "SWEEP: done, cleaned ${count} process(es)"
}

# ── Status ───────────────────────────────────────────
cmd_status() {
  echo "=== Claude Plugin Orphan Sweeper ==="
  echo ""

  local orphans stale combined
  orphans=$(find_orphan_buns)
  stale=$(find_stale_version_buns)
  combined=$(printf '%s\n%s\n' "$orphans" "$stale" \
    | awk -F'\\|' 'NF>=2 && !seen[$1]++')

  if [[ -z "$combined" ]]; then
    echo "No stale bun processes found."
  else
    local count
    count=$(echo "$combined" | wc -l | tr -d ' ')
    echo "Found ${count} stale bun process(es):"
    echo ""
    printf "%-8s %-40s %-50s %s\n" "PID" "TYPE" "CWD" "CMD"
    printf "%-8s %-40s %-50s %s\n" "---" "----" "---" "---"
    echo "$combined" | while IFS='|' read -r pid type cwd args; do
      printf "%-8s %-40s %-50s %s\n" "$pid" "${type:0:40}" "${cwd:0:50}" "${args:0:60}"
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
