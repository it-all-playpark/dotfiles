# `cca` — foreground Claude セッション・スイッチャー 設計

- 日付: 2026-07-05
- ステータス: 実装済み（v1）
- 置き場所: dotfiles repo（個人環境ツール）

> **改訂 (2026-07-05, live-pivot):** 当初 v1 は `sessions-index.json` を live のデータ源とする設計だったが、実装後の実機検証で**この前提が誤り**と判明した。`sessions-index.json` は履歴であり、稼働中セッションは載らない/遅延書き込みのため、index 起点では live 作業を取りこぼす(稼働中プロジェクトに index が無い/古い)。そこで **「生きてる claude プロセス(pgrep+lsof の cwd)を背骨にし、鮮度は transcript `.jsonl` の実ファイル mtime、branch は git から直接取る」** live-pivot 設計に変更した。以下は改訂後の内容。§3〜§5・§10 が該当。

## 1. 目的 / 解決する痛み

複数プロジェクトを zellij session で分離し、各 session に `claude --cwd $(pwd)` の前景ペインを1つ持つ運用をしている。session が増えると **「どのプロジェクトの Claude が最近動いていて、今どれに飛べばいいか」** が一覧できず、切り替えが遅い。

`cca` は **生きている前景 Claude セッションを一覧し、fzf で選んで該当 zellij session に一発で attach する** ための小さな CLI。既存の fzf スイッチャー群（`common.nix` の `g` / `w` / `S` / `bd`）の兄弟として位置づける。

一次価値は **高速な切り替え**。状態表示はどこに飛ぶか判断するための補助。

## 2. スコープ

### v1 に入れるもの
- 生きている前景 Claude セッションの一覧（プロジェクト名 / gitBranch / 最終活動時刻 / summary）
- `fileMtime` の鮮度による active / idle の色分け（機械判定、推論なし）
- fzf で選択 → 該当 zellij session へ attach

### v1 に入れないもの（YAGNI）
- 背景 Claude / bg ジョブ / worktree 側エージェントの一覧（性質が違う。別スコープ）
- 🟡 approval 待ちの厳密判定（transcript には状態フラグが無く当て推量になる。欲しくなったら v2 で Notification hook）
- 常時表示オーバーレイ / 通知デーモン（別プロジェクト・別 spec。bash では辛く、必要なら Go/Rust TUI）

### 非目標
- Go / Rust への移植。Nix + bash で portability（home-manager が jq/fzf/lsof を全マシンに同一配布）と堅牢性が足りるため、switcher スコープでは移植しない。Go が復活するのはライブ TUI / オーバーレイという別ツールを作るときだけ。

## 3. データ源と役割分担

推論ゼロ。3つの機械的データ源を join するだけ。

| データ源 | 取得できるもの | 役割 |
|---|---|---|
| `pgrep -x claude` + `ps -o tty=` + `lsof -d cwd` | **制御端末を持つ**(=前景/対話)`claude` の cwd 集合 | **背骨。**一覧に出す対象そのもの。端末なし(tty=`??`)の背景 claude(サブエージェント/routine/常駐 daemon)は除外 |
| `~/.claude/projects/<enc(cwd)>/ *.jsonl` の実ファイル mtime | そのプロジェクトの transcript が最後に追記された実時刻 | 鮮度(🟢 active / 💤 idle + 相対時刻)。live 更新される真実 |
| `git -C <cwd> branch --show-current` | 現在の branch | 表示。index でなく git 直で正確 |
| `zellij list-sessions` | zellij session 名 | attach 先の実体 |

> **なぜ `sessions-index.json` を使わないか(実機検証で判明):** index は各プロジェクトの**履歴**であり、稼働中セッションは載らない/遅延書き込みされる。実際、稼働中の second-brain / jikka-scan / yeg は index が**存在せず**、skills は index があるが最新エントリが**150日前**だった。index 起点だと live 作業を取りこぼす。対して transcript `.jsonl` の実ファイル mtime は追記のたび更新される=リアルタイムの真実なので、こちらを鮮度源にする。
>
> cwd → transcript ディレクトリのエンコード規則: パス区切り `/` と `.` を `-` に置換(先頭 `/` も `-` に)。例 `/Users/x/ghq/github.com/a/skills` → `-Users-x-ghq-github-com-a-skills`。

## 4. アーキテクチャ / データフロー

```
cca
  │
  ├─ 1. live      : pgrep -x claude → 各 PID の cwd を lsof で取得(sort -u)
  │         → 生きてる cwd の集合。これが一覧の対象そのもの
  │
  ├─ 2. enumerate : 各 live cwd について
  │         branch = git -C cwd branch --show-current
  │         mtime  = enc(cwd) の transcript dir 内、最新 .jsonl の実 mtime
  │         → TSV [cwd, branch, mtime_epoch]
  │
  ├─ 3. render    : cwd\tbranch\tmtime → 表示整形して fzf に流す
  │         "second-brain  main                          🟢 3s"
  │         "jikka-scan    feature/report-partners-page  💤 41m"
  │         （🟢=直近 active / 💤=idle。.jsonl 実 mtime の鮮度で機械判定）
  │
  └─ 4. attach    : 選んだ行の cwd → zellij session を逆引き → attach / switch
           一意に決まらなければ zellij list-sessions を fzf に出して最終確認
```

`cca_live | cca_enumerate | cca_render | cca_pick` → 選択行の `cut -f1`(cwd) → `cca_join` → `cca_attach`。

## 5. コンポーネント境界（単体テスト可能な単位）

| 関数 | 役割 | 入力 → 出力 | 依存 |
|---|---|---|---|
| `cca_reltime` | 秒 → 相対時刻文字列 | 秒 → `3s`/`41m`/`4h`/`2d` | — (純) |
| `cca_encode_dir` | cwd → transcript dir 名 | cwd → `-Users-...` | — (純) |
| `cca_newest_mtime` | dir 内最新 .jsonl の epoch | dir → epoch or 0 | ls, stat(GNU/BSD両対応) |
| `cca_live` | 生存判定 | — → 生きてる cwd 集合 | pgrep, lsof |
| `cca_enumerate` | live cwd を情報付き TSV に | stdin cwd → cwd\tbranch\tmtime | git, (encode/newest_mtime) |
| `cca_render` | 表示整形・鮮度判定 | TSV → 表示 TSV | — (純, CCA_NOW注入可) |
| `cca_join` | cwd → zellij session 逆引き | cwd + stdin session名 → session名 | grep |
| `cca_pick` | fzf UI | TSV → 選択行 | fzf |
| `cca_attach` | 移動（副作用） | session 名 → attach/switch | zellij |

純関数部（reltime / encode_dir / newest_mtime / render）は fixture でユニットテスト、副作用部（live / enumerate / attach）は手動確認。v1 では summary 列は出さない(index を使わないため。必要になれば git log や transcript から後付け)。

## 6. 唯一の技術リスク: `cca_join`（cwd → zellij session 逆引き）

`zellij list-sessions` は session 名と作成時刻しか返さず、**session の cwd を機械的に取る綺麗な API が無い**。これが v1 検証の核心。

v1 の割り切り:
1. **規約前提マッチ**: session 名 ≈ cwd の basename でジョイン（session 名をプロジェクト名と揃えている前提なら一発で当たる）
2. **フォールバック**: 一意に決まらなければ `zellij list-sessions` を fzf に出して手動確定

**検証ポイント**: プロトタイプで「規約マッチがどれだけ当たるか」を実測する。当たらないケースが多ければ v2 で起動ラッパによる `session→cwd` マッピング記録を検討（ただし zero-install 方針に反するので最後の手段）。

> **実機で解消済み(2026-07-06):** 当初 basename 完全一致だと、zellij session 名が `-` を `_` にして付けられる運用(例 `second_brain` ↔ dir `second-brain`)で毎回外れフォールバックしていた。`cca_join` で両側を `_`→`-` 正規化して一致させることで、second-brain / jikka-scan / corporate-site / skills / yeg など実プロジェクトは別リスト無しで直接 attach できることを確認。規約リスクは実運用上ほぼ解消。
>
> なお **ホーム直下(`$HOME`)で起動した非プロジェクト claude は `cca_enumerate` で一覧から除外**する（対応する zellij session が無くフォールバック専用になりノイズのため）。

## 7. attach の挙動（zellij 制約への対応）

- zellij は2つの session に同時 attach できない。呼び出し元が既に別 session に attach 中の場合、`zellij` の session 切替（detach → attach、または利用可能なら session-switch アクション）を使う。
- 呼び出し元が zellij 外（bare shell）なら単純に `zellij attach <session>`。
- 実装時に手元の zellij バージョンで切替手段（`zellij attach` / session-switch 相当）を確認する。

## 8. スタック / 配布

| 段階 | 形 | 理由 |
|---|---|---|
| プロトタイプ | `~/bin/cca` など素の bash スクリプト（Nix 外） | nix rebuild ループは反復に遅い。まず素で回して規約マッチ率を実測 |
| 定着後（推奨） | `home-manager/programs/cca.nix` に `pkgs.writeShellApplication` | `runtimeInputs` で jq/fzf/lsof/zellij を明示・shellcheck 自動。PATH 上の実コマンドとして home-manager で全マシン同一配布 |

`writeShellApplication` を採用（`writeShellScriptBin` ではなく）: `runtimeInputs` で依存を closure に固定でき、shellcheck もかかるため。`programs/default.nix` の imports に追加する。

> `common.nix` の `shellSortcuts` への直書きは、`cca` が多関数・50行規模でエスケープ地獄になるため採らない。

## 9. テスト戦略

- `cca_reltime` / `cca_encode_dir` / `cca_newest_mtime` / `cca_render` / `cca_join`: `scripts/cca_test.sh` でユニットテスト（純/準純ロジック。newest_mtime は一時ディレクトリで検証）
- `cca_live` / `cca_enumerate` / `cca_attach`: 副作用系のため手動確認（実 live cwd を enumerate→render に流す統合確認を含む）
- `writeShellApplication` の shellcheck を CI 相当のチェックとして活用

## 10. 受け入れ基準（v1 完了の定義）

1. `cca` を叩くと、**今生きている全 claude プロセス**の cwd がプロジェクトとして fzf に一覧表示される（過去ログは出ない）。
2. 各行に project 名 / gitBranch / 最終活動時刻（`.jsonl` 実 mtime による active🟢 / idle💤 色分け + 相対時刻）が出る。
3. 行を選ぶと該当 zellij session に attach（または切替）できる。規約マッチが外れた場合は fzf フォールバックで手動確定できる。
4. mosh 先でも同じ `cca` が同じ挙動で動く（Nix 配布後）。

**実機検証済み(2026-07-05):** 4つの live プロジェクト(second-brain 🟢3s / skills 💤4h / jikka-scan 💤41m branch=feature/report-partners-page / yeg 💤56m)が正しい鮮度・branch で列挙されることを確認。
