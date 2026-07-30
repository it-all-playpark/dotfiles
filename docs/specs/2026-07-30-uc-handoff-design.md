# `uc-handoff` — キー1回でキーボードとポインタを両方隣の Mac へ渡す 設計

- 状態: 実装済み・実機検証待ち
- 対象リポジトリ: `dotfiles`（常駐デーモン）/ `zmk-config-fish`（キーマップ）
- 前提の検証: 2026-07-30 実機で完了（§3）
- PR: it-all-playpark/dotfiles#149（デーモン）/ it-all-playpark/zmk-config-fish#3（キーマップ）
- 残作業: §10 の手作業と §11 の受け入れ確認。加えて `nix build` でのビルド確認（§7.3）

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

`F13`〜`F35` は macOS のシステムホットキー・ghostty・zellij・Raycast のいずれとも
衝突しない（`home-manager/home/file/deskflow/README.md` に既出）。
deskflow 撤去までの併存期間中は、deskflow 側の `keystroke(F13)` /
`keystroke(F14)` と**意味が二重になる**点に注意する（§9）。

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

既存の `home.activation.deskflowServerConfig` と**同じ方式・同じ理由**で、
実体を固定パスへコピーする。

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

## 9. deskflow との併存

新方式が安定するまで deskflow は残す。併存期間中の注意:

- deskflow サーバが `keystroke(F13)` / `keystroke(F14)` をホットキーとして
  掴んでいる。`uc-handoff` の event tap と**どちらが先に食うか**が問題になる
- 併存させるなら、deskflow 側のホットキー 2 行をコメントアウトして
  `uc-handoff` に一本化するのが安全。deskflow 自体は起動したまま残せる
- 撤去は別 PR。cask（`deskflow-dev`）、activation script、`deskflow-server.conf`、
  README をまとめて落とす

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
