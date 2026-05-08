# Scripts Index

`scripts/` directory contains automation helpers invoked by triggers or directly.
All scripts must adhere to the conventions below.

## Conventions

- `$PROJECT_ROOT` defaults to `$(git rev-parse --show-toplevel)`; scripts should resolve relative paths from there.
- Exit codes:
  - `0` – Success / OK
  - `1` – Warning (non-blocking issue detected)
  - `2` – Error (blocking failure)
- Scripts must be idempotent and safe to run multiple times.
- Output should be human-readable; include a `--quiet` flag for CI use where appropriate.

## Scripts

### `setup.sh`

**Purpose**: Initialise project prerequisites (copy template files, install husky, set executable bits).
**Usage**: `bash scripts/setup.sh [--force] [--no-husky] [--no-github] [--quiet] [--init-git]`
**Exit codes**:
- `0`: Setup completed successfully.
- `1`: Error – critical dependency missing, abort.
- `2`: Partial – some steps were skipped intentionally.

### `verify.sh`

**Purpose**: Run constitution-level checks: file presence, husky install, scope-check syntax, YAML parse, MCP reachability, secrets scan.
**Usage**: `bash scripts/verify.sh [--with-mcp] [--with-browser] [--json] [--quiet]`
**Exit codes**:
- `0`: All checks pass.
- `1`: Failure – one or more checks failed.

### `check-scope.js`

**Purpose**: Read `task-scope.yaml` and verify that all staged files fall within the current task's `allowed_paths` and do not touch `forbidden_paths`. Also enforce `max_files_changed`.
**Usage**: `node scripts/check-scope.js [--task TASK_ID] [--dry-run]`
- Resolves task id from `--task` flag, then `CLAUDE_TASK_ID` env var, then `git config --local claude.taskId`, defaulting to `default`.
- `--dry-run` checks files in `HEAD~1..HEAD` instead of staged.

**Exit codes**:
- `0`: Scope compliant.
- `1`: Warnings only (e.g., requires_review, downgraded violations).
- `2`: Scope violation (blocking).
