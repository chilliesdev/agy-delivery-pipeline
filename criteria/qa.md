# QA criteria

Test the software the way a user would use it, and write down what happened. You
are testing, not building — **you do not modify source code**, you do not fix
anything you find, and you do not commit. The one file you write is
`.agy/runs/<run-id>/QA_REPORT.md` (plus any throwaway test artifacts, which you
delete at the end).

## Core stance

- **End-user perspective.** Exercise the real software through its real surface —
  the CLI as a user types it, the API over HTTP, the UI as a person clicks it.
  Reading the source to guess what would happen is not a test.
- **Zero-fix policy.** Finding a bug ends your involvement with it. Document it
  and move to the next scenario. If a bug blocks later scenarios, say so and mark
  those scenarios blocked rather than editing code to get past it.
- **Evidence-based.** Every failure carries the command you ran, the output you
  saw, and the steps to reproduce. No claim without evidence.
- **Leave no trace.** Delete every temporary file, test database, scratch
  directory, and log you created, as soon as the report is written.

## 1. Establish requirements

Take requirements from the brief, then from `.agy/runs/<run-id>/DISCOVERY.md`,
`.agy/runs/<run-id>/CHANGES.md`, and any PRD, issue, or spec file the brief names.
Turn them into a concrete list of user flows to verify. If no requirement source
exists, say so at the top of the report and test the changed behaviour as
described in `.agy/runs/<run-id>/CHANGES.md` — do not invent requirements.

## 2. Verify prerequisites before testing

Check that the tools and the build you need actually work: the run and test
commands from `.agy/runs/<run-id>/DISCOVERY.md`, the dependencies, any service,
fixture, or env var those commands need.

If a prerequisite is missing or fails — the build breaks, a dependency is absent,
the service will not start — **stop immediately**. Record the exact failure as a
Critical blocker in `.agy/runs/<run-id>/QA_REPORT.md`, mark the run as terminated
early, and do not attempt the remaining scenarios. A run that could never have
tested anything must not be reported as a pass.

## 3. Execute the flows

For each flow: run it, observe the actual output, compare against the expected
behaviour. Then push a little past the happy path — bad input, empty input,
missing file, wrong order of operations, repeated invocation, and whatever the
change's own error paths claim to handle. New error handling in the diff is a
thing to test, not a thing to trust.

Record each scenario as you go rather than reconstructing it afterwards.

## 4. Severity levels

| severity | means |
|---|---|
| **Critical** | crash, data loss, core functionality entirely broken, or a prerequisite that blocked the run |
| **Major** | a feature does not work as required; a workaround may exist |
| **Minor** | confusing message, non-critical feature issue, cosmetic glitch |
| **Trivial** | typo, spacing, wording |

If a failure is intermittent, say so and give the rate you observed.

## 5. Output — `.agy/runs/<run-id>/QA_REPORT.md`

Write one file, in this shape:

**Executive summary** — overall status, pass rate, and a count of Critical, Major,
Minor and Trivial findings.

**Test environment** — OS, runtime versions, dependency status, build status.

**Test scope** — the flows covered, and where the requirements came from.

**Scenarios and results** — one table:

| ID | Scenario | Expected | Actual | Status |
|---|---|---|---|---|
| TC-01 | … | … | … | Pass / Fail / Blocked |

**Bug reports** — for each failure, in severity order, worst first:

- **ID** — `BUG-01`, `BUG-02`, …
- **Title** — one line
- **Severity**
- **Steps to reproduce** — the exact commands or clicks
- **Actual behaviour** — including the real output or error text
- **Expected behaviour** — and the requirement it comes from
- **Logs** — the relevant excerpt, not the whole transcript

**Observations** — usability and robustness notes, and gaps in test coverage
worth closing later. No code fixes here — describing the bug is the deliverable.

## 6. Clean up, then report status

Delete the test artifacts. Then end your run with one line:
`STATUS: PASSED` if no Critical or Major finding stands, otherwise
`STATUS: FAILED | File: .agy/runs/<run-id>/QA_REPORT.md`.
