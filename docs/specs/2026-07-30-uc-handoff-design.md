# `uc-handoff` — キー1回でキーボードとポインタを両方隣の Mac へ渡す 設計

- 状態: 実機検証で設計前提の破綻が判明（§13）。方式を選び直し中
- 対象リポジトリ: `dotfiles`（常駐デーモン）/ `zmk-config-fish`（キーマップ）
- 前提の検証: 2026-07-30 実機で完了（§3）
- PR: it-all-playpark/dotfiles#149（デーモン）/ it-all-playpark/zmk-config-fish#3（キーマップ）
- 残作業: 方式の選び直し（§13.4）。§11 の受け入れ基準 1〜2 は一度も満たされていない

## 1. 目的 / 解決する痛み

Mac Studio と MacBook Pro の間で入力機器を共有するのに deskflow を使っていたが、
**キー転送経路が入力を壊す**。実害として出ているのは 2 つ。

- ZMK combo（`LANG1` / `LANG2` / `CAPS` 出力）が client 側で効かない
- `LCtrl` の長押しが Ctrl の 2 回連続押しとして解釈される

上流にも該当 issue が複数ある（修飾キー stuck 系: deskflow#10013 / #9011 / #9951、
IME 干渉系: #8977 / #9984 / #9992）。いずれも**キーボードを転送していること**に起因する。

一方、キーボードの機体切替は ZMK の BT プロファイル切替で既に完結していて、
そちらは壊れていない。**残る問題はポインタだけ**。

目標は、fish のキー 1 回でキーボードとポインタが同時に相手 Mac へ移ること。
そして、その経路にキーイベントの転送を一切含まないこと。

## 2. スコープ

### 入れるもの

- ZMK マクロ 2 つ（方向つきハンドオフ）
- macOS 常駐デーモン `uc-handoff`（両機に同一のものを配置）
- 固定パス配置 + launchd agent + nix ビルドの一式
- 検証プローブ `scripts/uc-edge-probe.swift` の保全

### 入れないもの（YAGNI）

- deskflow の撤去。新方式が安定するまで併存させ、問題が出たら戻せるようにする
  （**2026-07-31 追記**: 併存を終了し、別 PR で撤去済み。§9）
- ポインタ以外の共有。クリップボードは Universal Clipboard が別途効く
- 3 台目以降への対応。左右 2 台だけを前提にする
- 方向以外の設定項目。`~/.config/uc-handoff/direction` に持つのは左右の別だけで、
  押し込み時間などはコードの定数に置く

### 非目標

- deskflow の不具合を直すこと。上流に投げる話であって、ここで抱えない

## 3. 検証済みの前提

2026-07-30、Mac Studio 実機で実測。

- **合成 CGEvent でも Universal Control のエッジ押し込みは発火する。**
  Mac Studio の左端へ押し込むと MacBook Pro にポインタが出現することを確認した
- 押し込みイベントには **`kCGMouseEventDeltaX` / `kCGMouseEventDeltaY` を明示的に載せる**。
  絶対座標だけの `mouseMoved` では発火しない可能性があるため、載せる前提で設計する
- 実行には **Aqua セッション + アクセシビリティ許可**が要る。
  mosh / ssh 配下（`launchctl managername = Background`）では `AXIsProcessTrusted = false`
  になり、`CGGetActiveDisplayList` も 0 を返して post できない

検証コードは `scripts/uc-edge-probe.swift` として保全する。

## 4. 機体構成

```
  MacBook Pro  ──────  Mac Studio
     (左)                 (右)
  BT profile 0        BT profile 1
```

トラックパッドは Mac Studio に BT 接続したまま動かさない。
Magic Trackpad はリンクキーを 1 ホスト分しか保持しないので、
「トラックパッド自体を付け替える」方向は採らない。

> **2026-08-21 追記**: この前提は誤りだった。Magic デバイスは複数ホストのペアリングを
> 記憶しており、付け替えはソフトだけで完結する。出典と含意は §13.4。

## 5. キーコードの意味づけ

**押した相手ではなく、押された機体から見た方向**で定義する。
これにより、どちらの機体で押しても意味が破綻しない。

| キー | 意味 |
| --- | --- |
| `F13` | ポインタを**左**へ渡せ |
| `F14` | ポインタを**右**へ渡せ |

| 機体 | `F13` | `F14` |
| --- | --- | --- |
| Mac Studio（右） | 左 = MBP へ押し出す | 右に何も無い → **no-op** |
| MacBook Pro（左） | 左に何も無い → **no-op** | 右 = Mac Studio へ押し出す |

反対側のキーを押しても何も起きない。誤爆が自動的に無害になる。

`F13`〜`F35` は英数字の範囲外で、macOS のシステムホットキー・ghostty・zellij・
Raycast のいずれとも原理的に衝突しない。deskflow 時代に同じ理由で `F13` / `F14` を
選んでおり、実運用でも衝突は出ていない。

## 6. ZMK 側（`zmk-config-fish`）

空のままの `macros { }` ノードに 2 つ追加し、`layer_navi` の `F13` / `F14` の
位置をマクロへ差し替える。

```dts
macros {
    handoff_to_mbp: handoff_to_mbp {
        compatible = "zmk,behavior-macro";
        #binding-cells = <0>;
        bindings = <&macro_wait_time 100>, <&kp F13>, <&bt BT_SEL 0>;
    };

    handoff_to_studio: handoff_to_studio {
        compatible = "zmk,behavior-macro";
        #binding-cells = <0>;
        bindings = <&macro_wait_time 100>, <&kp F14>, <&bt BT_SEL 1>;
    };
};
```

**順序が本質**。キーコードを先に送り、待ってから BT プロファイルを切る。
逆にすると、切替後の機体にキーコードが飛んで意図が反転する。

`&kp` はマクロ内で press と release の両方を出す。BT リンクが落ちる前に
HID レポートが届いていればよいので 100ms 待つ。実測で詰められるなら短くしてよい。

`&macro_wait_time` の位置には罠がある。これは**その場で待つバインディングではなく、
以降に処理されるバインディングの `wait_ms` を書き換える状態変更**で、`&kp` の後ろに
置くと `&kp` の release には反映されない。既定は
`CONFIG_ZMK_MACRO_DEFAULT_WAIT_MS = 15`（`CONFIG_ZMK_MACRO_DEFAULT_TAP_MS` は 30）
なので、後ろに置くと待ちは 100ms ではなく 15ms になる。**必ず `&kp` の前に置くこと。**

実行順序そのもの（`&kp` が必ず先）は `wait_ms` の値に関わらず保証されるため、
位置を誤っても「反転」は起きない。壊れるのは待ち時間だけで、それゆえ気づきにくい。

## 7. macOS 側（`dotfiles`）

### 7.1 `uc-handoff` の責務

両機に同一バイナリを置き、方向だけを機体ごとに変える（§7.2）。

1. `CGEventTap` を `.cgSessionEventTap` に `keyDown` と `keyUp` の両方で張る
   （keyUp を食わないとアプリに漏れる。項目 4 の「両方を常に食う」はこの両方を指す）
2. `F13` / `F14` を捕捉し、**イベントを消費する**（`nil` を返してアプリに漏らさない）
3. 自機で有効化されている方向のキーだったら、エッジ押し込みを実行する
4. 有効化されていない方向なら押し込まない。ただし**イベントは同じく消費する**。
   両機で `F13` / `F14` の両方を常に食う、と決めておくことで、
   「片方の機体でだけキーがアプリに漏れる」という非対称を作らない

押し込みルーチンは検証済みのものをそのまま使う。本番の押し込み時間は
検証時の 2500ms も要らないので 500ms 程度から始め、実測で詰める。

### 7.2 方向の指定

両機に同じ nix 世代が適用されるため、機体ごとの差分を nix 側では表現できない。
既存の `hermes-watchdog` が使っているマーカーファイル方式に倣い、
実行時にファイルから読む。

    ~/.config/uc-handoff/direction

中身は `left` か `right` の 1 行。この機体から見て**隣の Mac がいる側**を書く。

| 機体 | 中身 |
| --- | --- |
| Mac Studio（右） | `left` |
| MacBook Pro（左） | `right` |

ファイルが無い、または解釈できない場合は、その旨をログに出して
**常駐せずに exit 0**（`hermes-watchdog` の marker skip と同じ扱い）。
設定を書き忘れた機体で黙って動き続けるより、起動しないほうが分かりやすい。

### 7.3 配置 — TCC のためのパス固定

**アクセシビリティ許可はバイナリのパスに紐づく。**
nix store のパスに置くと `nix run .#update` のたびに store hash が変わり、
許可が毎回切れる。symlink も駄目で、TCC は実体解決した store パスを記録する。

そこで実体を固定パスへコピーする（deskflow のサーバ設定を
`home.activation.deskflowServerConfig` で置いていたのと同じ方式・同じ理由。
そちらは deskflow 撤去に伴い削除済み）。

```nix
activation.ucHandoffBinary = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  ucHandoff="${config.home.homeDirectory}/.local/bin/uc-handoff"
  $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$ucHandoff"
  $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 555 \
    ${ucHandoffPkg}/bin/uc-handoff "$ucHandoff"
'';
```

launchd agent はこの固定パスを指す。バイナリの中身が変わっても
パスが同じなので、TCC の許可は生き続ける。

> 署名が変わると TCC が無効化される可能性は残る。ad-hoc 署名で
> 毎回 hash が変わるなら、初回セットアップ手順に「許可し直し」を明記する。
> ここは実装時に実測して判断する（§10）。
>
> `-framework ApplicationServices` のリンクが失敗しても
> `buildInputs = [ pkgs.darwin.apple_sdk.frameworks.ApplicationServices ]` を足さないこと。
> pin している nixpkgs (2026-07-26) では Apple SDK が darwin stdenv の既定 sysroot に
> 入っており `apple_sdk.frameworks.*` は撤去済みで、足すと eval が落ちる。

### 7.4 常駐

`launchd.agents.uc-handoff` で `KeepAlive = true` / `RunAtLoad = true`。
Aqua セッションで動く必要があるので user agent であること（daemon ではない）。

## 8. 失敗モード

| 事象 | 挙動 |
| --- | --- |
| Universal Control 未接続 / MBP スリープ | 押し込みが空振り。キーボードだけ切り替わる |
| アクセシビリティ未許可 | 押し込み不発。ログに出す |
| 反対方向のキーを押した | no-op |
| デーモンが落ちている | `F13` / `F14` が素通りするだけ |
| Universal Control が途中で切れる | ポインタが移らない。手でエッジに押し込めば復帰 |

表のうち押し込みが空振りしたケースでは、ポインタは画面端に置き去りになる。
「動かない」のではなく「端まで飛んだまま戻らない」のが実際の見え方で、
トラックパッドを動かせばそのまま復帰する。

**すべて「ポインタが移らない」で止まる。**
deskflow のようにキー入力そのものが壊れる経路が存在しない、というのが
この設計の一番の狙い。

## 9. deskflow の撤去（2026-07-31 完了）

当初は新方式が安定するまで deskflow を併存させる計画だったが、`uc-handoff` に
一本化できたため撤去した。落としたもの:

- Homebrew cask `deskflow/tap/deskflow-dev` と tap `deskflow/tap`
  （tap 単位の `trusted = true` も不要になった）
- `home.activation.deskflowServerConfig`
- `home-manager/home/file/deskflow/`（`deskflow-server.conf` と README）

`~/.config/deskflow/` と `~/Library/Deskflow/` は home-manager 管理外のため
apply では消えない。不要なら手で削除する。

これで `F13` / `F14` を掴むのは `uc-handoff` の event tap だけになり、
併存期間に懸念していたホットキーの二重解釈は起こらない。

## 10. 手作業として残るもの

初回 1 回だけ、各機で:

- `~/.config/uc-handoff/direction` に方向を書く（Mac Studio は `left`、MacBook Pro は `right`）。
  無いと常駐せず exit 0 する
- `~/.local/bin/uc-handoff` にアクセシビリティ許可
- Universal Control を有効化し、「ディスプレイの端を越えてカーソルを移動して
  近くの Mac に接続」を ON
- 両機が同一 Apple ID + 2FA、同一 Wi-Fi であること

`nix run .#update` は `sudo darwin-rebuild` を呼ぶため agent からは実行しない。
apply は人間が行う。

## 11. 受け入れ基準

1. Mac Studio で該当キーを押すと、キーボードが MBP に移り、
   ポインタも MBP に移る（1 アクション）
2. MBP で反対キーを押すと、両方 Mac Studio に戻る
3. 反対方向のキーを押しても何も起きない
4. `F13` / `F14` がアプリに漏れない
5. `nix run .#update` を実行してもアクセシビリティ許可が切れない
6. デーモンを止めても、キーボードの BT 切替だけは従来どおり動く

## 12. 未解決 / 実装時に決めること

- ~~nix で Swift をビルドする derivation の形~~ → **決着**。実装言語は C にした。
  `CGEventTap` / `CGEventPost` はもともと C API であり、nixpkgs の Swift が
  aarch64-darwin で通るかを実測できなかった（`nix eval` がサンドボックスで
  塞がれていた）ため、darwin stdenv + clang の確実な側に倒した。
  検証プローブ `scripts/uc-edge-probe.swift` は診断用に Swift のまま残す。
- 押し込み時間の実測チューニング（500ms 起点）
- ad-hoc 署名の cdhash 変動で TCC が切れる条件の実測（§7.3）。
  TCC は未署名 / ad-hoc バイナリを path + cdhash で記録する。nix の darwin fixup が打つ
  ad-hoc 署名の cdhash はバイナリ内容の関数であって store path に依存しない。したがって
  期待値は「切れるか切れないか」ではなく **ソースを変えたときだけ切れる**:
  - `uc-handoff.c` を変えずに `nix run .#update` → cdhash 不変 → 許可は生き残るはず
  - `uc-handoff.c` を変えて再ビルド → cdhash 変化 → 許可し直しが要る
  受け入れ基準 5 はこの前提で判定する。前者で切れたなら clang の出力が非決定的という
  ことなので、そのとき初めて `codesign` の扱いを考える
- `macro_wait_time` を 100ms から詰められるか

## 13. 実機検証の結果（2026-08-21）

§11 の受け入れ基準 1〜2 は**一度も満たされたことがなかった**。両機で常駐が始まったのが
2026-08-21 で、そこで初めて設計前提の破綻が表面化した。

### 13.1 なぜ検証されていなかったか

- **Mac Studio**: アクセシビリティ許可が TCC で拒否されたままだった
  (`auth_value=0` / `auth_reason=4` / `last_modified 2026-07-31 05:34:58`)。
  launchd から起動されたプロセスには責任アプリがいないため自前の許可が要る。
  `~/.local/state/uc-handoff.err.log` は 2026-07-31 から 2026-08-21 まで
  28,552 行すべてが権限エラーで、成功ログは 1 行も無い
- **MacBook Pro**: `home.activation.setupHermes` の素の `exit 0` が後続の
  `setupLaunchAgents` と `ucHandoffBinary` を丸ごと飛ばしていたため、plist も
  バイナリも生成されていなかった（dotfiles#166 で修正。回帰テストは
  `tests/hm-activation-exit.test.sh`）
- §3 の「2026-07-30 実機で実測」はターミナルからの手動起動で、責任プロセスである
  ターミナルの許可で通っていた。launchd 経由の常駐とは別物だった

### 13.2 設計前提の破綻

トラックパッドが Mac Studio 固定である以上、Universal Control のポインタ所有者は
常に Mac Studio で、MacBook 上のポインタは貸出状態にすぎない。そこへ §6 の BT
プロファイル切替が加わると、**キーボードだけが所有者機から離れる**。

実測（2026-08-21、両機常駐後。ポインタはトラックパッドで手動移動、押し込みは不使用）:

| キーボードの BT profile | 打鍵後のポインタ |
| --- | --- |
| 1 (Studio) のまま | MacBook に留まる |
| 0 (MacBook) へ切替 | **Studio へ回収される** |

差分は `&bt BT_SEL 0` だけで、合成押し込み (`uc_push`) は無関係だった。
Universal Control は貸出先がローカル打鍵を受けた時点で貸出を打ち切る。
§8 の失敗モード表に無い挙動。

### 13.3 代替案（キーボード転送を UC に任せる）も不成立

BT 切替をやめて UC にキーボード転送を任せると、ポインタは留まる。§1 が deskflow で
問題視した入力破壊（ZMK combo の `LANG1`/`LANG2`/`CAPS`、`LCtrl` 長押し、IME 変換）は
UC 転送では**すべて再現しなかった**。あれは deskflow の転送経路固有の不具合だった。

しかし別の破綻がある。Studio 側でクリックして作業してから MacBook へポインタを戻すと、
MacBook の first responder が復帰せず**クリックしないと入力を継続できない**。
`tell application "X" to activate` でも復帰しない（実測）。UC のポインタ回収や
フォーカス挙動を抑制する `defaults` キーも見つからなかった
（`com.apple.universalcontrol` にあるのは `Disable` と `DisableMagicEdges` のみ）。

ポインタが離れただけ（Studio でクリックしない）なら継続打鍵は可能。壊すのは
「Studio で実際に操作すること」で、これは最も頻度の高い動線にあたる。

### 13.4 §4 の前提が誤りだった

§4 の「Magic Trackpad はリンクキーを 1 ホスト分しか保持しない」は事実ではない。
`MegaManSec/magic-switch` の README 原文:

> Apple's Magic devices remember multiple hosts but only connect to one at a time;
> Magic Switch flips which Mac currently holds a peripheral, but it doesn't create
> those pairings for you.

事前に各機へ 1 回ペアリングしておけば、以後の切替はソフトのみで完結する
（"you won't re-pair by hand on every switch — Magic Switch handles the handoff"）。
したがって「トラックパッド自体を付け替える」方向は**採れる**。その場合、
キーボードは ZMK の BT 切替、ポインタは magic-switch となり、両方が各機に実ローカル
HID として繋がるため **Universal Control も uc-handoff も不要になる**。

未解決のリスクは magic-switch の issue #109（切替時に受け側 Mac で macOS の
Connection Request ダイアログが出る。トラックパッド固有で、v2.25.7 時点で open）。
アプリ自身のペアリング経路は `devicePairingUserConfirmationRequest` が
`replyUserConfirmation(initiated)` で自動承認しておりダイアログを出さない設計なので、
これは bluetoothd の別経路によるもの。発生条件は未文書で、作者と報告者で症状も
食い違っている（作者「出ても動く」／報告者「押さないと lost する」）。
抑制手段は無い（作者いわく自動押下は "it's not possible"）。

ただし構成上、完全なロックアウトは起こらない。受け側が MacBook なら内蔵トラック
パッドで押せる。受け側が Studio でも、ZMK キーボードは `&bt BT_SEL` で既に Studio へ
繋がっているためキーボードで消せる可能性があり、駄目でも MacBook 側から
`magicswitch://switch?peripheral=trackpad&direction=take` で取り戻せる。

### 13.5 実機で確かめた bond の実態（2026-08-21）

`blueutil` (nixpkgs 2.13.0) で実測した。対象はトラックパッド `a0-78-17-e5-50-10`。

**bond は確かに両機に同居する。** MacBook へ USB-C ケーブルでペアリングした直後の
`--paired`:

| 機体 | 状態 |
| --- | --- |
| Mac Studio | `paired`, **not connected** |
| MacBook Pro | `paired`, **connected (master)** |

§4 の「リンクキーを 1 ホスト分しか保持しない」はこれで反証された。

**しかし記録の同居と、ソフトによる切替可能性は別だった。** 非所有側の Mac Studio から
平文の bonded connect を撃つと、20 秒かけて失敗する。

    $ blueutil --connect a0-78-17-e5-50-10
    Failed to connect "a0-78-17-e5-50-10"
    ... 20.257 total

`--unpair` → `--pair` → `--connect` による手動での張り直しも失敗した。
**blueutil だけでは切替を実現できない。**

これは magic-switch がソースのコメントで名前を付けている状態そのものだった。

> A record that says `paired=true` while the device refuses the bonded connect is the
> stale-bond signature: the device actually answers to the other Mac.

magic-switch (`BluetoothPeripheralStore.swift`) はこの復旧を実装している。

1. bonded な `openConnection()` の失敗を検出
2. `rssi() != invalidRSSI` で圏内を確認（#103 / #113 の RSSI probe。20 秒ストールの回避）
3. `btDevice.perform(Selector(("remove")))` でローカルのペアリング記録を削除
4. settle 待ちののち `startDevicePair(...)` で再ペアリング
5. 確認要求は `devicePairingUserConfirmationRequest` が `replyUserConfirmation(true)` で自動承認

blueutil には 2〜5 が無い。`--pair` は PIN しか渡せず、確認要求を自動承認する仕組みを持たない。

**したがって README の「remember multiple hosts」は記録が共存するところまでで、
切替には再ペアリングのハンドシェイクが要る。それを無人で行うことが
magic-switch の実体的な価値である。**「単純だから blueutil + ssh で足りる」という
見立ては、この復旧経路を見落としていた。

補足として、`blueutil` の以下も実測・一次情報で確認した。

- classic IOBluetooth の列挙は TCC で保護されていない。Terminal.app は
  `kTCCServiceBluetoothAlways` の許可を持たないまま `--paired` が通る
  （TCC の Bluetooth は CoreBluetooth/BLE 向け）。launchd 文脈でも権限の壁は無い見込み
- ただし ssh 越しでは `--paired` / `--connected` / `--disconnect` が機能しない
  （blueutil issue #85）。§3 が記録した「ssh 配下は Aqua セッション外」と同種。
  受け側での実行は GUI セッション内の launchd user agent などに寄せる必要がある

**運用上の退避路**: USB-C ケーブルでの接続は BT の状態に関わらず必ずペアリングされる。
切替に失敗して詰んだときはケーブルで戻す。

### 13.6 残る採否判断

採否は magic-switch の実機検証で決める。観測項目は (1) 10 往復でのダイアログ発生頻度、
(2) 出た場合に押さずともトラックパッドが動くか、(3) Full Keyboard Access 有効時に
Return / Space で消せるか。

### 13.7 出典

- https://github.com/MegaManSec/magic-switch （README・ソース・issues。
  2026-08-21 時点で archived=false、最終 push 2026-08-20、最新 v2.25.7）
- https://github.com/MegaManSec/magic-switch/issues/109 （Connection Request ダイアログ）
- https://github.com/MegaManSec/magic-switch/issues/110 （本文に
  "Found while looking into #109; independent of it." と明記。#109 の修正ではない）
- 同名の商用製品 `www.magic-switch.com` とは無関係。取得元を間違えないこと
- https://github.com/toy/blueutil （2.13.0。`--unpair` と `--wait-*` は EXPERIMENTAL）
- https://github.com/toy/blueutil/issues/85 （ssh 越しで `--paired` / `--connected` /
  `--disconnect` が機能しない）
