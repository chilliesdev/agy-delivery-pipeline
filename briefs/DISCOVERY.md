# Phase 0: Discovery — <task>

Find out what completing and testing this task requires before modifying code.

## Goal
<Describe the discovery goal and task in 1-2 sentences>

## Scope of Investigation
- **Test command**: How this project is tested (framework, test runner command, where tests live).
- **Codebase touchpoints**: Files and modules involved in this task, and existing pattern files worth following.
- **Prerequisites**: Dependencies, services, migrations, fixtures, or environment variables needed.
- **Credentials & Permissions**: Any required API keys or approvals (names only, never secrets).
- **Blockers**: Anything that prevents implementation from starting.

## Invariant Rules
1. **Do not run shell commands.** Report the test runner command; do not execute it.
2. **Do not touch git.** No commits, no staging, no branches.
3. **Do not modify source code.** The only files you write are `<run-dir>/DISCOVERY.md`, `<run-dir>/TEST_COMMAND`, and `<run-dir>/phases/DISCOVERY/verdict`.
4. **Write nothing outside this repository.**

## Output Contract
1. Write the bare test command (single line, no markdown, no quotes) to `.agy/runs/<run-id>/TEST_COMMAND`.
2. Write full discovery findings to `.agy/runs/<run-id>/DISCOVERY.md`.
3. Write your one-line verdict — `STATUS: READY | File: .agy/runs/<run-id>/DISCOVERY.md` or `STATUS: BLOCKED | File: .agy/runs/<run-id>/DISCOVERY.md` — to `.agy/runs/<run-id>/phases/DISCOVERY/verdict`, and print that same line as the last line of your output in the form `STATUS: <verdict> | File: <path>`. Do not write `.agy/runs/<run-id>/phases/DISCOVERY/status`.
