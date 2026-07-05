# `cca` — foreground Claude セッション・スイッチャー 設計

- 日付: 2026-07-05
- ステータス: 設計承認済み（実装未着手）
- 置き場所: dotfiles repo（個人環境ツール）

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
| `~/.claude/projects/*/sessions-index.json` | `projectPath`(=cwd), `summary`, `gitBranch`, `fileMtime`, `modified`, `messageCount`, `isSidechain` | 何が / どこで / どのブランチ / 最終いつ。構造化済みなのでパースのみ |
| `ps` + `lsof`（cwd 取得） | 実在する `claude` プロセスの cwd 集合 | 「今生きてる」セッションに絞り、過去ログを捨てる |
| `zellij list-sessions` | zellij session 名（と作成時刻） | attach 先の実体 |

`sessions-index.json` の実データ形（確認済み）:

```json
{
  "version": 1,
  "entries": [
    {
      "sessionId": "6336cecd-...",
      "fullPath": ".../<sessionId>.jsonl",
      "fileMtime": 1769501587617,
      "summary": "Claude Code nix-darwin Setup Guide",
      "messageCount": 18,
      "modified": "2026-01-27T07:46:32.421Z",
      "gitBranch": "",
      "projectPath": "/Users/naramotoyuuji/.clawdbot",
      "isSidechain": false
    }
  ]
}
```

> 注: `sessions-index.json` は各プロジェクトの**履歴全件**を持つ。「今開いているか」は index だけでは判定できないため、`ps`/`lsof` の生存集合と intersect して現存セッションに絞る。`isSidechain: true` はサブエージェントの sidechain なので前景一覧からは除外する。

## 4. アーキテクチャ / データフロー

```
cca
  │
  ├─ 1. discover : ~/.claude/projects/*/sessions-index.json を glob → jq でパース
  │        各 project につき最新の非 sidechain entry を取り、
  │        TSV [cwd, summary, gitBranch, fileMtime] を出力
  │
  ├─ 2. live     : ps で claude プロセス列挙 → 各 PID の cwd を lsof で取得
  │        → 生きてる cwd の集合。1 の結果を intersect して過去ログを除外
  │
  ├─ 3. render   : 生きてる行だけを整形して fzf に流す
  │        "shift-bud       feature/issue-929   🟢 2m ago   Shift assignment bug"
  │        "corporate-site  main                💤 40m ago  Blog automation adoption"
  │        （🟢=直近 active / 💤=idle。fileMtime の鮮度だけで機械判定）
  │
  └─ 4. attach   : 選んだ行の cwd → zellij session を逆引き → attach / switch
           一意に決まらなければ zellij list-sessions を fzf に出して最終確認
```

`cca_discover | filter-by(cca_live) | cca_pick | cca_attach` とパイプで繋ぐ。

## 5. コンポーネント境界（単体テスト可能な単位）

| 関数 | 役割 | 入力 → 出力 | 依存 |
|---|---|---|---|
| `cca_discover` | index 収集・整形 | glob → TSV(cwd, summary, branch, mtime) | jq |
| `cca_live` | 生存判定 | — → 生きてる cwd の集合 | ps, lsof |
| `cca_join` | cwd → zellij session 逆引き | cwd → session 名 | zellij |
| `cca_pick` | fzf UI | TSV → 選択行 | fzf |
| `cca_attach` | 移動（副作用） | session 名 → attach/switch | zellij |

各関数は疎結合。純粋関数部（discover / join のロジック）は fixture でテストでき、副作用部（live / attach）は分離する。

## 6. 唯一の技術リスク: `cca_join`（cwd → zellij session 逆引き）

`zellij list-sessions` は session 名と作成時刻しか返さず、**session の cwd を機械的に取る綺麗な API が無い**。これが v1 検証の核心。

v1 の割り切り:
1. **規約前提マッチ**: session 名 ≈ cwd の basename でジョイン（session 名をプロジェクト名と揃えている前提なら一発で当たる）
2. **フォールバック**: 一意に決まらなければ `zellij list-sessions` を fzf に出して手動確定

**検証ポイント**: プロトタイプで「規約マッチがどれだけ当たるか」を実測する。当たらないケースが多ければ v2 で起動ラッパによる `session→cwd` マッピング記録を検討（ただし zero-install 方針に反するので最後の手段）。

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

- `cca_discover` / `cca_join`: fixture の `sessions-index.json` とモック `zellij list-sessions` 出力に対するユニットテスト（純ロジック）
- `cca_live` / `cca_attach`: 副作用系のため手動確認
- `writeShellApplication` の shellcheck を CI 相当のチェックとして活用

## 10. 受け入れ基準（v1 完了の定義）

1. `cca` を叩くと、生きている前景 Claude セッションのみが fzf に一覧表示される（過去ログ・sidechain は出ない）。
2. 各行に project 名 / gitBranch / 最終活動時刻（active/idle 色分け）/ summary が出る。
3. 行を選ぶと該当 zellij session に attach（または切替）できる。規約マッチが外れた場合は fzf フォールバックで手動確定できる。
4. mosh 先でも同じ `cca` が同じ挙動で動く（Nix 配布後）。
