# Delegate Task: <task>

Implement the requested task as a single bounded delegation.

## Task
<Detailed task description>

## Touchpoints
- **Files to touch**: <list files>
- **Files not to touch**: <list files>

## Constraints
- Follow existing repository patterns and conventions.
- Do not invent unrequested APIs or refactors.

## Invariant Rules
1. **Do not run shell commands.** In accept-edits mode a denied command aborts the entire run. The orchestrator runs all checks.
2. **Do not touch git.** No staging, no commits, no branches.
3. **Write nothing outside this repository**, and nothing in `.agy/` except your verdict file.

## Output Contract
When you are done, write one line — nothing else — to `.agy/runs/<run-id>/phases/DELEGATE/verdict`, and print that same line as the last line of your output, in the form `STATUS: <verdict> | File: <path>`. Use `STATUS: DONE` if you completed the task, `STATUS: BLOCKED` with the reason if you could not. Never write `.agy/runs/<run-id>/phases/DELEGATE/status` — that file belongs to the tooling.
