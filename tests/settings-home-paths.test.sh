#!/usr/bin/env bash
# tests/settings-home-paths.test.sh
# claude-code/settings.json に特定ユーザーのホーム（/Users/<name>/...）を直書きしない。
# settings.json は全ユーザー（flake.nix の USERNAMES）で共有するので、直書きしたパスは
# 他のユーザーのホストで空振りする。~ / $HOME が効かないキーは次の方法で書く:
#   - sandbox.filesystem.* / sandbox.network.allowUnixSockets → ~/ で書く（Claude Code が展開する）
#   - env → 値は展開されないので hooks/session-start-account-path.sh で $CLAUDE_ENV_FILE に書く
# 例外は sandbox.excludedCommands だけ: Claude が打ったコマンド文字列と照合するので、
# 絶対パスで呼ばれるスクリプトは絶対パス形式で登録するしかない（e151b78）。
# Run from the repo root: bash tests/settings-home-paths.test.sh
# Requires: jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${REPO_ROOT}/claude-code/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

echo "=== settings.json home path tests ==="

HITS="$(jq -r '
  paths(strings) as $p
  | select($p[0:2] != ["sandbox", "excludedCommands"])
  | getpath($p) as $v
  | select($v | test("/Users/"))
  | "\($p | map(tostring) | join(".")): \($v)"
' "${SETTINGS}")"

if [[ -z ${HITS} ]]; then
  echo "  PASS: no hardcoded /Users/ path outside sandbox.excludedCommands"
  echo "PASS: settings-home-paths"
  exit 0
fi

echo "  FAIL: hardcoded /Users/ path outside sandbox.excludedCommands"
printf '        %s\n' "${HITS}"
exit 1
