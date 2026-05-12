import re

SENSITIVE_PATH_PATTERNS = [
    re.compile(r"(^|[/\s'\"])\.env(\.\w+)?(\s|$|['\"])"),
    re.compile(r"\.ssh/"),
    re.compile(r"\.gnupg/"),
    re.compile(r"\.aws/"),
    re.compile(r"\.config/gh/"),
    re.compile(r"Library/Keychains/"),
    re.compile(r"/Users/[^/]+/\.(env|ssh|gnupg|aws)"),
]

# hermes built-in approvals が見落とすパターンのみ追加
# (python -c / node -e / bash -c / heredoc 等は built-in でカバー済み)
INTERPRETER_DENY_PATTERNS = [
    re.compile(r"\b(npx|pnpx|uvx|bunx)\b"),
    re.compile(r"\bdeno\s+(run|eval)\b"),
    re.compile(r"\beval\s+"),
    re.compile(r"\b(fish|dash)\s+-[^\s]*c\b"),
]


def _block_if_sensitive(tool_name, args, **_):
    args = args or {}
    haystack = " ".join(
        [
            str(args.get("command", "")),
            str(args.get("path", "")),
            str(args.get("file_path", "")),
            str(args.get("paths", "")),
        ]
    )
    if not haystack.strip():
        return None

    for pat in SENSITIVE_PATH_PATTERNS:
        if pat.search(haystack):
            return {
                "action": "block",
                "message": f"path_guard: sensitive path denied ({pat.pattern})",
            }

    if tool_name == "terminal":
        for pat in INTERPRETER_DENY_PATTERNS:
            if pat.search(haystack):
                return {
                    "action": "block",
                    "message": f"path_guard: interpreter/runner not allowed ({pat.pattern})",
                }

    return None


def register(ctx):
    ctx.register_hook("pre_tool_call", _block_if_sensitive)
