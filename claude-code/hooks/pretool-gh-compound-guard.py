#!/usr/bin/env python3
"""PreToolUse(Bash) hook: sandbox 内に戻されて落ちる gh / git 通信系の複合コマンドを deny

背景:
  settings.json の sandbox.excludedCommands に gh / git を入れて sandbox 外で
  動かしているが、harness が sandbox 外に出すのは「コマンド全体が単純で、
  全部分が excludedCommands に一致する」ときだけ。1 つでも外れると丸ごと
  sandbox 内で走り、gh は denyRead の ~/.config/gh を読めずに落ちる
  (git の GitHub 認証も credential helper が gh なので同じ理由で落ちる)。
  2026-09-20〜24 の tool-failures.jsonl で 73 件。パイプ由来は 12 件で、
  残りは `cd X && gh` / `> file` / for ループ / heredoc 連結など。

実測した harness の判定 (2026-09-24):
  sandbox 外: `gh a && git b` / `gh a; git b` / `gh a | gh b` / `gh a 2>&1 && git b`
              / `gh api x --jq '.a | b'` (引用符内の | は分割されない)
  sandbox 内: `gh a | head` / `gh a || true` / `cd X && gh a` / `VAR=x gh a`
              / `gh a > file` / `gh a 2>/dev/null` (ファイルへのリダイレクトは全部)
              / `git -C X push` / `git -c k=v push` / `git --work-tree=X push`
                (単独でも。-C 等を付けた git は excludedCommands が効かない。
                 `--no-pager` と `gh -R` は影響しない)

判定:
  1. gh、または git の通信系サブコマンド (push/pull/fetch/clone/ls-remote) を
     コマンド位置に含まなければ素通し
  2. 次のどれかに当たれば deny (理由に書き換え方を載せる)
     - パースできない (heredoc 等) / サブシェル・コマンド置換・制御構文
     - fd 複製 (2>&1 等) 以外のリダイレクト
     - excludedCommands に一致しない部分がある (環境変数の前置、
       -C / -c / --work-tree / --git-dir 付きの git を含む)
  excludedCommands は ~/.claude/settings.json から読む (harness と同じ真実)。

出力:
  deny 時: {"hookSpecificOutput":{"hookEventName":"PreToolUse",
            "permissionDecision":"deny","permissionDecisionReason":"..."}}
  それ以外: stdout 空で exit 0。例外時も exit 0 (fail-open。harness 側で
  落ちるだけで安全性には影響しない)

環境変数:
  GH_COMPOUND_GUARD_SETTINGS  読む settings.json のパス (テスト用)
"""

import contextlib
import fnmatch
import json
import os
import re
import shlex
import sys

SETTINGS_PATH = os.environ.get(
    "GH_COMPOUND_GUARD_SETTINGS", os.path.expanduser("~/.claude/settings.json")
)
DEFAULT_EXCLUDED = ["gh", "gh *", "git", "git *"]
GIT_NETWORK_SUBCOMMANDS = {"push", "pull", "fetch", "clone", "ls-remote"}
# git のグローバルオプションのうち値を次のトークンに取るもの
GIT_OPTS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
# 付けると excludedCommands に一致していても sandbox 内で実行される (2026-09-24 実測。
# --git-dir は worktree ガードに阻まれ未計測だが、対象を変える同類として扱う)
GIT_SANDBOXING_OPTS = {"-C", "-c", "--git-dir", "--work-tree"}
PUNCTUATION = "();<>|&\n"
SEPARATORS = {"&&", "||", ";", "|", "&"}
CONTROL_WORDS = {
    "for", "while", "until", "if", "then", "else", "elif", "fi",
    "do", "done", "case", "esac", "select", "function", "{", "}",
}  # fmt: skip
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
FD_DUP = {">&", "<&"}

REASON = """\
このコマンドは sandbox 内で実行され、gh（および GitHub 認証が必要な git push/pull/fetch/clone/ls-remote）は ~/.config/gh を読めずに失敗します。
gh / git が sandbox 外で動くのは、コマンド全体が「excludedCommands に一致する部分だけを && ; | でつないだもの」のときだけです。{detail}

書き換え方:
- 整形は gh の中で: `gh ... --jq '<filter>'` / `-q` / `--template`（引用符内の | は OK）
- ディレクトリ指定: `cd X && gh ...` → `gh -R owner/repo ...`
- git の -C / -c / --work-tree / --git-dir は、単独でも sandbox 行きになる（excludedCommands が効かない）。別ディレクトリで push / fetch するときは、`cd X` だけを 1 回の Bash 呼び出しで実行し（cwd は呼び出し間で保持される）、次の呼び出しで素の `git push` を実行する
- PR/issue 本文: 先に Write ツールでファイルを作り `gh pr create --body-file <path>`（heredoc や $(cat) と連結しない）
- 加工が必要なら呼び出しを分ける: gh / git だけを単独で実行 → その出力を見て次の Bash 呼び出しで処理
- 環境変数の前置（VAR=x gh）、ファイルへのリダイレクト（> file、2>/dev/null）、|| true、for ループも sandbox 行きになる。ループはコマンドを並べて && でつなぐ"""


def load_excluded():
    try:
        with open(SETTINGS_PATH, encoding="utf-8") as f:
            sandbox = json.load(f).get("sandbox") or {}
    except (OSError, ValueError):
        return DEFAULT_EXCLUDED
    if sandbox.get("enabled") is False:
        return None
    return sandbox.get("excludedCommands") or DEFAULT_EXCLUDED


def has_git_sandboxing_opt(words):
    """git のサブコマンドより前に -C / -c / --work-tree / --git-dir があるか。"""
    if not words or os.path.basename(words[0]) != "git":
        return False
    i = 1
    while i < len(words) and words[i].startswith("-"):
        if words[i].split("=", 1)[0] in GIT_SANDBOXING_OPTS:
            return True
        i += 2 if words[i] in GIT_OPTS_WITH_VALUE else 1
    return False


def matches_excluded(segment, patterns):
    if has_git_sandboxing_opt(segment):
        return False
    text = " ".join(segment)
    for raw in patterns:
        pat = os.path.expanduser(os.path.expandvars(raw))
        if pat.endswith(":*"):  # 旧来の prefix 記法 (codex:*)
            prefix = pat[:-2]
            if text == prefix or text.startswith(prefix + " "):
                return True
        elif fnmatch.fnmatchcase(text, pat):
            return True
    return False


def tokenize(cmd):
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCTUATION)
    lexer.whitespace = " \t\r"
    return list(lexer)


def is_git_network(words):
    i = 1
    while i < len(words):
        w = words[i]
        if w in GIT_OPTS_WITH_VALUE:
            i += 2
            continue
        if w.startswith("-"):
            i += 1
            continue
        return w in GIT_NETWORK_SUBCOMMANDS
    return False


def needs_outside(cmd_words_list):
    for words in cmd_words_list:
        if not words:
            continue
        name = os.path.basename(words[0])
        if name == "gh" or (name == "git" and is_git_network(words)):
            return True
    return False


def split_segments(tokens):
    """区切りで分割し、各セグメントの問題点を返す。

    返り値: (segments, problem)。problem は deny 理由の補足 (無ければ None)。
    segments は環境変数の前置・制御語を剥がす前の単語列。
    """
    segments, current, problem = [], [], None
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        # 記号だけのトークンが演算子。引用符内の | や > は単語に混ざるので対象外
        is_op = set(tok) <= set(PUNCTUATION)
        if is_op and tok.replace("\n", "") in SEPARATORS | {""}:
            # ";\n" や "&&\n" は 1 トークンにまとまる
            segments.append(current)
            current = []
        elif tok in FD_DUP:
            # 2>&1 → ['2', '>&', '1']。直前の fd 番号は current から外す
            if current and current[-1].isdigit():
                current.pop()
            i += 1  # 複製先 (1 / -) を読み飛ばす
        elif is_op and any(c in tok for c in "<>"):
            problem = problem or f"`{tok}` のリダイレクトが含まれています。"
            i += 1  # リダイレクト先を読み飛ばす
        elif is_op:
            problem = problem or f"サブシェル / `{tok.strip()}` が含まれています。"
        elif "$(" in tok or "`" in tok:
            problem = problem or "コマンド置換 `$(...)` が含まれています。"
        else:
            current.append(tok)
        i += 1
    segments.append(current)
    return [s for s in segments if s], problem


def command_words(segment):
    """制御語・環境変数の前置を剥がした、実際に起動されるコマンドの単語列。"""
    i = 0
    while i < len(segment) and (
        segment[i] in CONTROL_WORDS or ASSIGNMENT.match(segment[i])
    ):
        i += 1
    return segment[i:]


def judge(cmd, patterns):
    """deny するなら理由の補足を、しないなら None を返す。"""
    if not re.search(r"\bg(h|it)\b", cmd):
        return None
    try:
        tokens = tokenize(cmd)
    except ValueError:
        # heredoc 等でパースできない。gh を含むかは字面で判定する
        if re.search(r"(^|[\s;&|(`])gh\s", cmd):
            return "heredoc など解析できない構文が含まれています。"
        return None

    segments, problem = split_segments(tokens)
    if not needs_outside(command_words(s) for s in segments):
        # "$(gh ...)" のように引数の中に埋もれた gh も拾う
        if not any(re.search(r"(\$\(|`)\s*gh\s", t) for t in tokens):
            return None
        return "コマンド置換 `$(gh ...)` が含まれています。"
    if problem:
        return problem

    for seg in segments:
        if any(w in CONTROL_WORDS for w in seg[:1]):
            return f"制御構文 `{seg[0]}` が含まれています。"
        if not matches_excluded(seg, patterns):
            return f"excludedCommands に一致しない部分 `{' '.join(seg)[:80]}` が含まれています。"
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") not in (None, "Bash"):
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    patterns = load_excluded()
    if not cmd or patterns is None:
        return
    detail = judge(cmd, patterns)
    if detail is None:
        return
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": REASON.format(detail=detail),
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )


if __name__ == "__main__":
    with contextlib.suppress(Exception):  # fail-open
        main()
