# 自律営業エージェント構築計画

## 概要

現在の `/sales` CLIスキル（受動的）を、OpenClawベースの自律エージェント（能動的）に進化させる。
人間が出るのは商談だけ。それ以外はエージェントが自動で回す。

## 現状（As-Is）

```
人間が /sales sync を手動実行 → Gmail同期
人間が /sales remind を手動実行 → 停滞検知
人間が /sales followup を手動実行 → 議事録+お礼メール
人間が /sales analyze を手動実行 → 企業分析+メール案
```

- データ: Git リポジトリ（YAML/Markdown）、50社+のパイプライン
- ダッシュボード: Next.js on Vercel (SSG)
- 外部連携: Gmail, Google Calendar, gBizINFO API
- 既存スクリプト: auto-deploy.sh, create-draft.sh, get-events.sh, get-gemini-notes.sh, analyze-prospect.py, pipeline-health.sh

## 目標（To-Be）

```
OpenClaw エージェントが常駐
  ├── cron: Gmail sync（毎時） → 活動履歴自動更新
  ├── cron: pipeline health check（毎朝） → 停滞レポート → Slack投稿
  ├── cron: remind（毎朝） → フォローアップメール案 → Slack承認待ち
  ├── event: 顧客返信検知 → 日程調整メール生成 → Slack承認待ち
  ├── event: 翌日に商談あり → 企業分析レポート自動生成 → Slack投稿
  └── trigger: 「商談終わった」→ 議事録+お礼メール+pipeline更新
```

## 判断の分岐

| 確認不要（自動実行） | Slack確認が必要 |
|---|---|
| Gmail sync → activities 追加 | メール送信（全種別） |
| pipeline.yml の last_contact 更新 | 日程候補の提案 |
| 企業情報の自動リサーチ(gBizINFO) | ステータス変更 |
| ダッシュボードデプロイ | 新規リード追加 |
| 停滞レポート生成 | NA / NA期限の変更 |

## 技術選定: OpenClaw

- ローカル常駐エージェント（Mac Mini or VPS）
- SOUL.md でエージェントの行動ルール・人格を定義
- ビルトインのSlack/Gmail/Calendar連携
- cron ジョブでスケジュール実行
- ~/.openclaw/workspace にコンテキストファイル配置

### 代替案の検討

| 選択肢 | Pros | Cons |
|---|---|---|
| **OpenClaw** | 既存スキルのロジック移植が容易、Slack/Gmail連携ビルトイン、cron内蔵 | 新しいツール（2026年初頭〜）、ナレッジが少ない |
| Claude Code + cron | 既存スキルそのまま使える | 常駐エージェントとしては設計されていない |
| n8n / Activepieces | ワークフロー自動化に強い | LLM判断の柔軟性が低い |
| 自前Agent (Claude API) | 完全カスタマイズ可能 | 開発コスト大、メンテ負荷 |

**結論**: OpenClaw。既存 `/sales` のロジックをSOUL.mdに移植しやすく、Slack承認フローもビルトイン。

## 実装フェーズ

### Phase 1: 基盤構築（1-2日）

1. **OpenClawインストール & onboard**
   - `npm install -g openclaw@latest`
   - `openclaw onboard --install-daemon`
   - Gateway設定（Claude APIキー）

2. **SOUL.md 作成**
   - エージェントのID・人格定義
   - 営業データ構造の説明
   - 判断ルール（自動実行 vs Slack確認）
   - 停滞検知ルール（3種類）
   - メールトーンガイドライン
   - セキュリティ境界（やってはいけないこと）

3. **チャネル接続**
   - Slack（承認フロー・レポート投稿）
   - Gmail（sync用）
   - Google Calendar（日程調整用）

### Phase 2: 自動化ループ（2-3日）

4. **cronジョブ設定**
   - 毎時: Gmail sync → 差分を activities/ に反映
   - 毎朝 7:00: pipeline health check → Slack日次レポート
   - 毎朝 7:30: remind → フォローアップメール案 → Slack承認待ち

5. **Slack承認フロー実装**
   - メール案をSlackに投稿 → ボタンorリアクションで承認/却下
   - 承認 → Gmail下書き作成（or 直接送信）
   - 却下 → 理由を学習してMEMORY.mdに記録

6. **auto-deploy.sh 連携**
   - データ変更後に自動実行
   - ビルド失敗時はSlackに警告

### Phase 3: インテリジェント化（3-5日）

7. **日程調整の自動化**
   - 顧客返信を検知 → 「日程調整」文脈を判定
   - Google Calendar APIで空き枠取得
   - 候補日を含むメール案を生成 → Slack確認

8. **商談前の自動準備**
   - 翌日のカレンダーをスキャン
   - 該当企業の analyze を自動実行
   - 分析レポートをSlackに投稿

9. **商談後処理のトリガー**
   - Slackで「〇〇の商談終わった」と発言
   - → followup 相当を自動実行（議事録+お礼メール+pipeline更新）

### Phase 4: 学習と最適化（継続）

10. **MEMORY.md による学習**
    - 承認/却下パターンからメールトーンを調整
    - 効果的だったアプローチを記憶
    - 企業ごとの特性・注意点を蓄積

## ファイル構成（予定）

```
~/.openclaw/
├── workspace/
│   ├── SOUL.md           # エージェントの人格・行動ルール
│   ├── MEMORY.md         # 学習した知識
│   └── AGENTS.md         # マルチエージェント設定（将来）
├── skills/
│   └── sales/
│       ├── SKILL.md      # 営業スキル定義
│       └── scripts/      # 既存スクリプトのラッパー
└── cron/
    ├── gmail-sync.json
    ├── daily-report.json
    └── remind.json
```

## 既存資産の移植マップ

| 既存（/sales スキル） | 移植先（OpenClaw） |
|---|---|
| SKILL.md | SOUL.md の行動ルールセクション |
| references/*.md | SOUL.md + skills/sales/ |
| schema.yml | そのまま参照（salesリポジトリ内） |
| scripts/*.sh | skills/sales/scripts/ にラッパー |
| skill-config.json | OpenClaw の env 設定 |
| 停滞検知ルール | SOUL.md の Decision Rules |
| メールテンプレート | SOUL.md の Email Guidelines |

## コスト見積もり

| 項目 | 月額 |
|---|---|
| OpenClaw 本体 | 無料（OSS） |
| Claude API（推定） | $20-50/月（cronの頻度次第） |
| 実行環境 | $0（既存Mac）or $6/月（VPS） |
| **合計** | **$20-56/月** |

## リスクと対策

| リスク | 対策 |
|---|---|
| 誤送信 | メール送信は必ずSlack承認を経由。下書き作成→確認→送信の2段階 |
| APIコスト超過 | cronの頻度を調整、キャッシュ活用 |
| OpenClawの安定性 | daemon監視、Slack通知でダウン検知 |
| Git競合 | エージェントは専用ブランチ or 逐次commit |

## 次のアクション

- [ ] OpenClawをインストール & onboard 実行
- [ ] SOUL.md のドラフト作成
- [ ] Slackワークスペースにチャネル作成（#sales-agent）
- [ ] Gmail API / Calendar API の認証設定
- [ ] Phase 1 の cronジョブをテスト実行
