#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/cca"

FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - $desc"
  else
    echo "NOT OK - $desc"
    printf '  expected: [%s]\n  actual:   [%s]\n' "$expected" "$actual"
    FAIL=1
  fi
}

# --- cca_reltime ---
assert_eq "reltime 30s"  "30s" "$(cca_reltime 30)"
assert_eq "reltime 90=1m" "1m"  "$(cca_reltime 90)"
assert_eq "reltime 4000=1h" "1h" "$(cca_reltime 4000)"
assert_eq "reltime 200000=2d" "2d" "$(cca_reltime 200000)"

# --- cca_discover ---
# glob はアルファベット順: proj-alpha → proj-beta
# alpha は最新の非 sidechain(a2, mtime 3000)を採用。a3(sidechain)は無視。
# beta は branch 空。
disc_expected=$'/home/u/alpha\tRecent work\tfeat/x\t3000
/home/u/beta\tBeta task\t\t2000'
disc_actual="$(CCA_PROJECTS_DIR="$HERE/fixtures/projects" cca_discover)"
assert_eq "discover latest-non-sidechain per project" "$disc_expected" "$disc_actual"

exit "$FAIL"
