# gh / gcloud cwd 連動アカウント固定（PATH shim） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `gh` / `gcloud` を実行した cwd（`~/ghq/github.com/<org>/…`）に応じて、グローバル状態を一切書き換えずに正しいアカウント（`GH_CONFIG_DIR` / `CLOUDSDK_ACTIVE_CONFIG_NAME`）が使われる PATH shim を dotfiles に入れ、home-manager で `~/.claude/bin` を全シェルの PATH 先頭に載せる。あわせて sandbox 起因の `gcloud` 書込み失敗を settings.json で解消する。

**Architecture:** `claude-code/bin/account-exec`（bash、`$0` の basename で gh/gcloud を判定）へ `bin/gh` / `bin/gcloud` を symlink。shim は `$PWD` から org を取り、`~/.claude/account-map.json` を `jq` で引いて env を export し、PATH から shim dir（`$HOME/.claude/bin` と自身の物理 dir）を除いて解決した実体を `exec` する（exec 先の PATH は元のまま）。fail-open で passthrough。home-manager の `setupClaudeCode` activation が `bin/*` と `account-map.json` を `~/.claude/` へ symlink し、`zsh.nix` / `fish.nix` が `~/.claude/bin` を PATH 先頭に追加する。設計の唯一のソースは `docs/specs/2026-09-19-claude-account-env-design.md`。

**Tech Stack:** bash（`set -euo pipefail`、`jq` 必須）、Nix Flakes（nix-darwin + home-manager、treefmt: nixfmt / shfmt / json-sort-cli / ruff / stylua）、自前 PASS/FAIL 形式の bash テスト

## Global Constraints

- 作業ディレクトリは worktree `/Users/naramotoyuuji/ghq/github.com/it-all-playpark/dotfiles/.claude/worktrees/claude-account-env`（ブランチ `worktree-claude-account-env`）。全コマンドをここから実行し、絶対パスを使う
- `nix run .#update` は agent 実行不可（sandbox）。agent の検証範囲は `nix fmt -- --no-cache` / `nix flake check` / `nix eval` / 各 `*.test.sh` まで。apply は人間（Task 7）
- `claude-code/settings.json` は agent の sandbox で write deny（自己改変ガード）。agent は Edit/Write を試みず、diff を提示して人間が適用する（Task 5）。`jq` で読む検証は可
- 一時ファイルは `mktemp -d "${TMPDIR:-/tmp}/xxx.XXXXXX"`。`/tmp` 直書き禁止。`$CLAUDE_JOB_DIR/tmp` も使わない
- shellcheck / shfmt は素の PATH に無い。`nix develop -c shellcheck …` と `nix develop -c treefmt --no-cache --stdin <name>.sh < <file>` で呼ぶ（devShell に `treefmt` wrapper と `shellcheck` が入っていること、`treefmt --stdin` の存在を確認済み）
- pre-commit hook は staged の `*.sh` にしか shellcheck をかけない。拡張子なしの `claude-code/bin/account-exec` は Task 内で明示的に shellcheck / shfmt する
- `nix fmt` の json-sort-cli は autofix で JSON のキーをソートし final newline を入れる。`account-map.json` は `nix fmt` 後の状態を commit する（キー順が変わっても正）
- 削除は `rip`、機械的な文字列置換は `sd`（sed ではない）。symlink 作成は `ln -s`
- commit message は Conventional Commits + 絵文字（`feat(claude): ✨ …` / `test: ✅ …` / `chore(hm): 🔧 …` / `docs: 📝 …`）。日本語本文可。保護ブランチへの push 禁止、PR 経由
- 既存 spec §6 の処理順（1 明示指定→2 org 抽出→3 マップ→4 env set→5 実体解決→6 再帰防止）と §9 の 12 ケースを全て満たす。ADC 分離・gcloud の sandbox 除外・repo 単位マップ・launchd PATH はスコープ外
- flake の home attr 名は `homeConfigurations.naramotoyuuji-darwin`（確認済み）。macOS の `readlink -f` は動作確認済み。`fish` の実行は agent の permission で拒否されるので fish 側の PATH 順確認は Task 7（人間）
- 大西配列（`tnrs`）は本タスクに無関係。Neovim 等の設定には触れない

---

### Task 1: account-map.json + shim 本体 + テスト（基本 6 ケース）

**Files:**
- Create: `claude-code/account-map.json`
- Create: `claude-code/bin/account-exec`（実行ビット付き）
- Create: `claude-code/bin/gh`（相対 symlink → `account-exec`）
- Create: `claude-code/bin/gcloud`（相対 symlink → `account-exec`）
- Test: `claude-code/bin/account-exec.test.sh`

**Interfaces:**
- Consumes: `$0`（basename）、`$PWD` / `pwd -P`、`$HOME`、`$PATH`、env `ACCOUNT_MAP`（既定 `$HOME/.claude/account-map.json`）、env `ACCOUNT_EXEC_DEBUG`、`jq`
- Produces: 子プロセス env `GH_CONFIG_DIR` または `CLOUDSDK_ACTIVE_CONFIG_NAME`、実体への `exec "$real" "$@"`、stderr 警告（`account-exec: …` 1 行）、exit 2（未対応ツール名）/ 127（実体不在・自己再帰）

- [ ] **Step 1: `claude-code/account-map.json` を作成する**

```json
{
  "orgs": {
    "BusinessProcessDX": {
      "gcloud_config": "th-it-all",
      "gh_config_dir": "~/.config/gh-th-it-dev"
    },
    "Cistree-dev": {
      "gcloud_config": "default",
      "gh_config_dir": "~/.config/gh"
    },
    "YujiNaramoto": {
      "gcloud_config": "default",
      "gh_config_dir": "~/.config/gh"
    },
    "it-all-playpark": {
      "gcloud_config": "default",
      "gh_config_dir": "~/.config/gh"
    },
    "playpark-llc": {
      "gcloud_config": "default",
      "gh_config_dir": "~/.config/gh"
    }
  }
}
```

Run: `jq -e '.orgs | keys | length == 5' claude-code/account-map.json`
Expected: `true`

- [ ] **Step 2: 失敗するテスト（ケース 1〜6）を `claude-code/bin/account-exec.test.sh` に書く**

```bash
#!/usr/bin/env bash
# claude-code/bin/account-exec.test.sh
# gh / gcloud の cwd 連動アカウント shim (account-exec) のテスト。
# 設計: docs/specs/2026-09-19-claude-account-env-design.md §9
#
# Usage: bash claude-code/bin/account-exec.test.sh
#
# $TMPDIR 配下に一時 HOME を作り、ghq/github.com/<org>/repo/.claude/worktrees/x を掘る。
# fake の gh / gcloud（受け取った env と argv を 1 行ずつ出すだけ）を一時 dir に置き、
# shim dir ($HOME_T/.claude/bin、実運用と同じ位置) から実物の bin/gh, bin/gcloud を
# symlink して呼ぶ。ACCOUNT_MAP は一時ファイル。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/account-exec"

if [[ ! -x $SHIM ]]; then
  echo "FAIL: shim not executable: $SHIM" >&2
  exit 1
fi
for t in gh gcloud; do
  if [[ ! -L "$SCRIPT_DIR/$t" || "$(readlink "$SCRIPT_DIR/$t")" != "account-exec" ]]; then
    echo "FAIL: $SCRIPT_DIR/$t must be a symlink to account-exec" >&2
    exit 1
  fi
done

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/account-exec-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

pass() {
  printf "  \033[32mPASS\033[0m %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31mFAIL\033[0m %s\n" "$1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
}

# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------
HOME_T="$TMPROOT/home"
FAKE_BIN="$TMPROOT/fake-bin"
SHIM_BIN="$HOME_T/.claude/bin"
MAP="$TMPROOT/account-map.json"
ORG_REPO="$HOME_T/ghq/github.com/acme/repo"
ORG_WT="$ORG_REPO/.claude/worktrees/x"
GHONLY_REPO="$HOME_T/ghq/github.com/ghonly/repo"
UNMAPPED_REPO="$HOME_T/ghq/github.com/nobody/repo"
OUTSIDE_DIR="$HOME_T/elsewhere"

mkdir -p "$FAKE_BIN" "$SHIM_BIN" "$ORG_WT" "$GHONLY_REPO" "$UNMAPPED_REPO" "$OUTSIDE_DIR" "$TMPROOT/empty-bin"

for t in gh gcloud; do
  cat >"$FAKE_BIN/$t" <<'EOF'
#!/usr/bin/env bash
printf 'GH_CONFIG_DIR=%s\n' "${GH_CONFIG_DIR-<unset>}"
printf 'CLOUDSDK_ACTIVE_CONFIG_NAME=%s\n' "${CLOUDSDK_ACTIVE_CONFIG_NAME-<unset>}"
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
exit "${FAKE_EXIT:-0}"
EOF
  chmod +x "$FAKE_BIN/$t"
  # 実運用と同じ 2 段: ~/.claude/bin/gh → claude-code/bin/gh → account-exec
  ln -s "$SCRIPT_DIR/$t" "$SHIM_BIN/$t"
done

cat >"$MAP" <<'EOF'
{
  "orgs": {
    "acme": { "gh_config_dir": "~/.config/gh-acme", "gcloud_config": "acme-cfg" },
    "ghonly": { "gh_config_dir": "~/.config/gh-ghonly" }
  }
}
EOF

# run_shim <cwd> <tool> [args...]
#   RUN_PATH / RUN_MAP / RUN_ENV (配列) で上書き可。結果は OUT / ERR / RC に入る。
RUN_PATH="$SHIM_BIN:$FAKE_BIN"
RUN_MAP="$MAP"
RUN_ENV=()
OUT=""
ERR=""
RC=0
run_shim() {
  local dir="$1" tool="$2"
  shift 2
  set +e
  OUT="$(cd "$dir" && env -u GH_CONFIG_DIR -u CLOUDSDK_ACTIVE_CONFIG_NAME \
    HOME="$HOME_T" PATH="$RUN_PATH" ACCOUNT_MAP="$RUN_MAP" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SHIM_BIN/$tool" "$@" 2>"$TMPROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
}

reset_run() {
  RUN_PATH="$SHIM_BIN:$FAKE_BIN"
  RUN_MAP="$MAP"
  RUN_ENV=()
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

echo "=== account-exec tests ==="

# ---------------------------------------------------------------------------
# 1. mapped org の repo 直下で gh → GH_CONFIG_DIR が ~ 展開済みで届く
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=$HOME_T/.config/gh-acme"; then
  pass "01_mapped_org_gh_sets_config_dir"
else
  fail "01_mapped_org_gh_sets_config_dir" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 2. worktree パス …/<org>/repo/.claude/worktrees/x でも 1 と同じ
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_WT" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=$HOME_T/.config/gh-acme"; then
  pass "02_worktree_path_gh_sets_config_dir"
else
  fail "02_worktree_path_gh_sets_config_dir" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 3. mapped org で gcloud → CLOUDSDK_ACTIVE_CONFIG_NAME
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_REPO" gcloud config list
if [[ $RC -eq 0 ]] && contains "$OUT" "CLOUDSDK_ACTIVE_CONFIG_NAME=acme-cfg"; then
  pass "03_mapped_org_gcloud_sets_config_name"
else
  fail "03_mapped_org_gcloud_sets_config_name" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 4. gcloud_config を省略した org で gcloud → env 未設定のまま実体へ
# ---------------------------------------------------------------------------
reset_run
run_shim "$GHONLY_REPO" gcloud config list
if [[ $RC -eq 0 ]] && contains "$OUT" "CLOUDSDK_ACTIVE_CONFIG_NAME=<unset>" && [[ -z $ERR ]]; then
  pass "04_missing_key_leaves_env_unset"
else
  fail "04_missing_key_leaves_env_unset" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 5. 未登録 org / ghq 外 → env 未設定、stderr 空、argv そのまま
# ---------------------------------------------------------------------------
reset_run
run_shim "$UNMAPPED_REPO" gh repo view
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" && [[ -z $ERR ]] &&
  contains "$OUT" $'argc=2\narg=[repo]\narg=[view]'; then
  pass "05a_unmapped_org_passthrough"
else
  fail "05a_unmapped_org_passthrough" "rc=$RC out=$OUT err=$ERR"
fi

reset_run
run_shim "$OUTSIDE_DIR" gh repo view
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" && [[ -z $ERR ]] &&
  contains "$OUT" $'argc=2\narg=[repo]\narg=[view]'; then
  pass "05b_outside_ghq_passthrough"
else
  fail "05b_outside_ghq_passthrough" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 6. マップ不在 / JSON 不正 → env 未設定で実体へ、stderr に警告 1 行
# ---------------------------------------------------------------------------
reset_run
RUN_MAP="$TMPROOT/missing.json"
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" &&
  [[ "$(printf '%s\n' "$ERR" | grep -c '^account-exec:')" -eq 1 ]]; then
  pass "06a_missing_map_warns_once_and_passes_through"
else
  fail "06a_missing_map_warns_once_and_passes_through" "rc=$RC out=$OUT err=$ERR"
fi

reset_run
echo '{ "orgs": { not json' >"$TMPROOT/bad.json"
RUN_MAP="$TMPROOT/bad.json"
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=<unset>" &&
  [[ "$(printf '%s\n' "$ERR" | grep -c '^account-exec:')" -eq 1 ]]; then
  pass "06b_invalid_json_warns_once_and_passes_through"
else
  fail "06b_invalid_json_warns_once_and_passes_through" "rc=$RC out=$OUT err=$ERR"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "PASS: account-exec"
```

Run: `mkdir -p claude-code/bin && bash claude-code/bin/account-exec.test.sh; echo "exit=$?"`
Expected: `FAIL: shim not executable: …/claude-code/bin/account-exec` と `exit=1`（shim 未作成のため red）

- [ ] **Step 3: shim 本体 `claude-code/bin/account-exec` を書き、symlink を張る**

```bash
#!/usr/bin/env bash
# account-exec: gh / gcloud の cwd 連動アカウント固定 shim
#
# bin/gh と bin/gcloud はこのファイルへの symlink。$0 の basename で対象ツールを判定し、
# $PWD が $HOME/ghq/github.com/<org>/ 配下なら account-map.json を引いて
# GH_CONFIG_DIR / CLOUDSDK_ACTIVE_CONFIG_NAME を付け、PATH から shim dir を除いて
# 解決した実体を exec する。exec 先の PATH は元のまま（git → gh の credential helper
# 呼び出しも shim を通り続けるため）。
#
# 設計: docs/specs/2026-09-19-claude-account-env-design.md
#
# 環境変数:
#   ACCOUNT_MAP         マップの場所（既定 $HOME/.claude/account-map.json）
#   ACCOUNT_EXEC_DEBUG  =1 で判定結果を stderr に 1 行出す
#
# fail 方針は fail-open: マップ不在 / JSON 不正 / jq 不在 / 値が不正 のときは
# env を付けずに実体へ passthrough し、stderr に 1 行だけ警告する。
set -euo pipefail

tool="$(basename "$0")"
case "$tool" in
  gh)
    var=GH_CONFIG_DIR
    key=gh_config_dir
    ;;
  gcloud)
    var=CLOUDSDK_ACTIVE_CONFIG_NAME
    key=gcloud_config
    ;;
  *)
    echo "account-exec: unsupported tool name '$tool' (expected gh or gcloud)" >&2
    exit 2
    ;;
esac

warn() {
  echo "account-exec: $*" >&2
}

# $1 が $HOME/ghq/github.com/<org>/... なら <org> を出力、それ以外は空
org_of() {
  local rest
  case "$1" in
    "$HOME/ghq/github.com/"*)
      rest="${1#"$HOME/ghq/github.com/"}"
      printf '%s' "${rest%%/*}"
      ;;
  esac
}

org=""
val=""

# 1. 対象 env が既に set なら判定しない（明示指定、および shim が付けた env を
#    継承した孫プロセス gh → git → gh の二重判定防止）
if [ -z "${!var+x}" ]; then
  # 2. $PWD で判定。不一致なら pwd -P（symlink 解決後）で再試行
  org="$(org_of "$PWD")"
  if [ -z "$org" ]; then
    org="$(org_of "$(pwd -P)")"
  fi

  # 3. マップを引く
  if [ -n "$org" ]; then
    ACCOUNT_MAP="${ACCOUNT_MAP:-$HOME/.claude/account-map.json}"
    if ! command -v jq >/dev/null 2>&1; then
      warn "jq not found; passthrough without account mapping"
    elif [ ! -f "$ACCOUNT_MAP" ]; then
      warn "account map not found: $ACCOUNT_MAP; passthrough"
    else
      # 1 回の jq で「JSON 不正 / 未登録 / 値がオブジェクトでない / 値」を判別する
      result="$(jq -r --arg org "$org" --arg key "$key" '
        if type != "object" then "invalid"
        elif (.orgs | type) != "object" then "unmapped"
        elif (.orgs[$org] | type) == "null" then "unmapped"
        elif (.orgs[$org] | type) != "object" then "notobject"
        else "ok " + ((.orgs[$org][$key] // "") | tostring)
        end' "$ACCOUNT_MAP" 2>/dev/null)" || result="invalid"
      case "$result" in
        invalid) warn "account map is not valid JSON: $ACCOUNT_MAP; passthrough" ;;
        unmapped) ;;
        notobject) warn "orgs.$org in $ACCOUNT_MAP is not an object; passthrough" ;;
        "ok "*) val="${result#ok }" ;;
      esac

      # 4. 値を検査し、先頭の ~ だけ $HOME に展開して env に set
      case "$val" in
        "") ;;
        *"'"* | *$'\n'*)
          warn "orgs.$org.$key in $ACCOUNT_MAP contains a quote or newline; passthrough"
          val=""
          ;;
        "~") val="$HOME" ;;
        "~/"*) val="$HOME/${val#"~/"}" ;;
      esac
      if [ -n "$val" ]; then
        # shellcheck disable=SC2163
        export "$var=$val"
      fi
    fi
  fi
fi

# 5. PATH から shim dir（$HOME/.claude/bin と自身の物理 dir）を除いて実体を解決
self="$0"
if resolved="$(readlink -f "$0" 2>/dev/null)" && [ -n "$resolved" ]; then
  self="$resolved"
fi
self_dir="$(cd "$(dirname "$self")" && pwd -P)"
shim_dirs=":$HOME/.claude/bin:$self_dir:"
if home_bin_phys="$(cd "$HOME/.claude/bin" 2>/dev/null && pwd -P)"; then
  shim_dirs="$shim_dirs$home_bin_phys:"
fi

lookup_path=""
p_rest="$PATH:"
while [ -n "$p_rest" ]; do
  p="${p_rest%%:*}"
  p_rest="${p_rest#*:}"
  [ -z "$p" ] && continue
  p_phys="$(cd "$p" 2>/dev/null && pwd -P)" || p_phys="$p"
  case "$shim_dirs" in
    *":$p:"* | *":$p_phys:"*) continue ;;
  esac
  lookup_path="${lookup_path:+$lookup_path:}$p"
done

real=""
if [ -n "$lookup_path" ]; then
  real="$(PATH="$lookup_path" command -v "$tool" 2>/dev/null || true)"
fi
if [ -z "$real" ]; then
  echo "account-exec: real '$tool' not found in PATH (shim dirs excluded: $HOME/.claude/bin, $self_dir)" >&2
  exit 127
fi
# 6. 解決先が shim 自身（同一 inode）なら再帰しない
if [ "$real" -ef "$self" ]; then
  echo "account-exec: resolved '$tool' is the shim itself ($real); refusing to recurse" >&2
  exit 127
fi

if [ "${ACCOUNT_EXEC_DEBUG:-}" = 1 ]; then
  echo "account-exec: tool=$tool org=${org:-<none>} $var=${!var-<unset>} exec=$real" >&2
fi

exec "$real" "$@"
```

Run:
```bash
chmod +x claude-code/bin/account-exec
ln -s account-exec claude-code/bin/gh
ln -s account-exec claude-code/bin/gcloud
ls -l claude-code/bin
```
Expected: `account-exec` が `-rwxr-xr-x`、`gh -> account-exec`、`gcloud -> account-exec`

- [ ] **Step 4: テストを通す**

Run: `bash claude-code/bin/account-exec.test.sh`
Expected: `Results: 8 passed, 0 failed` と `PASS: account-exec`（01, 02, 03, 04, 05a, 05b, 06a, 06b）

- [ ] **Step 5: 未対応ツール名の exit 2 を手で確認する**

Run:
```bash
T="$(mktemp -d "${TMPDIR:-/tmp}/ae-name.XXXXXX")" && ln -s "$PWD/claude-code/bin/account-exec" "$T/foo" && "$T/foo"; echo "exit=$?"; rip "$T"
```
Expected: stderr に `account-exec: unsupported tool name 'foo' (expected gh or gcloud)`、`exit=2`

- [ ] **Step 6: shellcheck / shfmt（拡張子なしファイルは手動）**

Run:
```bash
nix develop -c shellcheck claude-code/bin/account-exec claude-code/bin/account-exec.test.sh
nix develop -c treefmt --no-cache --stdin claude-code/bin/account-exec.sh < claude-code/bin/account-exec > "${TMPDIR:-/tmp}/account-exec.fmt"
diff "${TMPDIR:-/tmp}/account-exec.fmt" claude-code/bin/account-exec && echo "shfmt: clean"
```
Expected: shellcheck は出力なし（exit 0）。diff は差分なしで `shfmt: clean`。差分が出たら `cp "${TMPDIR:-/tmp}/account-exec.fmt" claude-code/bin/account-exec` して Step 4 を再実行

- [ ] **Step 7: `nix fmt` を当てて commit**

Run:
```bash
nix fmt -- --no-cache
git status --short
bash claude-code/bin/account-exec.test.sh | tail -2
git add claude-code/account-map.json claude-code/bin/account-exec claude-code/bin/gh claude-code/bin/gcloud claude-code/bin/account-exec.test.sh
git commit -m "feat(claude): ✨ gh / gcloud の cwd 連動アカウント shim (bin/account-exec) と account-map.json を追加

\$PWD の ~/ghq/github.com/<org>/ から org を判定し、GH_CONFIG_DIR /
CLOUDSDK_ACTIVE_CONFIG_NAME を付けて PATH 上の実体を exec する。
グローバル状態 (hosts.yml / active_config) は書き換えない。
設計: docs/specs/2026-09-19-claude-account-env-design.md"
```
Expected: `git status --short` は `account-map.json` / `account-exec.test.sh` が json-sort-cli / shfmt で整形されていても可。テストは `Results: 8 passed, 0 failed`。commit 成功（pre-commit の shellcheck は `*.test.sh` にかかる）

---

### Task 2: shim テスト残り 6 ケース（7〜12）

**Files:**
- Modify: `claude-code/bin/account-exec.test.sh`（`# --- Summary` の直前に追記）
- Modify（必要時のみ）: `claude-code/bin/account-exec`

**Interfaces:**
- Consumes: Task 1 の `run_shim` / `reset_run` / `contains` / `pass` / `fail`、`RUN_PATH` / `RUN_MAP` / `RUN_ENV`
- Produces: ケース 07〜12 の PASS/FAIL 行

- [ ] **Step 1: ケース 7〜12 を `# --- Summary` の直前に挿入する**

`claude-code/bin/account-exec.test.sh` の行 `# --- Summary ---------------------------------------------------------------` の直前に以下を挿入する（Edit ツールで `old_string` を Summary 行、`new_string` を「以下 + Summary 行」にする）:

```bash
# ---------------------------------------------------------------------------
# 7. GH_CONFIG_DIR を事前に set して mapped org で gh → 事前の値を上書きしない
# ---------------------------------------------------------------------------
reset_run
RUN_ENV=("GH_CONFIG_DIR=$TMPROOT/preset-gh")
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$OUT" "GH_CONFIG_DIR=$TMPROOT/preset-gh" && [[ -z $ERR ]]; then
  pass "07_preset_env_is_not_overridden"
else
  fail "07_preset_env_is_not_overridden" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 8. 空白・引用符・--flag=value・空文字・$ を含む引数が 1 要素も欠けず壊れず届く
# ---------------------------------------------------------------------------
reset_run
run_shim "$ORG_REPO" gh pr create --title "hello world" --body "it's \"quoted\"" --label=a,b "" '$HOME'
expected_args='argc=9
arg=[pr]
arg=[create]
arg=[--title]
arg=[hello world]
arg=[--body]
arg=[it'"'"'s "quoted"]
arg=[--label=a,b]
arg=[]
arg=[$HOME]'
actual_args="$(printf '%s\n' "$OUT" | sed -n '3,$p')"
if [[ $RC -eq 0 && $actual_args == "$expected_args" ]]; then
  pass "08_argv_passed_verbatim"
else
  fail "08_argv_passed_verbatim" "rc=$RC actual=$actual_args err=$ERR"
fi

# ---------------------------------------------------------------------------
# 9. 実体が PATH に無い → exit 127、stderr にツール名
# ---------------------------------------------------------------------------
reset_run
RUN_PATH="$SHIM_BIN:$TMPROOT/empty-bin"
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 127 ]] && contains "$ERR" "gh" && contains "$ERR" "account-exec:"; then
  pass "09_missing_real_binary_exits_127"
else
  fail "09_missing_real_binary_exits_127" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 10. PATH に shim dir しか無い → exit 127（無限再帰しない）
# ---------------------------------------------------------------------------
reset_run
RUN_PATH="$SHIM_BIN"
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 127 ]] && contains "$ERR" "account-exec:"; then
  pass "10_shim_only_path_exits_127_without_recursion"
else
  fail "10_shim_only_path_exits_127_without_recursion" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 11. ACCOUNT_EXEC_DEBUG=1 → stderr に org / env / exec 先
# ---------------------------------------------------------------------------
reset_run
RUN_ENV=("ACCOUNT_EXEC_DEBUG=1")
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 0 ]] && contains "$ERR" "org=acme" &&
  contains "$ERR" "GH_CONFIG_DIR=$HOME_T/.config/gh-acme" &&
  contains "$ERR" "exec=$FAKE_BIN/gh"; then
  pass "11_debug_prints_decision"
else
  fail "11_debug_prints_decision" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 12. 実体の exit code が非 0 → shim の exit code も同じ
# ---------------------------------------------------------------------------
reset_run
RUN_ENV=("FAKE_EXIT=7")
run_shim "$ORG_REPO" gh auth status
if [[ $RC -eq 7 ]]; then
  pass "12_exit_code_propagates"
else
  fail "12_exit_code_propagates" "rc=$RC out=$OUT err=$ERR"
fi

```

Run: `bash claude-code/bin/account-exec.test.sh`
Expected: `Results: 14 passed, 0 failed`。FAIL が出た場合はその行の `rc= out= err=` を根拠に `account-exec` を直す（テストを緩めない）。特に 10 で 127 以外なら §6-5 の shim dir 除外（`shim_dirs` の文字列一致と物理パス一致）を疑う

- [ ] **Step 2: shellcheck / shfmt / nix fmt**

Run:
```bash
nix develop -c shellcheck claude-code/bin/account-exec claude-code/bin/account-exec.test.sh
nix develop -c treefmt --no-cache --stdin claude-code/bin/account-exec.sh < claude-code/bin/account-exec > "${TMPDIR:-/tmp}/account-exec.fmt"
diff "${TMPDIR:-/tmp}/account-exec.fmt" claude-code/bin/account-exec && echo "shfmt: clean"
nix fmt -- --no-cache
bash claude-code/bin/account-exec.test.sh | tail -2
```
Expected: shellcheck 出力なし、`shfmt: clean`、`Results: 14 passed, 0 failed`

- [ ] **Step 3: commit**

Run:
```bash
git add claude-code/bin/account-exec.test.sh claude-code/bin/account-exec
git commit -m "test(claude): ✅ account-exec の事前 env / argv 保全 / 127 / DEBUG / exit code のテストを追加 (spec §9 #7-12)"
```
Expected: commit 成功

---

### Task 3: home-manager activation（bin / account-map symlink）+ テスト

**Files:**
- Modify: `home-manager/home/default.nix`（`activation.setupClaudeCode` 内 2 箇所）
- Test: `tests/claude-bin-symlink.test.sh`

**Interfaces:**
- Consumes: 既存の `DOTFILES_CLAUDE` / `CLAUDE_DIR` シェル変数、`# hooks-symlink: begin/end` と同じマーカー流儀
- Produces: `~/.claude/bin/{account-exec,gh,gcloud}` → `dotfiles/claude-code/bin/*` の symlink（`*.test.sh` 除外、dangling 掃除つき）、`~/.claude/account-map.json` → `dotfiles/claude-code/account-map.json`。テストは `# bin-symlink: begin/end` と `# account-map-symlink: begin/end` の 2 ブロックを `sed -n` で抽出して検証する

- [ ] **Step 1: 失敗するテスト `tests/claude-bin-symlink.test.sh` を書く**

```bash
#!/usr/bin/env bash
# tests/claude-bin-symlink.test.sh
# home-manager/home/default.nix の activation.setupClaudeCode 内、
# `# bin-symlink: begin` / `: end` と `# account-map-symlink: begin` / `: end` で
# 囲まれたブロックを抽出し、~/.claude/bin と ~/.claude/account-map.json の
# symlink 管理ロジックを単体で検証する。
#
# 検証項目:
#   1. marker_blocks_found               - 両マーカーブロックが見つかる
#   2. links_account_exec_and_tool_links  - account-exec と repo 内 symlink (gh, gcloud) が
#                                           ~/.claude/bin に symlink される（gh は
#                                           dotfiles 側 bin/gh を指す 2 段構成）
#   3. skips_test_sh                      - *.test.sh は symlink されない
#   4. removes_dangling_dotfiles_symlink  - dotfiles/claude-code/bin を指す dangling
#                                           symlink は削除される
#   5. keeps_dangling_foreign_symlink     - dotfiles 以外を指す dangling symlink は残る
#   6. keeps_real_file                    - dotfiles に無い名前の実ファイルは残る
#   7. links_account_map                  - account-map.json が symlink される
#   8. skips_account_map_when_absent      - dotfiles 側に無ければ何もしない（エラーなし）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-bin-symlink-test.XXXXXX")"
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

# ---------------------------------------------------------------------------
# ブロック抽出
# ---------------------------------------------------------------------------
DEFAULT_NIX="$REPO_ROOT/home-manager/home/default.nix"
BIN_BLOCK="$(sed -n '/# bin-symlink: begin/,/# bin-symlink: end/p' "$DEFAULT_NIX")"
MAP_BLOCK="$(sed -n '/# account-map-symlink: begin/,/# account-map-symlink: end/p' "$DEFAULT_NIX")"

if [ -z "$BIN_BLOCK" ] || [ -z "$MAP_BLOCK" ]; then
  fail "marker_blocks_found" "$DEFAULT_NIX にマーカー # bin-symlink / # account-map-symlink の begin/end が揃っていない"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
else
  pass "marker_blocks_found"
fi

{
  echo "$MAP_BLOCK"
  echo "$BIN_BLOCK"
} >"$TMPROOT/block.sh"

run_block() {
  local dotfiles_claude="$1"
  local claude_dir="$2"
  DOTFILES_CLAUDE="$dotfiles_claude" CLAUDE_DIR="$claude_dir" bash -c 'set -eu; source "$1"' _ "$TMPROOT/block.sh"
}

# ---------------------------------------------------------------------------
# シナリオ 2 & 3 & 7: links_account_exec_and_tool_links / skips_test_sh / links_account_map
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s1/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s1/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR"
printf '#!/bin/sh\necho account-exec\n' >"$DOTFILES_CLAUDE/bin/account-exec"
chmod +x "$DOTFILES_CLAUDE/bin/account-exec"
ln -s account-exec "$DOTFILES_CLAUDE/bin/gh"
ln -s account-exec "$DOTFILES_CLAUDE/bin/gcloud"
echo "# test" >"$DOTFILES_CLAUDE/bin/account-exec.test.sh"
echo '{"orgs":{}}' >"$DOTFILES_CLAUDE/account-map.json"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s1.out" 2>&1 || true

if [ -L "$CLAUDE_DIR/bin/account-exec" ] && [ "$(readlink "$CLAUDE_DIR/bin/account-exec")" = "$DOTFILES_CLAUDE/bin/account-exec" ] &&
  [ -L "$CLAUDE_DIR/bin/gh" ] && [ "$(readlink "$CLAUDE_DIR/bin/gh")" = "$DOTFILES_CLAUDE/bin/gh" ] &&
  [ -L "$CLAUDE_DIR/bin/gcloud" ] && [ "$(readlink "$CLAUDE_DIR/bin/gcloud")" = "$DOTFILES_CLAUDE/bin/gcloud" ] &&
  [ -x "$CLAUDE_DIR/bin/gh" ] && [ "$("$CLAUDE_DIR/bin/gh")" = "account-exec" ]; then
  pass "links_account_exec_and_tool_links"
else
  fail "links_account_exec_and_tool_links" "bin/* の symlink が期待通りでない (out=$(cat "$TMPROOT/s1.out"); ls=$(ls -l "$CLAUDE_DIR/bin" 2>&1))"
fi

if [ ! -e "$CLAUDE_DIR/bin/account-exec.test.sh" ] && [ ! -L "$CLAUDE_DIR/bin/account-exec.test.sh" ]; then
  pass "skips_test_sh"
else
  fail "skips_test_sh" "account-exec.test.sh が symlink されてしまっている"
fi

if [ -L "$CLAUDE_DIR/account-map.json" ] && [ "$(readlink "$CLAUDE_DIR/account-map.json")" = "$DOTFILES_CLAUDE/account-map.json" ]; then
  pass "links_account_map"
else
  fail "links_account_map" "account-map.json の symlink が期待通りでない (out=$(cat "$TMPROOT/s1.out"))"
fi

# ---------------------------------------------------------------------------
# シナリオ 4: removes_dangling_dotfiles_symlink
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s2/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s2/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR/bin"
ln -sfn "$DOTFILES_CLAUDE/bin/gone" "$CLAUDE_DIR/bin/gone"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s2.out" 2>&1 || true

if [ ! -e "$CLAUDE_DIR/bin/gone" ] && [ ! -L "$CLAUDE_DIR/bin/gone" ]; then
  pass "removes_dangling_dotfiles_symlink"
else
  fail "removes_dangling_dotfiles_symlink" "gone の dangling symlink が削除されていない"
fi

# ---------------------------------------------------------------------------
# シナリオ 5: keeps_dangling_foreign_symlink
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s3/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s3/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR/bin" "$TMPROOT/s3/elsewhere"
ln -sfn "$TMPROOT/s3/elsewhere/other" "$CLAUDE_DIR/bin/other"
run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s3.out" 2>&1 || true

if [ -L "$CLAUDE_DIR/bin/other" ] && [ ! -e "$CLAUDE_DIR/bin/other" ] &&
  [ "$(readlink "$CLAUDE_DIR/bin/other")" = "$TMPROOT/s3/elsewhere/other" ]; then
  pass "keeps_dangling_foreign_symlink"
else
  fail "keeps_dangling_foreign_symlink" "他所を指す dangling symlink が誤って削除された、または状態が期待通りでない"
fi

# ---------------------------------------------------------------------------
# シナリオ 6 & 8: keeps_real_file / skips_account_map_when_absent
# ---------------------------------------------------------------------------
DOTFILES_CLAUDE="$TMPROOT/s4/dotfiles/claude-code"
CLAUDE_DIR="$TMPROOT/s4/home/.claude"
mkdir -p "$DOTFILES_CLAUDE/bin" "$CLAUDE_DIR/bin"
echo "#!/bin/sh" >"$CLAUDE_DIR/bin/local-tool"
if run_block "$DOTFILES_CLAUDE" "$CLAUDE_DIR" >"$TMPROOT/s4.out" 2>&1; then
  s4_rc=0
else
  s4_rc=$?
fi

if [ -f "$CLAUDE_DIR/bin/local-tool" ] && [ ! -L "$CLAUDE_DIR/bin/local-tool" ]; then
  pass "keeps_real_file"
else
  fail "keeps_real_file" "実ファイル local-tool が変更・削除されてしまった"
fi

if [ "$s4_rc" -eq 0 ] && [ ! -e "$CLAUDE_DIR/account-map.json" ] && [ ! -L "$CLAUDE_DIR/account-map.json" ]; then
  pass "skips_account_map_when_absent"
else
  fail "skips_account_map_when_absent" "account-map.json 不在時にエラー終了 (rc=$s4_rc) または symlink が作られた (out=$(cat "$TMPROOT/s4.out"))"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi

echo "PASS: claude-bin-symlink"
```

Run: `chmod +x tests/claude-bin-symlink.test.sh && bash tests/claude-bin-symlink.test.sh; echo "exit=$?"`
Expected: `FAIL: marker_blocks_found …` と `Results: 0 passed, 1 failed`、`exit=1`

- [ ] **Step 2: `home-manager/home/default.nix` に account-map symlink を追加する**

markdown ループの直後（`done` の次、`# MCP_*.md files` の前）に挿入する。Edit の `old_string`:

```
        [ -f "$DOTFILES_CLAUDE/$f" ] && ln -sf "$DOTFILES_CLAUDE/$f" "$target"
      done

      # MCP_*.md files
```

`new_string`:

```
        [ -f "$DOTFILES_CLAUDE/$f" ] && ln -sf "$DOTFILES_CLAUDE/$f" "$target"
      done

      # account-map-symlink: begin
      # gh / gcloud の cwd 連動アカウント shim (bin/account-exec) が引く org → アカウントマップ
      target="$CLAUDE_DIR/account-map.json"
      if [ -f "$target" ] && [ ! -L "$target" ]; then
        rm "$target"
      fi
      if [ -f "$DOTFILES_CLAUDE/account-map.json" ]; then
        ln -sf "$DOTFILES_CLAUDE/account-map.json" "$target"
      fi
      # account-map-symlink: end

      # MCP_*.md files
```

Run: `grep -n 'account-map-symlink' home-manager/home/default.nix`
Expected: `begin` と `end` の 2 行

- [ ] **Step 3: `home-manager/home/default.nix` に bin-symlink ブロックを追加する**

`# hooks-symlink: end` の直後（サブシェルを閉じる `)` の前）に挿入する。Edit の `old_string`:

```
      # hooks-symlink: end
      )
    '';
```

`new_string`:

```
      # hooks-symlink: end

      # bin-symlink: begin
      # gh / gcloud の cwd 連動アカウント shim (bin/account-exec と symlink の bin/gh, bin/gcloud) を
      # ~/.claude/bin/ へ symlink。bin/gh は repo 内で account-exec への symlink なので
      # ~/.claude/bin/gh → claude-code/bin/gh → account-exec の 2 段になる (ln -sf は dereference しない)
      if [ -d "$DOTFILES_CLAUDE/bin" ]; then
        mkdir -p "$CLAUDE_DIR/bin"

        # dotfiles 側で削除された shim の dangling symlink を掃除する
        # (dotfiles/claude-code/bin を指すものだけ対象)
        for t in "$CLAUDE_DIR"/bin/*; do
          if [ -L "$t" ] && [ ! -e "$t" ]; then
            case "$(readlink "$t")" in
              "$DOTFILES_CLAUDE"/bin/*) rm -f "$t" ;;
            esac
          fi
        done

        for f in "$DOTFILES_CLAUDE"/bin/*; do
          # repo 内 symlink (bin/gh) も対象にするため -f ではなく -e / -L で判定
          if { [ -e "$f" ] || [ -L "$f" ]; } && [ ! -d "$f" ]; then
            base="$(basename "$f")"
            case "$base" in
              *.test.sh) continue ;;
            esac
            target="$CLAUDE_DIR/bin/$base"
            if [ -e "$target" ] && [ ! -L "$target" ]; then
              rm "$target"
            fi
            ln -sf "$f" "$target"
          fi
        done
      fi
      # bin-symlink: end
      )
    '';
```

Run: `bash tests/claude-bin-symlink.test.sh`
Expected: `Results: 8 passed, 0 failed` と `PASS: claude-bin-symlink`

- [ ] **Step 4: 既存の hooks-symlink テストが壊れていないこと、nix 側の評価が通ることを確認する**

Run:
```bash
bash tests/claude-hooks-symlink.test.sh | tail -1
nix fmt -- --no-cache
nix eval --raw .#homeConfigurations.naramotoyuuji-darwin.config.home.activation.setupClaudeCode.data | grep -c -E 'bin-symlink: (begin|end)|account-map-symlink: (begin|end)'
```
Expected: `PASS: claude-hooks-symlink`、`nix fmt` は default.nix を変えない（変えたら整形結果を採用）、grep は `4`

- [ ] **Step 5: shellcheck / commit**

Run:
```bash
nix develop -c shellcheck tests/claude-bin-symlink.test.sh
git add home-manager/home/default.nix tests/claude-bin-symlink.test.sh
git commit -m "chore(hm): 🔧 claude-code/bin と account-map.json を ~/.claude へ symlink する activation を追加

hooks-symlink と同じ流儀 (dangling 掃除 + *.test.sh 除外)。bin/gh は repo 内 symlink
なので -f ではなく -e / -L で拾い、~/.claude/bin/gh → bin/gh → account-exec の 2 段にする。"
```
Expected: shellcheck 出力なし、commit 成功

---

### Task 4: zsh / fish の PATH に `~/.claude/bin` を追加

**Files:**
- Modify: `home-manager/programs/zsh.nix`（`envExtra`）
- Modify: `home-manager/programs/fish.nix`（`shellInit`）

**Interfaces:**
- Consumes: 既存の nix-profile PATH 行
- Produces: 全シェル（対話・非対話・mosh 経由・Claude Code の env snapshot）で `~/.claude/bin` が `~/.nix-profile/bin` より前に来る PATH

- [ ] **Step 1: `zsh.nix` の `envExtra` に追記する**

Edit の `old_string`:

```
      # SSH remote commands such as mosh-server run under non-interactive zsh.
      export PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"
    '';
```

`new_string`:

```
      # SSH remote commands such as mosh-server run under non-interactive zsh.
      export PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:$PATH"

      # gh / gcloud の cwd 連動アカウント shim (dotfiles/claude-code/bin → ~/.claude/bin)。
      # nix-profile の実体より前に置く。設計: docs/specs/2026-09-19-claude-account-env-design.md
      export PATH="$HOME/.claude/bin:$PATH"
    '';
```

Run: `nix eval --raw .#homeConfigurations.naramotoyuuji-darwin.config.programs.zsh.envExtra | grep -n 'claude/bin'`
Expected: `export PATH="$HOME/.claude/bin:$PATH"` を含む行が 1 つ、かつ nix-profile 行より後の行番号

- [ ] **Step 2: `fish.nix` の `shellInit` に追記する**

Edit の `old_string`:

```
      # PATH設定
      fish_add_path $HOME/.nix-profile/bin
```

`new_string`:

```
      # PATH設定
      fish_add_path $HOME/.nix-profile/bin
      # gh / gcloud の cwd 連動アカウント shim (~/.claude/bin)。fish_add_path は prepend なので
      # 後に呼ぶこの行が nix-profile より前に来る。設計: docs/specs/2026-09-19-claude-account-env-design.md
      fish_add_path $HOME/.claude/bin
```

Run: `nix eval --raw .#homeConfigurations.naramotoyuuji-darwin.config.programs.fish.shellInit | grep -n 'fish_add_path'`
Expected: `fish_add_path $HOME/.nix-profile/bin` の次に `fish_add_path $HOME/.claude/bin` が出る（この順で後者が prepend され PATH 先頭になる。`fish -lc 'which gh'` での実機確認は agent の permission で拒否されるので Task 7 で人間が行う）

- [ ] **Step 3: fmt / flake check / commit**

Run:
```bash
nix fmt -- --no-cache
nix flake check
git add home-manager/programs/zsh.nix home-manager/programs/fish.nix
git commit -m "chore(hm): 🔧 zsh / fish の PATH 先頭に ~/.claude/bin (gh / gcloud shim) を追加"
```
Expected: `nix flake check` が warning なしで終了（exit 0）、commit 成功

---

### Task 5: settings.json（sandbox）の変更 — 人間が適用、agent は diff 提示と検証

**Files:**
- Modify（人間のみ）: `claude-code/settings.json`（`sandbox.filesystem.allowWrite` / `denyRead`）

**Interfaces:**
- Consumes: 現状 `allowWrite` 末尾 `"~/.config/gws"`、`denyRead` 末尾 `"~/.config/gh/**"`
- Produces: `allowWrite` に `"~/.config/gcloud"`、`denyRead` に `"~/.config/gh-*/**"` が追加された settings.json

- [ ] **Step 1: agent は現状を `jq` で確認し、worktree 側の settings.json への Edit を 1 回だけ試す**

main checkout の `claude-code/settings.json` は `~/.claude/settings.json` の symlink 先なので sandbox の自己改変ガードで write deny。worktree 側のコピー（`.claude/worktrees/claude-account-env/claude-code/settings.json`）は別ファイルで、deny 対象かどうかは実行時にしか分からない。**1 回だけ** Edit（下の diff の 2 箇所）を試み、拒否されたら再試行せず Step 2 の diff 提示に切り替える。

Run:
```bash
jq -c '.sandbox.filesystem | {allowWrite, denyRead}' claude-code/settings.json
```
Expected: `allowWrite` の末尾が `"~/.config/gws"`、`denyRead` が `["~/.aws/**","~/.ssh/**","~/.gnupg/**","~/.config/gh/**"]`（まだ未適用）

- [ ] **Step 2: Edit が拒否された場合、人間へ提示する diff（このまま最終レポートに載せる）**

人間がこの worktree で適用する。エディタで次の diff を当てるか、下の jq one-liner を実行する:

```diff
--- a/claude-code/settings.json
+++ b/claude-code/settings.json
@@ sandbox.filesystem.allowWrite @@
         "~/ghq/**/.claude/scheduled_tasks.lock",
-        "~/.config/gws"
+        "~/.config/gws",
+        "~/.config/gcloud"
       ],
@@ sandbox.filesystem.denyRead @@
         "~/.gnupg/**",
-        "~/.config/gh/**"
+        "~/.config/gh/**",
+        "~/.config/gh-*/**"
       ]
```

jq で当てる場合（人間が worktree 直下で実行）:

```bash
jq '.sandbox.filesystem.allowWrite += ["~/.config/gcloud"] | .sandbox.filesystem.denyRead += ["~/.config/gh-*/**"]' claude-code/settings.json > "${TMPDIR:-/tmp}/settings.json" && mv "${TMPDIR:-/tmp}/settings.json" claude-code/settings.json && nix fmt -- --no-cache
```

理由（spec §8）: `~/.config/gcloud` の allowWrite は sandbox 内で `gcloud auth list` / token refresh が `credentials.db` `logs/` に書けず `Operation not permitted` で落ちる問題の修正。`~/.config/gh-*/**` の denyRead は分離した gh config dir を既存 `~/.config/gh/**` と同じ扱いにするため。`gh` 自体は `excludedCommands` の `gh:*` で sandbox 除外なので shim 経由でも影響なし。hooks の追加は無い。

- [ ] **Step 3: 適用後の検証（agent が実行）**

Run:
```bash
jq -e '.sandbox.filesystem.allowWrite | index("~/.config/gcloud")' claude-code/settings.json
jq -e '.sandbox.filesystem.denyRead | index("~/.config/gh-*/**")' claude-code/settings.json
jq -e '.sandbox.filesystem.denyRead | index("~/.config/gh/**")' claude-code/settings.json
nix flake check
```
Expected: 3 つの `jq -e` がそれぞれ配列 index（0 以上の整数）を出して exit 0（`null` なら未適用）。`nix flake check` exit 0

- [ ] **Step 4: commit（人間が適用済みであることを Step 3 で確認してから）**

Run:
```bash
git add claude-code/settings.json
git commit -m "chore(claude): 🔧 sandbox で ~/.config/gcloud を allowWrite、~/.config/gh-*/** を denyRead に追加

gcloud の credentials.db / logs 書込み失敗 (Operation not permitted) の修正と、
分離した gh config dir (GH_CONFIG_DIR=~/.config/gh-<account>) を ~/.config/gh と同じ扱いにするため。"
```
Expected: commit 成功。Step 3 が `null` のままなら commit せず、最終レポートで「settings.json は未適用」と明記する

---

### Task 6: README / spec 更新 + 最終検証

**Files:**
- Modify: `claude-code/README.md`（ツリー、activation リスト、新セクション、Rollback）
- Modify: `docs/specs/2026-09-19-claude-account-env-design.md`（状態行）

**Interfaces:**
- Consumes: spec §4〜§7・§10・§12
- Produces: 運用者向けの説明（仕組み、マップ編集、初回セットアップ、`which gh`、明示 env 素通し、`ACCOUNT_EXEC_DEBUG=1`）

- [ ] **Step 1: README のファイル構成ツリーを更新する**

Edit の `old_string`:

```
├── settings.json         # permissions（allow/deny）+ hooks 設定 + env
├── skill-config.json     # it-all-playpark/skills の per-skill デフォルト値
└── hooks/                # SessionStart / PreCompact / Pre|PostToolUse スクリプト
```

`new_string`:

```
├── settings.json         # permissions（allow/deny）+ hooks 設定 + env
├── skill-config.json     # it-all-playpark/skills の per-skill デフォルト値
├── account-map.json      # gh / gcloud の org → アカウントマップ（bin/account-exec が読む）
├── bin/                  # gh / gcloud の cwd 連動アカウント shim（account-exec + symlink の gh / gcloud）
└── hooks/                # SessionStart / PreCompact / Pre|PostToolUse スクリプト
```

- [ ] **Step 2: README の activation リストに 6, 7 を追加する**

Edit の `old_string`:

```
5. `hooks/*.{py,sh}` を `~/.claude/hooks/` に symlink（`*.test.sh` は除外）
```

`new_string`:

```
5. `hooks/*.{py,sh}` を `~/.claude/hooks/` に symlink（`*.test.sh` は除外）
6. `bin/*` を `~/.claude/bin/` に symlink（`*.test.sh` は除外。`bin/gh` / `bin/gcloud` は repo 内で
   `account-exec` への symlink なので `~/.claude/bin/gh` → `bin/gh` → `account-exec` の 2 段になる）
7. `account-map.json` を `~/.claude/account-map.json` に symlink
```

- [ ] **Step 3: README に `## gh / gcloud アカウント shim` セクションを追加する**

`## hooks` セクションの直前（`nix run .#update` のコードブロックと `## hooks` の間）に挿入する。Edit の `old_string` は次の 5 行（bash フェンス閉じ + 空行 + `## hooks`）:

````
```bash
nix run .#update
```

## hooks
````

`new_string`（`## hooks` 行までを含めて置換する）:

````
```bash
nix run .#update
```

## gh / gcloud アカウント shim

設計: `docs/specs/2026-09-19-claude-account-env-design.md`

gh と gcloud を複数アカウントで使い分けるとき、`gh auth switch` / `gcloud config configurations activate`
はグローバル状態（`~/.config/gh/hosts.yml` / `~/.config/gcloud/active_config`）を書き換えるため、
並列セッションや dev-flow の subagent が別 org で動くと互いに壊し合う。`bin/account-exec` は
**グローバル状態を一切切り替えず**、コマンドを実行した cwd から使うアカウントを決める PATH shim。

### 仕組み

```
Bash: gh pr create …  (cwd=~/ghq/github.com/BusinessProcessDX/repo/.claude/worktrees/x)
  └─ ~/.claude/bin/gh → claude-code/bin/gh → account-exec
       ├─ $PWD（不一致なら pwd -P）から org=BusinessProcessDX を取る
       ├─ ~/.claude/account-map.json の .orgs[org] を jq で引く
       ├─ GH_CONFIG_DIR=~/.config/gh-th-it-dev を export（gcloud なら CLOUDSDK_ACTIVE_CONFIG_NAME）
       └─ exec ~/.nix-profile/bin/gh pr create …
            （PATH から shim dir を除いて解決した実体。exec 先の PATH は元のまま）
```

- `~/.claude/bin` は home-manager が zsh（`envExtra`）/ fish（`shellInit`）の PATH 先頭に載せる。
  `which gh` / `which gcloud` は `~/.claude/bin/…` を指すようになる
- 同じスクリプト内で `cd org1 && gh …; cd org2 && gh …` としても各呼び出しが独立に解決される。
  `git push`（https）の credential helper `gh auth git-credential` も git が chdir 済みなので同じ dir で解決される
- **明示指定は素通し**: `GH_CONFIG_DIR=… gh …` / `CLOUDSDK_ACTIVE_CONFIG_NAME=… gcloud …` のように対象 env が
  既に set なら判定しない。実体を直接叩きたいときはこれか `~/.nix-profile/bin/gh`
- **fail-open**: マップ不在 / JSON 不正 / `jq` 不在 / 値に `'` や改行 を含む場合は env を付けずに実体へ
  passthrough し、stderr に `account-exec: …` を 1 行出す。ghq 外（`~/ghq/github.com/<org>/` に無い cwd）や
  未登録 org は無言で passthrough（既定のグローバル状態のまま）
- 実体が PATH に無い、または解決先が shim 自身なら exit 127（無限再帰しない）
- `ACCOUNT_EXEC_DEBUG=1 gh …` で判定結果（org / 付けた env / exec 先）を stderr に 1 行出す

### マップの編集（`account-map.json`）

```json
{
  "orgs": {
    "BusinessProcessDX": { "gcloud_config": "th-it-all", "gh_config_dir": "~/.config/gh-th-it-dev" },
    "it-all-playpark":   { "gcloud_config": "default",   "gh_config_dir": "~/.config/gh" }
  }
}
```

- キーは `~/ghq/github.com/<org>/` の `<org>`。`gh_config_dir` / `gcloud_config` は両方 optional で、
  無いキーは env を付けない（gcloud を使わない org は `gcloud_config` を省略する）
- 値の先頭 `~` だけ `$HOME` に展開する。それ以外の展開はしない
- `gcloud_config` は `gcloud config configurations list` に存在する構成名をそのまま書く
- dir の存在や構成名の妥当性は shim では検証しない（gh / gcloud が「未ログイン」等を正しく言う）
- 編集後は `nix run .#update` 不要（`~/.claude/account-map.json` は symlink）。`nix fmt` がキーをソートする

### 初回セットアップ（人間の作業）

```bash
gh auth logout -h github.com -u th-it-dev            # ~/.config/gh から失効エントリを除去
GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth login    # 分離 dir に th-it-dev を再ログイン
nix run .#update                                      # symlink / PATH / settings を反映
exec $SHELL -l                                        # PATH を取り直す
```

確認:

```bash
cd ~/ghq/github.com/BusinessProcessDX/<repo>
which gh                      # → ~/.claude/bin/gh
gh auth status                # → th-it-dev
gcloud config list            # → th-it-all (account th.it.dev@…)
cd ~/ghq/github.com/it-all-playpark/dotfiles
gh auth status                # → it-all-playpark
```

### 既知の限界

- gcloud ADC（`application_default_credentials.json`）は構成をまたいでグローバルなので対象外
- `GH_CONFIG_DIR` を分けると `config.yml`（alias, editor 等）も dir ごとに独立する。共有したくなったら
  `config.yml` だけ symlink する
- shim は毎回 `jq` を起動する（数 ms、gh / gcloud 自体の起動時間に埋もれる）
- ghq 外に clone した repo では判定できず既定のまま

テスト: `bash claude-code/bin/account-exec.test.sh`（shim、12 ケース）、
`bash tests/claude-bin-symlink.test.sh`（activation の symlink ロジック）。
`bin/account-exec` は拡張子が無いため pre-commit の shellcheck 対象外。変更時は
`nix develop -c shellcheck claude-code/bin/account-exec` を手で回す。

## hooks
````

- [ ] **Step 4: README の Rollback に shim の剥がし方を足す**

Edit の `old_string`:

```
rm ~/.claude/settings.json
rm ~/.claude/hooks/<name>.sh
```

`new_string`:

```
rm ~/.claude/settings.json
rm ~/.claude/hooks/<name>.sh
rm ~/.claude/bin/gh ~/.claude/bin/gcloud ~/.claude/bin/account-exec ~/.claude/account-map.json
```

- [ ] **Step 5: spec の状態行を更新する**

`docs/specs/2026-09-19-claude-account-env-design.md` の Edit。`old_string`:

```
- 状態: 設計承認済み（2026-09-19、shim 方式へ改訂）、未実装
```

`new_string`:

```
- 状態: 実装済み（2026-09-19、shim 方式へ改訂のうえ実装。`nix run .#update` と初回ログインは §10 参照）
```

- [ ] **Step 6: 最終検証（全テスト + fmt + flake check）**

Run:
```bash
nix fmt -- --no-cache
git status --short
bash claude-code/bin/account-exec.test.sh | tail -2
bash tests/claude-bin-symlink.test.sh | tail -1
bash tests/claude-hooks-symlink.test.sh | tail -1
bash tests/hooks-wiring.test.sh | tail -1
bash tests/sandbox-excluded-commands.test.sh | tail -1
nix develop -c shellcheck claude-code/bin/account-exec claude-code/bin/account-exec.test.sh tests/claude-bin-symlink.test.sh
nix flake check
```
Expected: `Results: 14 passed, 0 failed` / `PASS: account-exec`、`PASS: claude-bin-symlink`、`PASS: claude-hooks-symlink`、settings.json を読む既存テスト（`hooks-wiring` / `sandbox-excluded-commands`）も PASS、shellcheck 出力なし、`nix flake check` exit 0。`git status --short` に README / spec 以外の変更が無い

- [ ] **Step 7: commit と push**

Run:
```bash
git add claude-code/README.md docs/specs/2026-09-19-claude-account-env-design.md
git commit -m "docs: 📝 gh / gcloud アカウント shim の仕組み・マップ編集・初回セットアップを README に追記し spec を実装済みに更新"
git push -u origin worktree-claude-account-env
```
Expected: commit 成功、`origin/worktree-claude-account-env` に push（feature branch なので `allow-feature-push.sh` を通る）。PR 作成は人間の指示があるときのみ

---

### Task 7: 人間がやること（agent は実行しない。最終レポートにこのチェックリストを載せる）

**Files:**
- なし（実機の `~/.config/gh*` / `~/.config/gcloud` / `~/.claude/` と、main checkout の `claude-code/settings.json`）

**Interfaces:**
- Consumes: Task 1〜6 の commit 済みブランチ、spec §10 / §11
- Produces: 受け入れ基準 §11 の 4 項目が満たされた状態

- [ ] **Step 1: settings.json の変更を適用する（Task 5 Step 2 の diff または jq one-liner）**。適用したら agent に Task 5 Step 3 の検証と commit を依頼する

- [ ] **Step 2: PR を作り merge する**（`main` へ直接 push しない）。`nix run .#update` の activation は `~/ghq/github.com/it-all-playpark/dotfiles/claude-code`（main checkout の実パス）を symlink 元にするので、**main checkout がこのブランチの内容になってから** 次へ進む（merge 後 `git pull`、または main checkout でこのブランチを checkout）

- [ ] **Step 3: 失効 token の除去と分離 dir への再ログイン**

```bash
gh auth logout -h github.com -u th-it-dev
GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth login
```
Expected: `gh auth status` が `~/.config/gh` では `it-all-playpark` のみ、`GH_CONFIG_DIR=~/.config/gh-th-it-dev gh auth status` が `th-it-dev`

- [ ] **Step 4: 適用とシェル再起動**

```bash
cd ~/ghq/github.com/it-all-playpark/dotfiles
nix run .#update
exec $SHELL -l
```
Expected: activation がエラーなく完了。`ls -l ~/.claude/bin` に `gh -> …/dotfiles/claude-code/bin/gh` 等 3 本、`ls -l ~/.claude/account-map.json` が symlink

- [ ] **Step 5: 受け入れ確認（spec §10 / §11）**

```bash
which gh                      # → ~/.claude/bin/gh
fish -lc 'which gh'           # → ~/.claude/bin/gh（fish 側の PATH 合成順の確認。agent では実行不可）
cd ~/ghq/github.com/BusinessProcessDX/<repo>
gh auth status                # → th-it-dev
gcloud config list            # → th-it-all (account th.it.dev@…)
ACCOUNT_EXEC_DEBUG=1 gh auth status 2>&1 | grep account-exec   # org=BusinessProcessDX GH_CONFIG_DIR=…/gh-th-it-dev exec=…/.nix-profile/bin/gh
cd ~/ghq/github.com/it-all-playpark/dotfiles
gh auth status                # → it-all-playpark
cat ~/.config/gcloud/active_config      # 変わっていない
```
Expected: 上記の通り。`~/.config/gh/hosts.yml` と `~/.config/gcloud/active_config` は一切変化しない（§11-1）

- [ ] **Step 6: Claude Code セッション内での確認（§11-2, §11-3）**

新しい Claude Code セッションで:
- `it-all-playpark` と `BusinessProcessDX` の worktree をそれぞれ cwd にした subagent を同時に走らせ、両方で `gh auth status` が各自のアカウントを返す
- sandbox 内の Bash で `gcloud auth list` が `Operation not permitted` で落ちない（settings.json の `~/.config/gcloud` allowWrite が効いている）
- `bash claude-code/bin/account-exec.test.sh` と `nix flake check` が通る（§11-4）
