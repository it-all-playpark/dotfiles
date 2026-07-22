# hermes C7 (資格情報 blast radius) 要決定事項 decision-log (S? / P-C7)

対象 issue AC:

- AC-14: 「フェーズE着手前に、未解決事項C7の要決定事項(4項目)がすべて decision-logged されていることを確認できる（フェーズE前提条件）」

このドキュメントは C7 の 4 要決定事項それぞれについて、**決定 or 明示的保留**のいずれかを根拠・影響とともに記録する。フェーズE（Discord/Google Chat 対応）は本ログの存在を着手前提とする。issue 本体では 4 項目の最終決定は求められていないため、一部項目は「暫定方針を採用しつつ最終決定はフェーズE直前に再確認する」という明示的保留として記録している。

対象コンテナ環境: `hermes/config.yaml` の `terminal.docker_volumes` / `docker_forward_env`、および `claude-code/container.settings.json` の permissions。dispatch container は ChatOps 経由の外部依頼を実行するため、host 資格情報を container が保持することの blast radius（漏洩・誤用時の被害範囲）が C7 の論点。

## 1. gws mount 削除可否

**決定: 保留（現状維持のまま次回見直しトリガーを明記）**

- 現状: `hermes/config.yaml` の `terminal.docker_volumes` に
  `/Users/naramotoyuuji/.config/gws:/root/.config/gws:rw` が bind mount されている（`rw`）。
  これにより dispatch container 内のプロセスは host の Google Workspace CLI 資格情報
  （`~/.config/gws/token.json`、long-lived refresh_token を含む）を **読み書き**できる。
- 根拠: `gws-*` skills（gws-calendar / gws-docs 等）は Slack 経由の ChatOps 依頼で
  Google Workspace 操作を行うユースケースが hermes の対象範囲に含まれており、mount 削除は
  それらの skill を container 内で丸ごと無効化する。一方で `rw` 権限は
  `gws auth login` の再実行や token refresh を container 内から誘発した場合に
  host 側の token.json を書き換えうる副作用があり、`ro` へのダウングレードや
  「gws を使う job 種別のみ mount する」分離は未検証（`config.yaml` は terminal 全体の
  単一 volume 定義であり、per-job・per-skill での volume 差し替えは現行実装に存在しない）。
- 影響: gws mount を削除した場合、Slack 経由での Google Workspace 系依頼（カレンダー確認・
  ドキュメント書き込み等）は container 内 `gws` コマンドが認証情報を持てず失敗する
  （fail-closed になる。誤動作ではなく機能欠落として顕在化する）。維持した場合、
  container の権限が漏洩・侵害された場合の blast radius に Google Workspace
  （host ユーザーの Calendar/Docs への読み書き）が含まれる。
- 次回見直しトリガー: (a) `rw` → `ro` 化の実装（token refresh を host 側の対話フローに
  戻す）が可能になった時点、または (b) per-job / per-skill 単位で volume を絞れる
  実装（S1〜S4 で確定した dispatch container モデルの拡張）が入った時点で、削除ではなく
  `ro` 化を優先して再検討する。フェーズE着手時点でこの見直しが未着手でも、gws mount は
  Slack 経由の既存機能要件であるため、フェーズE自体の着手条件にはしない。

## 2. WebSearch 削除 or 受容

**決定: 受容（現状維持）**

- 現状: `claude-code/container.settings.json` の `permissions.allow` に `WebSearch` が
  含まれている。dispatch container 内で実行される Claude セッションは外部依頼
  （Slack/Discord/Google Chat 由来）に応じて任意の Web 検索クエリを発行できる。
- 根拠: WebSearch はサンドボックス外ネットワークへの任意アクセスを可能にする点で
  blast radius の一部を構成するが、(a) 検索結果の取得のみで書き込み・資格情報の
  持ち出しには直結しない、(b) `security.website_blocklist`
  （169.254.169.254 等のメタデータエンドポイント）と `security.tirith_enabled` による
  出力側ガード、(c) `permissions.deny` の `gh` / `git push` 系コマンド封止と組み合わさることで、
  WebSearch 単体を悪用した資格情報窃取（例: 検索クエリへの secret 埋め込みによる
  外部送信）は `redact_secrets: true` により軽減される。ChatOps の実用性
  （ユーザー依頼への回答に外部情報が必要なケースが多い）を優先し、削除ではなく受容する。
- 影響: WebSearch を受容する場合、悪意ある依頼者が container に「特定 URL へ機密情報を
  クエリパラメータとして送出させる」プロンプトインジェクションを試みる余地が残る
  （`redact_secrets` は既知パターンの secret 文字列を対象とし、任意の内部情報の
  漏洩を完全には防げない）。この残存リスクは C7 全体の一部として記録し、
  フェーズE で allowlist 外ユーザー遮断（AC-12）が入ることで攻撃者の入力経路自体を
  狭める方針と組み合わせて受容する。

## 3. fine-grained token 移行可否

**決定: 保留（移行は望ましいが本 issue の範囲外、フェーズE前の必須条件にはしない）**

- 現状: `hermes/config.yaml` の `terminal.docker_forward_env` に `GH_TOKEN` が含まれ、
  host 環境変数の `GH_TOKEN`（または `gh auth token` 経由で解決される値）が
  container にそのまま転送される。`hermes/.env.template` には `GH_TOKEN` のエントリは
  なく、host 側の `gh` CLI 認証（keyring 経由）に依存した値がフォワードされる設計であり、
  現行の token が classic PAT か fine-grained PAT かは `.env`/host 環境変数の実体
  （本 implementer からは `denyRead` 対象で確認不可）に依存する。
- 根拠: fine-grained PAT（repo 単位・permission 単位でスコープを絞れる GitHub token）へ
  の移行は、dispatch container が侵害された場合に到達可能な repo 範囲を
  `repo_bindings.yaml` に列挙された bind 対象 repo のみへ物理的に制限できる点で
  blast radius 低減に直結する。ただし移行には (a) fine-grained PAT の発行・
  ローテーション運用の確立、(b) `gh` CLI が fine-grained PAT で要求する操作
  （clone/PR 作成等）をすべてカバーできるかの実機検証、(c) 複数 bind repo
  にまたがる token 管理の複雑化、が伴い、いずれも本 issue の他フェーズ
  （A〜D）のスコープには含まれていない。加えて横断安全策側で
  `gh pr merge` 系コマンド封止・保護ブランチ push deny・branch protection 必須化
  （issue AC 該当項目）により、token の scope に関わらず危険操作自体を
  container 内 hook で二重に塞ぐ設計になっているため、fine-grained token
  移行は「多層防御の追加レイヤー」であり必須のブロッカーではない。
- 影響: 現状維持（token forward のまま）の場合、host の `gh` 認証が classic PAT や
  broad scope の token であれば、container 侵害時に bind 対象外の private repo
  （host ユーザーがアクセス可能な全 repo）への読み取り・書き込みが理論上可能になる
  （hook による deny は「危険コマンドパターン」の遮断であり、token の到達範囲自体は
  制限しない）。移行を今後実施する場合は、C7 の中で最優先の残課題として
  別途 issue 化することを推奨する。フェーズE着手条件にはしない
  （フェーズE は allowlist/mention/dedupe というリクエスト受付側の防御が主眼であり、
  token scope は独立した資格情報管理の論点のため）。

## 4. 脅威モデル節の追加

**決定: 決定（本ドキュメントを脅威モデル節の初版として位置づける。恒久的な配置先は `hermes/README.md` への集約を今後の課題とする）**

- 現状: `hermes/README.md` には token 投入手順・container 専用 OAuth token 発行手順など
  運用手順は存在するが、「dispatch container が保持する資格情報一覧とその blast radius」
  を体系立てて説明する独立の脅威モデル節は存在しない。
- 根拠: C7 の 1〜3 の各項目（gws mount / WebSearch / GH_TOKEN scope）は個別の
  decision-log としては記録できても、それらを横断して「container 侵害時に何が
  どこまで到達可能か」を一望できる資料がないと、フェーズE以降で新たな platform
  （Discord/Google Chat）を追加するたびに同じ論点を再検証するコストが発生する。
  そこで本ドキュメントを脅威モデル節の起点として位置づけ、下表に現時点で
  container が保持する資格情報と到達範囲をまとめる。将来的な恒久配置先としては
  `hermes/README.md` に「脅威モデル」節を新設し本表を移植することを推奨するが、
  その作業自体は本 P-C7 task のスコープ外（file_changes は本ファイルのみ）とする。
- 影響: 本節を欠いたままフェーズE（外部 platform 追加）に進むと、新規 platform 経由の
  攻撃面（allowlist 外ユーザー・mention なしメッセージ・重複配送）が既存の資格情報面の
  リスクとどう重なるかの評価が抜け落ちるリスクがあった。本節を用意することで
  フェーズE の S7 実装時にこの表を出発点として platform 別の追加軽減策
  （AC-12/AC-13）を評価できる。

### 資格情報 blast radius 表（脅威モデル初版）

| 資格情報 | 転送/mount 方式 | container 内到達範囲 | 現在の軽減策 | 本 decision-log 項目 |
|---|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `docker_forward_env` | Claude API 呼び出し（container 専用 token として別発行済み、host 対話用とは分離） | container 専用 token を個別発行する運用（README 記載） | 対象外（既に分離済み） |
| `GH_TOKEN` (gh CLI 認証) | `docker_forward_env` | `gh`/`git` 経由での GitHub API・repo 操作。scope は host 側認証実体に依存 | `container.settings.json` の `deny`（`gh pr merge`/`git push --force`/保護ブランチ push 等封止）、branch protection 必須化（issue AC 該当） | 項目3 (fine-grained token) |
| gws token.json | `docker_volumes` (`rw`) | Google Workspace（Calendar/Docs 等）への読み書き | なし（`rw` mount のまま） | 項目1 (gws mount) |
| WebSearch ツール | `container.settings.json` permissions.allow | 任意外部 URL への検索クエリ発行 | `security.website_blocklist`, `security.tirith_enabled`, `redact_secrets` | 項目2 (WebSearch) |

## まとめ

| 項目 | 状態 | 決定/保留 |
|---|---|---|
| 1. gws mount 削除可否 | decision-logged | 保留（現状 `rw` 維持、`ro` 化・per-job 分離を次回見直しトリガーとして記録） |
| 2. WebSearch 削除 or 受容 | decision-logged | 受容（既存ガード層との組み合わせで許容、残存リスクは明記） |
| 3. fine-grained token 移行可否 | decision-logged | 保留（移行は推奨するが本 issue 範囲外、多層防御で当面代替） |
| 4. 脅威モデル節の追加 | decision-logged | 決定（本ドキュメントを初版として追加。恒久配置先は `hermes/README.md` への統合を今後の課題として明記） |

4 項目すべてが decision-logged された状態となったため、S7（フェーズE: Discord/Google Chat 対応）着手の前提条件（AC-14）を満たす。
