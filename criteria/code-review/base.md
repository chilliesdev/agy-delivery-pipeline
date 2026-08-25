# Code review criteria

Review **the diff in `.agy/runs/<run-id>/REVIEW_DIFF.patch`** along two separate
axes. Report only — **you do not fix anything**, you do not edit source files,
and you do not commit. The single file you write is
`.agy/runs/<run-id>/REVIEW_FEEDBACK.md`.

- **Standards** — does the code follow how this repo says code should be written?
- **Spec** — does the code do what the task actually asked for?

Keep the axes separate while you work. A change can follow every convention and
still implement the wrong thing, or do exactly what was asked while breaking the
repo's conventions. Judging them together lets one axis mask the other.

## What to review

Two files were written for you before you were dispatched. You cannot run
`git diff` — shell commands are denied and the denial ends your run — so these
are the only account of the change you will get:

| file | what it is |
|---|---|
| `.agy/runs/<run-id>/REVIEW_DIFF.patch` | the unified diff. **This is the subject of the review.** |
| `.agy/runs/<run-id>/REVIEW_DIFF.stat` | every file the change touches, complete even when the patch is truncated |

**Read the patch first, and read all of it.** The current contents of a file are
context for understanding a hunk — they are *not* the thing being reviewed. This
distinction is the whole point: a test that was weakened, a guard that was
deleted, a default that changed, a branch that lost its only caller — none of
that exists in the post-change file. It exists only in the `-` lines of the
patch. A review that describes what the code now does, without reference to what
it did before, has reviewed the wrong thing.

So: open every hunk. Read the changed file around a hunk when you need the
surrounding context. Ignore unrelated pre-existing code — a finding must trace
to a hunk in the patch.

Both files open with `#` comment lines describing themselves; read that header,
it tells you the base the diff was taken against and whether anything was cut.

**If `.agy/runs/<run-id>/REVIEW_DIFF.patch` is missing, empty, or says no files
changed**, do not review the file contents instead and do not infer the change
from `.agy/runs/<run-id>/CHANGES.md`. Write `FAILED` as your verdict, say under
`## Standards` that no diff was provided so no review was possible, and stop.
An honest refusal is worth more than a review of the wrong subject.

**If the patch header says `TRUNCATED`**, you are seeing part of the change.
Review what is there, then say so explicitly at the top of your report and
list — from `.agy/runs/<run-id>/REVIEW_DIFF.stat` — the files whose hunks you
did not see.

## Axis 1 — Standards

First, find what this repo documents: `CODING_STANDARDS.md`, `CONTRIBUTING.md`,
`CLAUDE.md`, `AGENTS.md`, a style guide under `docs/`, lint/formatter config. A
documented repo standard always wins. Where the repo endorses something the
baseline below would flag, the repo is right and you suppress the finding.

Skip anything tooling already enforces. A linter or formatter catching it is not
a review finding.

On top of whatever the repo documents, always carry this smell baseline (Fowler,
_Refactoring_, ch. 3). Each entry reads *what it is* → *how to fix*. Every one is
a labelled judgement call — "possible Feature Envy" — never a hard violation.

- **Mysterious Name** — a function, variable, or type whose name does not reveal
  what it does or holds. → rename it; if no honest name comes, the design is murky.
- **Duplicated Code** — the same logic shape in more than one hunk or file. →
  extract the shared shape, call it from both.
- **Feature Envy** — a function reaching into another object's data more than its
  own. → move it onto the data it envies.
- **Data Clumps** — the same few fields or parameters keep travelling together. →
  bundle them into one type and pass that.
- **Primitive Obsession** — a string or number standing in for a domain concept
  that deserves its own type. → give the concept a small type.
- **Repeated Switches** — the same switch or if-cascade on the same type recurs
  across the change. → replace with polymorphism, or one shared map.
- **Shotgun Surgery** — one logical change forces scattered edits across many
  files. → gather what changes together into one module.
- **Divergent Change** — one file edited for several unrelated reasons. → split so
  each module changes for one reason.
- **Speculative Generality** — abstraction, parameters, or hooks added for needs
  the task does not have. → delete it; inline back until a real need shows.
- **Message Chains** — long `a.b().c().d()` navigation the caller should not
  depend on. → hide the walk behind one method on the first object.
- **Middle Man** — a class or function that mostly just delegates onward. → cut
  it, call the real target directly.
- **Refused Bequest** — a subclass that ignores or overrides most of what it
  inherits. → drop the inheritance, use composition.

## Axis 2 — Spec

The spec is the task description in the brief, plus
`.agy/runs/<run-id>/DISCOVERY.md` and `.agy/runs/<run-id>/CHANGES.md` if they
exist, plus any issue or spec file the brief names. Report:

- requirements the spec asked for that are **missing or partial** — including a
  requirement to *test* something, which is missing until a test in the patch
  exercises it
- behaviour in the diff that **was not asked for** (scope creep)
- requirements that look implemented but where the **implementation is wrong**

Quote the spec line each finding rests on. If no spec source exists at all, say
so under the Spec heading and move on — do not invent requirements.

## Failure patterns to check every time

These are the recurring ways a generated change goes wrong. Go through the list
one item at a time against the patch — not from memory of having read it — before
you conclude anything:

- stubbed functions, `TODO`s, or `pass`/`return null` bodies standing in for work
- APIs, flags, or config keys that do not exist in the dependency being called
- tests weakened, skipped, deleted, or rewritten to match broken behaviour
- **a new branch, flag, or error path with no test that exercises it end to end.**
  A test that calls the helper directly is not a test of the branch: if the diff
  adds a flag, something must run the real entry point with that flag set. This
  is a Minor, and it is the single most commonly missed finding.
- error paths swallowed — bare catches, ignored return codes, discarded errors
- hardcoded absolute paths, machine-specific paths, or secrets in source
- files created or modified outside the intended scope of the task
- a `-` line whose removal is not explained by the task — deleted validation, a
  dropped case, a narrowed assertion

## Severity ordering

Order every finding in `.agy/runs/<run-id>/REVIEW_FEEDBACK.md` by severity, worst
first:

| severity | means |
|---|---|
| **Critical** | breaks the build or tests, loses data, ships a secret, or the change does not do what was asked at all |
| **Major** | a requirement missing or wrong, an error path unhandled, a documented standard hard-violated |
| **Minor** | scope creep, a baseline smell worth acting on, a weak name, a missing test for a new branch |
| **Nit** | style, wording, formatting that tooling does not already enforce |

## Output — `.agy/runs/<run-id>/REVIEW_FEEDBACK.md`

Write one file, in this shape:

1. A one-line verdict: `PASSED` if nothing Critical or Major stands, otherwise
   `FAILED`.
2. A count per severity.
3. `## Examined` — see below.
4. `## Standards` — findings, severity-ordered.
5. `## Spec` — findings, severity-ordered. Note here if no spec was available.

### `## Examined` — required, whether or not you found anything

One bullet per file in `.agy/runs/<run-id>/REVIEW_DIFF.stat`, in this shape:

```
- `wordstat/cli.py` (+10 / -1) — new `--json` flag, parser wiring, the branch in
  `main()`. Checked: flag default, output shape, existing text path unchanged.
```

The file path, its line counts from the stat, what the hunks do, and what you
actually checked in them. If a file is in the stat and not in this list, you did
not review the change — you reviewed part of it, and the list is how that becomes
visible instead of invisible.

This section is not optional and it is not a formality. **A review that reports
zero findings is a claim, and this list is the evidence for it.** Zero findings
with a complete `## Examined` list is a clean review. Zero findings with an empty
or absent one is an empty review wearing a clean review's shape, and it will be
read as exactly that.

### Every finding

Each finding carries, in this order:

- **severity**
- **`path/to/file.ext:LINE`** — a real path from the patch and a real line number.
  Not "in the CLI", not "the test file". If you can only anchor to a hunk, give
  the hunk header (`@@ -20,6 +20,9 @@`) and the path.
- **a quoted snippet** — the actual line or lines from the patch, in a fenced
  block, with the leading `+` or `-` kept so it is clear whether the code is being
  added or removed. Two or three lines, not the whole hunk.
- **what is wrong**, in one or two sentences
- **what to do instead**
- **the authority**: the standard (file plus rule) for a standards violation, the
  smell's name for a baseline finding, or the quoted spec line for a spec finding

A finding with no path and no line is not a finding; either anchor it or drop it.
Do not merge or rerank across the two axes — they stay separate.

Be concrete and short. A finding nobody can act on without rereading the whole
diff is not a finding.

### Before you write the verdict

Reread your own report and ask: does it contain a single file path, a single line
number, a single quoted line from the patch? If it does not, you have produced
the shape of a review and none of its content. Go back to
`.agy/runs/<run-id>/REVIEW_DIFF.patch` and read the hunks.
