---
description: Check that agy is installed, signed in, and offers the model a tier resolves to.
argument-hint: [--tier low|medium|high]
---

Run the agy preflight, fresh — do not report a result from earlier in this
session:

```
${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh --tier ${ARGUMENTS:-low}
```

Report the outcome plainly, and on failure give the fix rather than only the
code:

| exit | means | fix |
|---|---|---|
| 0 | agy is signed in and has the model | nothing to do |
| 127 | `agy` is not on `PATH` | `curl -fsSL https://antigravity.google/cli/install.sh \| bash`, then put `~/.local/bin` on `PATH` |
| 3 | `agy models` returned nothing — not signed in | run `agy` once interactively and complete its sign-in |
| 4 | the model is not available to this account | the script prints the ids that *are*; pick one, or pass a raw id as `--tier` |
| 7 | the fetch hung past the bound | re-run — it often works; if every run stops at the same bound, something is holding the fetch open |
| 8 | no writable scratch directory | point `TMPDIR` somewhere writable |

The listing is fetched live and never cached, so this is the check to reach for
when a phase starts failing mid-session.
