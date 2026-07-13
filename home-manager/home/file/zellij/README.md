# Zellij 設定 — モバイル閲覧対応

## 設計方針

スマホ（iPhone / Moshi）から触るときの2つの課題への最小対応:

1. **pane 分割で画面が小さくて読めない** → サーバ側で解決（stack layout / BreakPane）
2. **ショートカットが打ちにくい** → クライアント側で解決（Moshi のショートカット
   ビルダーに既存の Alt バインドを割り当てる。config は変えない）

キーバインド体系は従来の `Alt+大西配列` のまま。追加は2つだけ:

| キー | 動作 |
|------|------|
| `Alt b` | pane を新タブに昇格（BreakPane）。タブ切替で全画面閲覧する用 |
| `Ctrl+a k` | 逆順レイアウト切替。base から1発で **stack**（完全スタック）へ |

## レイアウト（layouts/mobile.kdl）

builtin compact 相当 + `stack`（完全スタック, min_panes=2）を**末尾**に追加したもの。
stack はフォーカス pane だけ展開し他はタイトル1行になるので、狭い画面でも読める。
`Ctrl+a k`（逆順1発）または `Ctrl+a Space` の循環で到達する。

swap layout の順序は builtin と同じ vertical → horizontal を先頭に維持している。
Zellij は pane 開閉時に先頭から合致する swap layout を自動選択するため、
stack を先頭に置くとデスクトップでも pane を開いた瞬間にスタック表示になってしまう。

## モバイル（iPhone / Moshi）側の推奨設定

Moshi のショートカットビルダーで既存バインドをボタン / スワイプに割り当てる:

| 割当先 | キー | 用途 |
|--------|------|------|
| ボタン | `Alt z` | pane 全画面トグル |
| ボタン | `Alt b` | pane→タブ昇格 |
| ボタン | `Ctrl+a` `k` | stack レイアウト切替 |
| スワイプ左右 | `Alt T` / `Alt S` | タブ移動 |
| D-pad | `Alt t/n/r/s` | pane フォーカス移動 |
| ボタン | `Alt i` | スクロールモード（中は単打キー） |

補助機能:

- **Sticky modifier**: Ctrl/Alt を1タップ→次のキーに適用、ダブルタップ→ロック
- **Mouse Mode**: タップが zellij に届くので compact-bar のタブ切替も可
- **iOS フローティングキーボード**: キーボードをピンチインで縮小し隅に退避できる

## 既知の制約

- `default_layout` は**新規セッション作成時のみ**参照される。既存セッションは
  従来の挙動のまま（壊れないが stack layout も使えない）。作り直しは不要で、
  新レイアウトを使いたいセッションだけ作り直せばよい
- 複数クライアント同時 attach 時は最小クライアントに合わせてリサイズされる
  （tmux の grouped session 相当は Zellij に無い）。スマホとデスクトップの
  同時利用時はスマホ専用セッションを分けること
- `Ctrl+a k`（PreviousSwapLayout）が base からラップしない実装だった場合は
  no-op になる。その場合は `Ctrl+a Space` ×3 で stack に到達する
