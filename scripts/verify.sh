#!/usr/bin/env bash
set -uo pipefail

if [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m';    RED='\033[0;31m';  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi
say()      { printf "%b\n" "$*" >&2; }
info()     { say "${BLUE}[INFO]${NC}    $*"; }
ok_msg()   { say "${GREEN}[PASS]${NC}    $*"; }
fail_msg() { say "${RED}[FAIL]${NC}    $*"; }
skip_msg() { say "${YELLOW}[SKIP]${NC}    $*"; }

PASS=0; FAIL=0; SKIP=0; CHECKS_TOTAL=0
JSON=0; WITH_MCP=0; WITH_BROWSER=0; QUIET=0

for arg in "$@"; do
  case "$arg" in
    --with-mcp)     WITH_MCP=1 ;;
    --with-browser) WITH_BROWSER=1 ;;
    --json)         JSON=1 ;;
    --quiet)        QUIET=1 ;;
    *)              fail_msg "Unknown flag: $arg"; exit 1 ;;
  esac
done

[ "$QUIET" -eq 1 ] && exec 3>&1 >/dev/null 2>&1 && trap 'exec >&3 2>&1' EXIT

pass() { PASS=$((PASS+1)); CHECKS_TOTAL=$((CHECKS_TOTAL+1)); [ "$JSON" -eq 0 ] && ok_msg "$1"; return 0; }
fail() { FAIL=$((FAIL+1)); CHECKS_TOTAL=$((CHECKS_TOTAL+1)); [ "$JSON" -eq 0 ] && fail_msg "$1"; return 1; }
skip() { SKIP=$((SKIP+1)); CHECKS_TOTAL=$((CHECKS_TOTAL+1)); [ "$JSON" -eq 0 ] && skip_msg "$1"; return 0; }

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
IN_GIT=0
if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then IN_GIT=1; fi

say "${BOLD}${CYAN}=== Agent System Integrity Check ===${NC}"
say "${BLUE}Project: $PROJECT_ROOT${NC}"
say ""

check_files() {
  local MISSING=""
  for f in \
    ".ai/CONSTITUTION.md" \
    ".ai/task-scope.yaml" \
    ".ai/triggers.yaml" \
    ".ai/SCRIPTS.md" \
    "scripts/check-scope.js" \
    ".husky/pre-commit"; do
    if [ ! -f "$PROJECT_ROOT/$f" ]; then
      MISSING="$MISSING $f"
    fi
  done
  if [ -z "$MISSING" ]; then
    pass "All required files present"
  else
    fail "Missing files:$MISSING"
  fi
}

check_husky_installed() {
  if [ -d "$PROJECT_ROOT/.husky/_" ]; then
    pass "Husky installed (.husky/_/ exists)"
    return
  fi
  if [ -f "$PROJECT_ROOT/package.json" ]; then
    local PREPARE
    PREPARE="$(node -e "try{var p=require('$PROJECT_ROOT/package.json');console.log((p.scripts||{}).prepare||'')}catch(e){console.log('')}" 2>/dev/null || echo "")"
    if echo "$PREPARE" | grep -q "husky"; then
      pass "Husky configured via package.json scripts.prepare"
      return
    fi
  fi
  skip "Husky not yet installed (run scripts/setup.sh)"
}

check_hooks_exec() {
  if [ -x "$PROJECT_ROOT/.husky/pre-commit" ]; then
    pass "Husky pre-commit hook is executable"
  elif [ -f "$PROJECT_ROOT/.husky/pre-commit" ]; then
    fail "Husky pre-commit hook exists but is not executable"
  else
    skip "Husky pre-commit hook not found"
  fi
}

check_scope_syntax() {
  if [ ! -f "$PROJECT_ROOT/scripts/check-scope.js" ]; then
    skip "scripts/check-scope.js not found"
    return
  fi
  if node --check "$PROJECT_ROOT/scripts/check-scope.js" 2>/dev/null; then
    pass "check-scope.js passes syntax check"
  else
    fail "check-scope.js has syntax errors"
  fi
}

check_yaml_parse() {
  for yf in ".ai/task-scope.yaml" ".ai/triggers.yaml"; do
    if [ ! -f "$PROJECT_ROOT/$yf" ]; then
      skip "YAML check: $yf not found"
      continue
    fi
    local FULL="$PROJECT_ROOT/$yf"
    local NEEDS_TASKS=0
    case "$yf" in *task-scope.yaml) NEEDS_TASKS=1 ;; esac
    if NEEDS_TASKS=$NEEDS_TASKS YF="$FULL" node -e "
      var fs=require('fs');
      var content=fs.readFileSync(process.env.YF,'utf8');
      if (!content.match(/^version\s*:/m)) throw new Error('missing version');
      if (process.env.NEEDS_TASKS === '1' && !content.match(/^tasks\s*:/m)) throw new Error('missing tasks');
    " 2>/dev/null; then
      pass "YAML parse: $yf looks valid"
    else
      fail "YAML parse: $yf has structural issues"
    fi
  done
}

check_mcp() {
  if [ "$WITH_MCP" -eq 0 ]; then
    skip "MCP check disabled (use --with-mcp to enable)"
    return
  fi

  local MCP_FILE="${HOME}/.mcp.json"
  if [ ! -f "$MCP_FILE" ]; then
    fail "MCP config not found at ~/.mcp.json"
    return
  fi

  local ENTRIES
  ENTRIES="$(MCP_FILE="$MCP_FILE" node -e "
    var cfg=require(process.env.MCP_FILE);
    var names=['cl-opus','ds-pro','ds-flash','gpt-high','cl-qa'];
    var found=[];
    (cfg.mcpServers?Object.keys(cfg.mcpServers):[]).forEach(function(k){
      if(names.indexOf(k)>=0) found.push(k);
    });
    console.log(found.join(' '));
  " 2>/dev/null || echo "")"

  if [ -n "$ENTRIES" ]; then
    pass "MCP entries found: $ENTRIES"
  else
    fail "No expected MCP server entries found in ~/.mcp.json"
  fi

  for PORT in 18082 18083 18085; do
    local CODE
    CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT/health" 2>/dev/null || echo "unreachable")"
    if echo "$CODE" | grep -qE '^2[0-9][0-9]$'; then
      pass "MCP proxy port $PORT: reachable (HTTP $CODE)"
    else
      skip "MCP proxy port $PORT: $CODE (proxy may not be running)"
    fi
  done
}

check_browser() {
  if [ "$WITH_BROWSER" -eq 0 ]; then
    skip "Browser QA check disabled (use --with-browser to enable)"
    return
  fi
  if npx --yes puppeteer --version >/dev/null 2>&1; then
    pass "Puppeteer available for browser QA"
  else
    skip "Puppeteer not available"
  fi
}

check_branch_protection() {
  if [ -d "$PROJECT_ROOT/.github" ]; then
    if [ -f "$PROJECT_ROOT/.github/branch-protection.md" ]; then
      pass "Branch protection documentation found"
    else
      skip "No branch-protection.md in .github/"
    fi
  else
    skip "No .github/ directory"
  fi
}

check_precommit_path() {
  local HOOKS_PATH
  HOOKS_PATH="$(git -C "$PROJECT_ROOT" config core.hooksPath 2>/dev/null || echo "")"
  if [ "$HOOKS_PATH" = ".husky" ] || [ "$HOOKS_PATH" = "$PROJECT_ROOT/.husky" ]; then
    pass "Git core.hooksPath points to husky: $HOOKS_PATH"
  elif [ -d "$PROJECT_ROOT/.husky/_" ]; then
    pass "Husky appears properly initialised"
  elif [ -n "$HOOKS_PATH" ]; then
    skip "Git hooksPath is '$HOOKS_PATH' (expected .husky)"
  else
    skip "Git hooksPath not set"
  fi
}

check_no_secrets() {
  if [ "$IN_GIT" -eq 0 ]; then
    skip "No git repository — secrets check skipped"
    return
  fi
  local FILES
  # Exclude common doc/config files where placeholder examples live; keep code paths.
  FILES="$(git -C "$PROJECT_ROOT" ls-files 2>/dev/null | grep -Ev '\.(md|markdown|txt|rst|yaml|yml|json|html)$' || true)"
  if [ -z "$FILES" ]; then
    skip "No tracked source files — secrets check skipped"
    return
  fi
  local HITS=0
  if echo "$FILES" | (cd "$PROJECT_ROOT" && xargs grep -lE 'AKIA[0-9A-Z]{16}' 2>/dev/null) | grep -q .; then
    HITS=1
  fi
  if echo "$FILES" | (cd "$PROJECT_ROOT" && xargs grep -liE "secret_key[[:space:]]*=[[:space:]]*['\"]" 2>/dev/null) | grep -q .; then
    HITS=1
  fi
  if [ "$HITS" -eq 0 ]; then
    pass "No tracked secrets detected (best-effort scan)"
  else
    fail "Potential secrets found in tracked files — review immediately"
  fi
}

check_files
check_husky_installed
check_hooks_exec
check_scope_syntax
check_yaml_parse
check_mcp
check_browser
check_branch_protection
check_precommit_path
check_no_secrets

say ""
say "${BOLD}----------------------------------------${NC}"
say "${BOLD}Results:${NC} ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}  (total: $CHECKS_TOTAL)"

if [ "$JSON" -eq 1 ]; then
  printf '{"pass":%d,"fail":%d,"skip":%d,"total":%d}\n' "$PASS" "$FAIL" "$SKIP" "$CHECKS_TOTAL"
fi

if [ "$FAIL" -gt 0 ]; then
  say "${RED}${BOLD}Some checks failed.${NC}"
  exit 1
else
  say "${GREEN}${BOLD}All checks passed.${NC}"
  exit 0
fi
