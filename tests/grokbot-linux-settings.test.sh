#!/usr/bin/env bash
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
#   8. deny_same_as_input               - permissions.deny は入力と同じ
#   9. other_keys_same_as_input         - box 用に変える値以外は入力と同じ
#  10. sandbox_stays_on                 - sandbox.enabled / failIfUnavailable / network.strictAllowlist は true
#  11. allowed_domains_add_stripe_vercel - allowedDomains は入力の全エントリ + stripe / vercel の 5 つ
#  12. default_mode_accept_edits        - permissions.defaultMode は acceptEdits
#  13. additional_directories           - 入力から引き継ぐものに /workspace が足され、/home/box は入らない
#  14. enabled_plugins                  - box 用の有効 / 無効が入り、他の plugin は入力と同じ
#  15. deny_write_mapped (checkout ごと) - denyWrite は入力のエントリを残し、checkout パスと /workspace 配下に写したものが足される
#  16. deny_write_example               - ~/ghq/*/*/*/.git/config → /workspace/*/.git/config

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

check_default "deny_same_as_input" '$i.permissions.deny' '$o.permissions.deny'

check_default "other_keys_same_as_input" '
  $i
  | del(.sandbox, .env, .hooks, .enabledPlugins, .permissions.additionalDirectories, .permissions.defaultMode)
  | .permissions.deny as $deny
  | walk(tmp)
  | .permissions.deny = $deny' '
  $o
  | del(.sandbox, .env, .hooks, .enabledPlugins, .permissions.additionalDirectories, .permissions.defaultMode)'

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
    + ($base | map(select(startswith("~/ghq/**")) | "/workspace" + .[5:]))
    | unique' '
    $o.sandbox.filesystem.denyWrite | unique'
done

check_default "deny_write_example" '
  $i.sandbox.filesystem.denyWrite | index("~/ghq/*/*/*/.git/config") != null' '
  $o.sandbox.filesystem.denyWrite | index("/workspace/*/.git/config") != null'

summary
echo "PASS: grokbot-linux-settings"
