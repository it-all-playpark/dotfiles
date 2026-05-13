# claude-code

[Claude Code](https://docs.claude.com/en/docs/claude-code) の設定を dotfiles で管理する。
home-manager の `activation.setupClaudeCode` が `~/.claude/` 配下に symlink を張る。

`claude-code` バイナリ自体は mise で管理（`home-manager/home/file/mise/config.toml` の
`"npm:@anthropic-ai/claude-code"`）。本ディレクトリは設定のみを扱う。

## ファイル構成

```
claude-code/
├── README.md             # このファイル
├── CLAUDE.md             # global Claude Code instructions（PRINCIPLES.md / RULES.md を import）
├── PRINCIPLES.md         # ソフトウェアエンジニアリングの原則
├── RULES.md              # 振る舞いのルール（priority / workflow / safety / git 等）
├── settings.json         # permissions（allow/deny）+ hooks 設定 + env
├── skill-config.json     # it-all-playpark/skills の per-skill デフォルト値
└── hooks/                # SessionStart / PreCompact / Pre|PostToolUse スクリプト
```

`PRINCIPLES.md` / `RULES.md` はかつて SuperClaude framework の一部として導入したが、
framework 自体は使っていない。今は普遍的なガードレールとしてのテキストのみを残し、
`CLAUDE.md` から `@PRINCIPLES.md` / `@RULES.md` で import している。

## activation

`home-manager/home/default.nix` の `activation.setupClaudeCode` が以下を実施する:

1. `~/.claude/` ディレクトリ作成（無ければ）
2. `settings.json` を symlink
3. `CLAUDE.md` / `PRINCIPLES.md` / `RULES.md` / `FLAGS.md` / `README.md` を symlink（存在するもののみ）
4. `MCP_*.md` / `MODE_*.md` ファイルがあれば symlink
5. `hooks/*.{py,sh}` を `~/.claude/hooks/` に symlink（`*.test.sh` は除外）

`skills/` は `scripts/setup-skills.sh` で別管理（`setup.sh` から呼び出される）。
activation 側では触らないので、既存の symlink を壊さない。

```bash
nix run .#update
```

## hooks

`settings.json` の `hooks` セクションで wire し、`~/.claude/hooks/` にある実体スクリプトを呼ぶ。

| イベント | スクリプト | 役割 |
|---------|----------|------|
| `SessionStart` (startup / resume / compact) | `session-start-replay.sh` | 直近の作業状態を再表示 |
| `SessionStart` (startup) | `claude-zombie-kill` skill | 48h 以上 idle な claude プロセスを kill |
| `PreCompact` | `pre-compact-dump.sh` | compact 前に session 状態を `claudedocs/session-*.md` へ退避 |
| `PreToolUse` Skill | `skill-retrospective` の `journal.sh track-skill` | skill 使用ログ |
| `PreToolUse` Write (`*/SKILL.md`) | `validate-skill-frontmatter.sh` | skill frontmatter 検証 |
| `PreToolUse` Bash (`git push*`) | `allow-feature-push.sh` | protected branch への push を抑止 |
| `PreToolUse` Bash | `pretool-bash-credential-guard.sh` | prod credential を含むコマンドを抑止 |
| `PreToolUse` Bash (`git worktree add*`) | `generate-worktreeinclude.sh` | `.worktreeinclude` 自動生成 |
| `PreToolUse` Bash (`gh pr merge*`) | `allow-pr-merge.sh` | merge 先 branch チェック |
| `PostToolUse` 系 | `posttool-secret-mask.sh` | 出力中の secret をマスク |

テストファイル（`*.test.sh`）は symlink 対象外。

## settings.json の方針

- `permissions.allow`: 標準ツール（Read/Write/Edit/Bash/Task* など）と MCP ツールを明示的に許可
- `permissions.deny`: protected branch への push、危険な `gh api` / `git reset --hard` / `rm -rf` 等を遮断
- `permissions.additionalDirectories`: ghq の主要 workspace を予め通す
- `hooks`: 上記表の通り

permission を追加するときは、まず deny ルールに引っかからないか確認すること
（deny は allow より優先される）。

## skill-config.json

`it-all-playpark/skills` リポジトリの skill が読み込む per-skill デフォルト値。
ブログ系（`blog-fact-check` / `blog-seo-improve` / `blog-internal-links` 等）の閾値や、
`sales` skill のテンプレート文面などを集約している。

機密情報は **入れない**（このファイルは public repo にコミットされる）。
シークレットは各 skill が `~/.config/<skill>/` 等から個別に読む方式にする。

## skills のセットアップ

skills 本体は別 repo（[it-all-playpark/skills](https://github.com/it-all-playpark/skills)）で管理。
`scripts/setup-skills.sh` が `~/.claude/skills` / `~/.codex/skills` / `~/.gemini/antigravity/skills`
へ symlink を張る。詳細は本体 [README.md](../README.md#agent-skills) の Agent Skills セクション参照。

## Rollback

```bash
git revert <commit>
nix run .#update
# 必要なら symlink を手動で剥がす
rm ~/.claude/settings.json
rm ~/.claude/hooks/<name>.sh
```
