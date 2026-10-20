#!/usr/bin/env bash
# tests/lima-sandbox-ci.test.sh
# CI がパッチ版 Lima（lib/lima-sandbox）を build するのを、関係するパスが変わったときだけにする仕組みを確かめる。
# Run from anywhere: bash tests/lima-sandbox-ci.test.sh
# Requires: git, yq (yq-go)
#
# - ci.yml の判定 step（id: lima-sandbox）の run を取り出し、一時 repo の差分で skip_build を出すかを見る
# - tests/lima-sandbox.test.sh を偽の nix で走らせ、LIMA_SANDBOX_SKIP_BUILD=1 で nix build を呼ばないことを見る

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_YML="${REPO_ROOT}/.github/workflows/ci.yml"

PASS=0
FAIL=0
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

for cmd in git yq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "SKIP: ${cmd} not on PATH" >&2
    exit 0
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lima-sandbox-ci-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

echo "=== lima-sandbox CI tests ==="
echo ""
echo "--- ci.yml: lima-sandbox step ---"

yq '.jobs.check.steps[] | select(.id == "lima-sandbox") | .run' "${CI_YML}" >"${TMPROOT}/decide.sh"
tests_env="$(yq '.jobs.check.steps[] | select(.name == "Tests") | .env.LIMA_SANDBOX_SKIP_BUILD' "${CI_YML}")"

# -------------------------------------------------------------------------
# tests_step_receives_skip_build: Tests step に判定 step の出力が LIMA_SANDBOX_SKIP_BUILD で渡る
# -------------------------------------------------------------------------
echo "- tests_step_receives_skip_build"
# shellcheck disable=SC2016 # 意図的: ci.yml 上の式を文字列として比べる
if [ "${tests_env}" = '${{ steps.lima-sandbox.outputs.skip_build }}' ]; then
  pass "tests_step_receives_skip_build"
else
  fail "tests_step_receives_skip_build" "got=${tests_env}"
fi

# -------------------------------------------------------------------------
# checkout_fetches_parent: base（HEAD^1）と diff を取れるだけの履歴を checkout が取る
# -------------------------------------------------------------------------
echo "- checkout_fetches_parent"
depth="$(yq '.jobs.check.steps[] | select(.uses == "actions/checkout@*") | .with["fetch-depth"]' "${CI_YML}")"
if [ "${depth}" = "0" ] || { [ "${depth}" -ge 2 ] 2>/dev/null; }; then
  pass "checkout_fetches_parent"
else
  fail "checkout_fetches_parent" "fetch-depth=${depth}"
fi

# 一時 repo: base の commit に 1 commit 足し、その commit を HEAD にして判定 step を走らせる。
# 出力は GITHUB_OUTPUT の skip_build（1 なら build しない、空なら build する）
new_repo() {
  local dir="$1"
  git init -q "${dir}"
  mkdir -p "${dir}/lib/lima-sandbox" "${dir}/tests"
  for f in README.md flake.nix flake.lock lib/lima-sandbox/default.nix tests/lima-sandbox.test.sh; do
    echo base >"${dir}/${f}"
  done
  git -C "${dir}" add -A
  git -C "${dir}" -c user.name=t -c user.email=t@example.invalid commit -q -m base
}

change() {
  local dir="$1" path="$2"
  mkdir -p "$(dirname "${dir}/${path}")"
  echo change >>"${dir}/${path}"
  git -C "${dir}" add -A
  git -C "${dir}" -c user.name=t -c user.email=t@example.invalid commit -q -m change
}

decide() {
  local dir="$1" event="$2" before="${3:-}"
  : >"${dir}.out"
  (cd "${dir}" && EVENT_NAME="${event}" BEFORE="${before}" GITHUB_OUTPUT="${dir}.out" \
    bash -e "${TMPROOT}/decide.sh" >"${dir}.log" 2>&1) || echo "exit=$?" >>"${dir}.log"
  sed -n 's/^skip_build=//p' "${dir}.out"
}

# expect_decision <name> <event> <changed path> <expected skip_build>
expect_decision() {
  local name="$1" event="$2" path="$3" expected="$4" dir before got
  dir="${TMPROOT}/${name}"
  new_repo "${dir}"
  before="$(git -C "${dir}" rev-parse HEAD)"
  change "${dir}" "${path}"
  echo "- ${name}"
  got="$(decide "${dir}" "${event}" "${before}")"
  if [ "${got}" = "${expected}" ]; then
    pass "${name}"
  else
    fail "${name}" "skip_build=${got:-<empty>} expected=${expected:-<empty>} log=$(tail -n 3 "${dir}.log")"
  fi
}

expect_decision pr_unrelated_skips_build pull_request README.md 1
expect_decision pr_lima_sandbox_dir_builds pull_request lib/lima-sandbox/deny.go ""
expect_decision pr_flake_lock_builds pull_request flake.lock ""
expect_decision pr_flake_nix_builds pull_request flake.nix ""
expect_decision pr_lima_sandbox_test_builds pull_request tests/lima-sandbox.test.sh ""
expect_decision pr_similar_path_skips_build pull_request docs/lib/lima-sandbox/x.md 1
expect_decision push_unrelated_skips_build push README.md 1
expect_decision push_lima_sandbox_dir_builds push lib/lima-sandbox/default.nix ""
expect_decision dispatch_builds workflow_dispatch README.md ""

# -------------------------------------------------------------------------
# 差分を取れないときは build する側に倒す
# -------------------------------------------------------------------------
echo "- push_initial_builds"
dir="${TMPROOT}/push_initial"
new_repo "${dir}"
got="$(decide "${dir}" push 0000000000000000000000000000000000000000)"
if [ -z "${got}" ]; then pass "push_initial_builds"; else fail "push_initial_builds" "skip_build=${got}"; fi

echo "- push_unknown_before_builds"
dir="${TMPROOT}/push_unknown"
new_repo "${dir}"
change "${dir}" README.md
got="$(decide "${dir}" push 1111111111111111111111111111111111111111)"
if [ -z "${got}" ]; then pass "push_unknown_before_builds"; else fail "push_unknown_before_builds" "skip_build=${got}"; fi

echo "- pr_without_parent_builds"
dir="${TMPROOT}/pr_root"
new_repo "${dir}"
got="$(decide "${dir}" pull_request)"
if [ -z "${got}" ]; then pass "pr_without_parent_builds"; else fail "pr_without_parent_builds" "skip_build=${got}"; fi

echo ""
echo "--- tests/lima-sandbox.test.sh: LIMA_SANDBOX_SKIP_BUILD ---"

# 偽の nix: 呼ばれた引数を記録し、aarch64-darwin で daemon に届くふりをする（build は失敗させる）
mkdir -p "${TMPROOT}/bin"
cat >"${TMPROOT}/bin/nix" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${NIX_STUB_LOG}"
case "$1" in
store) exit 0 ;;
build) exit 1 ;;
eval)
  case "$*" in
  *--json*) echo '{"patched":true,"plain":false}' ;;
  *currentSystem*) printf 'aarch64-darwin' ;;
  *) printf '0.0.0' ;;
  esac
  ;;
esac
EOF
chmod +x "${TMPROOT}/bin/nix"

run_lima_test() {
  local name="$1"
  shift
  : >"${TMPROOT}/${name}.nix.log"
  env "$@" PATH="${TMPROOT}/bin:${PATH}" NIX_STUB_LOG="${TMPROOT}/${name}.nix.log" \
    bash "${REPO_ROOT}/tests/lima-sandbox.test.sh" >"${TMPROOT}/${name}.out" 2>&1 || true
}

# -------------------------------------------------------------------------
# skip_build_skips_nix_build: 1 なら build を要する 2 つを SKIP と出して nix build を呼ばず、
# 評価だけの home_packages_use_patched_lima は走らせる
# -------------------------------------------------------------------------
echo "- skip_build_skips_nix_build"
run_lima_test skip LIMA_SANDBOX_SKIP_BUILD=1
problems=""
grep -q '^build' "${TMPROOT}/skip.nix.log" && problems="${problems} nix-build-called"
grep -qF 'SKIP: binary_contains_egress_patch' "${TMPROOT}/skip.out" || problems="${problems} no-skip-binary"
grep -qF 'SKIP: version_matches_nixpkgs_lima' "${TMPROOT}/skip.out" || problems="${problems} no-skip-version"
grep -qF 'PASS: home_packages_use_patched_lima' "${TMPROOT}/skip.out" || problems="${problems} home-packages-not-run"
if [ -z "${problems}" ]; then
  pass "skip_build_skips_nix_build"
else
  fail "skip_build_skips_nix_build" "${problems} out=$(tail -n 8 "${TMPROOT}/skip.out")"
fi

# -------------------------------------------------------------------------
# no_skip_build_runs_nix_build: 変数が無いときは今どおり nix build して 2 つを検査する
# -------------------------------------------------------------------------
echo "- no_skip_build_runs_nix_build"
run_lima_test noskip -u LIMA_SANDBOX_SKIP_BUILD
problems=""
grep -q '^build' "${TMPROOT}/noskip.nix.log" || problems="${problems} nix-build-not-called"
grep -qF 'SKIP:' "${TMPROOT}/noskip.out" && problems="${problems} skipped"
grep -qF -- '- binary_contains_egress_patch' "${TMPROOT}/noskip.out" || problems="${problems} binary-not-run"
grep -qF -- '- version_matches_nixpkgs_lima' "${TMPROOT}/noskip.out" || problems="${problems} version-not-run"
if [ -z "${problems}" ]; then
  pass "no_skip_build_runs_nix_build"
else
  fail "no_skip_build_runs_nix_build" "${problems} out=$(tail -n 8 "${TMPROOT}/noskip.out")"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: lima-sandbox-ci"
