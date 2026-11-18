#!/usr/bin/env bash
# shellcheck disable=SC2016 # 意図的: jq の式（$i / $o / $checkout などは jq の変数）をシングルクォートで渡す
# tests/grokbot-linux-settings.test.sh
# Grok Bot の box（Linux）用の Claude Code settings を作る変換定義
# home-manager/grokbot-linux/settings.jq を、nix を使わずに repo の claude-code/settings.json へ当てて検証する
# （nix の build は home-manager/grokbot-linux/default.nix が同じファイルを jq -f で使う）。
# 入力から引き継ぐ値の期待値は直書きせず、入力から読んで作る。
#
# 検証項目:
#   1. generates                        - 変換が成功して JSON になる
#   2. no_mac_only_values               - sandbox・additionalDirectories・env・hook の command に macOS 専用の値が残らない
#   3. no_private_tmp                   - /private/tmp/ 始まりの値が残らない
#   4. sandbox_lists_inherit_input      - sandbox の各リストは、入力から macOS 専用と meeting 用の値を除き
#                                         /private/tmp/ を /tmp/ にしたもの
#   5. env_inherits_input               - env も同じ規則
#   6. hooks_inherit_input              - hook は command が macOS 専用のものだけ除き、残りは入力と同じ内容・順序
#   7. no_empty_hook_groups             - hook が無くなった matcher グループとイベントは残らない
#   8. deny_keeps_input                 - permissions.deny は入力のルールを同じ順で先頭に残す
#   9. other_keys_same_as_input         - box 用に変える値以外は入力と同じ
#  10. sandbox_stays_on                 - sandbox.enabled / failIfUnavailable / network.strictAllowlist は true
#  11. allowed_domains_add_stripe_vercel - allowedDomains は入力の全エントリ + stripe / vercel の 5 つ
#  12. default_mode_accept_edits        - permissions.defaultMode は acceptEdits
#  13. additional_directories           - 入力から引き継ぐものに /workspace が足され、/home/box は入らない
#  14. enabled_plugins                  - box 用の有効 / 無効が入り、他の plugin は入力と同じ
#  15. deny_write_mapped (checkout ごと) - denyWrite は入力のエントリ（`**` 入りを除く）を残し、checkout パスと /workspace 配下に写したものと、
#                                         ~/.claude へ symlink する指示書（checkout の claude-code/*.md）と box 構成の入力が足される
#  16. deny_write_example               - ~/ghq/*/*/*/.git/config → /workspace/*/.git/config と <checkout>/.git/config
#  17. edit_deny_mapped (checkout ごと)  - permissions.deny に、入力の ~/ghq 起点の Edit ルールと ~/ghq 起点の denyWrite を
#                                         `//` 始まりの checkout パスと /workspace 配下（深さを問わない）に写した Edit ルールと、
#                                         ~/.claude へ symlink する指示書（checkout の claude-code/*.md）と box 構成の入力の Edit ルールが足される
#  18. edit_deny_example                - checkout の box 構成の入力・claude-code/*.md・claude-code/hooks と /workspace 配下の .git/hooks・.claude/settings.json が
#                                         Edit で塞がれる（具体例）
#  19. no_single_slash_path_rules      - 生成物の Edit / Read / Write / MultiEdit / NotebookEdit のルールに単一の / 始まり（settings ファイル起点の
#                                         相対になる）のパスが無い
#  20. allow_edit_tools_workspace_only  - permissions.allow は入力のエントリ + Workflow（承認ダイアログに巨大な script が出ないようにする）。
#                                         素の Edit / Write / MultiEdit は /workspace 配下だけに当たる同じツールのルールに置き換わる
#  21. deny_write_box_config_inputs     - box 構成の入力（checkout の home-manager/grokbot-linux・claude-code/settings.json・flake.nix）が
#                                         denyWrite に入る（具体例。Edit の deny は 18 で確かめる）
#  22. checkout_trailing_slash          - checkout を末尾 / 付きで渡しても、末尾 / 無しと同じ生成物になる（deny のパスに // が混じらない）
#  23. deny_write_no_double_star (checkout ごと)      - denyWrite に `**` 入りのエントリが残らない（Linux の sandbox は glob を展開しない）
#  24. deny_write_double_star_targets (checkout ごと) - 入力の `**` のエントリ（~/ghq/**/.githooks 等）が守る対象は、
#                                         checkout 直下の具体パス（<checkout>/.githooks 等）で denyWrite に入る
#  25. edit_deny_path_and_subtree (checkout ごと) - 生成物の denyWrite の /workspace 配下（checkout 自身を除く）の各エントリは、
#                                         そのパスと配下（/**）の両方の Edit ルールで塞がれる
#  26. edit_tool_rules_absolute         - box で足す Edit / Write / MultiEdit のルールのパスは `//` 始まりの絶対パス

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/grokbot-linux-settings-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

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

summary() {
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  if [ "${FAIL}" -gt 0 ]; then
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
      echo "  - ${err}"
    done
    exit 1
  fi
}

INPUT="$REPO_ROOT/claude-code/settings.json"
FILTER="$REPO_ROOT/home-manager/grokbot-linux/settings.jq"

# box 構成の既定の checkout パスと、別の場所に置いたときのパス
DEFAULT_CHECKOUT="/workspace/dotfiles"
OTHER_CHECKOUT="/srv/box/dotfiles-checkout"

generate() {
  jq --arg checkout "$1" -f "$FILTER" "$INPUT"
}

if generate "$DEFAULT_CHECKOUT" >"$TMPROOT/default.json" 2>"$TMPROOT/default.err" &&
  generate "$OTHER_CHECKOUT" >"$TMPROOT/other.json" 2>"$TMPROOT/other.err"; then
  pass "generates"
else
  fail "generates" "変換に失敗した ($(cat "$TMPROOT"/*.err))"
  summary
fi

# 期待値・実測値を作る jq 式の共通部分。$i が入力（Mac 版）、$o が生成物、$checkout が生成に渡した checkout パス
cat >"$TMPROOT/prelude.jq" <<'JQ'
# macOS 専用の値
def mac_only:
  type == "string"
  and test("/Library/|/opt/homebrew|osascript|moshi|\\.orbstack|\\.lima/|docker-proxy|/private/tmp/claude-[0-9]+");
def tmp: if type == "string" and startswith("/private/tmp/") then "/tmp/" + .[13:] else . end;
# 入力のリストのうち box に引き継ぐエントリ
def kept: map(select(mac_only | not) | tmp);
# hook を 1 件ずつ {イベント, matcher グループの hooks 以外, hook} に開く
def flat_hooks: [to_entries[] | .key as $e | .value[] | del(.hooks) as $g | .hooks[] | {event: $e, group: $g, hook: .}];
# box 用に変える sandbox のキーを除く（残りは入力から引き継ぐ）
def without_box_sandbox_keys:
  del(.enabled, .failIfUnavailable, .network.strictAllowlist, .network.allowedDomains, .filesystem.denyWrite);
# box 構成の入力になる checkout のファイル（checkout 起点の相対パス）
def box_config_inputs: ["home-manager/grokbot-linux", "claude-code/settings.json", "flake.nix"];
$src[0] as $i | $o[0] as $o |
JQ

# check <名前> <生成物の JSON> <checkout> <期待値の jq 式> <実測値の jq 式>
check() {
  local name="$1" out="$2" checkout="$3" expected_expr="$4" actual_expr="$5"
  local prelude expected actual
  prelude="$(cat "$TMPROOT/prelude.jq")"
  if ! expected="$(jq -n -S --slurpfile src "$INPUT" --slurpfile o "$out" --arg checkout "$checkout" "$prelude $expected_expr" 2>&1)" ||
    ! actual="$(jq -n -S --slurpfile src "$INPUT" --slurpfile o "$out" --arg checkout "$checkout" "$prelude $actual_expr" 2>&1)"; then
    fail "$name" "jq 式を評価できない (expected=${expected:-} actual=${actual:-})"
    return
  fi
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    printf '%s\n' "$expected" >"$TMPROOT/expected.json"
    printf '%s\n' "$actual" >"$TMPROOT/actual.json"
    fail "$name" "期待値（<）と生成物（>）が違う: $(diff "$TMPROOT/expected.json" "$TMPROOT/actual.json" | grep '^[<>]' | head -20 | tr '\n' ' ')"
  fi
}

check_default() {
  check "$1" "$TMPROOT/default.json" "$DEFAULT_CHECKOUT" "$2" "$3"
}

# ---------------------------------------------------------------------------
# macOS 専用の値・meeting 用の値を除き、/private/tmp を /tmp にする
# ---------------------------------------------------------------------------
check_default "no_mac_only_values" '[]' '
  [$o.sandbox | .. | strings]
  + $o.permissions.additionalDirectories
  + ($o.env | to_entries | map(.key, .value))
  + [$o.hooks[][].hooks[].command]
  | map(select(mac_only))'

check_default "no_private_tmp" '[]' '
  [$o | del(.permissions.deny) | .. | strings | select(startswith("/private/tmp/"))]'

check_default "sandbox_lists_inherit_input" '
  $i.sandbox
  | walk(if type == "array" then kept else . end)
  | .filesystem.allowWrite -= ["~/Documents/meetings"]
  | .excludedCommands |= map(select(startswith("meeting ") | not))
  | without_box_sandbox_keys' '
  $o.sandbox | without_box_sandbox_keys'

check_default "env_inherits_input" '
  $i.env | with_entries(select(((.key | mac_only) or (.value | mac_only)) | not)) | map_values(tmp)' '
  $o.env'

check_default "hooks_inherit_input" '
  $i.hooks | flat_hooks | map(select(.hook.command | mac_only | not))' '
  $o.hooks | flat_hooks'

check_default "no_empty_hook_groups" '[]' '
  [$o.hooks | to_entries[] | select((.value | length) == 0 or any(.value[]; (.hooks | length) == 0)) | .key]'

check_default "deny_keeps_input" '$i.permissions.deny' '
  $o.permissions.deny[0:($i.permissions.deny | length)]'

check_default "other_keys_same_as_input" '
  $i
  | del(.sandbox, .env, .hooks, .enabledPlugins, .permissions.additionalDirectories, .permissions.defaultMode, .permissions.deny, .permissions.allow)
  | walk(tmp)' '
  $o
  | del(.sandbox, .env, .hooks, .enabledPlugins, .permissions.additionalDirectories, .permissions.defaultMode, .permissions.deny, .permissions.allow)'

# ---------------------------------------------------------------------------
# box 用に変える値
# ---------------------------------------------------------------------------
check_default "sandbox_stays_on" '[true, true, true]' '
  [$o.sandbox.enabled, $o.sandbox.failIfUnavailable, $o.sandbox.network.strictAllowlist]'

check_default "allowed_domains_add_stripe_vercel" '
  ["api.stripe.com", "stripe.com", "api.vercel.com", "vercel.com", "ai-gateway.vercel.sh"] as $added
  | $i.sandbox.network.allowedDomains + ($added - $i.sandbox.network.allowedDomains)' '
  $o.sandbox.network.allowedDomains'

check_default "default_mode_accept_edits" '"acceptEdits"' '$o.permissions.defaultMode'

# 素の Edit / Write / MultiEdit は /workspace 配下だけに当たる同じツールのルールに置き換わる（素のものは残らない）。
# 権限ルールの絶対パスは `//` で始める: `//path` がファイルシステムの絶対パス、`/path` は project root 起点の相対、
# `**` は深さを問わない一致（https://code.claude.com/docs/en/permissions の Read and Edit）
check_default "allow_edit_tools_workspace_only" '
  $i.permissions.allow
  | map(if . == "Edit" or . == "Write" or . == "MultiEdit" then . + "(//workspace/**)" else . end)
  | . + (["Workflow"] - .)' '
  $o.permissions.allow'

check_default "additional_directories" '
  ($i.permissions.additionalDirectories | kept) + ["/workspace"] - ["/home/box"]' '
  $o.permissions.additionalDirectories'

check_default "enabled_plugins" '
  $i.enabledPlugins + {
    "playpark-core@playpark": true,
    "dev-flow@playpark": true,
    "playpark-skills@playpark": true,
    "security-guidance@claude-plugins-official": true,
    "vercel@claude-plugins-official": true,
    "stripe@claude-plugins-official": true,
    "host-exec@playpark": false,
    "meeting@playpark": false,
    "bg-sessions@playpark": false,
    "mosh-paste@playpark": false
  }' '
  $o.enabledPlugins'

# ---------------------------------------------------------------------------
# denyWrite を checkout パスと /workspace 配下に写す（既定の checkout と、別の場所の checkout の両方で確かめる）
# ---------------------------------------------------------------------------
for case_name in default other; do
  if [ "$case_name" = default ]; then
    checkout="$DEFAULT_CHECKOUT"
  else
    checkout="$OTHER_CHECKOUT"
  fi
  check "deny_write_mapped ($case_name checkout)" "$TMPROOT/$case_name.json" "$checkout" '
    ($i.sandbox.filesystem.denyWrite | kept) as $base
    | $base
    + ($base | map(select(startswith("~/ghq/github.com/it-all-playpark/dotfiles/")) | $checkout + .[41:]))
    + ($base | map(select(startswith("~/ghq/*/*/")) | "/workspace" + .[9:]))
    + ($base | map(select(startswith("~/ghq/*/*/*/")) | $checkout + .[11:]))
    + ($base | map(select(startswith("~/ghq/**/")) | $checkout + .[8:]))
    + [$checkout + "/claude-code/*.md"]
    + (box_config_inputs | map($checkout + "/" + .))
    | map(select(contains("**") | not))
    | unique' '
    $o.sandbox.filesystem.denyWrite | unique'

  # Linux の sandbox は denyWrite の glob を展開しないので、`**` 入りのエントリは効かない（#501）
  check "deny_write_no_double_star ($case_name checkout)" "$TMPROOT/$case_name.json" "$checkout" '[]' '
    [$o.sandbox.filesystem.denyWrite[] | select(contains("**"))]'

  # 入力の `**` のエントリが守る対象（.githooks 等）は、checkout 直下の具体パスで残る
  check "deny_write_double_star_targets ($case_name checkout)" "$TMPROOT/$case_name.json" "$checkout" '
    [$i.sandbox.filesystem.denyWrite[] | select(contains("**")) | $checkout + "/" + (split("/") | last)]' '
    [$i.sandbox.filesystem.denyWrite[] | select(contains("**")) | $checkout + "/" + (split("/") | last)
     | select(. as $p | $o.sandbox.filesystem.denyWrite | index($p) != null)]'
done

check_default "deny_write_example" '
  $i.sandbox.filesystem.denyWrite | index("~/ghq/*/*/*/.git/config") != null' '
  $o.sandbox.filesystem.denyWrite | (index("/workspace/*/.git/config") != null and index($checkout + "/.git/config") != null)'

check_default "deny_write_box_config_inputs" '[true, true, true]' '
  $o.sandbox.filesystem.denyWrite as $d
  | [
      ($d | index("/workspace/dotfiles/home-manager/grokbot-linux") != null),
      ($d | index("/workspace/dotfiles/claude-code/settings.json") != null),
      ($d | index("/workspace/dotfiles/flake.nix") != null)
    ]'

# checkout を末尾 / 付きで渡しても、末尾 / 無しと同じ生成物になる（deny のパスに `//` が混じらない）
if ! generate "$OTHER_CHECKOUT/" >"$TMPROOT/other-slash.json" 2>"$TMPROOT/other-slash.err"; then
  fail "checkout_trailing_slash" "変換に失敗した ($(cat "$TMPROOT/other-slash.err"))"
elif cmp -s "$TMPROOT/other.json" "$TMPROOT/other-slash.json"; then
  pass "checkout_trailing_slash"
else
  fail "checkout_trailing_slash" "末尾 / 無し（<）と末尾 / 付き（>）で生成物が違う: $(diff "$TMPROOT/other.json" "$TMPROOT/other-slash.json" | grep '^[<>]' | head -20 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# Edit の deny を checkout パスと /workspace 配下に写す（denyWrite は Bash にしか効かず、acceptEdits の Edit / Write を止めない）。
# 期待値は入力から作る: 入力の ~/ghq 起点の Edit ルールはそのパスを、~/ghq 起点の denyWrite はそのパスと配下（/**）を、
# `//` 始まりの絶対パスに写す（checkout は //<checkout>、~/ghq/*/*/ と ~/ghq/** は //workspace/** に）
# ---------------------------------------------------------------------------
for case_name in default other; do
  if [ "$case_name" = default ]; then
    checkout="$DEFAULT_CHECKOUT"
  else
    checkout="$OTHER_CHECKOUT"
  fi
  check "edit_deny_mapped ($case_name checkout)" "$TMPROOT/$case_name.json" "$checkout" '
    def to_box:
      if startswith("~/ghq/github.com/it-all-playpark/dotfiles/") then "/" + $checkout + .[41:]
      elif startswith("~/ghq/*/*/") then "//workspace/**" + .[9:]
      elif startswith("~/ghq/**") then "//workspace" + .[5:]
      else error("写す規則の無い ~/ghq パス: " + .) end;
    ($i.permissions.deny | map(select(startswith("Edit(~/ghq")) | .[5:-1] | "Edit(" + to_box + ")"))
    + ($i.sandbox.filesystem.denyWrite | map(select(startswith("~/ghq")) | to_box | ("Edit(" + . + ")", "Edit(" + . + "/**)")))
    + ["Edit(/" + $checkout + "/claude-code/*.md)"]
    + (box_config_inputs | map("/" + $checkout + "/" + . | ("Edit(" + . + ")", "Edit(" + . + "/**)")))
    | unique' '
    $o.permissions.deny[($i.permissions.deny | length):] | unique'

  # 生成物の denyWrite の /workspace 配下（checkout 自身を除く）の各エントリは、ファイルかディレクトリかを書き分けず、
  # そのパスと配下（/**）の両方の Edit ルールで塞がれる
  check "edit_deny_path_and_subtree ($case_name checkout)" "$TMPROOT/$case_name.json" "$checkout" '
    [$o.sandbox.filesystem.denyWrite[]
     | select(startswith("/workspace/") and (startswith($checkout + "/") | not))
     | "//workspace/**" + .[10:] | ("Edit(" + . + ")", "Edit(" + . + "/**)")]' '
    [$o.sandbox.filesystem.denyWrite[]
     | select(startswith("/workspace/") and (startswith($checkout + "/") | not))
     | "//workspace/**" + .[10:] | ("Edit(" + . + ")", "Edit(" + . + "/**)")
     | select(. as $r | $o.permissions.deny | index($r) != null)]'
done

check_default "edit_deny_example" '[true, true, true, true, true, true, true, true]' '
  $o.permissions.deny as $d
  | [
      ($d | index("Edit(//workspace/dotfiles/home-manager/grokbot-linux/**)") != null),
      ($d | index("Edit(//workspace/dotfiles/claude-code/settings.json)") != null),
      ($d | index("Edit(//workspace/dotfiles/flake.nix)") != null),
      ($d | index("Edit(//workspace/dotfiles/claude-code/*.md)") != null),
      ($d | index("Edit(//workspace/dotfiles/claude-code/hooks/**)") != null),
      ($d | index("Edit(//workspace/dotfiles/claude-code/bin/**)") != null),
      ($d | index("Edit(//workspace/**/*/.git/hooks/**)") != null),
      ($d | index("Edit(//workspace/**/*/.claude/settings.json)") != null)
    ]'

check_default "no_single_slash_path_rules" '[]' '
  [$o.permissions | (.allow, .deny, .ask) // [] | .[]
   | select(test("^(Edit|Read|Write|MultiEdit|NotebookEdit)\\(/[^/]"))]'

# box で足す Edit / Write / MultiEdit のルール（入力に無いもの）のパスは、すべて `//` 始まりの絶対パス
check_default "edit_tool_rules_absolute" '[]' '
  [$o.permissions | (.allow, .deny, .ask) // [] | .[]
   | select(test("^(Edit|Write|MultiEdit)\\("))
   | select(. as $r | $i.permissions | [(.allow, .deny, .ask) // [] | .[]] | index($r) == null)
   | select(test("^(Edit|Write|MultiEdit)\\(//[^/]") | not)]'

summary
echo "PASS: grokbot-linux-settings"
