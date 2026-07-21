# hermes ChatOps コンテナ merge 封止 decision-log (C16 / P2)

対象 issue AC:

- 「`gh pr merge` 系コマンドおよび nightly base への無人自動マージが ChatOps コンテナから実行できないことを確認できる（横断安全策）」

対象ファイル: `claude-code/container.settings.json`（ChatOps dispatch コンテナが mount する `/root/.claude/settings.json` の source）。

## 何を、なぜ

`container.settings.json` は `permissions.allow` に `"Bash"` を無制限で含んでいる（コンテナ内で任意の Bash コマンドを実行できる前提の許可リスト）。この状態で `permissions.deny` に個別コマンドの拒否パターンが積まれることで、危険操作を deny-list で個別に封止する設計になっている（`git push --force` 系、`rm -rf` 系、`sudo` 等、既存の deny エントリを参照）。

ChatOps dispatch フロー（hermes 経由で Slack/Discord/Google Chat からの依頼を受けて `claude --bg` を起動するコンテナ）では、依頼者の意図しない自動 PR マージが実行されると、レビュー・CI ゲートを経ないまま nightly / main 等の保護ブランチへ変更が取り込まれるリスクがある。特に nightly base への無人自動マージは、レビューなしでの変更混入を招きやすい。

これを防ぐため、本 task (P2) で `permissions.deny` に `"Bash(gh pr merge:*)"` を追加した。これにより ChatOps コンテナ内の Claude セッションは `gh pr merge` およびそのオプション付きバリエーション（`--auto`, `--squash`, `--admin` 等すべて）を一切実行できない。マージは常に人間が host 側（コンテナ外）で行う。

## `disableBypassPermissionsMode` との関係

`container.settings.json` の `permissions.disableBypassPermissionsMode` は既に `"disable"` に設定されている（本 task 実装前から）。これは Claude Code の bypassPermissions モード（`--dangerously-skip-permissions` 相当、全 permission チェックをスキップするモード）自体をコンテナ内で有効化できないようにする設定であり、`permissions.deny` の deny エントリが session 内から迂回されないことを保証する前提条件になっている。

`disableBypassPermissionsMode: "disable"` が外れると、`deny` に `Bash(gh pr merge:*)` を積んでいても bypass モードで permission チェックそのものが素通りしてしまい、本 task の封止が無意味になる。したがって両者は対（`disableBypassPermissionsMode: "disable"` かつ `deny` に `gh pr merge` 系を含む）で維持する必要がある。

## なぜ `container.settings.json` に // コメントを入れないか

`container.settings.json` は ChatOps コンテナ起動時に `/root/.claude/settings.json` へ bind mount される実行時設定ファイルであり、Claude Code の settings loader が strict JSON としてパースする。`//` コメントを混入させると:

1. mount 先での JSON parse が壊れ、コンテナが settings を読み込めずに起動失敗、または permission 設定が全く適用されない安全側でない状態に陥る
2. 本リポジトリの CI（`nix flake check` / treefmt）と、`jq empty` によるアサート運用（本ファイルのようなテストで `permissions.deny` の中身を機械検証する仕組み）が、strict JSON でなくなることで壊れる

このため、C16 の意図（bypass 封止と `gh pr merge` 禁止の根拠）はこの `claudedocs/` 配下の散文ドキュメントに記録し、`container.settings.json` 自体は deny エントリという JSON 値のみを追加する形にとどめている。

## 検証方法

`container.settings.json` に対し以下を `jq` でアサートすることで、この安全策が退行していないことを機械的に確認できる。

```bash
jq empty claude-code/container.settings.json
jq -e '.permissions.deny | index("Bash(gh pr merge:*)")' claude-code/container.settings.json
jq -e '.permissions.disableBypassPermissionsMode == "disable"' claude-code/container.settings.json
```

いずれも exit code 0 であれば、strict JSON が維持され、`gh pr merge` 系コマンドが deny され、bypass permission モードが無効化されている状態が保たれている。
