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

# --- cca_encode_dir ---
# '/' と '.' を '-' に(先頭 / も '-')。github.com の '.' も潰れる。
assert_eq "encode_dir path with dot" \
  "-Users-naramotoyuuji-ghq-github-com-it-all-playpark-skills" \
  "$(cca_encode_dir /Users/naramotoyuuji/ghq/github.com/it-all-playpark/skills)"
assert_eq "encode_dir short" "-a-b-c-d" "$(cca_encode_dir /a/b.c/d)"

# --- cca_newest_mtime ---
mt_tmp="$(mktemp -d)"
: > "$mt_tmp/a.jsonl"
mt_exp="$(stat -c %Y "$mt_tmp/a.jsonl" 2>/dev/null || stat -f %m "$mt_tmp/a.jsonl")"
assert_eq "newest_mtime returns file epoch" "$mt_exp" "$(cca_newest_mtime "$mt_tmp")"
assert_eq "newest_mtime empty/absent dir → 0" "0" "$(cca_newest_mtime "$mt_tmp/none")"
rm -rf "$mt_tmp"

# --- cca_render ---
# 入力は cwd\tbranch\tmtime_epoch(秒)。CCA_NOW=3000 基準。
# 行1: mtime 3000, age 0 <300 → 🟢 0s, branch feat/x
# 行2: mtime 1000, age 2000 → 33m, >300 → 💤, branch 空 → –
# 行3: mtime 0(transcript無し)→ 鮮度不明 "–"、巨大 age を出さない
render_in=$'/home/u/alpha\tfeat/x\t3000
/home/u/beta\t\t1000
/home/u/home\t\t0'
render_expected=$'/home/u/alpha\talpha\tfeat/x\t🟢 0s
/home/u/beta\tbeta\t–\t💤 33m
/home/u/home\thome\t–\t–'
render_actual="$(printf '%s' "$render_in" | CCA_NOW=3000 CCA_ACTIVE_WINDOW=300 cca_render)"
assert_eq "render icon/reltime/branch-fallback/no-mtime" "$render_expected" "$render_actual"

# --- cca_join ---
# session 名は '_' で付けられることがある(second_brain)が cwd basename は '-'(second-brain)。
# 両側正規化して一致させ、元の session 名を返す。
sessions=$'alpha\nshift-bud\ncorporate-site\nsecond_brain'
assert_eq "join exact basename" "alpha" "$(printf '%s' "$sessions" | cca_join /home/u/alpha)"
assert_eq "join normalizes _ vs -" "second_brain" "$(printf '%s' "$sessions" | cca_join /home/u/second-brain)"
assert_eq "join no match returns empty" "" "$(printf '%s' "$sessions" | cca_join /home/u/unknown)"

# --- cca_cmd_list (--list) ---
# 上流(cca_live/cca_enumerate)を fixture に差し替え、fzf/zellij を「呼ばれたら失敗」スタブにして
# --list がデータパイプ(cca_live|cca_enumerate|cca_render)のみで完結し、fzf/zellij を一切呼ばないことを検証する。
cca_live() { printf '%s\n' /home/u/alpha /home/u/beta; }
cca_enumerate() { printf '%s\n' $'/home/u/alpha\tfeat/x\t3000' $'/home/u/beta\t\t1000'; }
fzf() { echo FZF-CALLED >&2; return 99; }
zellij() { echo ZELLIJ-CALLED >&2; return 99; }

list_actual="$(CCA_NOW=3000 CCA_ACTIVE_WINDOW=300 cca_cmd_list)"
list_expected=$'/home/u/alpha\talpha\tfeat/x\t🟢 0s\n/home/u/beta\tbeta\t–\t💤 33m'
assert_eq "cca --list (cca_cmd_list) outputs TSV without calling fzf/zellij" "$list_expected" "$list_actual"

exit "$FAIL"
