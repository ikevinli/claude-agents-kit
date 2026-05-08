#!/usr/bin/env node

// check-scope.js — Phase 4 scope enforcement.
// Reads .ai/task-scope.yaml, checks staged files against task scope.
// Exit codes: 0 (clean), 1 (warnings), 2 (blocks).
// No external dependencies.

'use strict';

const { execFileSync } = require('child_process');
const { readFileSync, statSync } = require('fs');
const { resolve } = require('path');

// ---------------------------------------------------------------------------
// Minimal YAML parser — flat keys, nested mappings, lists, scalars.
// No anchors, aliases, multiline strings.
// ---------------------------------------------------------------------------

function promoteToList(frame) {
    // Convert an empty-object placeholder into an array (lazy YAML promotion).
    if (frame._mayBeList && !Array.isArray(frame.obj) && Object.keys(frame.obj).length === 0) {
        const arr = [];
        if (frame._parent !== undefined && frame._key !== undefined) {
            frame._parent[frame._key] = arr;
        }
        frame.obj = arr;
        frame._mayBeList = false;
    }
}

function parseYaml(text, filepath) {
    const lines = text.split(/\r?\n/);
    const root = {};
    const stack = [{ obj: root, indent: -1 }];
    let lineNo = 0;

    for (const rawLine of lines) {
        lineNo++;
        const line = rawLine.replace(/[ \t]*#.*$/, '');
        if (/^\s*$/.test(line)) continue;

        const listMatch = line.match(/^(\s*)-\s+(.*)$/);
        const kvMatch = line.match(/^(\s*)([^-\s][^:]*?)\s*:\s*(.*)$/);

        if (listMatch && !listMatch[2].match(/^[^:]+?\s*:\s/)) {
            // Pure list item: "- value"
            const indent = listMatch[1].length;
            const value = parseScalar(listMatch[2].trim());
            while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop();
            promoteToList(stack[stack.length - 1]);
            const parent = stack[stack.length - 1].obj;
            if (!Array.isArray(parent)) {
                throw new Error(`${filepath}:${lineNo}: expected list parent for '-' item`);
            }
            parent.push(value);
            continue;
        }

        if (listMatch) {
            // List item with mapping: "- id: foo"
            const indent = listMatch[1].length;
            const inner = listMatch[2];
            const innerKv = inner.match(/^([^:]+?)\s*:\s*(.*)$/);
            if (!innerKv) {
                throw new Error(`${filepath}:${lineNo}: malformed list-mapping item`);
            }
            while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop();
            promoteToList(stack[stack.length - 1]);
            const parent = stack[stack.length - 1].obj;
            if (!Array.isArray(parent)) {
                throw new Error(`${filepath}:${lineNo}: expected list parent for '- key:' item`);
            }
            const newObj = {};
            parent.push(newObj);
            stack.push({ obj: newObj, indent });
            const key = innerKv[1].trim();
            const rawVal = innerKv[2].trim();
            assignKey(newObj, key, rawVal, indent + 2, stack, filepath, lineNo);
            continue;
        }

        if (kvMatch) {
            const indent = kvMatch[1].length;
            const key = kvMatch[2].trim();
            const rawVal = kvMatch[3].trim();
            while (stack.length > 1 && stack[stack.length - 1].indent >= indent) stack.pop();
            const parent = stack[stack.length - 1].obj;
            if (Array.isArray(parent)) {
                throw new Error(`${filepath}:${lineNo}: cannot put bare key inside list`);
            }
            assignKey(parent, key, rawVal, indent, stack, filepath, lineNo);
            continue;
        }

        if (line.trim()) {
            throw new Error(`${filepath}:${lineNo}: unparseable line: ${rawLine.trim()}`);
        }
    }

    return root;
}

function assignKey(parent, key, rawVal, indent, stack, filepath, lineNo) {
    if (rawVal === '') {
        // Could be mapping or list — decide on next line. Default to object;
        // if a '-' item appears at deeper indent, replace with array.
        const placeholder = {};
        parent[key] = placeholder;
        stack.push({ obj: placeholder, indent, _key: key, _parent: parent });
        // Mark for possible list promotion
        stack[stack.length - 1]._mayBeList = true;
        return;
    }
    if (rawVal.startsWith('[') && rawVal.endsWith(']')) {
        const inner = rawVal.slice(1, -1);
        const items = inner ? inner.split(',').map(s => parseScalar(s.trim().replace(/^["']|["']$/g, ''))) : [];
        parent[key] = items;
        return;
    }
    parent[key] = parseScalar(rawVal);
}

// Promote object→array on first '-' encounter
const _origPush = Array.prototype.push;

function parseScalar(raw) {
    if (raw === '' || raw == null) return null;
    if ((raw.startsWith('"') && raw.endsWith('"')) || (raw.startsWith("'") && raw.endsWith("'"))) {
        return raw.slice(1, -1);
    }
    if (/^(true|True|TRUE|yes)$/.test(raw)) return true;
    if (/^(false|False|FALSE|no)$/.test(raw)) return false;
    if (raw === 'null' || raw === '~' || raw === 'NULL') return null;
    if (/^-?\d+$/.test(raw)) return parseInt(raw, 10);
    if (/^-?\d+\.\d+$/.test(raw)) return parseFloat(raw);
    return raw;
}

// Post-process: walk the tree and convert any { } that has only numeric-keyed
// list items into arrays. (Our parser handles this via stack frames already.)

// ---------------------------------------------------------------------------
// Glob → regex (supports *, **, ?)
// ---------------------------------------------------------------------------

function globToRegex(pattern) {
    let regex = '';
    let i = 0;
    while (i < pattern.length) {
        const ch = pattern[i];
        if (ch === '*') {
            if (pattern[i + 1] === '*') {
                if (pattern[i + 2] === '/') {
                    regex += '(?:.*/)?';
                    i += 3;
                    continue;
                }
                regex += '.*';
                i += 2;
                continue;
            }
            regex += '[^/]*';
            i++;
        } else if (ch === '?') {
            regex += '[^/]';
            i++;
        } else if ('.+^$()|[]{}\\'.includes(ch)) {
            regex += '\\' + ch;
            i++;
        } else {
            regex += ch;
            i++;
        }
    }
    return new RegExp('^' + regex + '$');
}

function matchesAnyGlob(filepath, patterns) {
    if (!patterns || patterns.length === 0) return false;
    const normalized = filepath.replace(/\\/g, '/');
    for (const pattern of patterns) {
        try {
            if (globToRegex(pattern).test(normalized)) return true;
        } catch (_) { /* skip bad pattern */ }
    }
    return false;
}

// ---------------------------------------------------------------------------
// TTY + colors
// ---------------------------------------------------------------------------

const isTTY = process.stdout.isTTY;
const C = {
    reset: isTTY ? '\x1b[0m' : '',
    red: isTTY ? '\x1b[31m' : '',
    green: isTTY ? '\x1b[32m' : '',
    yellow: isTTY ? '\x1b[33m' : '',
    bold: isTTY ? '\x1b[1m' : '',
    dim: isTTY ? '\x1b[2m' : '',
};
const fmt = (s, c) => C[c] + s + C.reset;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
    const args = process.argv.slice(2);
    const dryRun = args.includes('--dry-run');
    let taskOverride = null;
    const taskIdx = args.indexOf('--task');
    if (taskIdx !== -1 && taskIdx + 1 < args.length) taskOverride = args[taskIdx + 1];

    let projectRoot;
    try {
        projectRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], {
            encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
        }).trim();
    } catch (_) {
        process.stderr.write(fmt('[scope-check] fatal: not inside a git repository.\n', 'red'));
        process.exit(1);
    }

    let taskId = taskOverride || process.env.CLAUDE_TASK_ID || '';
    if (!taskId) {
        try {
            taskId = execFileSync('git', ['config', '--local', 'claude.taskId'], {
                encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
            }).trim();
        } catch (_) { taskId = ''; }
    }
    if (!taskId) taskId = 'default';

    const scopeFile = resolve(projectRoot, '.ai', 'task-scope.yaml');
    try { statSync(scopeFile); } catch (_) {
        process.stderr.write(fmt(`[scope-check] error: ${scopeFile} not found.\n`, 'red'));
        process.exit(2);
    }

    let scopeConfig;
    try {
        scopeConfig = parseYaml(readFileSync(scopeFile, 'utf8'), scopeFile);
    } catch (err) {
        process.stderr.write(fmt(`[scope-check] error: ${err.message}\n`, 'red'));
        process.exit(2);
    }

    const enforce = !(scopeConfig.scope_check && scopeConfig.scope_check.enforce === false);
    const blockOnViolation = !(scopeConfig.scope_check && scopeConfig.scope_check.block_on_violation === false);

    if (!enforce) {
        process.stdout.write(fmt('[scope-check] enforce=false — skipping.\n', 'dim'));
        process.exit(0);
    }

    // Find task entry
    let taskEntry = null;
    const tasks = Array.isArray(scopeConfig.tasks) ? scopeConfig.tasks : [];
    for (const t of tasks) {
        if (t && t.id === taskId) { taskEntry = t; break; }
    }

    const scope = taskEntry || scopeConfig.default_scope || {};
    const allowedPaths = scope.allowed_paths || ['**/*'];
    const forbiddenPaths = scope.forbidden_paths || [];
    const maxFilesChanged = typeof scope.max_files_changed === 'number' ? scope.max_files_changed : Infinity;
    const requiresReview = scope.requires_review === true;

    let files;
    try {
        const diffArgs = dryRun
            ? ['diff', '--name-only', 'HEAD~1', 'HEAD']
            : ['diff', '--cached', '--name-only', '--diff-filter=ACMR'];
        const out = execFileSync('git', diffArgs, {
            encoding: 'utf8', cwd: projectRoot, stdio: ['ignore', 'pipe', 'pipe'],
        }).trim();
        files = out ? out.split('\n').filter(Boolean) : [];
    } catch (err) {
        process.stderr.write(fmt(`[scope-check] error: git diff failed: ${err.message}\n`, 'red'));
        process.exit(2);
    }

    if (files.length === 0) {
        process.stdout.write(fmt('[scope-check] no files to check.\n', 'dim'));
        process.exit(0);
    }

    const results = [];
    let hasBlock = false, hasWarn = false;

    for (const f of files) {
        if (matchesAnyGlob(f, forbiddenPaths)) {
            if (blockOnViolation) { results.push({ file: f, status: 'BLOCK', reason: 'matches forbidden_paths' }); hasBlock = true; }
            else { results.push({ file: f, status: 'WARN', reason: 'matches forbidden_paths (not blocking)' }); hasWarn = true; }
            continue;
        }
        if (!matchesAnyGlob(f, allowedPaths)) {
            if (blockOnViolation) { results.push({ file: f, status: 'BLOCK', reason: 'not in allowed_paths' }); hasBlock = true; }
            else { results.push({ file: f, status: 'WARN', reason: 'not in allowed_paths (not blocking)' }); hasWarn = true; }
            continue;
        }
        results.push({ file: f, status: 'OK', reason: 'allowed' });
    }

    if (files.length > maxFilesChanged) {
        const msg = `${files.length} files changed, max=${maxFilesChanged}`;
        if (blockOnViolation) { results.unshift({ file: '[scope-limit]', status: 'BLOCK', reason: msg }); hasBlock = true; }
        else { results.unshift({ file: '[scope-limit]', status: 'WARN', reason: msg }); hasWarn = true; }
    }

    if (requiresReview) {
        results.unshift({ file: '[review-flag]', status: 'WARN', reason: 'task requires_review=true' });
        hasWarn = true;
    }

    const header = dryRun ? '[scope-check] dry-run report' : '[scope-check] pre-commit report';
    process.stdout.write(fmt(`\n${header} — task: ${taskId}\n`, 'bold'));
    process.stdout.write(fmt('-'.repeat(72) + '\n', 'dim'));

    for (const r of results) {
        const color = r.status === 'OK' ? 'green' : r.status === 'WARN' ? 'yellow' : 'red';
        process.stdout.write(`  ${fmt(r.status.padEnd(5), color)} ${r.file}`);
        if (r.reason) process.stdout.write(fmt(`  (${r.reason})`, 'dim'));
        process.stdout.write('\n');
    }

    process.stdout.write(fmt('-'.repeat(72) + '\n', 'dim'));
    const summaryColor = hasBlock ? 'red' : hasWarn ? 'yellow' : 'green';
    const summary = hasBlock ? 'BLOCKED' : hasWarn ? 'WARNINGS' : 'OK';
    process.stdout.write(fmt(`  Summary: ${summary}  |  Files: ${files.length}  |  Task: ${taskId}\n\n`, summaryColor));

    process.exit(hasBlock ? 2 : hasWarn ? 1 : 0);
}

main();
