#!/usr/bin/env bash
set -euo pipefail

# helpers
if [ -z "${NO_COLOR:-}" ]; then
  BOLD='\033[1m';    RED='\033[0;31m';  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'
  NC='\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi
say()      { printf "%b\n" "$*" >&2; }
info()     { say "${BLUE}[INFO]${NC}    $*"; }
success()  { say "${GREEN}[OK]${NC}      $*"; }
warn()     { say "${YELLOW}[WARN]${NC}    $*"; }
fail()     { say "${RED}[FAIL]${NC}    $*"; }
step()     { say "${BOLD}${CYAN}[STEP]${NC}   $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

FORCE=0
NO_HUSKY=0
NO_GITHUB=0
QUIET=0
INIT_GIT=0
EXIT_CODE=0

for arg in "$@"; do
  case "$arg" in
    --force)     FORCE=1 ;;
    --no-husky)  NO_HUSKY=1 ;;
    --no-github) NO_GITHUB=1 ;;
    --quiet)     QUIET=1 ;;
    --init-git)  INIT_GIT=1 ;;
    *)           fail "Unknown flag: $arg"; exit 1 ;;
  esac
done

# don't install into the template itself
if [ "$(cd "$PROJECT_ROOT" && pwd)" = "$(cd "$TEMPLATE_DIR" && pwd)" ]; then
  info "This is the template directory, not a project — exiting."
  exit 0
fi

if [ "$QUIET" -eq 1 ]; then
  exec 3>&1 >/dev/null 2>&1
  trap 'exec >&3 2>&1' EXIT
fi

say "${BOLD}${CYAN}=== Claude Agent Template Setup ===${NC}"
info "Template: $TEMPLATE_DIR"
info "Target:   $PROJECT_ROOT"

# step 1: node version
step "1/7  Checking Node.js version..."
if ! command -v node >/dev/null 2>&1; then
  fail "Node.js is not installed. Requires Node 20+."
  exit 1
fi
NODE_MAJOR="$(node --version | sed 's/v//' | cut -d. -f1)"
if [ "$NODE_MAJOR" -lt 20 ]; then
  fail "Node $NODE_MAJOR detected, but Node 20+ is required."
  exit 1
fi
success "Node.js $NODE_MAJOR detected."

# step 2: git repo
step "2/7  Checking git repository..."
IN_GIT=0
if git rev-parse --git-dir >/dev/null 2>&1; then
  IN_GIT=1
  success "Git repository detected."
else
  warn "Not inside a git repository."
  if [ "$INIT_GIT" -eq 1 ]; then
    info "Initialising git repository..."
    git init "$PROJECT_ROOT"
    IN_GIT=1
    success "Git repository initialised."
  elif [ "$QUIET" -eq 0 ]; then
    warn "Run with --init-git to initialise one automatically, or run 'git init' manually."
  fi
fi

# step 3: detect existing
step "3/7  Checking for existing agent files..."
EXISTING=""
for dir in .ai scripts .husky .github; do
  if [ -d "$PROJECT_ROOT/$dir" ]; then
    EXISTING="$EXISTING $dir"
  fi
done
if [ -n "$EXISTING" ]; then
  warn "Existing directories detected:$EXISTING"
  if [ "$FORCE" -eq 1 ]; then
    info "--force supplied: will overwrite existing files."
  else
    warn "Use --force to overwrite, or remove them manually. Skipping copy."
    EXIT_CODE=2
    step "No files copied. Exiting."
    exit "$EXIT_CODE"
  fi
fi

# step 4: copy template files
step "4/7  Copying template files..."
COPY_DIRS=".ai scripts .husky"
if [ "$NO_GITHUB" -eq 0 ]; then
  COPY_DIRS="$COPY_DIRS .github"
fi
if [ "$NO_HUSKY" -eq 1 ]; then
  COPY_DIRS="$(echo "$COPY_DIRS" | sed 's/\.husky//g')"
fi
for dir in $COPY_DIRS; do
  SRC="$TEMPLATE_DIR/$dir"
  DST="$PROJECT_ROOT/$dir"
  if [ ! -d "$SRC" ]; then
    warn "Source directory $SRC not found, skipping."
    continue
  fi
  mkdir -p "$DST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$SRC/" "$DST/" 2>/dev/null || cp -R "$SRC/." "$DST/"
  else
    cp -R "$SRC/." "$DST/"
  fi
  success "Copied $dir/"
done

# step 5: package.json + husky
step "5/7  Setting up package.json and husky..."
cd "$PROJECT_ROOT"
if [ ! -f "$PROJECT_ROOT/package.json" ]; then
  if [ "$QUIET" -eq 1 ]; then
    info "No package.json found, skipping husky installation."
    NO_HUSKY=1
  else
    warn "No package.json found."
    read -r -p "Create a minimal package.json? [y/N] " ANSWER
    if [ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ]; then
      npm init -y >/dev/null 2>&1
      success "Created package.json."
    else
      info "Skipping package.json creation. Husky will be skipped."
      NO_HUSKY=1
    fi
  fi
fi

if [ -f "$PROJECT_ROOT/package.json" ] && [ "$NO_HUSKY" -eq 0 ]; then
  info "Installing husky..."
  npm pkg set scripts.prepare="husky" 2>/dev/null || true
  npm install --save-dev husky >/dev/null 2>&1 || {
    warn "Husky install failed — continuing without hooks."
    NO_HUSKY=1
    EXIT_CODE=2
  }
  if command -v npx >/dev/null 2>&1 && [ "$NO_HUSKY" -eq 0 ]; then
    npx husky >/dev/null 2>&1 || {
      warn "npx husky init failed — hooks may not fire."
      EXIT_CODE=2
    }
  fi
  success "Husky configured."
elif [ "$NO_HUSKY" -eq 1 ]; then
  info "Husky skipped (--no-husky or no package.json)."
fi

# step 6: chmod
step "6/7  Setting executable permissions..."
for file in scripts/*.sh; do
  [ -f "$file" ] && chmod +x "$file" && info "  +x $file"
done
if [ -f ".husky/pre-commit" ]; then
  chmod +x .husky/pre-commit && info "  +x .husky/pre-commit"
fi
success "Permissions set."

# step 7: stage files
step "7/7  Staging files in git..."
if [ "$IN_GIT" -eq 1 ]; then
  for dir in .ai scripts .husky; do
    if [ -d "$PROJECT_ROOT/$dir" ]; then
      git -C "$PROJECT_ROOT" add "$dir" 2>/dev/null || true
      info "  git add $dir"
    fi
  done
  if [ "$NO_GITHUB" -eq 0 ] && [ -d "$PROJECT_ROOT/.github" ]; then
    git -C "$PROJECT_ROOT" add .github 2>/dev/null || true
    info "  git add .github"
  fi
  success "Files staged (not committed)."
else
  info "No git repo — skipping git add."
fi

# summary
say ""
say "${BOLD}${GREEN}=== Setup complete ===${NC}"
say "Files installed to: $PROJECT_ROOT"
say ""
say "${BOLD}Next steps:${NC}"
say "  1. Edit ${CYAN}.ai/task-scope.yaml${NC} with your project tasks"
say "  2. Review ${CYAN}.ai/CONSTITUTION.md${NC} for agent rules"
say "  3. Review ${CYAN}.ai/triggers.yaml${NC} for automation triggers"
say "  4. Run ${CYAN}scripts/verify.sh${NC} to validate the setup"
say "  5. Commit: ${CYAN}git commit -m 'chore: add agent governance'${NC}"
say ""

exit "$EXIT_CODE"
