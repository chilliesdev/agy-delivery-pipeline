# Phase 1: Implementation — <task>

Implement the requested feature or fix according to the acceptance criteria and discovery findings.

## Goal
<Goal in one sentence>

## Touchpoints
- **Files to create or modify**: <list files>
- **Files not to touch**: <list files>
- **Pattern file to imitate**: <pattern file path>

## Acceptance Criteria
- <Acceptance criteria stated as behaviour, not commands>

## Invariant Rules
1. **Do not run shell commands.** The orchestrator runs all test and verification commands.
2. **Do not touch git.** Do not commit; leave all changes in the working tree.
3. **Write nothing outside this repository**, and nothing in `.agy/` except `<run-dir>/CHANGES.md` and your verdict file.

## Output Contract
1. Write a concise summary of changes to `.agy/runs/<run-id>/CHANGES.md`.
2. Write your one-line verdict — `STATUS: DONE | File: .agy/runs/<run-id>/CHANGES.md` or `STATUS: BLOCKED | File: .agy/runs/<run-id>/CHANGES.md` — to `.agy/runs/<run-id>/phases/IMPLEMENT/verdict`, and print that same line as the last line of your output in the form `STATUS: <verdict> | File: <path>`. Do not write `.agy/runs/<run-id>/phases/IMPLEMENT/status`.
