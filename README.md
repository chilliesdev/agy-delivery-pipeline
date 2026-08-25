# agy-delivery-pipeline

[![CI](https://github.com/chilliesdev/agy-delivery-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/chilliesdev/agy-delivery-pipeline/actions/workflows/ci.yml)

A Claude Code **plugin** that hands coding work to the
[Antigravity CLI](https://antigravity.google/docs/cli/overview/) (`agy`) while
Claude Code stays the orchestrator — writing briefs, running the checks, reading
the diff, and gating every result.

Two halves:

- **Ambient delegation.** Once installed, non-trivial implementation work goes to
  `agy` as a single headless worker instead of Claude editing the code itself.
- **The pipeline.** One task driven end to end — discovery, implementation, a
  code-review retry loop, QA, docs and release preparation — on `/agy:pipeline`.

There are no sub-agents anywhere. Every dispatch is one `agy -p` process, and
exactly one is ever running.

## Requirements

- Antigravity CLI — `curl -fsSL https://antigravity.google/cli/install.sh | bash`
  (installs `agy` to `~/.local/bin`)
- Claude Code
- bash (works on macOS's bash 3.2)

## Install

```
/plugin marketplace add chilliesdev/agy-delivery-pipeline
/plugin install agy@agy-delivery-pipeline
```

Then check the setup once:

```
/agy:preflight
```

> The old `ln -s "$PWD" ~/.claude/skills/multi-agent-delivery-pipeline` install no
> longer works. `SKILL.md` now lives at `skills/agy-pipeline/SKILL.md` and reaches
> its scripts through `${CLAUDE_PLUGIN_ROOT}`, which only a plugin install sets.
> Remove any old symlink; the plugin replaces it.

## Commands

| command | does |
|---|---|
| `/agy:pipeline <task>` | the five phases; `--from N --to N` runs part of the range |
| `/agy:delegate <task>` | one bounded task, one worker — the explicit form of ambient mode |
| `/agy:preflight` | fresh check that agy is installed, signed in, and has the model |
| `/agy:phase <PHASE> <brief>` | dispatch a single phase by hand, to recover a stalled run |

## Ambient delegation

The `agy-delegate` skill triggers on its own. It claims implementation work that
touches more than one file or changes behaviour rather than fixing something
already written — judgement against a stated bar, not a line count. Claude keeps
conversation, planning, git, running tests, the gate, and small edits.

The first delegation in a session asks; after that it dispatches and reports.
That consent lives in the conversation and nowhere else, so no stale marker file
can ever answer for a session that has not agreed.

One `agy -p` at tier `medium`. No review phase — `--verify`,
`check-diff-integrity.sh`, and Claude spot-checking the diff form the gate. Work
wanting a review loop wants `/agy:pipeline`.

**If agy is missing, signed out, or the model is unavailable, the plugin says so
once and Claude does the work itself.** It degrades to a no-op, never to a wall.

On this path `.agy/` is ignored via `.git/info/exclude` rather than the tracked
`.gitignore`: ambient delegation runs in whatever repo you happen to be in, and
has no business editing a tracked file there for its own scratch directory.

## The pipeline

`/agy:pipeline` only — it does not trigger on description match, which keeps it
from competing with `agy-delegate` over the same requests.

| # | Phase | Tier | Produces |
|---|---|---|---|
| 0 | Discovery — what's needed to build *and test* the task | low | `.agy/runs/<run-id>/DISCOVERY.md`, `.agy/runs/<run-id>/TEST_COMMAND` |
| 1 | Implementation | medium | `.agy/runs/<run-id>/CHANGES.md` |
| 2 | Code review, with a capped retry loop | high | `.agy/runs/<run-id>/REVIEW_FEEDBACK.md` |
| 3 | QA (`--mode full --sandbox`) | medium | `.agy/runs/<run-id>/QA_REPORT.md` |
| 4 | Docs, then release *preparation* | low / high | `.agy/runs/<run-id>/RELEASE_FACTS.md`, `.agy/runs/<run-id>/RELEASE_PLAN.md` |

All phases run on Gemini 3.7 Flash; the tier sets reasoning effort.

Each phase prints exactly one line back to the orchestrator:

```
STATUS: READY | Phase: DISCOVERY | Run: 2026-08-24T09-51-03Z-a4f1 | Log: /path/to/.agy/runs/2026-08-24T09-51-03Z-a4f1/phases/DISCOVERY/log
```

Everything else — the full worker transcript — stays on disk in
`.agy/runs/<run-id>/phases/<PHASE>/log`.

`--from N` refuses rather than improvising. Phases read what earlier ones wrote,
and a phase dispatched without its inputs does not error — the worker invents a
plausible brief from nothing. `check-phase-range.sh` checks `run.json` to verify
that earlier phases completed with a passing status and left their artifacts in
the run directory. A filename cannot say which task it was written for, and a
record can. If anything is missing or unrecorded, the script names the missing
files and the phase that writes each one, and the run stops there.

## The run directory

Every run is scoped under `.agy/runs/<run-id>/`:

```
.agy/
  current                  # plain file holding current run id
  last                     # plain file holding last run id
  runs/
    <run-id>/
      run.json             # machine-readable provenance: task, base commit, phase outcomes
      DISCOVERY.md         # phase artifacts directly under the run dir
      TEST_COMMAND
      CHANGES.md
      REVIEW_DIFF.patch
      REVIEW_DIFF.stat
      REVIEW_FEEDBACK.md
      QA_REPORT.md
      RELEASE_FACTS.md
      RELEASE_PLAN.md
      criteria/            # resolved criteria copied inside --add-dir
      phases/
        <PHASE>/
          brief.md         # copy of the dispatched brief
          verdict          # worker verdict (authoritative)
          status           # phase.sh STATUS line
          log              # full worker transcript
          verify.log       # --verify output
```

`current` and `last` are plain one-line files holding a run id rather than
symlinks (for portability across platforms and Git Bash).

Inspect past runs with `run-dir.sh`:

```
scripts/run-dir.sh list
scripts/run-dir.sh show [--run <id|current|last>]
```

## The run ledger

Every dispatch — pipeline phase or standalone delegation — appends one record
to `.agy/ledger.jsonl`. It is a single append-only line per dispatch, spanning
all runs in the repository. It is never rewritten, never truncated, and never
sorted.

Every gate in this repository was added in response to a single incident. That
is a sound way to *find* a gate and a poor way to *keep* one. Nothing here would
ever have told you that a rule had stopped earning its place, or that a
paragraph added to `criteria/code-review.md` made reviews better rather than
merely longer.

`REVIEW_THIN` is the standing example: it exists because one review came back as
empty scaffolding, and it is deliberately **not** wired into `--verify` because
nobody could tell whether it was reliable enough to override a verdict. With a
hundred runs recorded, whether thin reviews predict a later `VERIFY_FAILED`
becomes a question with an answer, and the rule can be promoted or deleted on
evidence instead of staying a maybe forever.

And the number that matters most: **how often `--verify` overrides a worker's
`PASSED`.** That figure is the entire justification for the gate, and until now
nobody knew it.

A record holds dispatch metadata, timings, exit codes, gate verdicts, retry
counters, token usage, turn counts, agy status, and diff/review summaries:

```json
{"run":"2026-08-24T09-51-03Z-a4f1","phase":"REVIEW","attempt":1,"tier":"high","model":"gemini-3.7-flash-high","backend":"agy","started":"2026-08-24T09:51:20Z","elapsed_s":42,"worker_rc":0,"verdict":"PASSED","verify_ran":true,"verify_rc":0,"status":"PASSED","retries_spent":0,"retries_refunded":0,"task_id":"b3f81e62a1c0","usage":{"input_tokens":8000,"output_tokens":2000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":10000},"num_turns":1,"agy_status":"SUCCESS","diff":{"files":3,"insertions":45,"deletions":12,"truncated":false},"review":{"anchors":4,"status":"REVIEW_EVIDENCED"}}
```

Records carry `usage` — `input_tokens`, `output_tokens`, `thinking_tokens`,
`cache_read_tokens`, `total_tokens` — alongside `num_turns` and agy's own
`agy_status`.

**The privacy stance, plainly.** The task string is recorded as a 12-character
hash by default (`git hash-object`, requiring no extra dependencies). Setting
`AGY_LEDGER_TASK=plain` opts into recording literal task strings. Brief bodies,
diffs, logs, and file contents stay in the run directory and never enter the
ledger. The intent that follows is deliberate: *the ledger should be safe to
share; the run directory should not have to be.*

A failed ledger append never fails a dispatch. Recording is a side effect, not
the job.

### Inspecting the ledger

Query summary metrics across recorded runs with `scripts/report.sh`:

```
scripts/report.sh [--dir <repo>] [--since <date>] [--phase <NAME>] [--run <id>]
                  [--price-in <usd-per-mtok>] [--price-out <usd-per-mtok>]
```

It parses the JSONL records in portable bash 3.2 (no `jq` or Python required)
and prints:

- dispatch counts and pass rates by phase
- retry convergence distribution (rounds 1, 2, 3+, and unresolved cap hits)
- median and max elapsed wall-clock times per phase
- token spend per phase, with dead rounds (refunded worker failures) separated
- average token efficiency per successful task
- gate and verification outcomes, including `--verify` overrides and missing
  worker statuses
- corrupt or unparseable line counts

### Token budgets and pricing

`scripts/phase.sh --budget-tokens <n>` enforces a spend ceiling for a run.
Before dispatching, it sums `total_tokens` across all ledger records for the
run. If already at or past the ceiling, it refuses to dispatch, returning
`STATUS: BUDGET_EXCEEDED(spent=N, budget=M)` (exit 7) — the same shape as
`RETRY_CAP_REACHED`, and refused **before** the dispatch so an over-budget run
costs nothing more.

**Budgets are in tokens, not dollars.** Prices change, differ per model and per
account, and a stale number presented as a cost is worse than no number. Rates
can be supplied to `scripts/report.sh` via `--price-in` and `--price-out` (USD
per million tokens) for a derived dollar figure; without them, the report says
nothing about money.

## Configuration

Model selection, tier mappings, and phase fallbacks are configured in
`agy.toml`. Model resolution is handled by `scripts/resolve-model.sh`.

### Resolution order

Config files are resolved in order (first hit wins):

1. `<repo>/.claude/agy.toml` — the project's own Claude Code configuration
2. `<repo>/agy.toml` — the project root configuration
3. `agy.toml` — the plugin's vendored default configuration

This matches the same precedence order that `scripts/resolve-criteria.sh`
uses for criteria files. If no config file exists anywhere, built-in defaults
apply (`low` -> `gemini-3.7-flash-low`, `medium` -> `gemini-3.7-flash-medium`,
`high` -> `gemini-3.7-flash-high`).

### What can be set

- **`[driver]`:** sets the default backend driver (`name = "agy"`).
- **`[tiers]`:** maps abstract tier names to concrete model IDs.
- **`[phases.<NAME>]`:** configures a phase's default `tier` and an optional
  `fallbacks` array of model IDs.
- **`[limits]`:** sets run constraints like `max_cost_tokens` and
  `max_wall_clock`.

```toml
[driver]
name = "agy"

[phases.REVIEW]
tier      = "high"
fallbacks = ["gemini-3.7-flash-high", "gemini-3.7-flash-medium"]

[phases.DISCOVERY]
tier = "low"

[tiers]
low    = "gemini-3.7-flash-low"
medium = "gemini-3.7-flash-medium"
high   = "gemini-3.7-flash-high"

[limits]
max_cost_tokens = 500000
max_wall_clock  = "45m"
```

### The tier vocabulary

The tier vocabulary — `low`, `medium`, `high` — expresses what a phase is
**worth** (its reasoning investment and weight), not what specific binary or API
it runs on. When newer models arrive or a project rebinds tiers, the binding
moves while the phase definitions and intent remain unchanged.

### Precedence rules

1. **Raw model ID beats everything:** Passing a raw model ID to `--tier` (e.g.
   `--tier custom-model-id`) bypasses tier lookup entirely.
2. **Explicit command-line `--tier` beats config:** Passing `--tier high`
   forces that tier regardless of any per-phase config in `agy.toml`.
3. **Project config beats vendored defaults:** Values in
   `<repo>/.claude/agy.toml` or `<repo>/agy.toml` override the vendored
   `agy.toml`.
4. **Per-phase config applies when no `--tier` is passed:** `scripts/phase.sh`
   passes no tier argument by default, allowing `scripts/resolve-model.sh` to
   resolve the phase's configured tier from `agy.toml`.

### Diagnostic output on stderr

`scripts/resolve-model.sh` prints only the resolved model ID to stdout on a
single line (suitable for command substitution). It reports on **stderr** which
config file and which entry decided the resolution:

```
resolve-model: resolved 'gemini-3.7-flash-high' from /path/to/agy.toml ([phases.REVIEW].tier = high)
```

A surprising model choice is therefore immediately diagnosable rather than
mysterious.

### Format restriction

The configuration parser reads a deliberately restricted subset of TOML:

- Single-level section headers: `[section]` or `[section.subsection]` (e.g.
  `[tiers]`, `[limits]`, `[phases.REVIEW]`)
- Double-quoted strings: `key = "value"`
- Integers: `key = 123`
- Single-line string arrays: `key = ["a", "b"]`

**Disallowed:** Nested tables beyond one level (`[a.b.c]`), multi-line arrays,
and inline trailing comments after values (`key = "val" # comment`).

**Why:** There is no `jq`, no Python, and no TOML parser library available in
baseline environments (macOS bash 3.2). Adding dependencies is not an option —
the same reasoning that keeps `run.json` hand-written.

**Error handling:** Malformed lines or unsupported syntax are **refused with an
error message, not silently ignored**. If `scripts/resolve-model.sh` encounters
an unparseable line, it halts immediately, prints the filename, line number, and
exact reason to stderr, and exits with code 2.

### Fallback chains

A fallback chain specifies alternative models if the primary configured model
is unavailable in the user's `agy models` account listing.

Falling back to a weaker model is **reported, not silent**: a code review run
at `medium` reasoning when configured for `high` is a different review. When a
fallback is taken:

- `scripts/preflight.sh` reports the fallback to stderr and in its summary line
  (`preflight: ok — agy signed in, fell back to … (… unavailable)`).
- `scripts/phase.sh` appends ` | Fallback: <model-id>` to the STATUS line sent
  to the orchestrator.
- The run ledger records the actual fallback model that executed.

## Worker drivers

Exactly one file knows what the backend is: its driver script under
`drivers/<name>.sh` (currently [drivers/agy.sh](drivers/agy.sh)). Everything
above it — the orchestrator, phase sequencing, brief linting, diff integrity,
criteria resolution, gates, and the ledger — is backend-neutral.

The driver is selected through:

1. CLI flag: `--driver <name>` passed to `scripts/phase.sh`
2. Configuration: `[driver]` table in `agy.toml` (`name = "agy"`)
3. Default: `agy`

An unknown driver name is **refused**, whether passed via `--driver` or
configured in `agy.toml`, naming the drivers that exist (exit 2). A name that
looks applied and is not is the failure this repo distrusts most.

[drivers/README.md](drivers/README.md) defines the contract for writing another
driver. Each driver implements three functions: `driver_run`, `driver_models`,
and `driver_capabilities`.

### Capabilities: encoding backend behavior as data

The repo's hardest-won knowledge used to live only in prose. It is now data
reported by `driver_capabilities`:

```
shell=no  sandbox=yes  effort=yes  read_outside_dir=no  plan_mode_writes=no
usage_reporting=json  stdout_must_be_pipe=yes  stdin_must_be_devnull=yes
```

Each key encodes a concrete operational characteristic of the backend:

- **`shell` (`no` | `yes`):** Whether the worker is permitted to run shell
  commands. For `agy`, `no` encodes that permission denials abort headless runs
  in `accept-edits`.
- **`sandbox` (`yes` | `no`):** Whether the backend supports sandboxed
  execution (`--sandbox`).
- **`effort` (`yes` | `no`):** Whether the backend supports reasoning effort
  levels (`--effort`).
- **`read_outside_dir` (`no` | `yes`):** Whether the worker can read files
  outside `--add-dir`. For `agy`, `no` encodes that reading external paths
  aborts the run.
- **`plan_mode_writes` (`no` | `yes`):** Whether read-only plan mode permits
  writing output reports. For `agy`, `no` encodes that `--mode plan` blocks the
  worker from writing its own report and verdict.
- **`usage_reporting` (`json` | `none` | `always`):** How token usage is
  reported. For `agy`, `json` encodes that token metrics require
  `--output-format json`.
- **`stdout_must_be_pipe` (`yes` | `no`):** For `agy`, `yes` encodes that stdout
  must be read through a pipe rather than a plain file to prevent hangs.
- **`stdin_must_be_devnull` (`yes` | `no`):** For `agy`, `yes` encodes that
  stdin must be redirected from `/dev/null` to prevent input drain hangs.

These keys are the facts documented in
[agy behaviours worth knowing](#agy-behaviours-worth-knowing) made
machine-readable.

This matters plainly: a different backend has a different list. One that allows
shell commands makes the "do not run shell commands" rule unnecessary and the
whole `scripts/check-test-command.sh` dance redundant. Capabilities cannot be a
comment, or the second backend silently inherits the first one's workarounds.

`scripts/phase.sh` is the live consumer: it inspects `shell=` from
`driver_capabilities` and automatically passes `--allow-shell` to
`scripts/check-brief.sh` when the driver permits shell execution.

### Architectural claim

The interesting thing here is not agy. It is the shape — an orchestrator that
never writes code, workers that never gate themselves, file-based state between
them, and every claim checked mechanically before the next dispatch. That shape
is backend-agnostic, and the gates did not change when agy moved behind an
interface. That they did not change is the evidence that the shape was real
rather than a description of one CLI's quirks.

Be careful not to overclaim: **no second driver exists**, and none of this is
proven against one. A second backend is where the design gets tested, and until
one lands this is a well-shaped hypothesis.

## Diff integrity check

`scripts/check-diff-integrity.sh` mechanically inspects diffs against the brief
for the failure modes a passing test suite cannot catch:

- **Weakened tests (`DIFF_TESTS_WEAKENED`):** deleted test files, added test
  skips (`@pytest.mark.skip`, `it.only`, `t.Skip`), or assertions rewritten to
  tautologies (`assert True`). Exits 3 to override worker claims and fail the
  phase or gate.
- **Suspicious changes (`DIFF_SUSPICIOUS`):** falling assertion counts,
  modified assertion literals without source changes, and scope creep (set
  difference between touched paths and the brief). Surfaced for human review
  without failing automatically.
- **Unchecked languages (`DIFF_UNCHECKED`):** if a diff touches languages with
  no rules defined, it reports unchecked rather than claiming clean.

This turns the human diff read into a **spot check rather than the load-bearing
gate** — catching mechanical shortcuts automatically while leaving semantic
judgement, invented APIs, and unanalysed languages to the orchestrator.

## Brief linting

`scripts/check-brief.sh` validates brief structure and safety constraints
before any worker is dispatched. `scripts/phase.sh` runs it automatically on
every dispatch and refuses an invalid brief before starting `agy`, so a bad
brief costs zero model calls and zero tokens. Pass `--no-brief-lint` (or set
`AGY_SKIP_BRIEF_LINT=1`) to bypass.

The brief is the only artifact in the pipeline that nothing validated. Scripts
are tested, diffs captured and analysed, criteria resolved by a script with its
own suite, verdicts parsed defensively from two routes with a rule about which
wins — and briefs were composed freehand and dispatched. Six ways to lose a
dispatch, every one enforced by the model remembering to type a sentence.

After run-scoped state landed, briefs kept naming the old verdict path,
`.tmp/<PHASE>.verdict`. agy refused the write as an invalid artifact path,
declared the run an ERROR, and still exited 0 with the work done and the verdict
carried only by the printed-line fallback. The authoritative half of the verdict
contract failed silently, and a text scan costing nothing would have caught it
before the dispatch. That is #44, and `check-brief.sh` now has a fixture for
exactly it.

Checks performed:
- **Verdict path:** must point to `.agy/runs/<run-id>/phases/<PHASE>/verdict`
  (rejects stale `.tmp/` and wrong phase/run paths).
- **Both verdict routes:** worker must be instructed to write the verdict file
  and print the final `STATUS:` line to stdout.
- **Shell prohibition:** brief must prohibit shell execution (unless
  `--allow-shell` is given or phase runs in full mode).
- **Git prohibition:** brief must forbid git commits, staging, and branching.
- **Input paths:** all referenced repo files and criteria files must exist.
- **No outside paths:** no references to paths outside the repo or user home.

Shipped templates in `briefs/` (`briefs/DISCOVERY.md`, `briefs/IMPLEMENT.md`,
`briefs/REVIEW.md`, `briefs/QA.md`, `briefs/RELEASE.md`, `briefs/DELEGATE.md`)
provide the standard, pre-validated starting shape for each phase.

## Secret scanning

`scripts/check-secrets.sh` scans briefs and captured diffs for credentials
before any worker is dispatched. `scripts/phase.sh` runs it automatically on
every dispatch and refuses on detection with `STATUS: SECRETS_FOUND` (exit 3)
before starting `agy`, preventing accidental leakage to external models. Pass
`--no-secret-scan` (or set `AGY_SKIP_SECRET_SCAN=1`) to bypass.

Checks performed (high-confidence, low-false-positive set):
- **Private keys:** headers and blocks (`BEGIN … PRIVATE KEY`).
- **AWS access keys:** `AKIA` followed by 16 alphanumeric characters.
- **GitHub tokens:** `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`.
- **Slack tokens:** `xoxb-`, `xoxa-`, `xoxp-`, `xoxr-`, `xoxs-`.
- **Google API keys:** `AIza` followed by 35 characters.
- **.env assignments:** assignments with non-placeholder secret values.

**Never prints the secret.** Refusals name the pattern, file, and line number
without echoing the credential value into logs or terminal scrollback. Obvious
placeholders (`changeme`, `your-key-here`, `<insert-key>`) are ignored to avoid
false alarms.

## Running a phase by hand

The scripts are usable outside Claude Code:

```
scripts/preflight.sh --tier low
RUN_ID=$(scripts/run-dir.sh new --task "my task")
scripts/check-brief.sh --phase DISCOVERY --brief .agy/runs/$RUN_ID/phases/DISCOVERY/brief.md --dir . --run "$RUN_ID"
scripts/check-secrets.sh --brief .agy/runs/$RUN_ID/phases/DISCOVERY/brief.md --dir . --run "$RUN_ID"
scripts/phase.sh --phase DISCOVERY --run "$RUN_ID" --brief .agy/runs/$RUN_ID/phases/DISCOVERY/brief.md --tier low
scripts/capture-diff.sh --dir .
scripts/check-diff-integrity.sh --dir .
```

## agy behaviours worth knowing

Established by testing, not from the docs. The scripts, briefs, and driver
capabilities ([Worker drivers](#worker-drivers)) are shaped around them:

- **`--add-dir` is mandatory** (`read_outside_dir=no`). Without it agy ignores
  the cwd and writes into `~/.gemini/antigravity-cli/scratch`.
- **A denied permission aborts the whole headless run** (`shell=no`). In
  `accept-edits` a worker that tries to run `npm test` dies with rc=1 *after*
  doing its work correctly. Briefs therefore say "do not run shell commands; the
  orchestrator runs the checks."
- **`--mode plan` denies every write** (`plan_mode_writes=no`), including the
  worker writing its own report — so read-only phases still run in
  `accept-edits`, constrained by the brief rather than the mode.
- **agy hangs when its stdout is a plain file** (`stdout_must_be_pipe=yes`), and
  **drains stdin before it answers** (`stdin_must_be_devnull=yes`), so anything
  reading it uses a pipe and `</dev/null`.
- **agy reports token usage, but only under `--output-format json`**
  (`usage_reporting=json`). The default text output carries none. The JSON
  object also carries `duration_seconds`, `num_turns`, a `conversation_id`, and
  agy's own `status`. Two flag details worth stating because both cost time to
  find: `-p` takes the next argument as its prompt, so the prompt must be
  attached as `-p='…'` with `--output-format` elsewhere on the command line; and
  every existing constraint still holds — stdout must be a pipe rather than a
  plain file, and stdin must be `</dev/null`.

  Switching to JSON moved the worker's text inside a `response` field, so the
  **printed-line verdict route** now has to be extracted from JSON before a
  `STATUS:` line can be found in it. The file route was unaffected. That is the
  verdict contract's two routes earning their keep — one of them changed shape
  entirely and the other did not notice.

## Security guarantees

The pipeline enforces concrete architectural guarantees across every run:

- **No push, no tag, no merge.** No script and no worker in this repository runs
  `git push`, creates a tag, or merges — not behind a flag, not as a default.
  The release phase inspects, prepares and proposes, printing the commands a
  person then runs by hand.
- **Workers never handle credentials.** Discovery reports credential names and
  never values; secret scanning prevents credentials from entering briefs or
  diffs.
- **The orchestrator prints commands rather than running them.** Irreversible
  actions are surfaced as instructions for the operator, never executed
  autonomously.
- **The orchestrator gates every dispatch.** A worker's `STATUS: PASSED` is a
  claim, not evidence: the orchestrator runs the tests itself, checks diff
  integrity, and spot-checks the diff before advancing.
- **Brief path confinement.** `scripts/check-brief.sh` refuses briefs naming
  paths outside the repository or pointing to stale temporary locations.
- **Ledger privacy by default.** `scripts/ledger.sh` records task strings as a
  hash by default (`git hash-object`), keeping `.agy/ledger.jsonl` safe to
  share.

See [docs/threat-model.md](docs/threat-model.md) for the complete threat model,
trust boundaries, and uncovered risks.

## Design stance

Delegation is a skill rather than a hook. A `PreToolUse` deny on `Edit` would
mean Claude cannot edit code in any repo where the plugin is enabled — including
this one — and a broken agy install would brick the session. Ambient routing is a
judgement call about what counts as non-trivial, and a skill that Claude can
decline is the right shape for a judgement call.

## Platforms

| platform | status |
|---|---|
| macOS, bash 3.2 | supported, exercised in CI on every push |
| Linux, bash 5 | supported, exercised in CI on every push |
| Windows via WSL | expected to work, **not tested** |
| Windows Git Bash | **not supported** |

Observed CI environments passing all test suites:
- `macos-latest` — GNU bash 3.2.57(1)-release (arm64-apple-darwin25)
- `ubuntu-latest` — GNU bash 5.2.21(1)-release (x86_64-pc-linux-gnu)

Git Bash is not supported: `git worktree`, `.git/info/exclude`, and path
handling all differ, and phase dispatch (#31) depends on worktrees. Note that
run-scoped state deliberately uses hyphens rather than colons in run ids, and
plain files rather than symlinks for `current` and `last`, precisely so the
layout is not the thing that breaks — the groundwork exists even though the
platform is untested and unsupported.

### Watchdog and timeout portability

The timeout watchdog in `scripts/preflight.sh` and
`scripts/check-test-command.sh` is hand-rolled everywhere rather than using
`timeout(1)` or `gtimeout(1)`. macOS ships neither, so a `timeout`-based path
could only ever be a second implementation. Maintaining two timeout
mechanisms would mean the branch run most often in CI differs from what macOS
users execute, risking quiet divergence. Furthermore, the hand-rolled
watchdog uses `set -m` and process groups to TERM and KILL whole process trees,
preventing orphaned child processes that `timeout(1)` leaves running.

### Known unknowns

- **`~/.local/bin` on PATH:** `scripts/preflight.sh` exit 127 suggests adding
  `~/.local/bin` to PATH, which matches standard macOS installs but may differ
  on some Linux distributions or shell setups.
- **Locales, spaces, and case sensitivity:** Non-UTF-8 locales, paths
  containing spaces, and case-sensitive filesystems have not been exhaustively
  tested with `--dir` or the criteria-copy step.
- **Git version floor:** `git add -N`, `git for-each-ref`, and `git worktree`
  are required across scripts. A strict minimum version floor is unestablished;
  Ubuntu CI pins a recent version incidentally.

## Tests

```
scripts/run-tests.sh
```

Runs all suites in sorted order and exits non-zero if any fails. Pass suite
paths to run a subset, or `--quiet` to report only failures and the summary:

```
scripts/run-tests.sh tests/manifest.sh tests/doc-links.sh tests/check-diff-integrity.sh
```

CI runs the full suite on macOS (bash 3.2) and Ubuntu (bash 5). Each suite
builds throwaway repos under `$TMPDIR` and writes nothing inside this one.

## Status

Phases 0 through 3 and the docs half of Phase 4 have been run end to end against
a real repo, and the pipeline produced working code. **The release step has never
run against a real project.** It has a script (`check-release.sh`), a vendored
flow (`criteria/release.md`) and a refusal status — but "mechanized and tested"
is not the same as "exercised", and the first real release through it should be
watched closely.

**The plugin packaging is new and equally unexercised.** The ambient delegate
skill, the phase range, and the `.git/info/exclude` path all have test coverage,
but none of them has been through a real session yet.
