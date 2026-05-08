#!/usr/bin/env bash
set -euo pipefail

# install.sh — install launchd plists for proxy auto-restart on macOS
# Flags: --uninstall, --status, --restart

if [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi
say()    { printf "%b\n" "$*" >&2; }
info()   { say "${BLUE}[INFO]${NC}  $*"; }
ok_msg() { say "${GREEN}[OK]${NC}    $*"; }
warn()   { say "${YELLOW}[WARN]${NC}  $*"; }
fail()   { say "${RED}[FAIL]${NC}  $*"; }

ACTION=install
for arg in "$@"; do
  case "$arg" in
    --uninstall) ACTION=uninstall ;;
    --status)    ACTION=status ;;
    --restart)   ACTION=restart ;;
    *) fail "unknown flag: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/.claude/logs"
PLISTS=(com.user.gpt55-proxy com.user.opus-proxy)

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ] && [ "$ACTION" = "install" ]; then
  fail "node not found in PATH; aborting."
  exit 1
fi

# Resolve OPENROUTER_API_KEY: env > ~/.claude/.env > prompt-on-install
load_api_key() {
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    return 0
  fi
  local envfile="$HOME/.claude/.env"
  if [ -f "$envfile" ]; then
    # shellcheck disable=SC1090
    OPENROUTER_API_KEY="$(grep -E '^OPENROUTER_API_KEY=' "$envfile" | head -n1 | cut -d= -f2- | sed 's/^["'\'']//;s/["'\'']$//')"
    if [ -n "$OPENROUTER_API_KEY" ]; then
      info "loaded OPENROUTER_API_KEY from $envfile"
      export OPENROUTER_API_KEY
      return 0
    fi
  fi
  return 1
}

mkdir -p "$LAUNCH_AGENTS" "$LOG_DIR"

uninstall_one() {
  local label="$1"
  local target="$LAUNCH_AGENTS/$label.plist"
  if [ -f "$target" ]; then
    launchctl unload "$target" 2>/dev/null || true
    rm -f "$target"
    ok_msg "uninstalled $label"
  else
    info "$label not installed"
  fi
}

install_one() {
  local label="$1"
  local src="$SCRIPT_DIR/$label.plist"
  local target="$LAUNCH_AGENTS/$label.plist"

  if [ ! -f "$src" ]; then
    fail "template plist missing: $src"
    return 1
  fi

  # detect proxy script referenced in the plist
  local proxy_path
  proxy_path="$(grep -A1 'ProgramArguments' "$src" | grep '<string>/Users' | grep -v '/node' | sed -E 's/.*<string>(.*)<\/string>.*/\1/' | head -n1)"
  if [ -n "$proxy_path" ] && [ ! -f "$proxy_path" ]; then
    warn "$label: proxy script $proxy_path not found — skipping install"
    return 0
  fi

  # warn on label collision (different label, same target script)
  if [ -n "$proxy_path" ]; then
    local collision
    collision="$(grep -lF "$proxy_path" "$LAUNCH_AGENTS"/*.plist 2>/dev/null | grep -v "$target" | head -n1 || true)"
    if [ -n "$collision" ]; then
      warn "$label: another plist already manages $proxy_path: $(basename "$collision")"
      warn "  installing both will cause port conflicts. Skipping. Run --uninstall on the other plist first."
      return 0
    fi
  fi

  # substitute /usr/local/bin/node with detected NODE_BIN, and inject API key
  local key_repl="${OPENROUTER_API_KEY:-__OPENROUTER_API_KEY__}"
  sed -e "s|<string>/usr/local/bin/node</string>|<string>$NODE_BIN</string>|" \
      -e "s|__OPENROUTER_API_KEY__|$key_repl|g" \
      "$src" > "$target"

  if [ "$key_repl" = "__OPENROUTER_API_KEY__" ]; then
    warn "$label: OPENROUTER_API_KEY not set — proxy will start but API calls will 401."
    warn "  Set env var or add OPENROUTER_API_KEY=... to ~/.claude/.env, then re-run."
  fi

  launchctl unload "$target" 2>/dev/null || true
  if launchctl load -w "$target" 2>/dev/null; then
    ok_msg "loaded $label (node=$NODE_BIN)"
  else
    fail "launchctl load failed for $label"
    return 1
  fi
}

case "$ACTION" in
  install)
    say "${BOLD}Installing launchd plists...${NC}"
    load_api_key || warn "OPENROUTER_API_KEY not found in env or ~/.claude/.env — placeholder will remain in plist."
    for label in "${PLISTS[@]}"; do install_one "$label"; done
    say ""
    say "${BOLD}Installed plists:${NC}"
    for label in "${PLISTS[@]}"; do
      if launchctl list | grep -q "$label"; then
        ok_msg "$label is loaded"
      fi
    done
    say ""
    say "Logs: $LOG_DIR"
    say "Useful commands:"
    say "  launchctl list | grep com.user"
    say "  launchctl unload $LAUNCH_AGENTS/<label>.plist"
    say "  $(basename "$0") --restart"
    ;;
  uninstall)
    say "${BOLD}Uninstalling launchd plists...${NC}"
    for label in "${PLISTS[@]}"; do uninstall_one "$label"; done
    ;;
  status)
    say "${BOLD}launchctl list (com.user.*):${NC}"
    launchctl list | grep com.user || info "no com.user.* services loaded"
    ;;
  restart)
    say "${BOLD}Restarting...${NC}"
    for label in "${PLISTS[@]}"; do
      target="$LAUNCH_AGENTS/$label.plist"
      [ -f "$target" ] || continue
      launchctl unload "$target" 2>/dev/null || true
      launchctl load -w "$target" && ok_msg "restarted $label"
    done
    ;;
esac
