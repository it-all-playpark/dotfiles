#!/usr/bin/env python3
"""PreToolUse(Bash) hook: live な skills checkout で作業ツリーを書き換える git を deny

背景:
  ~/.claude/skills は it-all-playpark/skills の checkout そのもので、Claude Code が
  毎セッション skill / agent / hook として読み込む。sandbox は repo 全体を書き込み
  禁止にしている。この hook を足した当時は素の git が excludedCommands で sandbox 外で
  動いたので、`git checkout <branch>` / `git reset --hard` / `git pull` などで中身を
  差し替えられた（差し替えた内容は次のセッションで sandbox 外の hook としても動き得る）。
  git / gh を excludedCommands から外した後（issue #249）は素の git も sandbox 内で走り、
  書き換えは repo の保護で失敗する。この hook はその手前で、開発先（skills-dev）を示して止める。

  開発は通常の clone（~/ghq/github.com/it-all-playpark/skills-dev）で行い、PR を
  merge したあと live checkout を人間が pull する。live checkout でエージェントが
  作業ツリーを書き換える正当な理由は無い。

判定:
  - payload の cwd が live checkout（~/.claude/skills の実体）の中
    （.claude/worktrees/ 配下は別 worktree なので対象外）
  - コマンドに、書き換え系サブコマンドの素の git が含まれる
  -C / -c / --git-dir / --work-tree 付きの git は対象外（ここでは止めない。当時から
  sandbox 内で走り、repo の保護で失敗する）。読むだけの git は素通し。

出力:
  deny 時: {"hookSpecificOutput":{"hookEventName":"PreToolUse",
            "permissionDecision":"deny","permissionDecisionReason":"..."}}
  それ以外: stdout 空で exit 0。例外時も exit 0（fail-open）

環境変数:
  LIVE_SKILLS_GUARD_ROOT  live checkout のパス（テスト用。既定は ~/.claude/skills の実体）
"""

import contextlib
import json
import os
import re
import shlex
import sys

MUTATING = {
    "checkout", "switch", "reset", "restore", "merge", "pull", "rebase",
    "cherry-pick", "revert", "am", "apply", "stash", "clean", "rm", "mv",
    "commit", "read-tree", "checkout-index", "update-index", "submodule",
}  # fmt: skip
GIT_OPTS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
GIT_SANDBOXING_OPTS = {"-C", "-c", "--git-dir", "--work-tree"}
PUNCTUATION = "();<>|&\n"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

REASON = """\
{root} は ~/.claude/skills として Claude Code が読み込んでいる live checkout なので、作業ツリーを書き換える git（`git {sub}`）はここでは止めています。
- 開発: ~/ghq/github.com/it-all-playpark/skills-dev（通常の clone）で branch を切り、commit → push → PR。そこでは sandbox 内で git もテストも普通に動く。まだ無ければ `git clone https://github.com/it-all-playpark/skills.git ~/ghq/github.com/it-all-playpark/skills-dev`
- live checkout の更新（merge 後の pull など）は人間が行う。必要ならユーザーに `git -C {root} pull` の実行を依頼して止まる
- 読むだけの git（status / log / diff / fetch / branch の一覧など）はそのまま使える"""


def live_root():
    root = os.environ.get("LIVE_SKILLS_GUARD_ROOT") or os.path.expanduser(
        "~/.claude/skills"
    )
    return os.path.realpath(root)


def inside_live(cwd, root):
    cwd = os.path.realpath(cwd)
    if cwd != root and not cwd.startswith(root + os.sep):
        return False
    rel = os.path.relpath(cwd, root)
    return not (rel == ".claude/worktrees" or rel.startswith(".claude/worktrees/"))


def git_subcommand(words):
    """素の git のサブコマンドを返す。-C 等の付いた git と git 以外は None。"""
    i = 0
    while i < len(words) and ASSIGNMENT.match(words[i]):
        i += 1
    if i < len(words) and words[i] in {"command", "exec", "builtin"}:
        i += 1
    if i >= len(words) or os.path.basename(words[i]) != "git":
        return None
    i += 1
    while i < len(words) and words[i].startswith("-"):
        if words[i].split("=", 1)[0] in GIT_SANDBOXING_OPTS:
            return None
        i += 2 if words[i] in GIT_OPTS_WITH_VALUE else 1
    return words[i] if i < len(words) else None


def segments(cmd):
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCTUATION)
    lexer.whitespace = " \t\r"
    current = []
    for tok in lexer:
        if set(tok) <= set(PUNCTUATION):
            if current:
                yield current
            current = []
        else:
            current.append(tok)
    if current:
        yield current


def judge(cmd, cwd, root):
    if not re.search(r"\bgit\b", cmd) or not inside_live(cwd, root):
        return None
    try:
        segs = list(segments(cmd))
    except ValueError:
        # heredoc 等でパースできない。字面で書き換え系の git を拾う
        m = re.search(r"(?:^|[\s;&|(])git\s+(" + "|".join(MUTATING) + r")\b", cmd)
        return m.group(1) if m else None
    for words in segs:
        sub = git_subcommand(words)
        if sub in MUTATING:
            return sub
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") not in (None, "Bash"):
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    cwd = data.get("cwd") or os.getcwd()
    root = live_root()
    sub = judge(cmd, cwd, root)
    if sub is None:
        return
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": REASON.format(root=root, sub=sub),
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )


if __name__ == "__main__":
    with contextlib.suppress(Exception):  # fail-open
        main()
