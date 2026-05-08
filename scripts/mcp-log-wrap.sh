#!/usr/bin/env bash
# mcp-log-wrap.sh — Lightweight stdio wrapper for MCP servers.
# Tees JSON-RPC traffic to a log file with timestamps and key redaction.
#
# Usage: mcp-log-wrap.sh <server-name> <cmd> [cmd-args...]
#
# Example .mcp.json entry (wrapping mcp-ds-pro.py):
#   {"command": "/Users/mac/.claude-template/scripts/mcp-log-wrap.sh",
#    "args": ["ds-pro", "python3", "/Users/mac/.claude/mcp-ds-pro.py"]}
#
# Env vars:
#   MCP_LOG_DIR      — log directory (default: $HOME/.claude/logs)
#   MCP_LOG_DISABLE  — if "1", logging is bypassed and the command is exec'd directly

set -uo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <server-name> <cmd> [cmd-args...]" >&2
    exit 1
fi

SERVER_NAME="$1"
shift

if [ "${MCP_LOG_DISABLE:-0}" = "1" ]; then
    exec "$@"
fi

LOG_DIR="${MCP_LOG_DIR:-$HOME/.claude/logs}"
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    exec "$@"
fi
LOG_FILE="$LOG_DIR/mcp-calls.log"

# rotate at 50MB (single rotation)
if [ -f "$LOG_FILE" ]; then
    log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$log_size" -gt 52428800 ] 2>/dev/null; then
        mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    fi
fi

# Write the python helper to a tmpfile so we can keep stdin available for the MCP.
PY_SCRIPT="$(mktemp -t mcp-log-wrap.XXXXXX.py)"
trap 'rm -f "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PYEOF'
import os, re, signal, subprocess, sys, threading
from datetime import datetime, timezone

server_name = sys.argv[1]
log_path    = sys.argv[2]
cmd_args    = sys.argv[3:]

REDACT = [
    (re.compile(rb'sk-[A-Za-z0-9_-]{20,}'), b'sk-***REDACTED***'),
    (re.compile(rb'AKIA[0-9A-Z]{16}'),       b'AKIA****REDACTED****'),
]
TRUNCATE = 2000

try:
    log_fd = open(log_path, 'ab', buffering=0)
except Exception:
    log_fd = None

def log_line(direction, payload):
    if log_fd is None:
        return
    try:
        for pat, repl in REDACT:
            payload = pat.sub(repl, payload)
        if len(payload) > TRUNCATE:
            payload = payload[:TRUNCATE] + b'...[truncated]'
        ts = datetime.now(timezone.utc).isoformat()
        line = f'{ts} [{server_name}] {direction} '.encode('utf-8') + payload + b'\n'
        log_fd.write(line)
    except Exception:
        pass

try:
    proc = subprocess.Popen(
        cmd_args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        bufsize=0,
    )
except FileNotFoundError as e:
    sys.stderr.write(f'mcp-log-wrap: command not found: {cmd_args[0]}: {e}\n')
    sys.exit(127)
except Exception as e:
    sys.stderr.write(f'mcp-log-wrap: spawn failed: {e}\n')
    sys.exit(1)

def forward_signal(signum, _frame):
    if proc.poll() is None:
        try:
            proc.send_signal(signum)
        except Exception:
            pass

signal.signal(signal.SIGINT, forward_signal)
signal.signal(signal.SIGTERM, forward_signal)

def pump(src, dst, direction):
    try:
        for line in iter(src.readline, b''):
            log_line(direction, line.rstrip(b'\n'))
            try:
                dst.write(line)
                dst.flush()
            except (BrokenPipeError, OSError):
                break
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass

t_in  = threading.Thread(target=pump, args=(sys.stdin.buffer,  proc.stdin,  '>>'), daemon=True)
t_out = threading.Thread(target=pump, args=(proc.stdout,       sys.stdout.buffer, '<<'), daemon=True)
t_in.start(); t_out.start()

try:
    rc = proc.wait()
except KeyboardInterrupt:
    proc.terminate()
    try: rc = proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill(); rc = proc.wait()

t_out.join(timeout=2)

if log_fd is not None:
    try: log_fd.close()
    except Exception: pass

sys.exit(rc)
PYEOF

exec python3 "$PY_SCRIPT" "$SERVER_NAME" "$LOG_FILE" "$@"
