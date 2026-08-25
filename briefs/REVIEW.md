# Phase 2: Code Review

Review the captured diff against project coding standards and task specification.

## Criteria
Read and follow `.agy/runs/<run-id>/criteria/code-review.md`.

## Subject of Review
The change under review is in `.agy/runs/<run-id>/REVIEW_DIFF.patch`, with a per-file summary in `.agy/runs/<run-id>/REVIEW_DIFF.stat`.
That patch is the sole subject of review; existing file contents are context only.

## Invariant Rules
1. **Do not run shell commands.** You cannot run `git diff`; the patch and stat files are your only account of the change.
2. **Do not touch git.** Do not commit.
3. **Do not modify source code or fix anything.** Findings must only be reported in feedback.
4. **Write nothing outside this repository.**

## Output Contract
1. Write findings to `.agy/runs/<run-id>/REVIEW_FEEDBACK.md`, ordered by severity, every finding anchored to `file:line` with a quoted snippet, including an `## Examined` section listing all reviewed files.
2. Write your one-line verdict — `STATUS: PASSED | File: .agy/runs/<run-id>/REVIEW_FEEDBACK.md` or `STATUS: FAILED | File: .agy/runs/<run-id>/REVIEW_FEEDBACK.md` — to `.agy/runs/<run-id>/phases/REVIEW/verdict`, and print that same line as the last line of your output in the form `STATUS: <verdict> | File: <path>`. Do not write `.agy/runs/<run-id>/phases/REVIEW/status`.
