# Deskflow server config

Mac 間でキーボード・マウスを共有する Deskflow のサーバ設定 (`deskflow-server.conf`)。
アプリ本体は `darwin/default.nix` の Homebrew cask で導入している。cask は安定版の
`deskflow` ではなく master 追従の **`deskflow-dev`**（→「カーソル固着」の節）。

配置先は `~/.config/deskflow/deskflow-server.conf`。home-manager の symlink ではなく
**activation script (`home.activation.deskflowServerConfig`) による実体コピー**（mode 444）。
理由は「なぜ symlink ではなく実体コピーか」の節。

## 初回セットアップ（手動、1回だけ）

1. Deskflow の GUI → Server タブ → **Use external configuration file** を有効化
2. パスに `~/.config/deskflow/deskflow-server.conf` を指定
3. サーバを再起動

`~/Library/Deskflow/Deskflow.conf` の `[server]` セクションに以下が入れば成功:

```ini
externalConfig=true
externalConfigFile=/Users/<user>/.config/deskflow/deskflow-server.conf
```

**`/nix/store/...` が入っていたら失敗**（→ 次節）。その場合は Deskflow を終了してから
`Deskflow.conf` の `externalConfigFile` 行を上記のパスへ手で書き直す。Deskflow が起動中に
編集すると、終了時の QSettings 書き戻しで消える。

デフォルトの `~/Library/Deskflow/deskflow-server.conf` は書き込み可能なまま残してある。
外部設定を無効に戻しても GUI が書き込みに失敗しない。

## なぜ symlink ではなく実体コピーか

Deskflow の GUI はファイル選択ダイアログで選ばれたパスを**実体解決してから**
`Deskflow.conf` の `externalConfigFile` に記録する。`~/.config/deskflow/deskflow-server.conf`
が home-manager の symlink だと、記録されるのは

```
externalConfigFile=/nix/store/<hash>-hm_deskflowserver.conf
```

という**その時点の世代の store path** になる。この conf を編集すると hash が変わるが
`Deskflow.conf` 側は古い hash を指したままなので、

- Deskflow は**古い世代の conf を読み続ける**（編集が無反応に見える）
- `nix-collect-garbage` 後は**パスごと消えて読めなくなる**

`home.activation.deskflowServerConfig` で実体ファイルとして置けば解決結果が指定パスと
一致するので、この経路が成立しない。activation は `entryAfter [ "linkGeneration" ]`
（`writeBoundary` ではない）— このパスは以前 `home.file` 管理だったため、その撤去処理の
後でないと消される。

## なぜ read-only (mode 444) で平気か

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

## ホットキー切替後にカーソルが固まる件（upstream 修正済み / cask を dev にした理由）

v1.26.0 の `OSXScreen::leave()` はカーソルを画面中央へ warp せず `m_xCursor` /
`m_yCursor` も更新しない。一方 `onMouseMove()` の secondary 側は「今の実座標 −
`m_xCursor`」で移動量を出すため、切替直後の 1 発目が巨大な delta になり
`bogusZoneSize` のフィルタに落ちて捨てられる。さらに v1.26.0 は移動イベントを
`return event` でローカルにも流したうえで毎回カーソルを中央へ warp し続けるので、
**トラックパッドは動いているのにサーバー側のカーソルが中央に貼り付いて動かない**
ように見える。

エッジ切替では warp サイクルが途切れず baseline が同期されたままなので発火しない。
つまり**ホットキー切替に固有の症状**で、F13/F14 化（修飾キー stuck の対策）とは
独立した問題。

upstream では 2 本の PR で解消済み:

| PR | 内容 | merge |
| --- | --- | --- |
| [#9784](https://github.com/deskflow/deskflow/pull/9784) | `leave()` でカーソルを中央へ warp し baseline を同期（[#9779](https://github.com/deskflow/deskflow/issues/9779) の修正） | 2026-06-01 |
| [#9963](https://github.com/deskflow/deskflow/pull/9963) | `leave()` で `CGAssociateMouseAndMouseCursorPosition(false)` によりマウスを capture し、client 制御中は `kCGMouseEventDeltaX/Y` の生 delta を読む。移動イベントはローカルへ流さず消費し、`enter()` で再結合 | 2026-07-18 |

**どちらも v1.26.0（2026-02-16 リリース）には入っていない**。安定版の次リリースを
待つ代わりに、公式 tap の `deskflow-dev`（`continuous` = master ビルドを追う cask）
へ切り替えている。

### 安定版へ戻す場合

`darwin/default.nix` の cask を `deskflow/tap/deskflow` に戻し、apply 前に
`brew uninstall --cask deskflow-dev` を実行する（両 cask は `conflicts_with`）。
逆方向へ切り替えるときも同様に、先に旧 cask を uninstall しておくこと。

### 別件（未修正・低頻度）

`AppUtilUnix::getCurrentLanguageCode()` が `CFArrayGetCount(layoutLanguages) &&
layoutLanguages` と NULL チェックを後置しており SIGSEGV しうる。キーダウン毎に
呼ばれるが実測で数日に 1 回程度。上記のカーソル固着とは別件。

## 編集時の注意

- **非 ASCII 文字を書かない**。`ConfigReadContext::readLine()` の `isgraph` 検査で
  parse エラーになる。コメントも英語で書くこと
- `#` 以降は行コメントとして除去される
- `switchToScreen()` の画面名は `section: screens` の宣言と一致させる
