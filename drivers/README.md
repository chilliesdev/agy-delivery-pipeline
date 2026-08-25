# Worker Drivers

Worker drivers provide a standard abstraction layer between the delivery pipeline and headless AI coding workers.

All gatekeeping, verdict contract verification, preflight checks, diff recording, secret scanning, and retries in the pipeline are backend-neutral. Exactly one component interacts with a specific AI worker backend: its driver script under `drivers/<name>.sh`.

---

## The Driver Contract

Each driver script must reside at `drivers/<name>.sh` (for example, `drivers/agy.sh`) and implement three functions:

### 1. `driver_run`

Executes one brief through the backend worker headlessly.

```bash
driver_run --brief <file> --dir <dir> --model <id> --mode <m> --effort <e> \
           [--sandbox] --timeout <t> --log <file>
```

- **Arguments**:
  - `--brief <file>`: Path to the brief markdown file containing instructions and contract.
  - `--dir <dir>`: Target repository directory (working tree root).
  - `--model <id>`: Backend model identifier (resolved from tier or specified directly).
  - `--mode <m>`: Phase execution mode (`accept-edits`, `plan`, or `full`).
  - `--effort <e>`: Reasoning effort level (`low`, `medium`, or `high`), if supported.
  - `--sandbox`: Optional flag indicating sandboxed execution mode.
  - `--timeout <t>`: Execution timeout duration (e.g. `30m`).
  - `--log <file>`: Path where the full transcript log must be saved.
- **Returns**: Exit code (`0` on clean completion, non-zero on worker failure).
- **Side Effects**:
  - Writes the raw transcript / output to `<log>`.
  - Emits JSON metadata to `<phase_dir>/result.json` if structured usage reporting is enabled.
  - Echoes extracted response to stdout.

### 2. `driver_models`

Lists available models for the worker backend.

```bash
driver_models
```

- **Arguments**: None.
- **Returns**: Available model identifiers, one per line to stdout. Exit code `0` on success, non-zero if unavailable or unauthenticated.

### 3. `driver_capabilities`

Emits backend-specific operational characteristics as key-value pairs.

```bash
driver_capabilities
```

- **Arguments**: None.
- **Returns**: `key=value` lines on stdout.

---

## Capabilities Specification

The capabilities reported by `driver_capabilities` allow the brief builder, linter, and orchestrator to adapt dynamically rather than hardcoding backend-specific assumptions into prose.

| Key | Values | Description |
|---|---|---|
| `shell` | `no` \| `yes` | Whether the worker is permitted to run shell commands. When `yes`, brief lint bypasses the shell prohibition check (`--allow-shell`). |
| `sandbox` | `yes` \| `no` | Whether the driver backend supports a sandboxed execution mode (`--sandbox`). |
| `effort` | `yes` \| `no` | Whether the driver backend has a reasoning-effort level dial (`--effort`). |
| `read_outside_dir` | `no` \| `yes` | Whether the worker can read files outside the working directory. |
| `plan_mode_writes` | `no` \| `yes` | Whether read-only plan mode permits the worker writing its own output report. |
| `usage_reporting` | `json` \| `none` \| `always` | How token usage is reported by the backend (`json` means structured JSON output is required). |
| `stdout_must_be_pipe` | `yes` \| `no` | Whether stdout must be a pipe rather than a plain file to prevent hangs. |
| `stdin_must_be_devnull` | `yes` \| `no` | Whether stdin must be redirected from `/dev/null` to prevent input drain hangs. |

---

## Driver Selection & Configuration

The delivery pipeline selects a driver through:

1. **CLI Flag**: `--driver <name>` passed to `scripts/phase.sh` (highest priority).
2. **Project Config**: `[driver]` section in `.claude/agy.toml` or `agy.toml`:
   ```toml
   [driver]
   name = "agy"
   ```
3. **Default**: `agy` (implemented by `drivers/agy.sh`).

---

## Adding a New Driver

To add a new backend driver:

1. Create `drivers/<name>.sh`.
2. Implement `driver_capabilities`, `driver_models`, and `driver_run`.
3. Ensure bash 3.2 compatibility (`set -uo pipefail`, portable syntax).
4. Add corresponding tests under `tests/`.
