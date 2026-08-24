---
description: Hand one bounded coding task to agy as a single headless worker, then verify what comes back.
argument-hint: <task>
---

Delegate this to agy as a single worker:

$ARGUMENTS

Load the `agy-delegate` skill and follow it. This is the explicit form of what
that skill does ambiently — invoked this way, **do not ask for consent first**:
running this command is the consent.

Everything else in the skill still applies: write the brief, dispatch one
`DELEGATE` phase, run the tests through `--verify`, and read the diff yourself
before reporting. A worker's `STATUS: PASSED` is a claim, not evidence.

If this task wants a review loop, QA, or a release, it wants `/agy:pipeline`
instead. Say so rather than growing this into one.
