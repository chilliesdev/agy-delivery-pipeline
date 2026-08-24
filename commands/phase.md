---
description: Dispatch one agy pipeline phase by hand, for recovering a pipeline run that stalled.
argument-hint: <PHASE> <brief-file> [--tier low|medium|high]
---

Dispatch a single phase:

$ARGUMENTS

```
${CLAUDE_PLUGIN_ROOT}/scripts/phase.sh --phase <PHASE> --brief <brief-file> --tier <tier>
```

This is the escape hatch, not the normal path — reach for it when a pipeline run
stalled and you want to re-run one phase without restarting, or when you have
written a brief by hand.

The brief file must already exist; this command does not write one. If you need
a brief composed for you, use `/agy:delegate` or `/agy:pipeline`, which do.

Report the STATUS line it prints and nothing else from the log. The verdict is a
claim: check the artifact the phase was supposed to write before calling it done.
