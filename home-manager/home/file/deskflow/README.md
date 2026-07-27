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
| F13 | MacBook Pro (`OMBP-M3P.local`) へ切替 |
| F14 | Mac Studio (`USERnoMac-Studio.local`) へ切替 |

ZMK キーボード (`zmk-config-fish`) の `layer_navi` から出している。右親指の
`&lt 2 ESC` を押しながら、左小指ホーム (position 9) が F13、右小指ホーム
(position 18) が F14。

**キー名は大文字小文字を区別する**。`kKeyNameMap` にあるのは `F13` であって
`f13` ではない。`F13`〜`F35` が使える。

## なぜ修飾キーを使わないのか

以前は物理 ⌘⌃T / ⌘⌃S を使っていたが、macOS サーバーでは**修飾キーを含む
ホットキーは必ず入力状態を壊す**。

ホットキーが押されている最中に画面切替が発動するため、`⌃ up` / `⌘ up` が
**切替先の機体に飛び、サーバーは release を一度も受け取らない**。結果として
サーバー側で修飾キーが押しっぱなしになり、

- 長押しが `ctrl+ctrl` / `⌘+⌘` の二重押しとして認識される
- トラックパッドのクリックが ⌃クリック・⌘クリック扱いになる
- Bluetooth の接続先を切り替えて戻すと直る（HID 再列挙で状態がリセットされるため）

という症状が出る。修飾キーを含まない単発キーならこの経路が成立しない。ZMK の
`&lt`（layer-tap）のホールドはレイヤー切替が firmware 内部で完結し**ホストに
何も送らない**ので、レイヤーキー自体も Deskflow からは見えない。

F13/F14 は英数字の範囲外なので、macOS システムホットキー・ghostty・zellij・
Raycast のいずれとも原理的に衝突しない。

## 既知の未解決バグ（upstream）

`OSXScreen::leave()` がカーソルを画面中央に warp せず `m_xCursor`/`m_yCursor` を
更新しないため、baseline が stale になる（deskflow/deskflow#9779、open）。
`MSWindowsScreen::leave()` と `XWindowsScreen::leave()` は両方 warp するので
**macOS サーバーだけの欠陥**。ホットキー切替で発火し、エッジ切替では起きない。

サーバー側でカーソルが動かなくなる症状はこれが原因の可能性がある。修飾キーの
stuck とは独立した問題なので、F13/F14 化しても残るなら upstream 修正が必要。

## 編集時の注意

- **非 ASCII 文字を書かない**。`ConfigReadContext::readLine()` の `isgraph` 検査で
  parse エラーになる。コメントも英語で書くこと
- `#` 以降は行コメントとして除去される
- `switchToScreen()` の画面名は `section: screens` の宣言と一致させる
