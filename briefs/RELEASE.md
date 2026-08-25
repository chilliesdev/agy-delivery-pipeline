# Phase 4b: Release Preparation

Prepare release documentation and release plan for the completed task.

## Criteria
Read and follow `.agy/runs/<run-id>/criteria/release.md` alongside release facts in `.agy/runs/<run-id>/RELEASE_FACTS.md`.

## Invariant Rules
1. **Do not run shell commands.**
2. **Do not touch git.** Never run git commit, git tag, git merge, or git push commands. All irreversible git actions are reserved for humans.
3. **Write nothing outside this repository.**

## Output Contract
1. Write the prepared release plan and staged command instructions to `.agy/runs/<run-id>/RELEASE_PLAN.md`.
2. Write your one-line verdict — `STATUS: DONE | File: .agy/runs/<run-id>/RELEASE_PLAN.md` or `STATUS: BLOCKED | File: .agy/runs/<run-id>/RELEASE_PLAN.md` — to `.agy/runs/<run-id>/phases/RELEASE/verdict`, and print that same line as the last line of your output in the form `STATUS: <verdict> | File: <path>`. Do not write `.agy/runs/<run-id>/phases/RELEASE/status`.
