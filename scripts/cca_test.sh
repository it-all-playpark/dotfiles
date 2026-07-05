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
# beta は branch 空。gamma は全 entry が sidechain なので1行も出さない(select(length>0)パス)。
disc_expected=$'/home/u/alpha\tRecent work\tfeat/x\t3000
/home/u/beta\tBeta task\t\t2000'
disc_actual="$(CCA_PROJECTS_DIR="$HERE/fixtures/projects" cca_discover)"
assert_eq "discover latest-non-sidechain per project" "$disc_expected" "$disc_actual"

# --- cca_render ---
# CCA_NOW=3000s 基準。fileMtime は ms なので /1000。
# 行1: mtime 3000000ms=3000s, age 0 <300 → 🟢, rel 0s, branch feat/x
# 行2: mtime 1000000ms=1000s, age 2000 → 33m, >300 → 💤, branch 空 → –
render_in=$'/home/u/alpha\tRecent work\tfeat/x\t3000000
/home/u/beta\tOld\t\t1000000'
render_expected=$'/home/u/alpha\talpha\tfeat/x\t🟢 0s\tRecent work
/home/u/beta\tbeta\t–\t💤 33m\tOld'
render_actual="$(printf '%s' "$render_in" | CCA_NOW=3000 CCA_ACTIVE_WINDOW=300 cca_render)"
assert_eq "render icon/reltime/branch-fallback" "$render_expected" "$render_actual"

# --- cca_join ---
sessions=$'alpha\nshift-bud\ncorporate-site'
assert_eq "join match by basename" "alpha" "$(printf '%s' "$sessions" | cca_join /home/u/alpha)"
assert_eq "join no match returns empty" "" "$(printf '%s' "$sessions" | cca_join /home/u/unknown)"

exit "$FAIL"
