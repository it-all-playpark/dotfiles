# Deskflow server config

Mac 間でキーボード・マウスを共有する Deskflow のサーバ設定 (`deskflow-server.conf`)。
アプリ本体は `darwin/default.nix` の Homebrew cask で導入している。

配置先は `~/.config/deskflow/deskflow-server.conf`（home-manager の read-only symlink）。

## 初回セットアップ（手動、1回だけ）

1. Deskflow の GUI → Server タブ → **Use external configuration file** を有効化
2. パスに `~/.config/deskflow/deskflow-server.conf` を指定
3. サーバを再起動

`~/Library/Deskflow/Deskflow.conf` の `[server]` セクションに以下が入れば成功:

```ini
externalConfig=true
externalConfigFile=/Users/<user>/.config/deskflow/deskflow-server.conf
```

デフォルトの `~/Library/Deskflow/deskflow-server.conf` は書き込み可能なまま残してある。
外部設定を無効に戻しても GUI が書き込みに失敗しない。

## なぜ read-only symlink で平気か

`CoreProcess::persistServerConfig()` は外部設定が有効なとき、パスと readable 判定を
返すだけでファイルを書かない。内部設定モードのときだけデフォルトパスを
`WriteOnly | Truncate` で開いて書き出す。GUI がこのファイルへ書くのは
「Save server configuration as...」をユーザーが明示的に実行したときのみ。

## ホットキーの修飾キー名が反転している件

macOS サーバーでは `OSXKeyState::mapDeskflowHotKeyToMac()` の変換が直感と食い違う:

| conf の名前 | 実際の物理キー |
| --- | --- |
| `Shift` | ⇧ |
| `Control` | ⌃ |
| `Alt` | **⌘**（⌥ ではない） |
| `Super` | **⌥**（⌘ ではない） |
| `Meta` | **黙って捨てられる** |

ホットキーの照合は `InputFilter::KeystrokeCondition::match` が登録済みホットキー ID
だけで行うので、実際に効く物理キーはこの変換が全てを決める。

GUI のホットキー録音は Qt の macOS ctrl/meta swap により物理 ⌃ を `Meta`、物理 ⌘ を
`Control` と書き出すため、**GUI で作ったホットキーは必ず死ぬ**
(upstream: deskflow/deskflow#7972)。この conf を手で編集すること。

## 現在のホットキー

| 物理キー | 動作 |
| --- | --- |
| ⌘⌃T | MacBook Pro (`OMBP-M3P.local`) へ切替 |
| ⌘⌃S | Mac Studio (`USERnoMac-Studio.local`) へ切替 |

大西配列の t=左 / s=右 に合わせてある。⌘ を含む組み合わせは ghostty が消費して
zellij・nvim・fish には届かないので、`Alt+t/n/r/s` や `Ctrl+Alt+t/n/r/s` を使う
zellij とは衝突しない。macOS システムホットキー（⌘⌃ の英字は ⌃⌘D のみ）、
ghostty デフォルト（⌘⌃ は `f` `=` 矢印 `⇧J`）、Raycast（⌘Space）とも未使用を確認済み。

## 編集時の注意

- **非 ASCII 文字を書かない**。`ConfigReadContext::readLine()` の `isgraph` 検査で
  parse エラーになる。コメントも英語で書くこと
- `#` 以降は行コメントとして除去される
- `switchToScreen()` の画面名は `section: screens` の宣言と一致させる
