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
