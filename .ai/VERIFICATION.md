# Verification Checklist

End-to-end verification for the multi-agent system.

## 1. Quick Smoke Test (5-minute confidence)

- [ ] Run `bash scripts/verify.sh` and confirm exit code 0
- [ ] Run `node scripts/check-scope.js --dry-run` on a clean working tree and confirm exit code 0 with no BLOCK messages
- [ ] Execute `git commit --allow-empty -m "test"` and observe pre-commit hook output without errors

## 2. Governance Layer

- [ ] File `.ai/CONSTITUTION.md` exists and contains current version/date
- [ ] File `.ai/task-scope.yaml` parses as valid YAML and contains at least one task entry under `tasks`
- [ ] File `.ai/triggers.yaml` parses as valid YAML without errors
- [ ] File `.ai/SCRIPTS.md` documents exactly the scripts present in `scripts/`

## 3. Pre-commit Hook

- [ ] Husky is installed: `.husky/_/husky.sh` exists
- [ ] `.husky/pre-commit` is executable (`ls -l` shows `-rwxr-xr-x`)
- [ ] Direct commit to `main` branch is blocked unless `ALLOW_MAIN_COMMIT=1` is set
- [ ] Staging a file containing a fake AWS access key (the literal string `AKIA` followed by 16 random uppercase alphanumerics) triggers a BLOCK
- [ ] Staging a file larger than 5 MB triggers a BLOCK unless `ALLOW_LARGE_FILES=1` is set
- [ ] Staging a file outside the current task's scope reports a BLOCK and aborts commit

## 4. GitHub CI

- [ ] Push to a feature branch triggers the workflow (visible in GitHub Actions)
- [ ] Required check `ci-success` appears in GitHub UI as passing after workflow completion
- [ ] Pull request targeting `main` shows `ci-success` as a required check and cannot merge while failing
- [ ] Branch protection rules on `main` are configured per `.github/branch-protection.md`

## 5. MCP Server Health

- [ ] File `~/.mcp.json` includes entries for `cl-opus`, `ds-pro`, `ds-flash`, `gpt-high`, and `cl-qa`
- [ ] From a Claude Code session, prompt `mcp__ds-flash__ask_ds_flash` with content "ping" — returns a response
- [ ] Same for `mcp__ds-pro__ask_ds_pro`, `mcp__gpt-high__ask_gpt_high`, `mcp__cl-opus__ask_cl_opus`
- [ ] Using `mcp__cl-qa__puppeteer_navigate` to `https://example.com` returns a result with title "Example Domain"

## 6. Production Hardening (Phase 8)

- [ ] Launchd plists are loaded: `launchctl list | grep -E '(gpt55-proxy|opus-proxy)'` shows entries with PID
- [ ] Killing the proxy process (`pkill -f gpt55-proxy.js`) — within 30 seconds `launchctl list` shows it relaunched with new PID
- [ ] MCP call log file exists at `~/.claude/logs/mcp-calls.log` and grows on use

## 7. Cross-Project Reuse

- [ ] In a fresh Git project, `bash /Users/mac/.claude-template/scripts/setup.sh` populates `.ai/`, `.husky/`, `scripts/`, `.github/`
- [ ] Modify a file inside `forbidden_paths` of a task — `node scripts/check-scope.js` reports BLOCK
- [ ] Switch task via `git config --local claude.taskId feat-add-component` — scope changes, previously-OK files become BLOCKED

## 8. Failure Modes

- [ ] With gpt-high proxy stopped: `mcp__gpt-high__ask_gpt_high` returns informative error within timeout (no hang)
- [ ] Malformed `.ai/task-scope.yaml`: `check-scope.js` reports the error line and exits 2
- [ ] Network outage: `cl-opus` (direct API) and DS proxies fail with clear error messages, no hangs

## 9. Sign-Off

- Date verified: ____
- Verified by: ____
- System version (`git rev-parse HEAD` or release tag): ____
- Notes / discrepancies: ____
