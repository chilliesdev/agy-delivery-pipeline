# Phase 3: QA

Execute end-to-end verification and QA testing for the implemented changes.

## Criteria
Read and follow `.agy/runs/<run-id>/criteria/qa.md`.

## Verification Scope
Simulate user flows and verify scenarios using test commands defined in `.agy/runs/<run-id>/DISCOVERY.md`.

## Invariant Rules
1. **Do not modify source code.**
2. **Do not touch git.** Do not commit.
3. **Write nothing outside this repository.**
4. Shell commands are permitted exclusively within the sandbox execution environment for running test flows.

## Output Contract
1. Write full QA findings and scenario results to `.agy/runs/<run-id>/QA_REPORT.md`.
2. Write your one-line verdict — `STATUS: PASSED | File: .agy/runs/<run-id>/QA_REPORT.md` or `STATUS: FAILED | File: .agy/runs/<run-id>/QA_REPORT.md` — to `.agy/runs/<run-id>/phases/QA/verdict`, and print that same line as the last line of your output in the form `STATUS: <verdict> | File: <path>`. Do not write `.agy/runs/<run-id>/phases/QA/status`.
