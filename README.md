# Claude Telegram Watchdog

Keepalive daemon for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) + [Telegram channel plugin](https://github.com/anthropics/claude-code/tree/main/packages/claude-code-plugins).

Monitors the Claude Code process and Telegram Bot API health, automatically restarts on failure, and cleans up orphan processes. Includes an **orphan sweeper** that periodically kills leaked bun processes from any Claude Code plugin. Optionally runs as a macOS launchd service for boot-time auto-start.

## How it works

```
launchd (boot) ──> launchd-wrapper.sh ──> tmux session ──> watchdog.sh ──> claude --channels telegram
                                                              │
                                                              ├─ health check every 60s
                                                              │   ├─ process alive?
                                                              │   ├─ channel process exists?
                                                              │   └─ Bot API getMe OK?
                                                              │
                                                              └─ 5 consecutive failures → full restart
                                                                  (kill process tree + orphan cleanup)
```

## Quick start

```bash
git clone https://github.com/MizzenAI/claude-telegram-watchdog.git
cd claude-telegram-watchdog

# 1. Configure
cp .env.example .env
# Edit .env — set WORK_DIR at minimum

# 2. One-command start (recommended)
bash start.sh                 # start watchdog in tmux + sweep orphans
bash start.sh status          # check status
bash start.sh stop            # stop everything
bash start.sh restart         # restart

# 3. Or run in foreground (good for debugging)
bash watchdog.sh

# 4. Or install as launchd service (auto-start on boot)
bash install.sh
```

## Prerequisites

- macOS (launchd integration is macOS-specific; the watchdog itself runs on any Unix)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Telegram channel plugin configured (`~/.claude/channels/telegram/.env` with `TELEGRAM_BOT_TOKEN`)
- `tmux` installed (`brew install tmux`)

## Usage

### Watchdog

```bash
bash watchdog.sh              # run in foreground
bash watchdog.sh status       # show status
bash watchdog.sh stop         # stop running instance
```

### Orphan sweeper

Scans for leaked bun processes from **all** Claude Code plugins (not just telegram) and kills them. Runs automatically via launchd every 120 seconds after `install.sh`.

```bash
bash orphan-sweeper.sh              # single sweep (kill orphans)
bash orphan-sweeper.sh status       # show orphans without killing
bash orphan-sweeper.sh dry-run      # report what would be killed
```

### launchd (auto-start on login)

```bash
bash install.sh               # install & load
bash install.sh uninstall     # unload & remove
```

### tmux session

```bash
tmux attach -t claude-telegram    # attach to the running session
# Ctrl+B, D to detach
```

## Configuration

Copy `.env.example` to `.env`. Only `WORK_DIR` is required — everything else has sensible defaults.

| Variable | Default | Description |
|----------|---------|-------------|
| `WORK_DIR` | script directory | Directory where Claude Code runs |
| `HTTP_PROXY` / `HTTPS_PROXY` | *(none)* | Proxy for network requests |
| `CLAUDE_BIN` | auto-detected | Path to `claude` binary |
| `TELEGRAM_CHANNEL` | `plugin:telegram@claude-plugins-official` | Channel spec for `--channels` |
| `TELEGRAM_ENV_FILE` | `~/.claude/channels/telegram/.env` | File containing `TELEGRAM_BOT_TOKEN` |
| `CLAUDE_AUTOCOMPACT_PCT` | `50` | Context autocompact threshold |
| `CLAUDE_EXTRA_FLAGS` | *(none)* | Extra flags appended to claude command |
| `CHECK_INTERVAL` | `60` | Health check interval (seconds) |
| `MAX_FAILURES` | `5` | Consecutive failures before restart |
| `RESTART_DELAY` | `10` | Delay between restarts (seconds) |
| `LOG_DIR` | `./logs` | Log file directory |
| `LOG_MAX_BYTES` | `5242880` (5MB) | Log rotation threshold |
| `TMUX_SESSION` | `claude-telegram` | tmux session name |

## Files

```
├── start.sh             # One-command start/stop/restart/status
├── watchdog.sh          # Core daemon — health check + restart loop
├── orphan-sweeper.sh    # Periodic cleanup of orphan bun processes from all plugins
├── launchd-wrapper.sh   # launchd → tmux bridge (blocks until session ends)
├── install.sh           # Install/uninstall launchd services (watchdog + sweeper)
├── .env.example         # Configuration template
└── logs/                # Runtime logs (gitignored)
    ├── watchdog.log
    ├── orphan-sweeper.log
    └── launchd.log
```

## Troubleshooting

**Watchdog starts but Claude exits immediately**
- Check `logs/watchdog.log` for error messages
- Verify `claude` is authenticated: run `claude` manually first
- Verify the Telegram plugin is configured: check `~/.claude/channels/telegram/.env`

**Health check always fails (network)**
- If behind a proxy, set `HTTP_PROXY` / `HTTPS_PROXY` in `.env`
- Test manually: `curl https://api.telegram.org/bot<TOKEN>/getMe`

**Orphan bun processes eating CPU**
- `bash watchdog.sh stop` kills them automatically
- Or manually: `pkill -f "bun.*server.ts"`

## License

MIT
