# cca Session Switcher Implementation Plan

> **⚠️ 改訂あり (2026-07-05, live-pivot):** 本計画は当初 `sessions-index.json` 起点(Task 2 `cca_discover` / Task 5 `cca_filter_live`)で書かれたが、実機検証で index が live を映さないと判明し、**「live プロセス起点 + transcript `.jsonl` 実 mtime + git branch」** に再設計した。`cca_discover`/`cca_filter_live` は廃止され `cca_encode_dir`/`cca_newest_mtime`/`cca_enumerate` に置換。最新の正しい設計は spec (`docs/specs/2026-07-05-cca-session-switcher-design.md`) の改訂版と実装 `scripts/cca` を参照。以下 Task 2/3/5/6 のデータ源記述は歴史的経緯として残す。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 生きている前景 Claude セッションを一覧し、fzf で選んで該当 zellij session に一発で attach する bash CLI `cca` を作る。

**Architecture:** `~/.claude/projects/*/sessions-index.json`(構造化済み)を jq でパースして「何が/どこで/どのブランチ/最終いつ」を得(推論ゼロ)、`ps`+`lsof` の生存 cwd 集合で「今開いてる」ものだけに絞り、fzf で選択、cwd→zellij session を basename 規約で逆引きして attach。純関数(discover/render/reltime/join)は fixture で TDD、副作用系(live/attach/pick)は手動検証。定着後に `writeShellApplication` で nix 化。

**Tech Stack:** bash, jq, fzf, lsof, zellij, Nix home-manager (`pkgs.writeShellApplication`)

---

## 関数コントラクト(全タスク共通・命名を固定する)

| 関数 | 入力 | 出力 | 種別 |
|---|---|---|---|
| `cca_reltime` | age秒(arg) | `30s`/`5m`/`3h`/`2d` を stdout | 純 |
| `cca_discover` | `$CCA_PROJECTS_DIR`(既定 `$HOME/.claude/projects`) | TSV 各行 `cwd \t summary \t gitBranch \t fileMtime_ms` | 純(FS読取) |
| `cca_render` | stdin: discover の TSV / `$CCA_NOW`,`$CCA_ACTIVE_WINDOW` | TSV 各行 `cwd \t projName \t branch \t "icon reltime" \t summary` | 純 |
| `cca_join` | arg: cwd / stdin: session名(1行1個) | 一致した session名 or 空 | 純 |
| `cca_live` | — | 生きてる claude の cwd(1行1個) | 副作用 |
| `cca_filter_live` | stdin: 先頭列 cwd の TSV | live に含まれる行だけ | 副作用(cca_live呼ぶ) |
| `cca_pick` | stdin: render の TSV | 選択された1行 | 副作用(fzf) |
| `cca_attach` | arg: session名 | attach/switch | 副作用(zellij) |
| `cca_main` | argv | パイプ全体 | 副作用 |

パイプライン: `cca_discover | cca_filter_live | cca_render | cca_pick` → 選択行の `cut -f1` = cwd → `cca_join` → `cca_attach`。

fzf は先頭列 cwd を隠す(`--with-nth=2..`)。選択後に `cut -f1` で cwd を復元。

---

## File Structure

- Create: `scripts/cca` — 本体(関数群 + `cca_main`。sourced 時は main を実行しないガード付き)
- Create: `scripts/cca_test.sh` — fixture ベースのユニットテスト(純関数のみ)
- Create: `scripts/fixtures/projects/-proj-alpha/sessions-index.json` — テスト用 index(複数 entry + sidechain)
- Create: `scripts/fixtures/projects/-proj-beta/sessions-index.json` — テスト用 index(branch 空)
- Create: `home-manager/programs/cca.nix` — `writeShellApplication`(`scripts/cca` を `readFile`)
- Modify: `home-manager/programs/default.nix` — imports に `./cca.nix` を追加

`cca.nix` は `builtins.readFile ../../scripts/cca` で本体を1ソースから読む(重複を作らない)。

---

## Task 1: スクリプト雛形 + テストハーネス + `cca_reltime`

**Files:**
- Create: `scripts/cca`
- Create: `scripts/cca_test.sh`

- [ ] **Step 1: 失敗するテストを書く(`scripts/cca_test.sh`)**

```bash
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

exit "$FAIL"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/cca_test.sh`
Expected: FAIL(`scripts/cca` が無い/`cca_reltime: command not found`)

- [ ] **Step 3: 雛形 + `cca_reltime` を実装(`scripts/cca`)**

```bash
#!/usr/bin/env bash
# cca — foreground Claude セッション・スイッチャー
set -euo pipefail

cca_reltime() {
  local s="$1"
  if   [ "$s" -lt 60 ];    then echo "${s}s"
  elif [ "$s" -lt 3600 ];  then echo "$((s/60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s/3600))h"
  else                          echo "$((s/86400))d"
  fi
}

cca_main() {
  echo "cca: not implemented yet" >&2
  return 1
}

# sourced（テスト）時は main を実行しない
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cca_main "$@"
fi
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/cca_test.sh`
Expected: `cca_reltime` の4アサートが全て `ok`、exit 0

- [ ] **Step 5: 実行ビットを付けて commit**

```bash
chmod +x scripts/cca
git add scripts/cca scripts/cca_test.sh
git commit -m "feat: 🎸 cca 雛形とテストハーネス, cca_reltime"
```

---

## Task 2: `cca_discover`(index パース)

**Files:**
- Modify: `scripts/cca`
- Modify: `scripts/cca_test.sh`
- Create: `scripts/fixtures/projects/-proj-alpha/sessions-index.json`
- Create: `scripts/fixtures/projects/-proj-beta/sessions-index.json`

- [ ] **Step 1: fixture を作る(`scripts/fixtures/projects/-proj-alpha/sessions-index.json`)**

```json
{
  "version": 1,
  "entries": [
    {"sessionId": "a1", "fileMtime": 1000, "summary": "Old work", "gitBranch": "main", "projectPath": "/home/u/alpha", "isSidechain": false},
    {"sessionId": "a2", "fileMtime": 3000, "summary": "Recent work", "gitBranch": "feat/x", "projectPath": "/home/u/alpha", "isSidechain": false},
    {"sessionId": "a3", "fileMtime": 5000, "summary": "Sidechain noise", "gitBranch": "feat/x", "projectPath": "/home/u/alpha", "isSidechain": true}
  ]
}
```

- [ ] **Step 2: 2つめの fixture を作る(`scripts/fixtures/projects/-proj-beta/sessions-index.json`)**

```json
{
  "version": 1,
  "entries": [
    {"sessionId": "b1", "fileMtime": 2000, "summary": "Beta task", "gitBranch": "", "projectPath": "/home/u/beta", "isSidechain": false}
  ]
}
```

- [ ] **Step 3: 失敗するテストを追加(`scripts/cca_test.sh` の `exit "$FAIL"` の直前に挿入)**

```bash
# --- cca_discover ---
# glob はアルファベット順: proj-alpha → proj-beta
# alpha は最新の非 sidechain(a2, mtime 3000)を採用。a3(sidechain)は無視。
# beta は branch 空。
disc_expected=$'/home/u/alpha\tRecent work\tfeat/x\t3000
/home/u/beta\tBeta task\t\t2000'
disc_actual="$(CCA_PROJECTS_DIR="$HERE/fixtures/projects" cca_discover)"
assert_eq "discover latest-non-sidechain per project" "$disc_expected" "$disc_actual"
```

- [ ] **Step 4: テストを実行して失敗を確認**

Run: `bash scripts/cca_test.sh`
Expected: FAIL(`cca_discover: command not found`)

- [ ] **Step 5: `cca_discover` を実装(`scripts/cca` の `cca_reltime` の後に追加)**

```bash
cca_discover() {
  local dir="${CCA_PROJECTS_DIR:-$HOME/.claude/projects}"
  local f
  for f in "$dir"/*/sessions-index.json; do
    [ -f "$f" ] || continue
    jq -r '
      [.entries[] | select(.isSidechain == false)]
      | select(length > 0)
      | max_by(.fileMtime)
      | [.projectPath, .summary, .gitBranch, (.fileMtime | tostring)]
      | @tsv
    ' "$f"
  done
}
```

- [ ] **Step 6: テストを実行して通過を確認**

Run: `bash scripts/cca_test.sh`
Expected: 全アサート `ok`、exit 0

- [ ] **Step 7: commit**

```bash
git add scripts/cca scripts/cca_test.sh scripts/fixtures
git commit -m "feat: 🎸 cca_discover: sessions-index.json をパースし最新非sidechainを抽出"
```

---

## Task 3: `cca_render`(表示整形・active/idle 判定)

**Files:**
- Modify: `scripts/cca`
- Modify: `scripts/cca_test.sh`

- [ ] **Step 1: 失敗するテストを追加(`exit "$FAIL"` の直前)**

```bash
# --- cca_render ---
# CCA_NOW=3000s 基準。fileMtime は ms なので /1000。
# 行1: mtime 3000000ms=3000s, age 0 <300 → 🟢, rel 0s, branch feat/x
# 行2: mtime 1000000ms=1000s, age 2000 → 33m, >300 → 💤, branch 空 → –
render_in=$'/home/u/alpha\tRecent work\tfeat/x\t3000000
/home/u/beta\tOld\t\t1000000'
render_expected=$'/home/u/alpha\talpha\tfeat/x\t🟢 0s\tRecent work
/home/u/beta\tbeta\t–\t💤 33m\tOld'
render_actual="$(CCA_NOW=3000 CCA_ACTIVE_WINDOW=300 printf '%s' "$render_in" | CCA_NOW=3000 CCA_ACTIVE_WINDOW=300 cca_render)"
assert_eq "render icon/reltime/branch-fallback" "$render_expected" "$render_actual"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/cca_test.sh`
Expected: FAIL(`cca_render: command not found`)

- [ ] **Step 3: `cca_render` を実装(`scripts/cca` の `cca_discover` の後に追加)**

```bash
cca_render() {
  local now="${CCA_NOW:-$(date +%s)}"
  local win="${CCA_ACTIVE_WINDOW:-300}"
  local line cwd summary branch mtime_ms mtime age icon rel proj
  # raw 行読み + \x1f センチネル分割。
  # 理由: `IFS=$'\t' read` はタブを IFS-whitespace として扱い、空フィールド
  #       (`\t\t`, 例: gitBranch 空)を潰してフィールドがズレる。\x1f は非空白なので
  #       連続しても空フィールドを保持する。`|| [ -n "$line" ]` は末尾改行なし入力の最終行救済。
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS=$'\x1f' read -r cwd summary branch mtime_ms <<< "${line//$'\t'/$'\x1f'}"
    mtime=$(( mtime_ms / 1000 ))
    age=$(( now - mtime ))
    if [ "$age" -lt 0 ]; then age=0; fi
    if [ "$age" -lt "$win" ]; then icon="🟢"; else icon="💤"; fi
    rel="$(cca_reltime "$age")"
    proj="$(basename "$cwd")"
    printf '%s\t%s\t%s\t%s %s\t%s\n' "$cwd" "$proj" "${branch:-–}" "$icon" "$rel" "$summary"
  done
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/cca_test.sh`
Expected: 全アサート `ok`、exit 0

- [ ] **Step 5: commit**

```bash
git add scripts/cca scripts/cca_test.sh
git commit -m "feat: 🎸 cca_render: active/idle アイコンと相対時刻で整形"
```

---

## Task 4: `cca_join`(cwd → zellij session 逆引き)

**Files:**
- Modify: `scripts/cca`
- Modify: `scripts/cca_test.sh`

- [ ] **Step 1: 失敗するテストを追加(`exit "$FAIL"` の直前)**

```bash
# --- cca_join ---
sessions=$'alpha\nshift-bud\ncorporate-site'
assert_eq "join match by basename" "alpha" "$(printf '%s' "$sessions" | cca_join /home/u/alpha)"
assert_eq "join no match returns empty" "" "$(printf '%s' "$sessions" | cca_join /home/u/unknown)"
```

- [ ] **Step 2: テストを実行して失敗を確認**

Run: `bash scripts/cca_test.sh`
Expected: FAIL(`cca_join: command not found`)

- [ ] **Step 3: `cca_join` を実装(`scripts/cca` の `cca_render` の後に追加)**

```bash
# stdin から session名(1行1個)を読み、cwd の basename と完全一致する行を返す
cca_join() {
  local cwd="$1" base
  base="$(basename "$cwd")"
  grep -Fx -- "$base" || true
}
```

- [ ] **Step 4: テストを実行して通過を確認**

Run: `bash scripts/cca_test.sh`
Expected: 全アサート `ok`、exit 0

- [ ] **Step 5: commit**

```bash
git add scripts/cca scripts/cca_test.sh
git commit -m "feat: 🎸 cca_join: basename 規約で cwd を zellij session に逆引き"
```

---

## Task 5: `cca_live` + `cca_filter_live`(生存判定・手動検証)

**Files:**
- Modify: `scripts/cca`

- [ ] **Step 1: `cca_live` と `cca_filter_live` を実装(`scripts/cca` の `cca_join` の後に追加)**

```bash
# 生きてる claude プロセスの cwd を1行1個で出す
cca_live() {
  local pid
  for pid in $(pgrep -x claude 2>/dev/null || true); do
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
  done | sort -u
}

# 先頭列が cwd の TSV を stdin で受け、live 集合に含まれる行だけ通す
cca_filter_live() {
  local live line cwd
  live="$(cca_live)"
  [ -n "$live" ] || return 0
  while IFS= read -r line; do
    cwd="${line%%$'\t'*}"
    if printf '%s\n' "$live" | grep -Fxq -- "$cwd"; then
      printf '%s\n' "$line"
    fi
  done
}
```

- [ ] **Step 2: 手動検証 — `cca_live` が実 claude の cwd を返すか**

前提: いずれかの zellij pane で `claude` を起動中にする。

Run: `bash -c 'source scripts/cca; cca_live'`
Expected: 起動中 claude の cwd が1行以上出る。
確認: `pgrep -x claude` で PID が出ること、macOS の `claude` のプロセス名が実際に `claude` であることを確認(異なれば `pgrep -x` の対象名を実測値に修正)。

- [ ] **Step 3: 手動検証 — `cca_filter_live` が生きてる cwd だけ残すか**

Run:
```bash
source scripts/cca
printf '%s\tX\tmain\t1000\n%s\tY\tmain\t2000\n' "$(pwd)" "/nonexistent/path" | cca_filter_live
```
Expected: `$(pwd)` 側の行のみ(このシェルが claude 配下でない場合は 0 行になり得る。その場合は実際に claude が動いている cwd を1行目に差し替えて再確認)。

- [ ] **Step 4: commit**

```bash
git add scripts/cca
git commit -m "feat: 🎸 cca_live/cca_filter_live: ps+lsof で生存セッションに絞る"
```

---

## Task 6: `cca_pick` + `cca_attach` + `cca_main`(結線・E2E 手動)

**Files:**
- Modify: `scripts/cca`

- [ ] **Step 1: `cca_pick`・`cca_attach`・`cca_main` を実装(`cca_main` の中身を差し替え)**

```bash
cca_pick() {
  fzf --delimiter='\t' --with-nth=2.. \
      --layout=reverse --prompt 'CLAUDE SESSION> ' \
      --preview 'printf "%s" {5}' --preview-window=up,3,wrap
}

cca_attach() {
  local sess="$1"
  [ -n "$sess" ] || { echo "cca: attach 先の session がありません" >&2; return 1; }
  if [ -z "${ZELLIJ:-}" ]; then
    exec zellij attach "$sess"
  fi
  # zellij 内から: switch-session が使えれば使う。無ければ手順を案内。
  if zellij action switch-session "$sess" 2>/dev/null; then
    return 0
  fi
  echo "cca: この zellij では内側からの切替不可。" >&2
  echo "     detach(既定 Ctrl-o d)後に: zellij attach $sess" >&2
  return 1
}

cca_main() {
  local sel cwd sessions sess
  sel="$(cca_discover | cca_filter_live | cca_render | cca_pick || true)"
  [ -n "$sel" ] || return 0
  cwd="$(printf '%s' "$sel" | cut -f1)"
  sessions="$(zellij list-sessions --no-formatting 2>/dev/null | awk '{print $1}')"
  sess="$(printf '%s' "$sessions" | cca_join "$cwd")"
  if [ -z "$sess" ]; then
    sess="$(printf '%s' "$sessions" | fzf --layout=reverse --prompt 'ZELLIJ SESSION> ' || true)"
  fi
  cca_attach "$sess"
}
```

- [ ] **Step 2: 自動テストが依然通ることを確認(純関数に regression が無いか)**

Run: `bash scripts/cca_test.sh`
Expected: 全アサート `ok`、exit 0

- [ ] **Step 3: 手動検証 — `zellij list-sessions --no-formatting` の出力形を確認**

Run: `zellij list-sessions --no-formatting | awk '{print $1}'`
Expected: session 名が1行1個で出る。装飾や `(current)` 接尾が混ざる場合は `awk`/`sed` を実測に合わせて調整。`--no-formatting` が無いバージョンなら `zellij list-sessions -s` 等の代替を確認。

- [ ] **Step 4: 手動 E2E — 規約マッチ率の実測(spec セクション6の核心リスク)**

複数プロジェクトで claude を起動した状態で:

Run: `bash scripts/cca`
Expected:
- 生きてる前景 claude だけが fzf に並ぶ(過去ログ・sidechain は出ない)
- 各行に project名 / branch / 🟢💤+相対時刻 / summary が出る
- 選ぶと該当 zellij session に attach/switch できる

記録: session 名 ≈ project basename の規約が **何件中何件当たったか**を控える。外れが多ければ spec セクション6のフォールバック(起動ラッパでの `session→cwd` 記録)を次サイクルで検討。

- [ ] **Step 5: commit**

```bash
git add scripts/cca
git commit -m "feat: 🎸 cca_pick/cca_attach/cca_main: fzf 選択から zellij attach まで結線"
```

---

## Task 7: Nix 化(`writeShellApplication` で PATH に配布)

**Files:**
- Create: `home-manager/programs/cca.nix`
- Modify: `home-manager/programs/default.nix`

- [ ] **Step 1: `home-manager/programs/cca.nix` を作成**

```nix
{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "cca";
      runtimeInputs = with pkgs; [ jq fzf lsof zellij coreutils gnugrep gawk procps ];
      text = builtins.readFile ../../scripts/cca;
      # 本体末尾の `if [ "${BASH_SOURCE[0]}" = "$0" ]` ガードにより cca_main が実行される
    })
  ];
}
```

- [ ] **Step 2: `home-manager/programs/default.nix` の imports に追加**

`./neovim.nix` の行の後に `./cca.nix` を追加:

```nix
    ./antigravity-cli.nix
    ./git.nix
    ./yazi.nix
    ./neovim.nix
    ./cca.nix
```

- [ ] **Step 3: `writeShellApplication` の shellcheck を含むビルドを確認**

Run: `nix build .#homeConfigurations.<name>.activationPackage` もしくは既存の switch コマンドの dry-run(リポジトリ既定の適用手順に合わせる)。
Expected: shellcheck 警告なしでビルド成功。警告が出たら `scripts/cca` を修正して Task 2〜6 のテストを再実行してから再ビルド。

> 注: `set -euo pipefail` の下で `pgrep`/`grep` が「該当なし=非0終了」でパイプを落とさないよう、本体は `|| true` を付与済み(Task 5/6)。shellcheck SC2086 等が出た場合は該当箇所を quote する。

- [ ] **Step 4: home-manager を適用して PATH 上の `cca` を検証**

Run: (リポジトリ既定の apply/switch コマンド) → その後 `command -v cca && cca`
Expected: `cca` が PATH に居り、Task 6 Step 4 と同じ E2E 挙動をする。

- [ ] **Step 5: commit**

```bash
git add home-manager/programs/cca.nix home-manager/programs/default.nix
git commit -m "feat: 🎸 cca を writeShellApplication で home-manager 配布"
```

---

## Self-Review

**Spec coverage:**
- 一覧(project/branch/mtime/summary) → Task 2(discover)+Task 3(render) ✅
- active/idle 機械判定 → Task 3(icon by CCA_ACTIVE_WINDOW) ✅
- 生きてるものだけ(ps+lsof, sidechain 除外) → Task 5(live/filter)+Task 2(isSidechain==false) ✅
- fzf 選択 → attach → Task 6(pick/attach/main) ✅
- cwd→session 逆引き + fzf フォールバック → Task 4(join)+Task 6(main のフォールバック) ✅
- 規約マッチ率の実測(spec の核心リスク) → Task 6 Step 4 ✅
- Nix `writeShellApplication` 配布・mosh 先同一挙動 → Task 7 ✅
- v1 非対象(bg/approval/overlay) → 計画に含めず ✅

**Placeholder scan:** 各コードステップに実コードあり。Task 3/6/7 の「実測に合わせて調整」は環境依存の検証手順であり、実装のプレースホルダではない(具体の確認コマンドと期待値を明示済み)。

**Type consistency:** discover の出力 4 列(cwd/summary/branch/mtime_ms)= render の入力、render の出力先頭列 cwd = main の `cut -f1`、`cca_join` は arg=cwd + stdin=session名、で全タスク一致。関数名 `cca_reltime/discover/render/join/live/filter_live/pick/attach/main` はコントラクト表と本文で一致。
