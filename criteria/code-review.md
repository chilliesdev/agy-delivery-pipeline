# Code review criteria

Review the working-tree diff along two separate axes. Report only — **you do not
fix anything**, you do not edit source files, and you do not commit. The single
file you write is `.tmp/REVIEW_FEEDBACK.md`.

- **Standards** — does the code follow how this repo says code should be written?
- **Spec** — does the code do what the task actually asked for?

Keep the axes separate while you work. A change can follow every convention and
still implement the wrong thing, or do exactly what was asked while breaking the
repo's conventions. Judging them together lets one axis mask the other.

## What to review

The uncommitted working-tree diff, unless the brief names a different fixed
point. Read the changed files around each hunk so you are judging the change in
context and not a floating fragment. Ignore unrelated pre-existing code — a
finding must trace to something the diff changed.

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

The spec is the task description in the brief, plus `.tmp/DISCOVERY.md` and
`.tmp/CHANGES.md` if they exist, plus any issue or spec file the brief names.
Report:

- requirements the spec asked for that are **missing or partial**
- behaviour in the diff that **was not asked for** (scope creep)
- requirements that look implemented but where the **implementation is wrong**

Quote the spec line each finding rests on. If no spec source exists at all, say
so under the Spec heading and move on — do not invent requirements.

## Failure patterns to check every time

These are the recurring ways a generated change goes wrong. Check for each one
explicitly before you conclude:

- stubbed functions, `TODO`s, or `pass`/`return null` bodies standing in for work
- APIs, flags, or config keys that do not exist in the dependency being called
- tests weakened, skipped, deleted, or rewritten to match broken behaviour
- error paths swallowed — bare catches, ignored return codes, discarded errors
- hardcoded absolute paths, machine-specific paths, or secrets in source
- files created or modified outside the intended scope of the task

## Severity ordering

Order every finding in `.tmp/REVIEW_FEEDBACK.md` by severity, worst first:

| severity | means |
|---|---|
| **Critical** | breaks the build or tests, loses data, ships a secret, or the change does not do what was asked at all |
| **Major** | a requirement missing or wrong, an error path unhandled, a documented standard hard-violated |
| **Minor** | scope creep, a baseline smell worth acting on, a weak name, a missing test for a new branch |
| **Nit** | style, wording, formatting that tooling does not already enforce |

## Output — `.tmp/REVIEW_FEEDBACK.md`

Write one file, in this shape:

1. A one-line verdict: `PASSED` if nothing Critical or Major stands, otherwise
   `FAILED`.
2. A count per severity.
3. `## Standards` — findings, severity-ordered.
4. `## Spec` — findings, severity-ordered. Note here if no spec was available.

Each finding carries: **severity**, the **file and line or hunk**, a quoted
snippet, what is wrong in one or two sentences, and what to do instead. Name the
standard (file plus rule) for a standards violation, or the smell, or the spec
line. Do not merge or rerank across the two axes — they stay separate.

Be concrete and short. A finding nobody can act on without rereading the whole
diff is not a finding.
