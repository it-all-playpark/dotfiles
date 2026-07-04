#!/usr/bin/env bash
# Test suite for stop-devflow-telemetry.sh
#
# Usage: bash stop-devflow-telemetry.test.sh
#
# Exit 0 on all pass, non-zero otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/stop-devflow-telemetry.sh"

PASS=0
FAIL=0
FAILURES=()

pass() {
  local name="$1"
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m %s\n" "$name"
}
fail() {
  local name="$1" msg="$2"
  FAIL=$((FAIL + 1))
  FAILURES+=("$name: $msg")
  printf "  \033[31mFAIL\033[0m %s (%s)\n" "$name" "$msg"
}

# --------------------------------------------------------------------------
# Setup / teardown helpers
# --------------------------------------------------------------------------

make_tmpdir() {
  mktemp -d "$TMPDIR/stop-devflow-test.XXXXXX"
}

# Build a minimal handoff JSON and write it to a file.
# Usage: make_handoff <tmpdir> <filename> [extra_json_fields]
# extra_json_fields is a jq filter string applied to base object, e.g.:
#   '. + {"eval_verdict":"PASS","iterate_status":"converged"}'
make_handoff() {
  local dir="$1" fname="$2" extra="${3:-.}"
  local base
  base=$(jq -n '{
    skill: "dev-flow",
    outcome: "success",
    issue: 203,
    journal_sh: "STUB_PLACEHOLDER",
    telemetry: {
      merge_tier: "REVIEW",
      gate_policy: "llm-major-advisory",
      danger_hits: [],
      shape: "standard",
      shape_refloored: false,
      plan_iter: 1,
      eval_iter: 1
    }
  }')
  echo "$base" | jq "$extra" >"${dir}/${fname}"
}

# --------------------------------------------------------------------------
# Test 1: hook not found / not executable → skip (guard)
# --------------------------------------------------------------------------
echo "=== stop-devflow-telemetry tests ==="

if [[ ! -f ${HOOK} ]]; then
  echo "  (hook not found yet — TDD red phase confirmed)"
  fail "hook_exists" "hook file not found: ${HOOK}"
fi

# If hook not found, remaining tests will fail in unhelpful ways. Bail early.
if ((FAIL > 0)); then
  echo ""
  echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi

if [[ ! -x ${HOOK} ]]; then
  fail "hook_executable" "hook not executable: ${HOOK}"
  echo ""
  echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
  for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi

# --------------------------------------------------------------------------
# Helper: run the hook with given env vars and stdin
# Returns hook exit code via $RUN_EXIT; hook stdout captured (should be empty)
# --------------------------------------------------------------------------
RUN_EXIT=0
RUN_OUT=""
run_hook() {
  # Args: env vars as NAME=VALUE pairs (passed via env command)
  # Reads remaining args as env overrides
  local envargs=("$@")
  RUN_EXIT=0
  RUN_OUT=""
  RUN_OUT=$(env "${envargs[@]}" bash "$HOOK" </dev/null 2>&1) || RUN_EXIT=$?
}

# --------------------------------------------------------------------------
# Test 2: pending dir not present → exit 0
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  # CLAUDE_JOURNAL_DIR points to a dir with no pending/ subdir
  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}" "HOME=${tmpd}"
  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "pending_dir_absent_exits_0"
  else
    fail "pending_dir_absent_exits_0" "expected exit 0, got ${RUN_EXIT}"
  fi
  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 3: escape hatch CLAUDE_DEVFLOW_TELEMETRY_HOOK=0 → exit 0
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"
  make_handoff "${tmpd}/journal/pending" "handoff.json"
  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}" "CLAUDE_DEVFLOW_TELEMETRY_HOOK=0"
  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "escape_hatch_exits_0"
  else
    fail "escape_hatch_exits_0" "expected exit 0 with escape hatch, got ${RUN_EXIT}"
  fi
  # File should still exist (not processed)
  if [[ -f "${tmpd}/journal/pending/handoff.json" ]]; then
    pass "escape_hatch_file_untouched"
  else
    fail "escape_hatch_file_untouched" "file should not be processed when escape hatch is set"
  fi
  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Stub journal.sh builder
# Creates a stub script that records its arguments to a capture file
# --------------------------------------------------------------------------
make_stub_journal() {
  local stub_path="$1" capture_file="$2" exit_code="${3:-0}"
  cat >"$stub_path" <<STUB_EOF
#!/usr/bin/env bash
# Stub journal.sh for testing
echo "\$*" >> "${capture_file}"
exit ${exit_code}
STUB_EOF
  chmod +x "$stub_path"
}

# --------------------------------------------------------------------------
# Test 4: happy path — 1 pending file → stub called with correct args, file removed
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"
  capture="${tmpd}/capture.txt"
  stub="${tmpd}/journal.sh"
  make_stub_journal "$stub" "$capture" 0

  # Build handoff with journal_sh pointing to stub
  jq -n \
    --arg js "$stub" \
    '{
      skill: "dev-flow",
      outcome: "success",
      issue: 203,
      journal_sh: $js,
      telemetry: {
        merge_tier: "REVIEW",
        gate_policy: "llm-major-advisory",
        danger_hits: [],
        shape: "standard",
        shape_refloored: false,
        plan_iter: 1,
        eval_iter: 1
      }
    }' >"${tmpd}/journal/pending/handoff.json"

  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}"

  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "happy_path_exits_0"
  else
    fail "happy_path_exits_0" "expected exit 0, got ${RUN_EXIT}. output: ${RUN_OUT}"
  fi

  # Check capture file exists and has content
  if [[ ! -f $capture ]]; then
    fail "happy_path_stub_called" "capture file not created (stub not called)"
  else
    captured=$(cat "$capture")
    # Expected args: log dev-flow success --issue 203 --merge-tier REVIEW ...
    if echo "$captured" | grep -q "log dev-flow success" &&
      echo "$captured" | grep -q -- "--issue 203" &&
      echo "$captured" | grep -q -- "--merge-tier REVIEW" &&
      echo "$captured" | grep -q -- "--gate-policy llm-major-advisory" &&
      echo "$captured" | grep -q -- "--danger-hits" &&
      echo "$captured" | grep -q -- "--shape standard" &&
      echo "$captured" | grep -q -- "--shape-refloored false" &&
      echo "$captured" | grep -q -- "--plan-iter 1" &&
      echo "$captured" | grep -q -- "--eval-iter 1"; then
      pass "happy_path_stub_called_with_correct_args"
    else
      fail "happy_path_stub_called_with_correct_args" "args mismatch. got: ${captured}"
    fi
    # eval_verdict and iterate_status should NOT appear (not in this handoff)
    if echo "$captured" | grep -q -- "--eval-verdict"; then
      fail "happy_path_no_eval_verdict" "--eval-verdict should not be present"
    else
      pass "happy_path_no_eval_verdict"
    fi
    if echo "$captured" | grep -q -- "--iterate-status"; then
      fail "happy_path_no_iterate_status" "--iterate-status should not be present"
    else
      pass "happy_path_no_iterate_status"
    fi
  fi

  # Pending file should be removed after success
  if [[ ! -f "${tmpd}/journal/pending/handoff.json" ]]; then
    pass "happy_path_pending_file_removed"
  else
    fail "happy_path_pending_file_removed" "pending file should be removed after successful processing"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 5: optional fields — eval_verdict + iterate_status present → flags appended
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"
  capture="${tmpd}/capture.txt"
  stub="${tmpd}/journal.sh"
  make_stub_journal "$stub" "$capture" 0

  jq -n \
    --arg js "$stub" \
    '{
      skill: "dev-flow",
      outcome: "success",
      issue: 42,
      journal_sh: $js,
      repo: "acme/skills",
      pr_number: 123,
      telemetry: {
        merge_tier: "AUTO",
        gate_policy: "llm-autonomous",
        danger_hits: ["sql-injection"],
        shape: "micro",
        shape_refloored: true,
        plan_iter: 2,
        eval_iter: 3,
        eval_verdict: "PASS",
        iterate_status: "converged",
        eval_staleness: "iterate_fixed"
      }
    }' >"${tmpd}/journal/pending/handoff.json"

  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}"

  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "optional_fields_exits_0"
  else
    fail "optional_fields_exits_0" "expected exit 0, got ${RUN_EXIT}. output: ${RUN_OUT}"
  fi

  if [[ -f $capture ]]; then
    captured=$(cat "$capture")
    if echo "$captured" | grep -q -- "--eval-verdict PASS"; then
      pass "optional_eval_verdict_present"
    else
      fail "optional_eval_verdict_present" "--eval-verdict PASS not found. got: ${captured}"
    fi
    if echo "$captured" | grep -q -- "--iterate-status converged"; then
      pass "optional_iterate_status_present"
    else
      fail "optional_iterate_status_present" "--iterate-status converged not found. got: ${captured}"
    fi
    if echo "$captured" | grep -q -- "--shape-refloored true"; then
      pass "optional_shape_refloored_true"
    else
      fail "optional_shape_refloored_true" "--shape-refloored true not found. got: ${captured}"
    fi
    if echo "$captured" | grep -q -- "--eval-staleness iterate_fixed"; then
      pass "optional_eval_staleness_present"
    else
      fail "optional_eval_staleness_present" "--eval-staleness iterate_fixed not found. got: ${captured}"
    fi
    if echo "$captured" | grep -q -- "--repo acme/skills"; then
      pass "optional_repo_present"
    else
      fail "optional_repo_present" "--repo acme/skills not found. got: ${captured}"
    fi
    if echo "$captured" | grep -q -- "--pr-number 123"; then
      pass "optional_pr_number_present"
    else
      fail "optional_pr_number_present" "--pr-number 123 not found. got: ${captured}"
    fi
  else
    fail "optional_fields_stub_called" "capture file not created"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 6: optional fields absent — no eval_verdict/iterate_status in handoff → flags absent
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"
  capture="${tmpd}/capture.txt"
  stub="${tmpd}/journal.sh"
  make_stub_journal "$stub" "$capture" 0

  jq -n \
    --arg js "$stub" \
    '{
      skill: "dev-flow",
      outcome: "success",
      issue: 10,
      journal_sh: $js,
      telemetry: {
        merge_tier: "HOLD",
        gate_policy: "deterministic-only",
        danger_hits: [],
        shape: "complex",
        shape_refloored: false,
        plan_iter: 5,
        eval_iter: 4
      }
    }' >"${tmpd}/journal/pending/handoff.json"

  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}"

  if [[ -f $capture ]]; then
    captured=$(cat "$capture")
    if ! echo "$captured" | grep -q -- "--eval-verdict"; then
      pass "no_eval_verdict_when_absent"
    else
      fail "no_eval_verdict_when_absent" "--eval-verdict should not appear"
    fi
    if ! echo "$captured" | grep -q -- "--iterate-status"; then
      pass "no_iterate_status_when_absent"
    else
      fail "no_iterate_status_when_absent" "--iterate-status should not appear"
    fi
    if ! echo "$captured" | grep -q -- "--eval-staleness"; then
      pass "no_eval_staleness_when_absent"
    else
      fail "no_eval_staleness_when_absent" "--eval-staleness should not appear"
    fi
    if ! echo "$captured" | grep -q -- "--repo"; then
      pass "no_repo_when_absent"
    else
      fail "no_repo_when_absent" "--repo should not appear"
    fi
    if ! echo "$captured" | grep -q -- "--pr-number"; then
      pass "no_pr_number_when_absent"
    else
      fail "no_pr_number_when_absent" "--pr-number should not appear"
    fi
  else
    fail "no_optional_fields_stub_called" "capture file not created"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 7: failure path — stub exits 1 → file restored, log written
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"
  capture="${tmpd}/capture.txt"
  stub="${tmpd}/journal.sh"
  make_stub_journal "$stub" "$capture" 1

  jq -n \
    --arg js "$stub" \
    '{
      skill: "dev-flow",
      outcome: "failure",
      issue: 99,
      journal_sh: $js,
      telemetry: {
        merge_tier: "REVIEW",
        gate_policy: "llm-major-advisory",
        danger_hits: [],
        shape: "standard",
        shape_refloored: false,
        plan_iter: 1,
        eval_iter: 1
      }
    }' >"${tmpd}/journal/pending/handoff.json"

  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}"

  # Hook must exit 0 even on failure
  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "failure_path_exits_0"
  else
    fail "failure_path_exits_0" "hook must always exit 0, got ${RUN_EXIT}"
  fi

  # Pending file should be restored (not removed) after failure
  if [[ -f "${tmpd}/journal/pending/handoff.json" ]]; then
    pass "failure_path_file_restored"
  else
    fail "failure_path_file_restored" "pending file should be restored after journal.sh failure"
  fi

  # Log file should be written
  logfile="${tmpd}/.claude/logs/stop-devflow-telemetry.log"
  if [[ -f $logfile ]]; then
    pass "failure_path_log_written"
    # Check log has content (timestamp + something)
    if [[ -s $logfile ]]; then
      pass "failure_path_log_nonempty"
    else
      fail "failure_path_log_nonempty" "log file is empty"
    fi
  else
    fail "failure_path_log_written" "log file not created at ${logfile}"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 8: malformed JSON → moved to pending/malformed/, error logged, exit 0
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"

  echo "{ not valid json }" >"${tmpd}/journal/pending/bad.json"

  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}"

  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "malformed_exits_0"
  else
    fail "malformed_exits_0" "hook must always exit 0, got ${RUN_EXIT}"
  fi

  # Original file should not exist in pending/
  if [[ ! -f "${tmpd}/journal/pending/bad.json" ]]; then
    pass "malformed_removed_from_pending"
  else
    fail "malformed_removed_from_pending" "malformed file should be moved out of pending/"
  fi

  # File should be in malformed/ subdir
  if ls "${tmpd}/journal/pending/malformed/" 2>/dev/null | grep -q "bad.json"; then
    pass "malformed_moved_to_malformed_dir"
  else
    fail "malformed_moved_to_malformed_dir" "malformed file not found in pending/malformed/"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 9: missing required key (no telemetry.merge_tier) → malformed treatment
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"

  # Valid JSON but missing required key
  echo '{"skill":"dev-flow","outcome":"success","issue":1,"journal_sh":"/bin/true","telemetry":{}}' \
    >"${tmpd}/journal/pending/nokey.json"

  run_hook "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}"

  if [[ $RUN_EXIT -eq 0 ]]; then
    pass "missing_key_exits_0"
  else
    fail "missing_key_exits_0" "hook must always exit 0, got ${RUN_EXIT}"
  fi

  if ls "${tmpd}/journal/pending/malformed/" 2>/dev/null | grep -q "nokey.json"; then
    pass "missing_key_moved_to_malformed"
  else
    fail "missing_key_moved_to_malformed" "file with missing required key should be in malformed/"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Test 10: stdout must be empty (hook prints nothing to stdout)
# --------------------------------------------------------------------------
{
  tmpd=$(make_tmpdir)
  mkdir -p "${tmpd}/journal/pending"
  capture="${tmpd}/capture.txt"
  stub="${tmpd}/journal.sh"
  make_stub_journal "$stub" "$capture" 0

  jq -n \
    --arg js "$stub" \
    '{
      skill: "dev-flow",
      outcome: "success",
      issue: 1,
      journal_sh: $js,
      telemetry: {
        merge_tier: "REVIEW",
        gate_policy: "llm-major-advisory",
        danger_hits: [],
        shape: "standard",
        shape_refloored: false,
        plan_iter: 1,
        eval_iter: 1
      }
    }' >"${tmpd}/journal/pending/handoff.json"

  stdout_out=$(env "CLAUDE_JOURNAL_DIR=${tmpd}/journal" "HOME=${tmpd}" bash "$HOOK" </dev/null 2>/dev/null || true)

  if [[ -z $stdout_out ]]; then
    pass "no_stdout_output"
  else
    fail "no_stdout_output" "hook should not write to stdout, got: ${stdout_out}"
  fi

  rm -rf "$tmpd"
}

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if ((FAIL > 0)); then
  printf '\n'
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
