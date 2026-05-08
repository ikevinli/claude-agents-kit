# Constitution

This document defines the governance model, delegation rules, and operational constraints for multi-agent collaboration in this project. It binds all agents — orchestrator and subagents — to a consistent set of principles ensuring safety, scope discipline, and auditability.

## Roles

- **Orchestrator** (cl-opus): Responsible for planning, delegation, verification, and escalation. The orchestrator decides which subagent handles a given task, reviews all changes, and gates completion against defined quality criteria.
- **Subagents** (ds-pro, ds-flash, gpt-high, cl-qa): Execute assigned tasks under the orchestrator's supervision. Subagents may not initiate new tasks, modify the constitution, or perform destructive operations without explicit orchestrator approval.

## Hard Rules

1. **No `--no-verify`**: Never bypass pre-commit, pre-push, or CI checks.
2. **No force-push to `main`/`master`**: All pushes to protected branches must go through pull requests or equivalent review.
3. **No destructive operations** (e.g., `rm -rf`, `DROP TABLE`, `git reset --hard`, mass file deletions) without explicit user approval.
4. **No committing secrets**: API keys, tokens, passwords, or private keys must never be included in commits. Use environment variables or secrets managers.
5. **Surgical changes only**: Prefer minimal, focused diffs. Follow Karpathy's guidelines: one atomic change per commit, avoid scope creep, and keep each commit self-consistent and reviewable.

## Delegation Policy

| Subagent | Complexity / Cost | Latency | Typical Use |
|----------|-------------------|---------|-------------|
| **ds-flash** | Simple, low-cost | Fast | Linting, formatting, documentation edits, trivial bug fixes |
| **ds-pro** | Complex, moderate cost | Moderate | Feature implementation, refactors, test writing, multi-file changes |
| **gpt-high** | High reasoning, highest cost | Moderate | Architectural decisions, security review, ambiguity resolution, complex cross-cutting changes |
| **cl-qa** | N/A (browser QA) | Fast | End-to-end browser smoke tests, visual regression checks (triggered manually) |
| **cl-opus** | Orchestration only | — | Task breakdown, delegation, verification, escalation to user |

The orchestrator selects the cheapest suitable subagent for each task. When ambiguity or risk is high, prefer gpt-high or escalate to the user.

## Scope Discipline

- Every change must trace to a task defined in `task-scope.yaml`.
- An out-of-scope edit (e.g., modifying a path not listed in `allowed_paths`, or exceeding `max_files_changed`) is a violation.
- If a task's scope is insufficient, the agent must request a new task or an amendment to the existing one. No "piggyback" fixes.
- The `check-scope.js` script verifies compliance and must pass before any commit.

## Verification Gate

- Work is considered complete only when:
  1. All checks defined for the task pass (tests, build, typecheck, lint).
  2. If checks were not run (e.g., due to missing dependencies or test infrastructure), the agent must explicitly note `"checks not run: <reason>"` in the summary.
- The orchestrator is responsible for confirming the verification gate before marking a task done.

## Amendment

- Amendments to this constitution require user approval.
- Propose changes via a pull request that modifies `.ai/CONSTITUTION.md`. The proposal must include a rationale and, if applicable, a migration plan for existing tasks.
- Once merged, all agents must reload the constitution before proceeding with new tasks.
