#!/usr/bin/env bash
# Exercise check-secrets.sh: that secrets in briefs and diffs are refused without
# echoing the secret value, that placeholders do not fire, that phase.sh enforces
# the scan before dispatch, and that --no-secret-scan bypasses it.
#
#   tests/check-secrets.sh
#
# Runs against throwaway repos under ${TMPDIR:-/tmp}. Nothing is written inside
# this repo. Prints one line per case and exits non-zero if any case fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../scripts/check-secrets.sh"
PHASE_SH="$HERE/../scripts/phase.sh"
RUN_DIR_SH="$HERE/../scripts/run-dir.sh"

[ -f "$CHECK" ] || { echo "check-secrets-test: check-secrets.sh not found next door" >&2; exit 2; }
[ -f "$PHASE_SH" ] || { echo "check-secrets-test: phase.sh not found next door" >&2; exit 2; }
[ -f "$RUN_DIR_SH" ] || { echo "check-secrets-test: run-dir.sh not found next door" >&2; exit 2; }

# shellcheck source=../scripts/run-dir.sh
. "$RUN_DIR_SH"

ROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-secrets.XXXXXX")" && pwd)"
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '%-34s ok   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL + 1)); printf '%-34s FAIL %s\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1" "$4"; else bad "$1" "$4 (got '$2', want '$3')"; fi; }

# Stub agy for phase.sh tests
STUB="$ROOT/agy"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)\ngemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
  exit 0
fi
[ -n "${STUB_CALLED_FILE:-}" ] && printf '1\n' >> "$STUB_CALLED_FILE"
if [ -f .agy/current ]; then
  CUR_RUN="$(cat .agy/current 2>/dev/null || true)"
  if [ -n "$CUR_RUN" ]; then
    mkdir -p ".agy/runs/$CUR_RUN/phases/${STUB_PHASE:-TEST}"
    printf '%b\n' "${STUB_VERDICT:-STATUS: DONE | File: CHANGES.md}" > ".agy/runs/$CUR_RUN/phases/${STUB_PHASE:-TEST}/verdict"
  fi
fi
printf '%b\n' "${STUB_VERDICT:-STATUS: DONE | File: CHANGES.md}"
exit 0
STUB_EOF
chmod +x "$STUB"

# Helper to create a throwaway repo
new_repo() {
  local name="$1"
  local r="$ROOT/repos/$name"
  mkdir -p "$r"
  ( cd "$r" && git init -q . && git config user.email "test@example.com" \
      && git config user.name "Tester" && git commit -q --allow-empty -m "initial" )
  local run_id
  run_id="$(run_dir_new --dir "$r" --task "secret test $name")"
  [ -n "$run_id" ] || { echo "check-secrets-test: run_dir_new failed for $name" >&2; exit 2; }
  printf '%s' "$r"
}

run_check() {
  OUT="$(/bin/bash "$CHECK" "$@" 2>/dev/null)"
  CODE=$?
}

# --- 1. Pattern fixture: private_key header in brief -------------------------
R="$(new_repo privkey-brief)"
BRIEF="$R/brief.md"
cat > "$BRIEF" <<'EOF'
# Task
Deploy with the following configuration:
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Y...
-----END RSA PRIVATE KEY-----
EOF
run_check --dir "$R" --brief "$BRIEF"
check privkey-rc "$CODE" 3 "exit 3 on private key in brief"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(private_key, brief.md:3)"*)
    ok privkey-status "reported SECRETS_FOUND(private_key, brief.md:3)" ;;
  *) bad privkey-status "unexpected output: $OUT" ;;
esac

# --- 2. Pattern fixture: generic private key (BEGIN PRIVATE KEY) -------------
BRIEF_GEN="$R/brief_gen.md"
cat > "$BRIEF_GEN" <<'EOF'
# Setup
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7...
-----END PRIVATE KEY-----
EOF
run_check --dir "$R" --brief "$BRIEF_GEN"
check privkey-gen-rc "$CODE" 3 "exit 3 on generic private key"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(private_key, brief_gen.md:2)"*)
    ok privkey-gen-status "reported SECRETS_FOUND(private_key, brief_gen.md:2)" ;;
  *) bad privkey-gen-status "unexpected output: $OUT" ;;
esac

# --- 3. Pattern fixture: AWS access key ID -----------------------------------
BRIEF_AWS="$R/brief_aws.md"
SECRET_AWS="AKIA1234567890ABCDEF"
cat > "$BRIEF_AWS" <<EOF
Use credentials: AWS_ACCESS_KEY_ID=$SECRET_AWS
EOF
run_check --dir "$R" --brief "$BRIEF_AWS"
check aws-rc "$CODE" 3 "exit 3 on AWS access key ID"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(aws_access_key, brief_aws.md:1)"*)
    ok aws-status "reported SECRETS_FOUND(aws_access_key, brief_aws.md:1)" ;;
  *) bad aws-status "unexpected output: $OUT" ;;
esac
case "$OUT" in
  *"$SECRET_AWS"*) bad aws-no-echo "output contained secret AWS key value" ;;
  *) ok aws-no-echo "output did not contain secret AWS key value" ;;
esac

# --- 4. Pattern fixture: GitHub token ----------------------------------------
BRIEF_GH="$R/brief_gh.md"
SECRET_GH="ghp_1234567890abcdef1234567890abcdef12"
cat > "$BRIEF_GH" <<EOF
GITHUB_TOKEN=$SECRET_GH
EOF
run_check --dir "$R" --brief "$BRIEF_GH"
check gh-rc "$CODE" 3 "exit 3 on GitHub token"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(github_token, brief_gh.md:1)"*)
    ok gh-status "reported SECRETS_FOUND(github_token, brief_gh.md:1)" ;;
  *) bad gh-status "unexpected output: $OUT" ;;
esac
case "$OUT" in
  *"$SECRET_GH"*) bad gh-no-echo "output contained secret GitHub token value" ;;
  *) ok gh-no-echo "output did not contain secret GitHub token value" ;;
esac

# --- 5. Pattern fixture: Slack token -----------------------------------------
BRIEF_SLACK="$R/brief_slack.md"
SECRET_SLACK="xoxb-123456789012-1234567890123-abcdef123456"
cat > "$BRIEF_SLACK" <<EOF
SLACK_BOT_TOKEN=$SECRET_SLACK
EOF
run_check --dir "$R" --brief "$BRIEF_SLACK"
check slack-rc "$CODE" 3 "exit 3 on Slack token"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(slack_token, brief_slack.md:1)"*)
    ok slack-status "reported SECRETS_FOUND(slack_token, brief_slack.md:1)" ;;
  *) bad slack-status "unexpected output: $OUT" ;;
esac
case "$OUT" in
  *"$SECRET_SLACK"*) bad slack-no-echo "output contained secret Slack token value" ;;
  *) ok slack-no-echo "output did not contain secret Slack token value" ;;
esac

# --- 6. Pattern fixture: Google API key --------------------------------------
BRIEF_GOOGLE="$R/brief_google.md"
SECRET_GOOGLE="AIzaSyA1234567890123456789012345678901"
cat > "$BRIEF_GOOGLE" <<EOF
API_KEY=$SECRET_GOOGLE
EOF
run_check --dir "$R" --brief "$BRIEF_GOOGLE"
check google-rc "$CODE" 3 "exit 3 on Google API key"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(google_api_key, brief_google.md:1)"*)
    ok google-status "reported SECRETS_FOUND(google_api_key, brief_google.md:1)" ;;
  *) bad google-status "unexpected output: $OUT" ;;
esac
case "$OUT" in
  *"$SECRET_GOOGLE"*) bad google-no-echo "output contained secret Google API key value" ;;
  *) ok google-no-echo "output did not contain secret Google API key value" ;;
esac

# --- 7. Pattern fixture: .env-style secret assignment ------------------------
BRIEF_ENV="$R/brief_env.md"
SECRET_ENV="SuperSecretP@ssw0rd!123"
cat > "$BRIEF_ENV" <<EOF
DATABASE_PASSWORD=$SECRET_ENV
EOF
run_check --dir "$R" --brief "$BRIEF_ENV"
check env-rc "$CODE" 3 "exit 3 on .env secret assignment"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(env_secret, brief_env.md:1)"*)
    ok env-status "reported SECRETS_FOUND(env_secret, brief_env.md:1)" ;;
  *) bad env-status "unexpected output: $OUT" ;;
esac
case "$OUT" in
  *"$SECRET_ENV"*) bad env-no-echo "output contained secret env value" ;;
  *) ok env-no-echo "output did not contain secret env value" ;;
esac

# --- 8. Placeholder-laden .env that must NOT fire ----------------------------
BRIEF_PLACEHOLDERS="$R/brief_placeholders.md"
cat > "$BRIEF_PLACEHOLDERS" <<'EOF'
# Sample configuration
PASSWORD=changeme
API_KEY=your-key-here
SECRET_TOKEN=YOUR_TOKEN_HERE
AUTH_KEY=<insert-key>
DB_PASS=
CLIENT_SECRET=xxx
AWS_SECRET=dummy
API_KEY=test
PRIVATE_KEY=TODO
TOKEN=example
SECRET=...
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
DATABASE_URL=postgres://user:pass@localhost:5432/mydb
EOF
run_check --dir "$R" --brief "$BRIEF_PLACEHOLDERS"
check placeholders-rc "$CODE" 0 "exit 0 on placeholder .env"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*)
    ok placeholders-status "reported SECRETS_NONE for placeholders" ;;
  *) bad placeholders-status "unexpected output: $OUT" ;;
esac

# --- 9. Diff containing a private key that must fire -------------------------
R_DIFF="$(new_repo diff-privkey)"
RUN_ID_DIFF="$(cat "$R_DIFF/.agy/current")"
PATCH_FILE="$R_DIFF/.agy/runs/$RUN_ID_DIFF/REVIEW_DIFF.patch"
cat > "$PATCH_FILE" <<'EOF'
diff --git a/keys/server.key b/keys/server.key
new file mode 100644
--- /dev/null
+++ b/keys/server.key
@@ -0,0 +1,5 @@
++-----BEGIN RSA PRIVATE KEY-----
++MIIEowIBAAKCAQEA0Y...
++-----END RSA PRIVATE KEY-----
EOF
run_check --dir "$R_DIFF" --diff "$PATCH_FILE"
check diff-privkey-rc "$CODE" 3 "exit 3 on private key in diff"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(private_key, "*".agy/runs/$RUN_ID_DIFF/REVIEW_DIFF.patch:6)"*)
    ok diff-privkey-status "reported SECRETS_FOUND in diff" ;;
  *) bad diff-privkey-status "unexpected output: $OUT" ;;
esac

# --- 10. phase.sh refusing without invoking a worker -------------------------
R_PHASE="$(new_repo phase-refuse)"
RUN_ID_PHASE="$(cat "$R_PHASE/.agy/current")"
BRIEF_LEAK="$R_PHASE/.agy/runs/$RUN_ID_PHASE/phases/IMPLEMENT/brief.md"
mkdir -p "$(dirname "$BRIEF_LEAK")"
SECRET_PHASE="AKIA999988887777ZZZZ"
cat > "$BRIEF_LEAK" <<EOF
# Phase 1: Implementation
Goal: implement with API key $SECRET_PHASE

Rules:
- Do not run shell commands.
- Do not touch git. No commits.
- Write nothing outside this repo.

Output Contract:
Write your one-line verdict to .agy/runs/$RUN_ID_PHASE/phases/IMPLEMENT/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

CALLED_LOG="$R_PHASE/worker_called.log"
rm -f "$CALLED_LOG"

PHASE_OUT="$(STUB_PHASE=IMPLEMENT STUB_CALLED_FILE="$CALLED_LOG" AGY_BIN="$STUB" \
  /bin/bash "$PHASE_SH" --phase IMPLEMENT --run "$RUN_ID_PHASE" --brief "$BRIEF_LEAK" --dir "$R_PHASE" --no-preflight 2>/dev/null)"
PHASE_RC=$?

check phase-refuse-rc "$PHASE_RC" 3 "phase.sh exited 3 on secret detection"
case "$PHASE_OUT" in
  *"STATUS: SECRETS_FOUND(aws_access_key, "*":2)"*)
    ok phase-refuse-status "phase.sh reported SECRETS_FOUND" ;;
  *) bad phase-refuse-status "unexpected phase.sh output: $PHASE_OUT" ;;
esac

# Check that worker was never called
if [ -f "$CALLED_LOG" ]; then
  bad phase-worker-not-called "worker was invoked despite secret detection"
else
  ok phase-worker-not-called "worker was not invoked"
fi

# Check that secret value was not printed by phase.sh
case "$PHASE_OUT" in
  *"$SECRET_PHASE"*) bad phase-no-echo "phase.sh output contained secret value" ;;
  *) ok phase-no-echo "phase.sh output did not contain secret value" ;;
esac

# --- 11. --no-secret-scan dispatching anyway ---------------------------------
STUB_PHASE=IMPLEMENT STUB_CALLED_FILE="$CALLED_LOG" AGY_BIN="$STUB" \
  /bin/bash "$PHASE_SH" --phase IMPLEMENT --run "$RUN_ID_PHASE" --brief "$BRIEF_LEAK" --dir "$R_PHASE" --no-preflight --no-secret-scan >/dev/null 2>&1
PHASE_BYPASS_RC=$?

check phase-bypass-rc "$PHASE_BYPASS_RC" 0 "phase.sh exited 0 with --no-secret-scan"
if [ -f "$CALLED_LOG" ]; then
  ok phase-bypass-called "worker was invoked with --no-secret-scan"
else
  bad phase-bypass-called "worker was not invoked with --no-secret-scan"
fi

# --- 12. SECRETS_UNCHECKED when no files provided ----------------------------
R_EMPTY="$(new_repo unchecked-case)"
run_check --dir "$R_EMPTY"
check unchecked-rc "$CODE" 0 "exit 0 on SECRETS_UNCHECKED"
case "$OUT" in
  *"STATUS: SECRETS_UNCHECKED(no_files_scanned)"*)
    ok unchecked-status "reported SECRETS_UNCHECKED" ;;
  *) bad unchecked-status "unexpected output: $OUT" ;;
esac

# --- 13. Ordering: brief with both a secret and a lint violation -------------
# A brief carrying both a credential and a lint violation (e.g. wrong phase verdict path)
# must refuse on SECRETS_FOUND, not BRIEF_INVALID, because disclosure takes precedence.
R_ORDER="$(new_repo order-test)"
RUN_ID_ORDER="$(cat "$R_ORDER/.agy/current")"
BRIEF_ORDER="$R_ORDER/.agy/runs/$RUN_ID_ORDER/phases/IMPLEMENT/brief.md"
mkdir -p "$(dirname "$BRIEF_ORDER")"
SECRET_ORDER="AKIA1111222233334444"
cat > "$BRIEF_ORDER" <<EOF
# Phase 1: Implementation
Goal: do the work with key $SECRET_ORDER

Rules:
- Do not run shell commands.
- Do not touch git. No commits.
- Write nothing outside this repo.

Output Contract:
Write your one-line verdict to .agy/runs/$RUN_ID_ORDER/phases/WRONG_PHASE/verdict, and print that same line as the last line of your output in the form STATUS: DONE | File: CHANGES.md.
EOF

ORDER_LOG="$R_ORDER/worker_called.log"
rm -f "$ORDER_LOG"
ORDER_OUT="$(STUB_PHASE=IMPLEMENT STUB_CALLED_FILE="$ORDER_LOG" AGY_BIN="$STUB" \
  /bin/bash "$PHASE_SH" --phase IMPLEMENT --run "$RUN_ID_ORDER" --brief "$BRIEF_ORDER" --dir "$R_ORDER" --no-preflight 2>/dev/null)"
ORDER_RC=$?

check order-rc "$ORDER_RC" 3 "phase.sh exited 3 on dual secret+lint violation"
case "$ORDER_OUT" in
  *"STATUS: SECRETS_FOUND(aws_access_key, "*":2)"*)
    ok order-status "phase.sh reported SECRETS_FOUND instead of BRIEF_INVALID" ;;
  *) bad order-status "unexpected phase.sh output: $ORDER_OUT" ;;
esac

# --- 14. Documentation line with config syntax / backticks / doc words --------
R_DOC="$(new_repo doc-config)"
BRIEF_DOC="$R_DOC/brief_doc.md"
cat > "$BRIEF_DOC" <<'EOF'
# Configuration syntax
The configuration supports:
`key = "value"`, `key = 123`, and `key = ["a", "b"]` on one line.
API_KEY=value
SECRET_TOKEN=key
AUTH_KEY=token
DATABASE_PASSWORD=secret
CLIENT_SECRET=example
EOF
run_check --dir "$R_DOC" --brief "$BRIEF_DOC"
check doc-config-rc "$CODE" 0 "exit 0 on config syntax and documentation words"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*)
    ok doc-config-status "reported SECRETS_NONE for config documentation" ;;
  *) bad doc-config-status "unexpected output: $OUT" ;;
esac

# --- 15. Fenced code block containing an env assignment -----------------------
R_FENCE="$(new_repo fence-env)"
BRIEF_FENCE="$R_FENCE/brief_fence.md"
cat > "$BRIEF_FENCE" <<'EOF'
# Example .env configuration
```bash
DATABASE_PASSWORD=SuperSecretP@ssw0rd!123
API_KEY=SuperSecretApiKey99999
```
EOF
run_check --dir "$R_FENCE" --brief "$BRIEF_FENCE"
check fence-env-rc "$CODE" 0 "exit 0 on assignment inside fenced code block"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*)
    ok fence-env-status "reported SECRETS_NONE for assignment in fenced block" ;;
  *) bad fence-env-status "unexpected output: $OUT" ;;
esac

# --- 16. Fenced code block containing high-confidence secrets must still fire -
R_FENCE_HIGH="$(new_repo fence-high-conf)"
BRIEF_FENCE_HIGH="$R_FENCE_HIGH/brief_fence_high.md"
cat > "$BRIEF_FENCE_HIGH" <<'EOF'
# Cloud credentials
```bash
AWS_ACCESS_KEY_ID=AKIA1234567890ABCDEF
```
EOF
run_check --dir "$R_FENCE_HIGH" --brief "$BRIEF_FENCE_HIGH"
check fence-high-rc "$CODE" 3 "exit 3 on AWS key inside fenced block"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(aws_access_key, "*":3)"*)
    ok fence-high-status "reported SECRETS_FOUND for AWS key in fenced block" ;;
  *) bad fence-high-status "unexpected output: $OUT" ;;
esac

# --- 17. Variable references in assignments must not fire --------------------
R_VAR="$(new_repo var-ref)"
BRIEF_VAR="$R_VAR/brief_var.md"
cat > "$BRIEF_VAR" <<'EOF'
# Variable reference configuration
DATABASE_PASSWORD=$MY_DATABASE_PASSWORD
API_KEY=${MY_API_KEY}
AUTH_TOKEN=$(cat /tmp/token)
EOF
run_check --dir "$R_VAR" --brief "$BRIEF_VAR"
check var-ref-rc "$CODE" 0 "exit 0 on variable reference assignments"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*)
    ok var-ref-status "reported SECRETS_NONE for variable references" ;;
  *) bad var-ref-status "unexpected output: $OUT" ;;
esac

# --- 18. Angle brackets in assignments must not fire -------------------------
R_ANGLE="$(new_repo angle-brackets)"
BRIEF_ANGLE="$R_ANGLE/brief_angle.md"
cat > "$BRIEF_ANGLE" <<'EOF'
# Angle bracket configuration
DATABASE_PASSWORD=<insert-db-password-here>
API_KEY=<YOUR_API_KEY>
AUTH_TOKEN=<token>
EOF
run_check --dir "$R_ANGLE" --brief "$BRIEF_ANGLE"
check angle-brackets-rc "$CODE" 0 "exit 0 on angle bracket assignments"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*)
    ok angle-brackets-status "reported SECRETS_NONE for angle bracket values" ;;
  *) bad angle-brackets-status "unexpected output: $OUT" ;;
esac

# --- 19. Values of 3 characters or fewer must not fire -----------------------
R_SHORT="$(new_repo short-values)"
BRIEF_SHORT="$R_SHORT/brief_short.md"
cat > "$BRIEF_SHORT" <<'EOF'
# Short value configuration
API_KEY=abc
DATABASE_PASSWORD=123
SECRET_TOKEN=xyz
EOF
run_check --dir "$R_SHORT" --brief "$BRIEF_SHORT"
check short-values-rc "$CODE" 0 "exit 0 on 3-char values"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*)
    ok short-values-status "reported SECRETS_NONE for short values" ;;
  *) bad short-values-status "unexpected output: $OUT" ;;
esac

# --- 20. Diff editing pattern list inside scripts/check-secrets.sh ------------
R_SELF="$(new_repo self-diff)"
PATCH_SELF="$R_SELF/self.patch"
cat > "$PATCH_SELF" <<'EOF'
diff --git a/scripts/check-secrets.sh b/scripts/check-secrets.sh
--- a/scripts/check-secrets.sh
+++ b/scripts/check-secrets.sh
@@ -148,3 +148,3 @@
-    *ghp_*|*gho_*|*ghu_*|*ghs_*|*ghr_*|*github_pat_*) ;;
+    *ghp_*|*gho_*|*ghu_*|*ghs_*|*ghr_*|*github_pat_*|*ghx_*) ;;
     *) return 1 ;;
EOF
run_check --dir "$R_SELF" --diff "$PATCH_SELF"
check self-diff-rc "$CODE" 0 "exit 0 on diff editing scanner pattern definitions"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*"| Skipped: scripts/check-secrets.sh, tests/check-secrets.sh"*)
    ok self-diff-status "reported SECRETS_NONE and named skipped scanner paths" ;;
  *) bad self-diff-status "unexpected output: $OUT" ;;
esac

# --- 21. Diff adding credential-shaped line to other file still refused -------
R_OTHER="$(new_repo other-file-diff)"
PATCH_OTHER="$R_OTHER/other.patch"
cat > "$PATCH_OTHER" <<'EOF'
diff --git a/scripts/check-secrets.sh b/scripts/check-secrets.sh
--- a/scripts/check-secrets.sh
+++ b/scripts/check-secrets.sh
@@ -1,3 +1,3 @@
-# check-secrets
+# check-secrets updated
diff --git a/src/app.py b/src/app.py
--- a/src/app.py
+++ b/src/app.py
@@ -0,0 +1,2 @@
+AWS_ACCESS_KEY_ID="AKIA1234567890ABCDEF"
EOF
run_check --dir "$R_OTHER" --diff "$PATCH_OTHER"
check other-diff-rc "$CODE" 3 "exit 3 on credential added to other file in diff"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(aws_access_key, other.patch:11)"*)
    ok other-diff-status "reported SECRETS_FOUND for other file" ;;
  *) bad other-diff-status "unexpected output: $OUT" ;;
esac

# --- 22. Diff adding credential-shaped line to scripts/check-secrets.sh outside patterns
# The entire scripts/check-secrets.sh file is exempted when scanning diffs to prevent
# heuristic false-positives/bypasses; the skip is explicitly named on the status line.
R_OUTSIDE="$(new_repo outside-patterns)"
PATCH_OUTSIDE="$R_OUTSIDE/outside.patch"
cat > "$PATCH_OUTSIDE" <<'EOF'
diff --git a/scripts/check-secrets.sh b/scripts/check-secrets.sh
--- a/scripts/check-secrets.sh
+++ b/scripts/check-secrets.sh
@@ -2,2 +2,3 @@
+# Pre-dispatch secret scanner
+FALLBACK_KEY="AKIA1234567890ABCDEF"
EOF
run_check --dir "$R_OUTSIDE" --diff "$PATCH_OUTSIDE"
check outside-diff-rc "$CODE" 0 "exit 0 on diff to scripts/check-secrets.sh (file-level skip)"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*"| Skipped: scripts/check-secrets.sh, tests/check-secrets.sh"*)
    ok outside-diff-status "reported SECRETS_NONE and named skipped scanner paths" ;;
  *) bad outside-diff-status "unexpected output: $OUT" ;;
esac

# --- 23. --skip on arbitrary path exempts only that path and names it ---------
R_SKIP="$(new_repo custom-skip)"
PATCH_SKIP="$R_SKIP/custom.patch"
cat > "$PATCH_SKIP" <<'EOF'
diff --git a/fixtures/test_credentials.json b/fixtures/test_credentials.json
--- a/fixtures/test_credentials.json
+++ b/fixtures/test_credentials.json
@@ -0,0 +1,2 @@
+{"token": "ghp_1234567890abcdef1234567890abcdef12"}
EOF
run_check --dir "$R_SKIP" --diff "$PATCH_SKIP" --skip fixtures/test_credentials.json
check custom-skip-rc "$CODE" 0 "exit 0 when exempted via --skip"
case "$OUT" in
  *"STATUS: SECRETS_NONE"*"| Skipped: scripts/check-secrets.sh, tests/check-secrets.sh, fixtures/test_credentials.json"*)
    ok custom-skip-status "reported SECRETS_NONE and named custom skipped path" ;;
  *) bad custom-skip-status "unexpected output: $OUT" ;;
esac

PATCH_SKIP_MULTI="$R_SKIP/multi.patch"
cat > "$PATCH_SKIP_MULTI" <<'EOF'
diff --git a/fixtures/test_credentials.json b/fixtures/test_credentials.json
--- a/fixtures/test_credentials.json
+++ b/fixtures/test_credentials.json
@@ -0,0 +1,2 @@
+{"token": "ghp_1234567890abcdef1234567890abcdef12"}
diff --git a/src/secrets.py b/src/secrets.py
--- a/src/secrets.py
+++ b/src/secrets.py
@@ -0,0 +1,2 @@
+API_KEY = "AIzaSyA1234567890123456789012345678901"
EOF
run_check --dir "$R_SKIP" --diff "$PATCH_SKIP_MULTI" --skip fixtures/test_credentials.json
check custom-skip-multi-rc "$CODE" 3 "exit 3 on unexempted file despite --skip on other file"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(google_api_key, multi.patch:10)"*)
    ok custom-skip-multi-status "reported SECRETS_FOUND on non-exempted file" ;;
  *) bad custom-skip-multi-status "unexpected output: $OUT" ;;
esac

# --- 24. Brief containing a credential is still refused unaffected ------------
R_BRIEF_SEC="$(new_repo brief-secret-with-skip)"
BRIEF_SEC="$R_BRIEF_SEC/brief_sec.md"
cat > "$BRIEF_SEC" <<'EOF'
# Task
Deploy with secret token:
GITHUB_TOKEN=ghp_1234567890abcdef1234567890abcdef12
EOF
run_check --dir "$R_BRIEF_SEC" --brief "$BRIEF_SEC" --skip "brief_sec.md"
check brief-secret-rc "$CODE" 3 "exit 3 on brief with credential even if --skip specified"
case "$OUT" in
  *"STATUS: SECRETS_FOUND(github_token, brief_sec.md:3)"*)
    ok brief-secret-status "reported SECRETS_FOUND for brief credential" ;;
  *) bad brief-secret-status "unexpected output: $OUT" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

