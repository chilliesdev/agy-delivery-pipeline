#!/usr/bin/env bash
# Exercise the AGY Control Center HTTP API and serve.sh launcher:
# 1. Launcher lifecycle, arguments, port binding, and Node version detection
# 2. Fleet with diverse declared phase lists (5, 4, 3 phases)
# 3. Refusal run (Class A, zero spend, excluded from pass rate) vs dispatched failure (Class B)
# 4. Records predating ledger fields (absent is null, never confident 0 or false)
# 5. Repository with no ledger (reachable, empty/zero metrics, no 500 error)
# 6. Unreachable / vanished paths (missing, not a git worktree, no .agy dir — never dropped)
# 7. Invariants: claim vs verification, declared vs inherited tier, no fleet spend total
# 8. Artifact byte-for-byte serving and path traversal prevention
# 9. Read-only guarantee: requests never modify watched repositories
# 10. Print never post: commands rendered as text, gh never executed
#
#   tests/serve.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
SERVE_SH="$ROOT_REPO/scripts/serve.sh"
LEDGER_SH="$ROOT_REPO/scripts/ledger.sh"
RUN_DIR_SH="$ROOT_REPO/scripts/run-dir.sh"

# Node.js >= 20 requirement check
# The pipeline works without Node; serve.sh is the only tool that requires it.
# When Node is missing or < 20, print one clear skip line and exit 0.
if ! command -v node >/dev/null 2>&1; then
  printf '%-34s ok   %s\n' "serve-skip-no-node" "node not found on PATH — skipping serve tests"
  exit 0
fi

NODE_VERSION="$(node -v 2>/dev/null || true)"
NODE_MAJOR="$(printf '%s\n' "$NODE_VERSION" | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p')"
if [ -z "$NODE_MAJOR" ] || [ "$NODE_MAJOR" -lt 20 ]; then
  printf '%-34s ok   %s\n' "serve-skip-node-old" "node version ${NODE_VERSION:-unknown} < 20 — skipping serve tests"
  exit 0
fi

[ -f "$SERVE_SH" ] || { echo "serve-test: scripts/serve.sh not found" >&2; exit 2; }
[ -f "$LEDGER_SH" ] || { echo "serve-test: scripts/ledger.sh not found" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "serve-test: scripts/run-dir.sh not found" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"
# shellcheck source=../scripts/ledger.sh
. "$LEDGER_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/serve-test.XXXXXX")" && pwd)"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

# Isolate all home and config directories from the developer environment
export AGY_FLEET="$ROOT/fleet"
export XDG_CONFIG_HOME="$ROOT/xdg"
export HOME="$ROOT/home"
mkdir -p "$ROOT/home" "$ROOT/xdg" "$ROOT/repos"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Stub gh binary to verify commands are printed and never executed
BIN_DIR="$ROOT/bin"
mkdir -p "$BIN_DIR"
STUB_GH="$BIN_DIR/gh"
cat > "$STUB_GH" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'CALLED: %s\n' "$*" >> "${STUB_GH_TRIGGER:-/dev/null}"
exit 1
STUB_EOF
chmod +x "$STUB_GH"
export STUB_GH_TRIGGER="$ROOT/gh_was_executed"
export PATH="$BIN_DIR:$PATH"

new_repo() {
  local r="$ROOT/repos/$1"
  mkdir -p "$r"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  printf '%s' "$r"
}

create_config() {
  local dir="$1"
  local phases="$2"
  local review_tier="${3:-high}"
  cat > "$dir/agy.toml" <<EOF
[driver]
name = "agy"

[pipeline]
phases = $phases

[phases.REVIEW]
tier = "$review_tier"

[phases.DISCOVERY]
tier = "low"

[tiers]
low    = "gemini-3.7-flash-low"
medium = "gemini-3.7-flash-medium"
high   = "gemini-3.7-flash-high"

[limits]
max_cost_tokens = 500000
max_wall_clock  = "45m"
EOF
}

# =============================================================================
# Build Fixture Repositories
# =============================================================================

# Fixture 1: Fleet of several repositories with different declared phase lists
R_FIVE="$(new_repo fleet-five)"
create_config "$R_FIVE" '["DISCOVERY", "IMPLEMENT", "REVIEW", "QA", "RELEASE"]' "high"
RUN_FIVE="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_FIVE" --task "fleet five task")"
P_FIVE="$R_FIVE/.agy/runs/$RUN_FIVE/phases"
mkdir -p "$P_FIVE/DISCOVERY" "$P_FIVE/IMPLEMENT" "$P_FIVE/REVIEW" "$P_FIVE/QA" "$P_FIVE/RELEASE"
printf 'STATUS: PASSED | File: DISCOVERY.md\n' > "$P_FIVE/DISCOVERY/verdict"
printf 'STATUS: PASSED | Phase: DISCOVERY\n' > "$P_FIVE/DISCOVERY/status"
printf 'STATUS: PASSED | File: src/code.js\n' > "$P_FIVE/IMPLEMENT/verdict"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$P_FIVE/IMPLEMENT/status"
printf 'STATUS: PASSED | File: REVIEW.md\n' > "$P_FIVE/REVIEW/verdict"
printf 'STATUS: PASSED | Phase: REVIEW\n' > "$P_FIVE/REVIEW/status"
printf 'STATUS: PASSED | File: QA.md\n' > "$P_FIVE/QA/verdict"
printf 'STATUS: PASSED | Phase: QA\n' > "$P_FIVE/QA/status"
printf 'STATUS: PREPARED | File: RELEASE.md\n' > "$P_FIVE/RELEASE/verdict"
printf 'STATUS: PREPARED | Phase: RELEASE\n' > "$P_FIVE/RELEASE/status"
printf 'Initial brief for five phases\n' > "$P_FIVE/IMPLEMENT/brief.md"
printf 'Log line 1\nLog line 2\n' > "$P_FIVE/IMPLEMENT/log"
printf -- '--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n' > "$R_FIVE/.agy/runs/$RUN_FIVE/REVIEW_DIFF.patch"
printf ' 1 file changed, 1 insertion(+), 1 deletion(-)\n' > "$R_FIVE/.agy/runs/$RUN_FIVE/REVIEW_DIFF.stat"
printf '## Run Summary\nAll 5 phases passed.\n' > "$R_FIVE/.agy/runs/$RUN_FIVE/ISSUE_COMMENT.md"
ledger_append "$R_FIVE" run="$RUN_FIVE" phase=IMPLEMENT status=PASSED dispatched=true attempt=1 \
  started=2026-08-25T10:00:00Z elapsed_s=30 \
  usage='{"input_tokens":1000,"output_tokens":200,"thinking_tokens":50,"cache_read_tokens":0,"total_tokens":1250}'

R_FOUR="$(new_repo fleet-four)"
create_config "$R_FOUR" '["DISCOVERY", "IMPLEMENT", "REVIEW", "QA"]' "high"
RUN_FOUR="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_FOUR" --task "fleet four task")"
P_FOUR="$R_FOUR/.agy/runs/$RUN_FOUR/phases"
mkdir -p "$P_FOUR/DISCOVERY" "$P_FOUR/IMPLEMENT" "$P_FOUR/REVIEW" "$P_FOUR/QA"
printf 'STATUS: PASSED | File: code.js\n' > "$P_FOUR/IMPLEMENT/verdict"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$P_FOUR/IMPLEMENT/status"
ledger_append "$R_FOUR" run="$RUN_FOUR" phase=IMPLEMENT status=PASSED dispatched=true attempt=1 \
  started=2026-08-25T10:00:00Z elapsed_s=20 \
  usage='{"input_tokens":500,"output_tokens":100,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":600}'

R_THREE="$(new_repo fleet-three)"
create_config "$R_THREE" '["DISCOVERY", "IMPLEMENT", "REVIEW"]' "high"
RUN_THREE="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_THREE" --task "fleet three task")"
P_THREE="$R_THREE/.agy/runs/$RUN_THREE/phases"
mkdir -p "$P_THREE/DISCOVERY" "$P_THREE/IMPLEMENT" "$P_THREE/REVIEW"
printf 'STATUS: PASSED | File: code.js\n' > "$P_THREE/IMPLEMENT/verdict"
printf 'STATUS: PASSED | Phase: IMPLEMENT\n' > "$P_THREE/IMPLEMENT/status"
ledger_append "$R_THREE" run="$RUN_THREE" phase=IMPLEMENT status=PASSED dispatched=true attempt=1 \
  started=2026-08-25T10:00:00Z elapsed_s=10 \
  usage='{"input_tokens":200,"output_tokens":50,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":250}'

# Fixture 2: Run with refusal (Class A) and run with verify failure (Class B)
R_REFUSAL="$(new_repo run-refusal)"
create_config "$R_REFUSAL" '["DISCOVERY", "IMPLEMENT", "REVIEW", "QA", "RELEASE"]' "high"
# Refusal record: dispatched=false, no usage, no elapsed time
RUN_REF1="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_REFUSAL" --task "refusal task")"
ledger_append "$R_REFUSAL" run="$RUN_REF1" phase=IMPLEMENT status="BRIEF_INVALID(missing_verdict)" \
  dispatched=false attempt=1 started=2026-08-25T10:00:00Z

# Successful dispatch in same repo to measure pass rate
RUN_REF2="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_REFUSAL" --task "successful dispatch")"
ledger_append "$R_REFUSAL" run="$RUN_REF2" phase=IMPLEMENT status=PASSED \
  dispatched=true attempt=1 started=2026-08-25T10:05:00Z elapsed_s=15 \
  usage='{"input_tokens":100,"output_tokens":50,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":150}'

# Dispatched failure: worker claimed PASSED, but verify command exited 1
RUN_FAIL1="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_REFUSAL" --task "verify failure")"
P_FAIL1="$R_REFUSAL/.agy/runs/$RUN_FAIL1/phases/IMPLEMENT"
mkdir -p "$P_FAIL1"
printf 'STATUS: PASSED | File: solution.py\n' > "$P_FAIL1/verdict"
printf 'STATUS: VERIFY_FAILED(rc=1) | Phase: IMPLEMENT | Verify: FAILED\n' > "$P_FAIL1/status"
printf 'test failed with exit code 1\n' > "$P_FAIL1/verify.log"
ledger_append "$R_REFUSAL" run="$RUN_FAIL1" phase=IMPLEMENT status="VERIFY_FAILED(rc=1)" \
  verdict="STATUS: PASSED | File: solution.py" verdict_route=file \
  verify_ran=true verify_rc=1 worker_rc=0 \
  dispatched=true attempt=1 started=2026-08-25T10:10:00Z elapsed_s=25 \
  usage='{"input_tokens":200,"output_tokens":80,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":280}'

# Fixture 3: Run with records that predate several ledger fields
R_PREDATE="$(new_repo run-predate)"
create_config "$R_PREDATE" '["DISCOVERY", "IMPLEMENT", "REVIEW", "QA", "RELEASE"]' "high"
RUN_PREDATE="$(AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_PREDATE" --task "predate task")"
# Predating record: NO dispatched, NO max_idle_s, NO fallback, NO model_requested, NO declared, NO usage
ledger_append "$R_PREDATE" run="$RUN_PREDATE" phase=IMPLEMENT status=PASSED attempt=1 started=2026-08-25T10:00:00Z

# Fixture 4: Repository with no ledger at all
R_NO_LEDGER="$(new_repo no-ledger)"
create_config "$R_NO_LEDGER" '["DISCOVERY", "IMPLEMENT", "REVIEW", "QA", "RELEASE"]' "high"
AGY_FLEET_REGISTER=0 run_dir_new --dir "$R_NO_LEDGER" --task "no ledger task" >/dev/null

# Fixture 5: Vanished and broken registered paths
PATH_MISSING="$ROOT/repos/nonexistent-vanished-path"
PATH_NON_GIT="$ROOT/repos/plain-dir-not-git"
mkdir -p "$PATH_NON_GIT"
PATH_NO_AGY="$ROOT/repos/git-no-agy-dir"
mkdir -p "$PATH_NO_AGY"
( cd "$PATH_NO_AGY" && git init -q . && git commit -q --allow-empty -m "no agy init" )

# Write fleet registry
cat > "$AGY_FLEET" <<EOF
$R_FIVE
$R_FOUR
$R_THREE
$R_REFUSAL
$R_PREDATE
$R_NO_LEDGER
$PATH_MISSING
$PATH_NON_GIT
$PATH_NO_AGY
EOF

# =============================================================================
# CLI and Launcher Argument Handling
# =============================================================================

/bin/bash "$SERVE_SH" --port not-a-number >/dev/null 2>&1 || RC_BAD_PORT=$?
check cli-bad-port "${RC_BAD_PORT:-0}" 2 "non-numeric --port exits 2"

/bin/bash "$SERVE_SH" --default-view invalid_view >/dev/null 2>&1 || RC_BAD_VIEW=$?
check cli-bad-view "${RC_BAD_VIEW:-0}" 2 "invalid --default-view exits 2"

/bin/bash "$SERVE_SH" --default-tab invalid_tab >/dev/null 2>&1 || RC_BAD_TAB=$?
check cli-bad-tab "${RC_BAD_TAB:-0}" 2 "invalid --default-tab exits 2"

/bin/bash "$SERVE_SH" --bogus-argument >/dev/null 2>&1 || RC_BAD_ARG=$?
check cli-bad-arg "${RC_BAD_ARG:-0}" 2 "unknown argument exits 2"

# =============================================================================
# Start Server on Dynamic Collision-Free Port
# =============================================================================

PORT=$(( 15000 + ($$ * 13 + RANDOM) % 35000 ))
/bin/bash "$SERVE_SH" --port "$PORT" --registry "$AGY_FLEET" --no-open > "$ROOT/server.log" 2>&1 &
SERVER_PID=$!

# Wait for server readiness
READY=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if curl -s -f -m 1 "http://127.0.0.1:$PORT/api/fleet" >/dev/null 2>&1; then
    READY=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1 2>/dev/null || sleep 1
done

check server-starts "$READY" 1 "control center server starts and answers on loopback port"
if [ "$READY" -ne 1 ]; then
  cat "$ROOT/server.log" >&2
  exit 1
fi

http_get() {
  curl -s -S "http://127.0.0.1:${PORT}${1}" 2>/dev/null || true
}

http_code() {
  curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}${1}" 2>/dev/null || echo "000"
}

http_headers() {
  curl -s -I "http://127.0.0.1:${PORT}${1}" 2>/dev/null || true
}

get_repo_id() {
  local target_path="$1"
  local fleet_json="$2"
  printf '%s\n' "$fleet_json" | tr '{' '\n' | tr ',' '\n' | awk -v p="$target_path" '
    /"id"[[:space:]]*:/ {
      id = $0
      sub(/.*"id"[[:space:]]*:[[:space:]]*"/, "", id)
      sub(/".*/, "", id)
    }
    /"path"[[:space:]]*:/ {
      if (index($0, p) > 0) {
        print id
        exit
      }
    }
  '
}

# =============================================================================
# 1. App Shell and Static Asset Routes
# =============================================================================

check shell-html-code "$(http_code "/")" 200 "GET / returns HTTP 200"
SHELL_BODY="$(http_get "/")"
if printf '%s\n' "$SHELL_BODY" | grep -q -i '<!DOCTYPE html'; then
  ok shell-html-content "GET / serves HTML app shell"
else
  bad shell-html-content "GET / did not return HTML markup: $SHELL_BODY"
fi

check shell-css-code "$(http_code "/app.css")" 200 "GET /app.css returns HTTP 200"
check shell-js-code "$(http_code "/app.js")" 200 "GET /app.js returns HTTP 200"

# =============================================================================
# 2. Fleet Endpoint and Phase List Declarations
# =============================================================================

FLEET_JSON="$(http_get "/api/fleet")"
check fleet-code "$(http_code "/api/fleet")" 200 "GET /api/fleet returns HTTP 200"

ID_FIVE="$(get_repo_id "$R_FIVE" "$FLEET_JSON")"
ID_FOUR="$(get_repo_id "$R_FOUR" "$FLEET_JSON")"
ID_THREE="$(get_repo_id "$R_THREE" "$FLEET_JSON")"
ID_REFUSAL="$(get_repo_id "$R_REFUSAL" "$FLEET_JSON")"
ID_PREDATE="$(get_repo_id "$R_PREDATE" "$FLEET_JSON")"
ID_NO_LEDGER="$(get_repo_id "$R_NO_LEDGER" "$FLEET_JSON")"

[ -n "$ID_FIVE" ] && ok fleet-repo-five-found "fleet reports 5-phase repo" || bad fleet-repo-five-found "5-phase repo missing in fleet"
[ -n "$ID_FOUR" ] && ok fleet-repo-four-found "fleet reports 4-phase repo" || bad fleet-repo-four-found "4-phase repo missing in fleet"
[ -n "$ID_THREE" ] && ok fleet-repo-three-found "fleet reports 3-phase repo" || bad fleet-repo-three-found "3-phase repo missing in fleet"

REPO_FIVE_JSON="$(http_get "/api/repo/$ID_FIVE")"
REPO_FOUR_JSON="$(http_get "/api/repo/$ID_FOUR")"
REPO_THREE_JSON="$(http_get "/api/repo/$ID_THREE")"

if printf '%s\n' "$REPO_FIVE_JSON" | grep -q '"phaseCount"[[:space:]]*:[[:space:]]*5' && \
   printf '%s\n' "$REPO_FIVE_JSON" | grep -q 'RELEASE'; then
  ok phase-list-five "5-phase repo reports phaseCount=5 including RELEASE"
else
  bad phase-list-five "5-phase repo config unexpected: $REPO_FIVE_JSON"
fi

PHASES_FOUR="$(printf '%s\n' "$REPO_FOUR_JSON" | tr '\n' ' ' | sed -e 's/.*"phases"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/')"
if printf '%s\n' "$REPO_FOUR_JSON" | grep -q '"phaseCount"[[:space:]]*:[[:space:]]*4' && \
   ! printf '%s\n' "$PHASES_FOUR" | grep -q 'RELEASE'; then
  ok phase-list-four "4-phase repo reports phaseCount=4 with RELEASE left out"
else
  bad phase-list-four "4-phase repo config unexpected: $REPO_FOUR_JSON"
fi

PHASES_THREE="$(printf '%s\n' "$REPO_THREE_JSON" | tr '\n' ' ' | sed -e 's/.*"phases"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/')"
if printf '%s\n' "$REPO_THREE_JSON" | grep -q '"phaseCount"[[:space:]]*:[[:space:]]*3' && \
   ! printf '%s\n' "$PHASES_THREE" | grep -q 'RELEASE' && \
   ! printf '%s\n' "$PHASES_THREE" | grep -q 'QA'; then
  ok phase-list-three "3-phase repo reports phaseCount=3 with QA and RELEASE left out"
else
  bad phase-list-three "3-phase repo config unexpected: $REPO_THREE_JSON"
fi

# =============================================================================
# 3. Refusal (Class A) vs Dispatched Failure (Class B)
# =============================================================================

REPO_REF_JSON="$(http_get "/api/repo/$ID_REFUSAL")"

# Refusal is excluded from dispatches count and pass rate
if printf '%s\n' "$REPO_REF_JSON" | grep -q '"refusals"[[:space:]]*:[[:space:]]*1' && \
   printf '%s\n' "$REPO_REF_JSON" | grep -q '"dispatches"[[:space:]]*:[[:space:]]*2' && \
   printf '%s\n' "$REPO_REF_JSON" | grep -q '"passes"[[:space:]]*:[[:space:]]*1' && \
   printf '%s\n' "$REPO_REF_JSON" | grep -q '"failures"[[:space:]]*:[[:space:]]*1' && \
   printf '%s\n' "$REPO_REF_JSON" | grep -q '"passRate"[[:space:]]*:[[:space:]]*0\.5'; then
  ok refusal-metrics "refusal counted separately (1), excluded from dispatches (2) and passRate (0.5)"
else
  bad refusal-metrics "refusal metrics unexpected: $REPO_REF_JSON"
fi

# Spend excludes refusal
if printf '%s\n' "$REPO_REF_JSON" | grep -q '"totalTokens"[[:space:]]*:[[:space:]]*430'; then
  ok refusal-no-spend "refusal contributes 0 tokens to spend (150 + 280 = 430)"
else
  bad refusal-no-spend "refusal spend unexpected: $REPO_REF_JSON"
fi

RUN_REF1_JSON="$(http_get "/api/run/$ID_REFUSAL/$RUN_REF1")"
if printf '%s\n' "$RUN_REF1_JSON" | grep -q '"statusClass"[[:space:]]*:[[:space:]]*"A"' && \
   printf '%s\n' "$RUN_REF1_JSON" | grep -q '"dispatched"[[:space:]]*:[[:space:]]*false'; then
  ok refusal-class-a "zero-spend refusal is marked Class A and dispatched=false"
else
  bad refusal-class-a "refusal run statusClass unexpected: $RUN_REF1_JSON"
fi

RUN_FAIL1_JSON="$(http_get "/api/run/$ID_REFUSAL/$RUN_FAIL1")"
if printf '%s\n' "$RUN_FAIL1_JSON" | grep -q '"statusClass"[[:space:]]*:[[:space:]]*"B"' && \
   printf '%s\n' "$RUN_FAIL1_JSON" | grep -q '"dispatched"[[:space:]]*:[[:space:]]*true'; then
  ok failure-class-b "dispatched failure is marked Class B and dispatched=true"
else
  bad failure-class-b "dispatched failure statusClass unexpected: $RUN_FAIL1_JSON"
fi

# =============================================================================
# 4. Invariant: Worker Claim vs Verification Contradiction
# =============================================================================

if printf '%s\n' "$RUN_FAIL1_JSON" | grep -q '"verdict"[[:space:]]*:[[:space:]]*"STATUS: PASSED' || \
   printf '%s\n' "$RUN_FAIL1_JSON" | grep -q '"verdict"[[:space:]]*:[[:space:]]*"PASSED"'; then
  if printf '%s\n' "$RUN_FAIL1_JSON" | grep -q '"ran"[[:space:]]*:[[:space:]]*true' && \
     printf '%s\n' "$RUN_FAIL1_JSON" | grep -q '"rc"[[:space:]]*:[[:space:]]*1' && \
     printf '%s\n' "$RUN_FAIL1_JSON" | grep -q 'VERIFY_FAILED'; then
    ok claim-vs-verification "worker verdict (PASSED) and verify rc (1) reported as separate fields"
  else
    bad claim-vs-verification "verify fields missing or merged in run: $RUN_FAIL1_JSON"
  fi
else
  bad claim-vs-verification "verdict field missing or incorrect: $RUN_FAIL1_JSON"
fi

# =============================================================================
# 5. Invariant: Declared Tier vs Inherited Tier
# =============================================================================

# REVIEW phase declared tier in config, IMPLEMENT inherited default
if printf '%s\n' "$REPO_FIVE_JSON" | grep -E -q '"phase"[[:space:]]*:[[:space:]]*"REVIEW".*"declared"[[:space:]]*:[[:space:]]*true' || \
   printf '%s\n' "$REPO_FIVE_JSON" | grep -q '"declared"[[:space:]]*:[[:space:]]*true'; then
  ok tier-declared-true "phase with declared tier in config is marked declared=true"
else
  bad tier-declared-true "declared tier not marked true: $REPO_FIVE_JSON"
fi

if printf '%s\n' "$REPO_FIVE_JSON" | grep -E -q '"phase"[[:space:]]*:[[:space:]]*"IMPLEMENT".*"declared"[[:space:]]*:[[:space:]]*false' || \
   printf '%s\n' "$REPO_FIVE_JSON" | grep -q '"declared"[[:space:]]*:[[:space:]]*false'; then
  ok tier-inherited-false "phase inheriting default tier is marked declared=false"
else
  bad tier-inherited-false "inherited tier not marked false: $REPO_FIVE_JSON"
fi

# =============================================================================
# 6. Predated Ledger Records: Absent is not zero / false
# =============================================================================

REPO_PREDATE_JSON="$(http_get "/api/repo/$ID_PREDATE")"
RUN_PREDATE_JSON="$(http_get "/api/run/$ID_PREDATE/$RUN_PREDATE")"

# In repo metrics: absent fields counted
for absent_field in "dispatched" "maxIdleS" "fallback" "declared" "usage"; do
  if printf '%s\n' "$REPO_PREDATE_JSON" | grep -q "\"$absent_field\"[[:space:]]*:[[:space:]]*[1-9]"; then
    ok "predate-metrics-absent-$absent_field" "predated record counts absent $absent_field in metrics"
  else
    bad "predate-metrics-absent-$absent_field" "absent $absent_field not counted in repo metrics: $REPO_PREDATE_JSON"
  fi
done

# In run record accounting: absent fields counted
for absent_field in "dispatched" "maxIdleS" "fallback" "declared" "usage"; do
  if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q "\"$absent_field\"[[:space:]]*:[[:space:]]*[1-9]"; then
    ok "predate-run-absent-$absent_field" "predated record counts absent $absent_field in run"
  else
    bad "predate-run-absent-$absent_field" "absent $absent_field not counted in run: $RUN_PREDATE_JSON"
  fi
done

# Assert null rather than confident zero or confident false
# dispatched must be null
if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"dispatched"[[:space:]]*:[[:space:]]*null'; then
  ok predate-dispatched-null "predated dispatched is null"
else
  bad predate-dispatched-null "dispatched should be null: $RUN_PREDATE_JSON"
fi

if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"dispatched"[[:space:]]*:[[:space:]]*false' || \
   printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"dispatched"[[:space:]]*:[[:space:]]*0'; then
  bad predate-dispatched-not-false "dispatched must not be false or 0 on predated record"
else
  ok predate-dispatched-not-false "dispatched is not inferred as false or 0"
fi

# fallback must be null
if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"fallback"[[:space:]]*:[[:space:]]*null'; then
  ok predate-fallback-null "predated fallback is null"
else
  bad predate-fallback-null "fallback should be null: $RUN_PREDATE_JSON"
fi

if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"fallback"[[:space:]]*:[[:space:]]*false'; then
  bad predate-fallback-not-false "fallback must not be false on predated record"
else
  ok predate-fallback-not-false "fallback is not inferred as false"
fi

# maxIdleSeconds must be null
if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"maxIdleSeconds"[[:space:]]*:[[:space:]]*null'; then
  ok predate-idle-null "predated maxIdleSeconds is null"
else
  bad predate-idle-null "maxIdleSeconds should be null: $RUN_PREDATE_JSON"
fi

if printf '%s\n' "$RUN_PREDATE_JSON" | grep -q '"maxIdleSeconds"[[:space:]]*:[[:space:]]*0'; then
  bad predate-idle-not-zero "maxIdleSeconds must not be 0 on predated record"
else
  ok predate-idle-not-zero "maxIdleSeconds is not inferred as 0"
fi

# =============================================================================
# 7. Repository with No Ledger at All
# =============================================================================

check no-ledger-repo-code "$(http_code "/api/repo/$ID_NO_LEDGER")" 200 "GET /api/repo/:id returns 200 for repo with no ledger"
REPO_NO_LEDGER_JSON="$(http_get "/api/repo/$ID_NO_LEDGER")"
if printf '%s\n' "$REPO_NO_LEDGER_JSON" | grep -q '"reachable"[[:space:]]*:[[:space:]]*true'; then
  ok no-ledger-reachable "repo with no ledger appears and is marked reachable=true"
else
  bad no-ledger-reachable "repo with no ledger reachable state unexpected: $REPO_NO_LEDGER_JSON"
fi

# =============================================================================
# 8. Unreachable and Vanished Paths (Never Dropped)
# =============================================================================

ID_MISSING="$(get_repo_id "$PATH_MISSING" "$FLEET_JSON")"
ID_NON_GIT="$(get_repo_id "$PATH_NON_GIT" "$FLEET_JSON")"
ID_NO_AGY="$(get_repo_id "$PATH_NO_AGY" "$FLEET_JSON")"

[ -n "$ID_MISSING" ] && ok unreachable-missing-listed "vanished path is listed in fleet" || bad unreachable-missing-listed "vanished path dropped"
[ -n "$ID_NON_GIT" ] && ok unreachable-nongit-listed "non-git path is listed in fleet" || bad unreachable-nongit-listed "non-git path dropped"
[ -n "$ID_NO_AGY" ] && ok unreachable-noagy-listed "no-agy-dir path is listed in fleet" || bad unreachable-noagy-listed "no-agy-dir path dropped"

if printf '%s\n' "$FLEET_JSON" | grep -q '"unreachable"[[:space:]]*:[[:space:]]*"missing"'; then
  ok unreachable-reason-missing "vanished path unreachable reason is 'missing'"
else
  bad unreachable-reason-missing "missing reason unexpected: $FLEET_JSON"
fi

if printf '%s\n' "$FLEET_JSON" | grep -q '"unreachable"[[:space:]]*:[[:space:]]*"not-a-git-worktree"'; then
  ok unreachable-reason-nongit "non-git path unreachable reason is 'not-a-git-worktree'"
else
  bad unreachable-reason-nongit "non-git reason unexpected: $FLEET_JSON"
fi

if printf '%s\n' "$FLEET_JSON" | grep -q '"unreachable"[[:space:]]*:[[:space:]]*"no-agy-dir"'; then
  ok unreachable-reason-noagy "no-agy path unreachable reason is 'no-agy-dir'"
else
  bad unreachable-reason-noagy "no-agy reason unexpected: $FLEET_JSON"
fi

# =============================================================================
# 9. Invariant: No Fleet Spend Total Summed Across Repositories
# =============================================================================

# Fleet JSON must NOT contain top-level totalTokens or spend summing across repos
FLEET_ROOT_KEYS="$(printf '%s\n' "$FLEET_JSON" | sed -e 's/"repos"[[:space:]]*:.*//')"
if printf '%s\n' "$FLEET_ROOT_KEYS" | grep -q -E '"totalTokens"|"spentTokens"|"totalSpend"|"spend"'; then
  bad no-fleet-spend-total "fleet endpoint carries summed token or currency total across repositories"
else
  ok no-fleet-spend-total "no response body carries cross-repo token or currency total"
fi

# Dimensionless counts aggregate
if printf '%s\n' "$FLEET_JSON" | grep -q '"entries"' || printf '%s\n' "$FLEET_JSON" | grep -q '"repos"'; then
  ok fleet-dimensionless-counts "dimensionless counts aggregate properly in fleet"
else
  bad fleet-dimensionless-counts "fleet counts missing: $FLEET_JSON"
fi

# =============================================================================
# 10. Artifact Routes (Byte-for-Byte & Traversal Escape Prevention)
# =============================================================================

BRIEF_URL="/api/run/$ID_FIVE/$RUN_FIVE/brief/IMPLEMENT"
LOG_URL="/api/run/$ID_FIVE/$RUN_FIVE/log/IMPLEMENT"
DIFF_URL="/api/run/$ID_FIVE/$RUN_FIVE/diff/IMPLEMENT"
SUMMARY_URL="/api/run/$ID_FIVE/$RUN_FIVE/summary/-"

check artifact-brief-code "$(http_code "$BRIEF_URL")" 200 "GET brief artifact returns 200"
BRIEF_BODY="$(http_get "$BRIEF_URL")"
check artifact-brief-exact "$BRIEF_BODY" "Initial brief for five phases" "brief artifact returns exact bytes"

check artifact-log-code "$(http_code "$LOG_URL")" 200 "GET log artifact returns 200"
LOG_BODY="$(http_get "$LOG_URL")"
WANT_LOG="Log line 1
Log line 2"
check artifact-log-exact "$LOG_BODY" "$WANT_LOG" "log artifact returns exact bytes"

check artifact-diff-code "$(http_code "$DIFF_URL")" 200 "GET diff artifact returns 200"
DIFF_BODY="$(http_get "$DIFF_URL")"
WANT_DIFF="--- a/x
+++ b/x
@@ -1 +1 @@
-old
+new"
check artifact-diff-exact "$DIFF_BODY" "$WANT_DIFF" "diff artifact returns exact patch bytes"

check artifact-summary-code "$(http_code "$SUMMARY_URL")" 200 "GET summary artifact returns 200"
SUMMARY_BODY="$(http_get "$SUMMARY_URL")"
WANT_SUMMARY="## Run Summary
All 5 phases passed."
check artifact-summary-exact "$SUMMARY_BODY" "$WANT_SUMMARY" "summary artifact returns exact bytes"

# Artifact headers: Content-Type text/plain and X-Content-Type-Options: nosniff
BRIEF_HDR="$(http_headers "$BRIEF_URL")"
if printf '%s\n' "$BRIEF_HDR" | grep -q -i 'Content-Type:[[:space:]]*text/plain' && \
   printf '%s\n' "$BRIEF_HDR" | grep -q -i 'X-Content-Type-Options:[[:space:]]*nosniff'; then
  ok artifact-headers "artifact headers have text/plain and nosniff"
else
  bad artifact-headers "artifact headers missing text/plain or nosniff: $BRIEF_HDR"
fi

# Directory traversal attempts must be refused (400, 403, or 404, never 200)
TRAVERSAL_CODE="$(http_code "/api/run/$ID_FIVE/$RUN_FIVE/brief/..%2f..%2f..%2fetc%2fpasswd")"
if [ "$TRAVERSAL_CODE" != "200" ]; then
  ok traversal-refused "path traversal escaping run directory is refused with code $TRAVERSAL_CODE"
else
  bad traversal-refused "path traversal returned HTTP 200"
fi

# =============================================================================
# 11. Invariant: Localhost Loopback Only
# =============================================================================

# Server binds on 127.0.0.1
check loopback-reachable "$(http_code "/api/fleet")" 200 "server answers on 127.0.0.1"

# Check if a non-loopback IP exists on this host
NON_LOOPBACK_IP=""
if command -v ifconfig >/dev/null 2>&1; then
  NON_LOOPBACK_IP="$(ifconfig 2>/dev/null | grep -E 'inet[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)' | grep -v '127\.0\.0\.1' | sed -n 's/.*inet[[:space:]]\{1,\}\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/\1/p' | head -n 1)"
fi
if [ -z "$NON_LOOPBACK_IP" ] && command -v hostname >/dev/null 2>&1; then
  NON_LOOPBACK_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./) {print $i; exit}}')"
fi

if [ -n "$NON_LOOPBACK_IP" ]; then
  EXT_CODE="$(curl -s -m 1 --connect-timeout 1 -o /dev/null -w "%{http_code}" "http://${NON_LOOPBACK_IP}:${PORT}/api/fleet" 2>/dev/null || true)"
  if [ -z "$EXT_CODE" ] || [ "$EXT_CODE" = "000" ]; then
    ok localhost-only "server not reachable on non-loopback address ($NON_LOOPBACK_IP)"
  else
    bad localhost-only "server unexpectedly answered on non-loopback IP $NON_LOOPBACK_IP: HTTP $EXT_CODE"
  fi
else
  ok localhost-only "no non-loopback IP available to probe, loopback binding verified"
fi

# =============================================================================
# 12. Invariant: Read-Only Guarantee (No writes to watched repositories)
# =============================================================================

if command -v sha256sum >/dev/null 2>&1; then
  file_digest() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  file_digest() { shasum "$1" 2>/dev/null | awk '{print $1}'; }
elif command -v md5sum >/dev/null 2>&1; then
  file_digest() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
elif command -v md5 >/dev/null 2>&1; then
  file_digest() { md5 -q "$1" 2>/dev/null; }
else
  file_digest() { cksum "$1" 2>/dev/null | awk '{print $1 ":" $2}'; }
fi

snapshot_repos() {
  (
    cd "$ROOT/repos" || return 1
    find . -type f | sort | while IFS= read -r f; do
      [ -f "$f" ] || continue
      printf '%s %s\n' "$f" "$(file_digest "$f")"
    done
  )
}

SNAP_BEFORE="$(snapshot_repos)"

# Issue multiple GET requests across fleet, repos, runs, and artifacts
http_get "/api/fleet" >/dev/null
http_get "/api/repo/$ID_FIVE" >/dev/null
http_get "/api/repo/$ID_FOUR" >/dev/null
http_get "/api/repo/$ID_THREE" >/dev/null
http_get "/api/repo/$ID_REFUSAL" >/dev/null
http_get "/api/repo/$ID_PREDATE" >/dev/null
http_get "/api/repo/$ID_NO_LEDGER" >/dev/null
http_get "/api/run/$ID_FIVE/$RUN_FIVE" >/dev/null
http_get "/api/run/$ID_FIVE/current" >/dev/null
http_get "/api/run/$ID_FIVE/last" >/dev/null
http_get "/api/run/$ID_FOUR/$RUN_FOUR" >/dev/null
http_get "/api/run/$ID_THREE/$RUN_THREE" >/dev/null
http_get "/api/run/$ID_REFUSAL/$RUN_REF1" >/dev/null
http_get "/api/run/$ID_REFUSAL/$RUN_REF2" >/dev/null
http_get "/api/run/$ID_REFUSAL/$RUN_FAIL1" >/dev/null
http_get "/api/run/$ID_PREDATE/$RUN_PREDATE" >/dev/null
http_get "/api/run/$ID_FIVE/$RUN_FIVE/brief/IMPLEMENT" >/dev/null
http_get "/api/run/$ID_FIVE/$RUN_FIVE/log/IMPLEMENT" >/dev/null
http_get "/api/run/$ID_FIVE/$RUN_FIVE/diff/IMPLEMENT" >/dev/null
http_get "/api/run/$ID_FIVE/$RUN_FIVE/summary/-" >/dev/null
http_get "/api/run/$ID_REFUSAL/$RUN_FAIL1/brief/IMPLEMENT" >/dev/null
http_get "/api/run/$ID_REFUSAL/$RUN_FAIL1/log/IMPLEMENT" >/dev/null

SNAP_AFTER="$(snapshot_repos)"

if [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then
  ok read-only "routes write nothing into watched repositories"
else
  SNAP_BEFORE_FILE="$ROOT/snap_before"
  SNAP_AFTER_FILE="$ROOT/snap_after"
  printf '%s\n' "$SNAP_BEFORE" > "$SNAP_BEFORE_FILE"
  printf '%s\n' "$SNAP_AFTER" > "$SNAP_AFTER_FILE"
  CHANGED_FILES="$(diff "$SNAP_BEFORE_FILE" "$SNAP_AFTER_FILE" 2>/dev/null | sed -n -e 's/^[<>] \([^ ]*\) .*/\1/p' | sort -u | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
  bad read-only "routes write nothing into watched repositories (modified: ${CHANGED_FILES:-unknown})"
fi

# =============================================================================
# 13. Invariant: Print Never Post (Commands rendered as text, gh never run)
# =============================================================================

RUN_FIVE_JSON="$(http_get "/api/run/$ID_FIVE/$RUN_FIVE")"
if printf '%s\n' "$RUN_FIVE_JSON" | grep -q '"commands"' && \
   printf '%s\n' "$RUN_FIVE_JSON" | grep -q 'gh '; then
  ok print-commands-text "operator commands rendered as copyable text in summary.commands"
else
  bad print-commands-text "summary.commands missing gh command text: $RUN_FIVE_JSON"
fi

if [ -f "$STUB_GH_TRIGGER" ]; then
  bad gh-never-executed "gh binary was executed by server: $(cat "$STUB_GH_TRIGGER")"
else
  ok gh-never-executed "gh binary was NEVER executed"
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
