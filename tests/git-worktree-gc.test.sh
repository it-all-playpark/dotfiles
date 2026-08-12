#!/usr/bin/env bash
# tests/git-worktree-gc.test.sh
# Functional test for home-manager/home/file/bin/git-worktree-gc.
# Run from the repo root: bash tests/git-worktree-gc.test.sh
# Requires: git, bash (tier-1 static) / git worktree (tier-2 functional)
#
# tier-1: 静的検証（wiring: home.file / abbr が script を指しているか）
# tier-2: 実 git repo + gh スタブによる機能検証
#
# tier-2 は $TMPDIR 配下に bare origin + 作業 repo + worktree を作り、
# PATH の先頭に gh スタブを差し込んで PR 状態を制御する。ネットワークは使わない。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/home-manager/home/file/bin/git-worktree-gc"
PASS=0
FAIL=0
SKIP=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

skip() {
  echo "  SKIP: $1 ($2)"
  SKIP=$((SKIP + 1))
}

echo "=== git-worktree-gc tests ==="
echo ""
echo "--- tier-1: wiring verification ---"

echo "- script_exists_and_is_bash"
if [ -f "$SCRIPT" ] && head -1 "$SCRIPT" | grep -q 'bash'; then
  pass "script_exists_and_is_bash"
else
  fail "script_exists_and_is_bash" "Expected bash script at ${SCRIPT}"
fi

echo "- script_syntax_is_valid"
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "script_syntax_is_valid"
else
  fail "script_syntax_is_valid" "bash -n failed for ${SCRIPT}"
fi

echo "- no_process_substitution"
# sandbox が /dev/fd/* を塞ぐ環境があるため、プロセス置換は使わない方針
# (dotfiles RULES.md / Sandbox Hygiene)。回帰防止。
# コメント行（方針を説明するために `< <(` の字面を含む）は対象外にする。
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE '< *\('; then
  fail "no_process_substitution" \
    "Process substitution '< (' found in ${SCRIPT}; use a tempfile instead"
else
  pass "no_process_substitution"
fi

echo "- homeFile_bin_wiring"
if grep -Fq '".local/bin/git-worktree-gc"' "${REPO_ROOT}/home-manager/home/default.nix" &&
  awk '/"\.local\/bin\/git-worktree-gc"/,/\};/' "${REPO_ROOT}/home-manager/home/default.nix" |
  grep -Fq 'executable = true;'; then
  pass "homeFile_bin_wiring"
else
  fail "homeFile_bin_wiring" \
    "Expected home.file.\".local/bin/git-worktree-gc\" with executable = true in home-manager/home/default.nix"
fi

echo "- abbrs_point_to_script"
COMMON_NIX="${REPO_ROOT}/home-manager/programs/common.nix"
if grep -qE '^ +wrm = .*git-worktree-gc' "$COMMON_NIX" &&
  grep -qE '^ +wrma = .*git-worktree-gc.*--all' "$COMMON_NIX" &&
  grep -qE '^ +wrmn = .*git-worktree-gc.*--dry-run' "$COMMON_NIX"; then
  pass "abbrs_point_to_script"
else
  fail "abbrs_point_to_script" \
    "Expected wrm / wrma / wrmn abbrs referencing git-worktree-gc in ${COMMON_NIX}"
fi

echo ""
echo "--- tier-2: functional verification (real git + gh stub) ---"

if ! command -v git >/dev/null 2>&1; then
  skip "functional tests" "git not available"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gwgc.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="${WORK}/bin"
FIXTURES="${WORK}/prstate"
mkdir -p "$STUB_BIN" "$FIXTURES"

# --- gh スタブ -------------------------------------------------------------
# $FIXTURES/<branch> の中身で挙動を決める:
#   MERGED / OPEN / CLOSED … その state を stdout に返して exit 0
#   NOPR                   … gh の「PR 無し」メッセージを stderr に出して exit 1
#   それ以外 / ファイル無し … 404 を stderr に出して exit 1 (= gh 障害)
cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
branch=""
prev=""
for a in "$@"; do
  if [ "$prev" = "view" ]; then branch="$a"; fi
  prev="$a"
done
f="${GWGC_FIXTURES}/${branch}"
mode="$(cat "$f" 2>/dev/null || echo MISSING)"
case "$mode" in
MERGED | OPEN | CLOSED)
  echo "$mode"
  exit 0
  ;;
NOPR)
  echo "no pull requests found for branch \"${branch}\"" >&2
  exit 1
  ;;
*)
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
  ;;
esac
STUB
chmod +x "${STUB_BIN}/gh"

export GWGC_FIXTURES="$FIXTURES"
export PATH="${STUB_BIN}:${PATH}"

git_q() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# --- fixture repo ----------------------------------------------------------
# origin(bare) ← repo(main) と、判定対象の worktree 群を作る。
ORIGIN="${WORK}/origin.git"
REPO="${WORK}/repo"
git_q init --bare -q "$ORIGIN"
git_q init -q "$REPO"
(
  cd "$REPO" || exit 1
  git_q remote add origin "$ORIGIN"
  echo base >base.txt
  git_q add base.txt
  git_q commit -qm base
  git_q push -q origin main
  git_q remote set-head origin main
) || {
  skip "functional tests" "fixture repo setup failed"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
  [ "$FAIL" -gt 0 ] && exit 1
  exit 0
}

# ブランチ + worktree を作る。$2=merged なら main に取り込んで push する。
make_wt() {
  local name="$1" merged="${2:-no}" dir="${3:-$1}"
  (
    cd "$REPO" || exit 1
    git_q branch -q "$name" main
    git_q worktree add -q "${REPO}/wt/${dir}" "$name"
    echo "$name" >"${REPO}/wt/${dir}/${name}.txt"
    git_q -C "${REPO}/wt/${dir}" add .
    git_q -C "${REPO}/wt/${dir}" commit -qm "work on $name"
    if [ "$merged" = "merged" ]; then
      git_q checkout -q main
      git_q merge -q --no-ff -m "merge $name" "$name"
      git_q push -q origin main
    fi
  )
}

# 1. PR MERGED               → 削除される
make_wt feat-merged merged
echo MERGED >"${FIXTURES}/feat-merged"

# 2. gh 障害 (404)           → 保護される  ★旧実装のデータ損失バグ
make_wt feat-gherror
echo BOOM >"${FIXTURES}/feat-gherror"

# 3. PR 無し + 未マージ      → 保護される  ★旧実装のデータ損失バグ
make_wt feat-nopr-unmerged
echo NOPR >"${FIXTURES}/feat-nopr-unmerged"

# 4. PR 無し + マージ済み    → 削除される
make_wt feat-nopr-merged merged
echo NOPR >"${FIXTURES}/feat-nopr-merged"

# 5. PR OPEN                 → 保護される
make_wt feat-open
echo OPEN >"${FIXTURES}/feat-open"

# 6. dirty worktree (MERGED) → 保護される
make_wt feat-dirty merged
echo MERGED >"${FIXTURES}/feat-dirty"
echo uncommitted >"${REPO}/wt/feat-dirty/scratch.txt"

# 7. dir 名とブランチ名の不一致 → 警告が出る
make_wt feat-mismatch merged issue-9999
echo MERGED >"${FIXTURES}/feat-mismatch"

OUT="${WORK}/out.txt"
(cd "$REPO" && bash "$SCRIPT" --dry-run) >"$OUT" 2>&1
DRY_RC=$?

assert_out() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$OUT"; then
    pass "$label"
  else
    fail "$label" "Expected /${pattern}/ in output:
$(sed 's/^/          /' "$OUT")"
  fi
}

echo "- dryrun_exits_zero"
if [ "$DRY_RC" -eq 0 ]; then
  pass "dryrun_exits_zero"
else
  fail "dryrun_exits_zero" "exit code ${DRY_RC}"
fi

echo "- merged_pr_is_removed"
assert_out "merged_pr_is_removed" "Would remove: feat-merged \(PR MERGED\)"

echo "- gh_error_is_protected"
assert_out "gh_error_is_protected" "Skip \(gh error\): feat-gherror"

echo "- nopr_unmerged_is_protected"
assert_out "nopr_unmerged_is_protected" "Skip \(no PR, unmerged\): feat-nopr-unmerged"

echo "- nopr_merged_is_removed"
assert_out "nopr_merged_is_removed" "Would remove: feat-nopr-merged \(no PR, merged into main\)"

echo "- open_pr_is_protected"
assert_out "open_pr_is_protected" "Skip \(PR OPEN\): feat-open"

echo "- dirty_worktree_is_protected"
assert_out "dirty_worktree_is_protected" "Skip \(dirty\): feat-dirty"

echo "- name_mismatch_is_warned"
assert_out "name_mismatch_is_warned" "Warn \(name mismatch\): dir=issue-9999 branch=feat-mismatch"

echo "- dryrun_removes_nothing"
if [ -d "${REPO}/wt/feat-merged" ]; then
  pass "dryrun_removes_nothing"
else
  fail "dryrun_removes_nothing" "--dry-run deleted ${REPO}/wt/feat-merged"
fi

# --- 実削除 ----------------------------------------------------------------
OUT2="${WORK}/out2.txt"
(cd "$REPO" && bash "$SCRIPT") >"$OUT2" 2>&1

echo "- real_run_removes_only_safe_worktrees"
gone_ok=1
for d in feat-merged feat-nopr-merged; do
  [ -d "${REPO}/wt/${d}" ] && gone_ok=0
done
kept_ok=1
for d in feat-gherror feat-nopr-unmerged feat-open feat-dirty; do
  [ -d "${REPO}/wt/${d}" ] || kept_ok=0
done
if [ "$gone_ok" = 1 ] && [ "$kept_ok" = 1 ]; then
  pass "real_run_removes_only_safe_worktrees"
else
  fail "real_run_removes_only_safe_worktrees" \
    "gone_ok=${gone_ok} kept_ok=${kept_ok}; output:
$(sed 's/^/          /' "$OUT2")"
fi

# --- default branch が main でない repo ------------------------------------
# 旧実装は main 決め打ちだったため dev 系 repo (jikka-scan, sales-pipeline) で
# 誤判定していた。origin/HEAD から解決できることを確認する。
ORIGIN2="${WORK}/origin2.git"
REPO2="${WORK}/repo2"
git_q init --bare -q "$ORIGIN2"
git_q init -q -b dev "$REPO2"
(
  cd "$REPO2" || exit 1
  git_q remote add origin "$ORIGIN2"
  echo base >base.txt
  git_q add base.txt
  git_q commit -qm base
  git_q push -q origin dev
  git_q remote set-head origin dev
  git_q branch -q feat-on-dev dev
  git_q worktree add -q "${REPO2}/wt/feat-on-dev" feat-on-dev
  git_q -C "${REPO2}/wt/feat-on-dev" commit -q --allow-empty -m work
  git_q checkout -q dev
  git_q merge -q --no-ff -m "merge feat-on-dev" feat-on-dev
  git_q push -q origin dev
)
echo NOPR >"${FIXTURES}/feat-on-dev"

OUT3="${WORK}/out3.txt"
(cd "$REPO2" && bash "$SCRIPT" --dry-run) >"$OUT3" 2>&1

echo "- default_branch_resolved_from_origin_head"
if grep -qE "Would remove: feat-on-dev \(no PR, merged into dev\)" "$OUT3"; then
  pass "default_branch_resolved_from_origin_head"
else
  fail "default_branch_resolved_from_origin_head" \
    "Expected dev to be resolved as default branch; output:
$(sed 's/^/          /' "$OUT3")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
