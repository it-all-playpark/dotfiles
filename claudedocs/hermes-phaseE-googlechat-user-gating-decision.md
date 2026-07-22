# hermes Google Chat AC-12 per-user gating gap 決定ログ (S7 / E3)

対象 issue AC:

- AC-12: 「Discord/Google Chat の allowlist 外ユーザーからの依頼、および mention なしメッセージが
  dispatch されないことを確認できる（フェーズE）」

evaluator の major finding（`escalate: true`, `escalate_reason: accountability`）を受け、
Google Chat 経路が AC-12 を **per-user 粒度では config だけで満たせない** という設計上の gap を
正直に記録し、受容可否を人間判断へ escalate するための decision-log。C7 の
[`claudedocs/hermes-c7-blast-radius-decisions.md`](hermes-c7-blast-radius-decisions.md) と同じ
「決定 or 明示的保留」を根拠・影響とともに記録するパターンに揃える。

## 概要

Discord は `DISCORD_ALLOWED_USERS`/`DISCORD_ALLOWED_ROLES`（env allowlist）+
`platforms.discord.extra.require_mention: true` により、config レベルで AC-12（allowlist 外
ユーザー拒否・mention なし拒否）を **per-user 粒度**で満たす。一方 Google Chat には native
adapter（`gateway/platforms/google_chat.py` 相当）が存在せず、generic webhook 経路
（`gateway/platforms/webhook.py`）の route 単位 shared HMAC secret のみで認証する。この secret
は「正しい secret を伴った POST か」を検証するものであり、「どの個人が送信したか」を検証しない。
そのため bound space（Google Chat 側の概念で route の外側にある「誰が secret を知っているか」の
実質的な境界）内の任意メンバーは、Google Chat 側サーバーが保持する secret を伴ってメッセージを
送るだけで dispatch を誘発でき、per-user allowlist・mention 概念による絞り込みを経由しない。

## gap の構造

- **経路**: Google Chat → generic webhook 経路（`gateway/platforms/webhook.py`）。
  `hermes/config.yaml` の `platforms.webhook.extra.routes.google-chat.secret` は
  `${GOOGLE_CHAT_WEBHOOK_SECRET}` を参照する route 単位 shared secret（`hermes/config.yaml:78-98`
  に記載のとおり `gateway/platforms/` に `google_chat.py` は存在しない）。
- **認証境界**: `webhook.py._handle_webhook` は `_validate_signature` で HMAC 署名（GitHub形式
  `X-Hub-Signature-256` / GitLab形式 `X-Gitlab-Token` / generic `X-Webhook-Signature`）を検証する
  だけで、送信者の識別情報（Google Chat の `user.name`/`user.email` 等）を認可判断に使う仕組みを
  持たない。secret は Google Chat 側サーバーが space にひも付けて保持するため、**bound space の
  全メンバーのメッセージが正しい secret を伴って到達する**。secret は「space（≒ route）の境界」で
  あって「個人の認可」ではない。
- **enforcement 層への非伝播**: `hermes/plugins/claude_runner/guard.py`（`check()` / `bindings_mod.
  resolve_repos(bindings, platform, channel)`）と `dispatch.py` の `dispatch_job` は
  `platform` + `channel`（Google Chat では space ID）から bind 対象 repo を解決する
  **channel（space）→ repo scope** の検証のみを行い、**user scope の検証パラメータを持たない**。
  つまり webhook 経路を通過した時点で end-user identity は enforcement 層に渡っておらず、
  per-user allowlist や mention 相当の絞り込みを guard 層で追加する接続点が現状存在しない。
- **repo 管理外**: enforcement 層の実体である `webhook.py` は `~/.hermes/hermes-agent/gateway/
  platforms/webhook.py`（editable install 側）にあり、本 repo（hermes plugin config）の管理外。
  よって `hermes/config.yaml` / `hermes/repo_bindings.yaml` の config 変更だけでは per-user
  gating を追加できず、追加するには `webhook.py` 自体の改修（または専用 `google_chat.py` adapter
  の新設）が必要。
- **Discord との対比**: Discord は `_is_allowed_user`（env `DISCORD_ALLOWED_USERS`/
  `DISCORD_ALLOWED_ROLES` allowlist）+ `require_mention`（strict mention gating）を native
  adapter 内で行い、いずれも**送信者個人**を認可の単位とする。Google Chat の shared secret 認証は
  この意味で対称ではなく、AC-12 の「allowlist 外ユーザー/mention なしを dispatch させない」を
  per-user 粒度で満たさない。

結論: Google Chat の webhook 経路は「未認証の送信元（誤った secret）を拒否する」という
route/space 境界の保証は満たすが、「allowlist 外の個人・mention なしのメッセージを拒否する」
という per-user 保証は満たさない。両者は別の保証であり、前計画（config だけで AC-12 GChat 充足と
した記述）はこの区別を暗黙に混同していた。

## 選択肢

### 案A: space + shared-secret 境界を Google Chat の信頼モデルとして受容する

- bound space の membership 管理（信頼できるメンバーのみが space に在籍していることを運用で
  担保する）を代償統制（compensating control）とする。
- 実装変更なし。既存の secret 検証（route 単位）+ channel(space)→repo scope の guard を
  そのまま「space 単位の認可境界」として運用する。
- **残存リスク**: space に在籍する全メンバーが full dispatch 能力を持つ（個人単位での制限が
  効かない）。mention gating も存在しないため、space 内の通常会話メッセージが誤って dispatch
  条件を満たしうる（webhook route 側の `events` フィルタ・prompt テンプレート次第では、
  space 内の任意発言が dispatch 対象になりうる）。space membership の管理不備（信頼できない
  メンバーの混入、space の URL/招待リンクの流出等）がそのまま per-user gating の欠落を突く
  攻撃面になる。

### 案B: gateway adapter 側に per-space 送信者検証 + mention 相当 gating を追加するまで production bind を保留する

- 対応: `~/.hermes/hermes-agent/gateway/platforms/webhook.py`（別 issue/別 repo でのパッチ）
  または専用 `google_chat.py` adapter の新設により、Google Chat の payload に含まれる送信者
  情報（`user.name`/`user.email` 等）を抽出して per-user allowlist 判定・mention 相当の
  gating（例: bot への `@メンション` に相当する Google Chat の `ANNOTATION_TYPE_UNSPECIFIED`/
  slash-invocation 判定）を追加する。この改修が入るまでは、Google Chat の production bind を
  保留する、または「space 内の全メンバーが既に信頼済み」と明示的に判断できる space のみに
  bind を限定する運用とする。
- **残存リスク**: 改修が入るまで Google Chat 経由の ChatOps 機能自体が使えない（機能欠落として
  顕在化。fail-closed 側に倒すトレードオフ）。改修コスト・スケジュールは本 issue のスコープ外
  （別 issue/別 repo）で未見積り。

## 残存リスク表

| 論点 | 内容 |
|---|---|
| C7 (資格情報 blast radius) との重なり | C7 は dispatch container が保持する host 資格情報（GH_TOKEN, gws token 等）の侵害時到達範囲を扱う。本 gap（GChat per-user 未保証）は「侵害の起点となりうる入力経路が per-user で絞られていない」という**攻撃面の入口側**の論点であり、C7 の資格情報 blast radius（**到達後の被害範囲**）と直接連鎖する — space 内の信頼できないメンバーが dispatch を誘発できれば、C7 で列挙した GH_TOKEN/gws mount/WebSearch の到達範囲がそのまま攻撃対象になる。 |

## 決定

**要決定（人間判断へ escalate、決定保留）**

- planner/implementer は本 gap の受容可否（案Aで受容するか、案Bで production bind を保留するか）
  を代行して決定しない。evaluator の `escalate_reason: accountability` の要請どおり、これは
  人間が選ぶべき決定点として提示するに留める。
- 決定後の手順: 人間が案A（受容）または案B（保留/gateway adapter 改修待ち）のいずれかを選んだ
  時点で、本ドキュメントの本節を「決定: 案A（受容）」または「決定: 案B（保留、追跡先 issue: …）」
  に書き換え、`hermes/README.md` の AC-12 チェックリスト（Google Chat 項）から本ファイルへの
  参照を維持したまま、選択した案に応じた運用注記（案A: space membership 管理の運用手順明記 /
  案B: production bind 保留の明記または追跡 issue リンク）を追記すること。
