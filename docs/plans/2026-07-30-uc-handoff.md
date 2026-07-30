# `uc-handoff` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** fish のキー 1 回で、キーボード（ZMK の BT プロファイル切替）とポインタ（Universal Control のエッジ押し込み）を同時に隣の Mac へ渡せるようにする。

**Architecture:** macOS 常駐デーモン `uc-handoff` が `CGEventTap` で `F13` / `F14` を捕捉して消費し、自機に設定された方向へ合成 `CGEvent` でポインタを押し出す。Universal Control がそれを拾って隣の Mac へポインタを移す。キーボード側は ZMK マクロが同じキーを送ってから BT プロファイルを切り替える。キーイベントの機体間転送は一切行わない。

**Tech Stack:** C（`ApplicationServices` / `CoreGraphics` / `libdispatch`）、nix（`stdenv.mkDerivation` + home-manager activation + `launchd.agents`）、ZMK（`zmk,behavior-macro`）

> **実装言語について。** spec は Swift と書いていたが C に変えた。`CGEventTap` /
> `CGEventPost` はもともと C API で Swift の利点が無く、nixpkgs の Swift が
> aarch64-darwin で通るかをこの環境では実測できなかった（nix daemon の socket が
> サンドボックスで塞がれていた）。このリポジトリにコンパイル済み成果物の前例が
> 無いことも踏まえ、darwin stdenv + clang の確実な側に倒している。
> 検証プローブ `scripts/uc-edge-probe.swift` は診断用に Swift のまま残す。

> **Task 1 / Task 2 の C は検証済み。** この計画に載せたコードをそのまま
> `cc -O2 -Wall -Wextra -Werror -framework ApplicationServices` でビルドし、
> 警告ゼロ・`--self-test` 全通過・方向未設定で exit 0・権限なしで exit 1 を
> 2026-07-30 に確認している。写経して動かなければ写し間違いを疑うこと。

## Global Constraints

- 対象は `aarch64-darwin` のみ。Intel Mac は対象外
- 機体配置と BT プロファイル: MacBook Pro = 左 = `BT_SEL 0` / Mac Studio = 右 = `BT_SEL 1`
- キーコードの意味: `F13` = ポインタを左へ渡せ / `F14` = ポインタを右へ渡せ
- macOS 仮想キーコード: `F13` = `105`、`F14` = `107`
- **TCC はバイナリのパスに紐づく。** バイナリは nix store ではなく `~/.local/bin/uc-handoff` に**実体コピー**する。symlink 不可（TCC が実体解決して store パスを記録するため）
- 両 Mac は同一ユーザー名で**同じ home-manager 世代**を適用する。機体ごとの差分を nix の引数で表現してはいけない
- `nix run .#update` は内部で `sudo darwin-rebuild` を呼ぶため **agent は実行しない**。検証範囲は `nix fmt` / `nix flake check` / `nix eval` まで。apply は人間
- 保護ブランチへの直接 push 禁止。feature branch + PR。
  既定ブランチは repo ごとに違う（`dotfiles` は `main`、`zmk-config-fish` は `master`）
- treefmt の対象は nix / python / lua / shell / json。C と Markdown は対象外なので手で整える
- deskflow の撤去はこの計画に含まない

## File Structure

### `dotfiles`

| ファイル | 責務 |
| --- | --- |
| `home-manager/home/file/uc-handoff/uc-handoff.c` | デーモン本体。純粋関数（方向判定・押し込み計画）と、副作用の殻（event tap・CGEvent post）を 1 ファイル内で分離する |
| `home-manager/programs/uc-handoff.nix` | derivation・固定パスへの実体コピー・launchd agent |
| `home-manager/programs/default.nix` | 上記の import を追加（変更） |
| `tests/uc-handoff.test.sh` | `uc-handoff --self-test` を叩くシェルテスト |
| `docs/specs/2026-07-30-uc-handoff-design.md` | §7.2 を引数方式からマーカーファイル方式へ修正（変更） |

C を 1 ファイルに収めるのは、純粋関数と殻の境界がファイル内で完結する規模（300 行未満）だから。分割するとビルド定義のほうが複雑になる。

### `zmk-config-fish`

| ファイル | 責務 |
| --- | --- |
| `config/boards/shields/fish/fish.keymap` | `macros` にハンドオフマクロ 2 つ、`layer_navi` の `F13` / `F14` を差し替え（変更） |

---

### Task 1: 純粋関数と `--self-test`

方向の解釈と押し込み計画を、GUI もイベントタップも要らない純粋関数として先に固める。ここが固まっていれば、残りは薄い殻になる。

**Files:**
- Create: `home-manager/home/file/uc-handoff/uc-handoff.c`
- Create: `tests/uc-handoff.test.sh`
- Modify: `docs/specs/2026-07-30-uc-handoff-design.md`（§7.2）

**Interfaces:**
- Consumes: なし
- Produces:
  - `typedef enum { DIR_NONE = 0, DIR_LEFT = 1, DIR_RIGHT = 2 } uc_direction_t;`
  - `uc_direction_t uc_parse_direction(const char *s);`
  - `uc_direction_t uc_direction_for_keycode(int64_t keycode);`
  - `typedef struct { CGPoint start; CGPoint step; } uc_push_plan_t;`
  - `uc_push_plan_t uc_plan_push(CGRect bounds, uc_direction_t dir, double delta);`
  - CLI: `uc-handoff --self-test` が全 assert 通過で exit 0、失敗で exit 1

- [ ] **Step 1: 失敗するテストを書く**

`tests/uc-handoff.test.sh`:

```bash
#!/usr/bin/env bash
# uc-handoff の純粋関数を --self-test 経由で検証する。
# GUI もアクセシビリティ権限も不要。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/home-manager/home/file/uc-handoff/uc-handoff.c"
BIN="$(mktemp -d)/uc-handoff"

trap 'rm -rf "$(dirname "$BIN")"' EXIT

cc -O2 -Wall -Wextra -Werror \
  -framework ApplicationServices \
  -o "$BIN" "$SRC"

if "$BIN" --self-test; then
  echo "PASS: uc-handoff --self-test"
else
  echo "FAIL: uc-handoff --self-test" >&2
  exit 1
fi
```

- [ ] **Step 2: テストを実行して失敗を確認**

```bash
chmod +x tests/uc-handoff.test.sh
./tests/uc-handoff.test.sh
```

期待: `cc` が `home-manager/home/file/uc-handoff/uc-handoff.c` を開けず
`No such file or directory` で落ちる。

- [ ] **Step 3: 純粋関数と self-test を実装する**

`home-manager/home/file/uc-handoff/uc-handoff.c`:

```c
// uc-handoff — F13/F14 を捕捉して Universal Control のエッジ押し込みを合成する。
//
//   uc-handoff --self-test   純粋関数の自己テスト（GUI 不要）
//   uc-handoff               常駐。方向は ~/.config/uc-handoff/direction から読む
//
// 方向は「この機体から見てどちら側に隣の Mac がいるか」。
// Mac Studio は right 配置なので direction=left、MacBook Pro は direction=right。

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// macOS 仮想キーコード
#define UC_KEY_F13 105
#define UC_KEY_F14 107

typedef enum { DIR_NONE = 0, DIR_LEFT = 1, DIR_RIGHT = 2 } uc_direction_t;

typedef struct {
  CGPoint start; // 押し込みを始める点（エッジのわずかに内側）
  CGPoint step;  // 1 イベントあたりの移動量
} uc_push_plan_t;

// "left" / "right" を方向に変換する。前後の空白と改行は無視する。
uc_direction_t uc_parse_direction(const char *s) {
  if (s == NULL) {
    return DIR_NONE;
  }
  while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') {
    s++;
  }
  size_t n = strlen(s);
  while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\n' ||
                   s[n - 1] == '\r')) {
    n--;
  }
  if (n == 4 && strncmp(s, "left", 4) == 0) {
    return DIR_LEFT;
  }
  if (n == 5 && strncmp(s, "right", 5) == 0) {
    return DIR_RIGHT;
  }
  return DIR_NONE;
}

// キーコードが要求している方向。F13 = 左へ、F14 = 右へ。
uc_direction_t uc_direction_for_keycode(int64_t keycode) {
  if (keycode == UC_KEY_F13) {
    return DIR_LEFT;
  }
  if (keycode == UC_KEY_F14) {
    return DIR_RIGHT;
  }
  return DIR_NONE;
}

// 全ディスプレイの外接矩形と方向から、押し込みの始点と 1 歩の量を決める。
// 始点はエッジの 2px 内側。そこから外向きに step を足していく。
uc_push_plan_t uc_plan_push(CGRect bounds, uc_direction_t dir, double delta) {
  const double inset = 2.0;
  uc_push_plan_t p;
  p.start = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
  p.step = CGPointMake(0, 0);

  if (dir == DIR_LEFT) {
    p.start = CGPointMake(CGRectGetMinX(bounds) + inset, CGRectGetMidY(bounds));
    p.step = CGPointMake(-delta, 0);
  } else if (dir == DIR_RIGHT) {
    p.start = CGPointMake(CGRectGetMaxX(bounds) - inset, CGRectGetMidY(bounds));
    p.step = CGPointMake(delta, 0);
  }
  return p;
}

// --- self-test -------------------------------------------------------------

static int uc_failures = 0;

static void uc_check(bool ok, const char *what) {
  if (!ok) {
    fprintf(stderr, "  FAIL: %s\n", what);
    uc_failures++;
  }
}

static int uc_self_test(void) {
  uc_check(uc_parse_direction("left") == DIR_LEFT, "parse left");
  uc_check(uc_parse_direction("right") == DIR_RIGHT, "parse right");
  uc_check(uc_parse_direction("left\n") == DIR_LEFT, "parse trailing newline");
  uc_check(uc_parse_direction("  right  ") == DIR_RIGHT, "parse surrounding space");
  uc_check(uc_parse_direction("") == DIR_NONE, "parse empty");
  uc_check(uc_parse_direction(NULL) == DIR_NONE, "parse NULL");
  uc_check(uc_parse_direction("up") == DIR_NONE, "parse unknown");
  uc_check(uc_parse_direction("lefty") == DIR_NONE, "parse prefix is not a match");

  uc_check(uc_direction_for_keycode(UC_KEY_F13) == DIR_LEFT, "F13 means left");
  uc_check(uc_direction_for_keycode(UC_KEY_F14) == DIR_RIGHT, "F14 means right");
  uc_check(uc_direction_for_keycode(0) == DIR_NONE, "other keycode is ignored");
  uc_check(uc_direction_for_keycode(106) == DIR_NONE, "F16 is ignored");

  CGRect b = CGRectMake(0, 0, 1920, 1080);

  uc_push_plan_t l = uc_plan_push(b, DIR_LEFT, 8.0);
  uc_check(l.start.x == 2.0, "left push starts 2px inside the left edge");
  uc_check(l.start.y == 540.0, "left push starts at vertical center");
  uc_check(l.step.x == -8.0, "left push steps outward");
  uc_check(l.step.y == 0.0, "left push does not drift vertically");

  uc_push_plan_t r = uc_plan_push(b, DIR_RIGHT, 8.0);
  uc_check(r.start.x == 1918.0, "right push starts 2px inside the right edge");
  uc_check(r.step.x == 8.0, "right push steps outward");

  // 原点が 0 でないマルチディスプレイ構成でも成り立つこと
  CGRect off = CGRectMake(-1440, -100, 1440, 900);
  uc_push_plan_t lo = uc_plan_push(off, DIR_LEFT, 8.0);
  uc_check(lo.start.x == -1438.0, "left push respects a negative origin");

  uc_push_plan_t n = uc_plan_push(b, DIR_NONE, 8.0);
  uc_check(n.step.x == 0.0 && n.step.y == 0.0, "DIR_NONE produces no movement");

  if (uc_failures == 0) {
    printf("uc-handoff self-test: all checks passed\n");
    return 0;
  }
  fprintf(stderr, "uc-handoff self-test: %d check(s) failed\n", uc_failures);
  return 1;
}

int main(int argc, const char *argv[]) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--self-test") == 0) {
      return uc_self_test();
    }
  }
  fprintf(stderr, "uc-handoff: not implemented yet\n");
  return 2;
}
```

- [ ] **Step 4: テストを実行して通ることを確認**

```bash
./tests/uc-handoff.test.sh
```

期待: `uc-handoff self-test: all checks passed` と `PASS: uc-handoff --self-test`。

- [ ] **Step 5: spec §7.2 を実装可能な形に直す**

`docs/specs/2026-07-30-uc-handoff-design.md` の §7.2 を、次の内容で置き換える。
理由は「両 Mac が同一ユーザー名で同じ home-manager 世代を適用するため、
launchd の引数を機体ごとに変えられない」こと。

```markdown
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
```

- [ ] **Step 6: spec §12 から Swift 前提の項目を落とす**

`docs/specs/2026-07-30-uc-handoff-design.md` §12 の

```markdown
- nix で Swift をビルドする derivation の形（`swiftPackages` を使うか、
  `stdenv.mkDerivation` で `swiftc` を直接叩くか）
```

を次で置き換える。

```markdown
- ~~nix で Swift をビルドする derivation の形~~ → **決着**。実装言語は C にした。
  `CGEventTap` / `CGEventPost` はもともと C API であり、nixpkgs の Swift が
  aarch64-darwin で通るかを実測できなかった（`nix eval` がサンドボックスで
  塞がれていた）ため、darwin stdenv + clang の確実な側に倒した。
  検証プローブ `scripts/uc-edge-probe.swift` は診断用に Swift のまま残す。
```

- [ ] **Step 7: コミット**

```bash
git add home-manager/home/file/uc-handoff/uc-handoff.c \
        tests/uc-handoff.test.sh \
        docs/specs/2026-07-30-uc-handoff-design.md
git commit -m "feat(uc-handoff): 🎸 方向判定と押し込み計画の純粋関数を追加"
```

---

### Task 2: イベントタップと押し込みの実装

純粋関数の上に副作用の殻を載せる。ここから先は GUI とアクセシビリティ権限が要るので、自動テストではなく手動確認で閉じる。

**Files:**
- Modify: `home-manager/home/file/uc-handoff/uc-handoff.c`

**Interfaces:**
- Consumes: Task 1 の `uc_parse_direction` / `uc_direction_for_keycode` / `uc_plan_push` / `uc_direction_t` / `uc_push_plan_t`
- Produces: 引数なしで起動すると常駐し、`F13` / `F14` を消費して押し込むバイナリ

- [ ] **Step 1: 押し込みと event tap を実装する**

`uc-handoff.c` の `#include` の直後に追加:

```c
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <unistd.h>
```

`// --- self-test` の**直前**に、以下を挿入する:

```c
// --- 副作用の殻 -------------------------------------------------------------

#define UC_PUSH_FRAMES 60      // 120Hz で約 500ms
#define UC_PUSH_INTERVAL_US 8333
#define UC_PUSH_DELTA 8.0

static uc_direction_t g_neighbor = DIR_NONE;
static CFMachPortRef g_tap = NULL;

// 全アクティブディスプレイの外接矩形
static CGRect uc_union_bounds(void) {
  CGDirectDisplayID ids[16];
  uint32_t n = 0;
  if (CGGetActiveDisplayList(16, ids, &n) != kCGErrorSuccess || n == 0) {
    return CGRectNull;
  }
  CGRect u = CGDisplayBounds(ids[0]);
  for (uint32_t i = 1; i < n; i++) {
    u = CGRectUnion(u, CGDisplayBounds(ids[i]));
  }
  return u;
}

// エッジ検出は絶対座標ではなく delta を見ているため、必ず delta を載せる。
static void uc_post_move(CGEventSourceRef src, CGPoint p, double dx, double dy) {
  CGEventRef e = CGEventCreateMouseEvent(src, kCGEventMouseMoved, p, kCGMouseButtonLeft);
  if (e == NULL) {
    return;
  }
  CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, (int64_t)dx);
  CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, (int64_t)dy);
  CGEventPost(kCGHIDEventTap, e);
  CFRelease(e);
}

static void uc_push(uc_direction_t dir) {
  CGRect u = uc_union_bounds();
  if (CGRectIsNull(u)) {
    fprintf(stderr, "uc-handoff: no active display, skipping push\n");
    return;
  }
  uc_push_plan_t plan = uc_plan_push(u, dir, UC_PUSH_DELTA);
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

  uc_post_move(src, plan.start, 0, 0);
  usleep(120000);

  CGPoint t = plan.start;
  for (int i = 0; i < UC_PUSH_FRAMES; i++) {
    t.x += plan.step.x;
    t.y += plan.step.y;
    uc_post_move(src, t, plan.step.x, plan.step.y);
    usleep(UC_PUSH_INTERVAL_US);
  }

  if (src != NULL) {
    CFRelease(src);
  }
}

static CGEventRef uc_tap_callback(CGEventTapProxy proxy, CGEventType type,
                                  CGEventRef event, void *ctx) {
  (void)proxy;
  (void)ctx;

  // タップが無効化されたら黙って戻さず、必ず再有効化する
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    if (g_tap != NULL) {
      CGEventTapEnable(g_tap, true);
    }
    return event;
  }

  if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
    return event;
  }

  int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  uc_direction_t requested = uc_direction_for_keycode(kc);
  if (requested == DIR_NONE) {
    return event;
  }

  // 自機に隣がいる向きの keyDown のときだけ押し込む。
  // タップのコールバックを塞ぐと macOS にタップごと切られるので、必ず別キューへ逃がす。
  if (type == kCGEventKeyDown && requested == g_neighbor) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      uc_push(requested);
    });
  }

  // F13/F14 は down/up ともに常に消費する。押し込む向きかどうかで
  // 消費の有無を変えると、機体によってキーが漏れる非対称ができる。
  return NULL;
}

// ~/.config/uc-handoff/direction を読む
static uc_direction_t uc_read_direction(void) {
  const char *home = getenv("HOME");
  if (home == NULL) {
    return DIR_NONE;
  }
  char path[1024];
  snprintf(path, sizeof(path), "%s/.config/uc-handoff/direction", home);
  FILE *f = fopen(path, "r");
  if (f == NULL) {
    fprintf(stderr, "uc-handoff: %s not found\n", path);
    return DIR_NONE;
  }
  char buf[64] = {0};
  if (fgets(buf, sizeof(buf), f) == NULL) {
    buf[0] = '\0';
  }
  fclose(f);
  return uc_parse_direction(buf);
}

static int uc_run(void) {
  g_neighbor = uc_read_direction();
  if (g_neighbor == DIR_NONE) {
    fprintf(stderr,
            "uc-handoff: direction is unset or invalid; "
            "write \"left\" or \"right\" to ~/.config/uc-handoff/direction. "
            "not starting.\n");
    return 0;
  }

  if (!AXIsProcessTrusted()) {
    fprintf(stderr,
            "uc-handoff: accessibility permission is missing. "
            "grant it to ~/.local/bin/uc-handoff in "
            "System Settings > Privacy & Security > Accessibility.\n");
    return 1;
  }

  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
  g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                           kCGEventTapOptionDefault, mask, uc_tap_callback, NULL);
  if (g_tap == NULL) {
    fprintf(stderr, "uc-handoff: failed to create the event tap\n");
    return 1;
  }

  CFRunLoopSourceRef rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_tap, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopCommonModes);
  CGEventTapEnable(g_tap, true);

  fprintf(stderr, "uc-handoff: watching F13/F14, neighbor is on the %s\n",
          g_neighbor == DIR_LEFT ? "left" : "right");

  CFRunLoopRun();
  return 0;
}
```

- [ ] **Step 2: `main` を差し替える**

`main` の `fprintf(stderr, "uc-handoff: not implemented yet\n"); return 2;` を
`return uc_run();` に置き換える。

```c
int main(int argc, const char *argv[]) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--self-test") == 0) {
      return uc_self_test();
    }
  }
  return uc_run();
}
```

- [ ] **Step 3: self-test が壊れていないことを確認**

```bash
./tests/uc-handoff.test.sh
```

期待: 変わらず PASS。純粋関数には触っていないので、ここが落ちたら殻が純粋関数を壊している。

- [ ] **Step 4: 方向未設定で常駐しないことを確認**

```bash
cc -O2 -Wall -Wextra -Werror -framework ApplicationServices \
  -o /tmp/uc-handoff home-manager/home/file/uc-handoff/uc-handoff.c
HOME=/nonexistent /tmp/uc-handoff; echo "exit=$?"
```

期待: `direction is unset or invalid` を出して `exit=0`。常駐しない。

- [ ] **Step 5: 手動で押し込みを確認**

**Mac Studio 実機の ghostty（zellij の外）で**実行すること。mosh / ssh 配下では
`AXIsProcessTrusted` が false になり動かない。

```bash
mkdir -p ~/.config/uc-handoff
echo left > ~/.config/uc-handoff/direction
cc -O2 -Wall -Wextra -Werror -framework ApplicationServices \
  -o /tmp/uc-handoff home-manager/home/file/uc-handoff/uc-handoff.c
/tmp/uc-handoff
```

初回は `/tmp/uc-handoff` にアクセシビリティ許可が要る。許可して再実行する。
`watching F13/F14, neighbor is on the left` が出たら、キーボードから `F13` を送る。

期待:
- MacBook Pro にポインタが移動する
- `F13` が手前のアプリに漏れない
- `F14` を押しても何も起きない（Mac Studio の右には何もいない）

- [ ] **Step 6: コミット**

```bash
git add home-manager/home/file/uc-handoff/uc-handoff.c
git commit -m "feat(uc-handoff): 🎸 F13/F14 を消費してエッジ押し込みを合成する"
```

---

### Task 3: nix ビルド・固定パス配置・launchd agent

**Files:**
- Create: `home-manager/programs/uc-handoff.nix`
- Modify: `home-manager/programs/default.nix`

**Interfaces:**
- Consumes: Task 2 完成後の `home-manager/home/file/uc-handoff/uc-handoff.c`
- Produces: `~/.local/bin/uc-handoff` に置かれた実体バイナリと、それを起動する launchd agent `com.playpark.uc-handoff`

- [ ] **Step 1: derivation と配置と agent を書く**

`home-manager/programs/uc-handoff.nix`:

```nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ucHandoff = pkgs.stdenv.mkDerivation {
    pname = "uc-handoff";
    version = "0.1.0";
    src = ../home/file/uc-handoff;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      $CC -O2 -Wall -Wextra -Werror \
        -framework ApplicationServices \
        -o uc-handoff uc-handoff.c
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -D -m 555 uc-handoff "$out/bin/uc-handoff"
      runHook postInstall
    '';
    meta.platforms = lib.platforms.darwin;
  };

  # TCC はバイナリのパスに紐づく。nix store のパスは世代ごとに変わるため、
  # そこを直接 launchd から起動するとアクセシビリティ許可が毎回切れる。
  # symlink も不可 (TCC が実体解決して store パスを記録する)。
  # deskflowServerConfig と同じく実体コピーで固定パスに置く。
  ucHandoffBin = "${config.home.homeDirectory}/.local/bin/uc-handoff";
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.activation.ucHandoffBinary = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    # 555 のまま install すると dest を開けず EACCES になるので先に消す。
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "${ucHandoffBin}"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -D -m 555 \
      ${ucHandoff}/bin/uc-handoff "${ucHandoffBin}"
  '';

  launchd.agents.uc-handoff = {
    enable = true;
    config = {
      Label = "com.playpark.uc-handoff";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          DIRECTION="${config.home.homeDirectory}/.config/uc-handoff/direction"
          if [ ! -f "$DIRECTION" ]; then
            echo "uc-handoff: $DIRECTION not found on this host — skipping (write 'left' or 'right')" >&2
            exit 0
          fi
          /bin/wait4path "${ucHandoffBin}" && exec "${ucHandoffBin}"
        ''
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
      };
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Interactive";
      StandardOutPath = "${config.home.homeDirectory}/.local/state/uc-handoff.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.local/state/uc-handoff.err.log";
    };
  };
}
```

`ProcessType` が `Interactive` なのは、event tap を張るために Aqua セッションで
動く必要があるため。`hermes-watchdog` の `Background` とは要件が違う。

- [ ] **Step 2: import を追加する**

`home-manager/programs/default.nix` の imports は五十音順でもアルファベット順でもなく、
`(import ...)` 形式が先、素のパスが後、という並びになっている。末尾に追加する。

```nix
{ pkgs, ... }:
{
  imports = [
    (import ./fish.nix { inherit pkgs; })
    (import ./zsh.nix { inherit pkgs; })
    (import ./google-cloud-sdk.nix { inherit pkgs; })
    ./antigravity-cli.nix
    ./git.nix
    ./yazi.nix
    ./neovim.nix
    ./cca.nix
    ./cc-launch.nix
    ./uc-handoff.nix
  ];
}
```

- [ ] **Step 3: フォーマットと評価を確認**

```bash
nix fmt
git diff --stat
nix flake check
```

期待: `nix fmt` で `uc-handoff.nix` が整形される（差分が出たらそれを取り込む）。
`nix flake check` が通る。**`nix run .#update` は agent が実行しないこと。**

- [ ] **Step 4: コミット**

```bash
git add home-manager/programs/uc-handoff.nix home-manager/programs/default.nix
git commit -m "feat(uc-handoff): 🎸 nix ビルドと固定パス配置と launchd agent を追加"
```

---

### Task 4: ZMK ハンドオフマクロ

**このタスクだけリポジトリが違う。** `zmk-config-fish` で作業する。

**Files:**
- Modify: `config/boards/shields/fish/fish.keymap`

**Interfaces:**
- Consumes: Task 1 で確定した `F13` = 左 / `F14` = 右 という意味づけ
- Produces: `layer_navi` から押せるハンドオフキー 2 つ

- [ ] **Step 1: マクロを定義する**

`fish.keymap` の空の `macros { };` を次で置き換える:

```dts
    macros {
        // ポインタとキーボードを隣の Mac へ同時に渡す。
        //
        // キーコードを先に送り、100ms 待ってから BT プロファイルを切り替える。
        // 逆順にすると、切替後の機体にキーコードが飛んで意図が反転する。
        //
        // &macro_wait_time はその場で待つのではなく、以降のバインディングの
        // wait_ms を書き換える状態変更。&kp の後ろに置くと F13 の release には
        // 反映されず、既定の 15ms (CONFIG_ZMK_MACRO_DEFAULT_WAIT_MS) が使われる。
        // 必ず &kp の前に置くこと。
        //
        // F13 = ポインタを左へ渡せ / F14 = ポインタを右へ渡せ。
        // 意味は「押された機体から見た方向」なので、隣がいない側のキーを
        // 押しても受け側が no-op として無視する。
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

- [ ] **Step 2: `layer_navi` を差し替える**

`layer_navi` の `&kp F13` を `&handoff_to_mbp` に、`&kp F14` を
`&handoff_to_studio` に置き換える。位置は変えない。

```dts
        layer_navi {
            bindings = <
                        &none       &none       &none       &none               &none       &kp C_BRI_DN &none      &kp C_BRI_UP
&none       &none       &none       &none       &none       &none               &none       &handoff_to_mbp &none  &handoff_to_studio &none  &none
            &none       &none       &none       &none                                       &kp C_VOL_DN &kp C_MUTE &kp C_VOL_UP &none
                                                &trans      &trans              &trans      &trans
            >;
        };
```

- [ ] **Step 3: ビルドが通ることを確認**

```bash
git switch -c worktree-uc-handoff-macro
git add config/boards/shields/fish/fish.keymap
git commit -m "feat(keymap): 🎸 ポインタとキーボードを同時に渡すハンドオフマクロを追加"
git push -u origin worktree-uc-handoff-macro
gh pr create --draft --repo it-all-playpark/zmk-config-fish --base master --fill
```

**`zmk-config-fish` に `main` は無い。** 既定ブランチは `master` で、しかもこのリポジトリは
`TakumaOnishi/zmk-config-fish` の fork。`gh pr create` は fork では親リポジトリを
base に取ろうとするため、`--repo it-all-playpark/zmk-config-fish` と `--base master`
の両方を明示しないと `No commits between main and ...` で失敗する。

`master` への直接 push は禁止なので必ず feature branch を切ること。

GitHub Actions のファームウェアビルドが緑になることを確認する。
devicetree の構文エラーはここで落ちる。

- [ ] **Step 4: ファームウェアを焼いて動作確認**

左右両方の `.uf2` を焼き、`layer_navi` を出して該当キーを押す。

期待: キーボードの接続先が切り替わり、`uc-handoff` が動いている機体では
ポインタも一緒に移る。

---

### Task 5: 両機のセットアップと受け入れ確認

**Files:** なし（手作業とドキュメント）

**Interfaces:**
- Consumes: Task 3 の `~/.local/bin/uc-handoff` と launchd agent、Task 4 のファームウェア

- [ ] **Step 1: 両機に方向を書く**

Mac Studio:

```bash
mkdir -p ~/.config/uc-handoff && echo left > ~/.config/uc-handoff/direction
```

MacBook Pro:

```bash
mkdir -p ~/.config/uc-handoff && echo right > ~/.config/uc-handoff/direction
```

- [ ] **Step 2: 両機に apply する（人間が実行）**

```bash
nix run .#update
```

- [ ] **Step 3: 両機でアクセシビリティを許可する**

システム設定 → プライバシーとセキュリティ → アクセシビリティ に
`~/.local/bin/uc-handoff` を追加する。追加後に agent を読み直す:

```bash
launchctl kickstart -k "gui/$(id -u)/com.playpark.uc-handoff"
tail -5 ~/.local/state/uc-handoff.err.log
```

期待: `watching F13/F14, neighbor is on the ...` がログに出る。

このコマンドは権限付与のときだけでなく、**`uc-handoff.c` を変更して apply したときにも必要**。
plist は世代が変わっても不変なので home-manager は agent を reload せず、
activation でバイナリを差し替えても古いプロセスが走り続ける。
activation script 側でも `kickstart -k` を打つようにしてあるが、手で確認するときはこれを使う。

- [ ] **Step 4: Universal Control を両機で有効化する**

システム設定 → ディスプレイ → 詳細設定 で、特に
「ディスプレイの端を越えてカーソルを移動して近くの Mac に接続」を ON。
両機が同一 Apple ID + 2FA、同一 Wi-Fi であること。

- [ ] **Step 5: deskflow のホットキーを外す**

併存期間中に `F13` / `F14` の意味が二重になるのを避ける。
`home-manager/home/file/deskflow/deskflow-server.conf` の
`keystroke(F13)` / `keystroke(F14)` の 2 行をコメントアウトし、apply する。
deskflow 自体は残す。

- [ ] **Step 6: 受け入れ基準を確認する**

spec §11 の 6 項目を順に確認する。

1. Mac Studio でハンドオフキーを押すと、キーボードとポインタが両方 MBP へ移る
2. MBP で反対キーを押すと、両方 Mac Studio に戻る
3. 反対方向のキーを押しても何も起きない
4. `F13` / `F14` がアプリに漏れない
5. `nix run .#update` を再実行してもアクセシビリティ許可が切れない
6. `launchctl bootout gui/$(id -u)/com.playpark.uc-handoff` でデーモンを止めても、
   キーボードの BT 切替だけは従来どおり動く

5 が落ちた場合は ad-hoc 署名の hash 変動が原因。spec §12 に記録し、
`codesign` の扱いを別途決める。

- [ ] **Step 7: 結果を spec に反映する**

spec §12「未解決 / 実装時に決めること」から、決着した項目を消す。
押し込み時間と `macro_wait_time` の実測値を本文に書き戻す。

```bash
git add docs/specs/2026-07-30-uc-handoff-design.md
git commit -m "docs(uc-handoff): 📝 実測値を反映し未解決項目を整理"
```
