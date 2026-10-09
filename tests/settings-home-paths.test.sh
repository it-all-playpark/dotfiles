#!/usr/bin/env bash
# tests/settings-home-paths.test.sh
# claude-code/settings.json に特定ユーザーのホーム（/Users/<name>/...）を直書きしない。
# settings.json は全ユーザー（flake.nix の USERNAMES）と clone した人で共有するので、直書きしたパスは
# 他のユーザーのホストで空振りする。~ / $HOME が効かないキーは次の方法で書く:
#   - sandbox.filesystem.* / sandbox.network.allowUnixSockets → ~/ で書く（Claude Code が展開する）
#   - env → 値は展開されないので hooks/session-start-account-path.sh で $CLAUDE_ENV_FILE に書く
#   - sandbox.excludedCommands → Claude が打ったコマンド文字列と照合する（展開しない）が、~/ で書けば
#     agent-vault-managed-env.sh がユーザーごとの絶対パスに展開した drop-in（60-home-paths.json）を書く
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
  | getpath($p) as $v
  | select($v | test("/Users/"))
  | "\($p | map(tostring) | join(".")): \($v)"
' "${SETTINGS}")"

if [[ -z ${HITS} ]]; then
  echo "  PASS: no hardcoded /Users/ path"
  echo "PASS: settings-home-paths"
  exit 0
fi

echo "  FAIL: hardcoded /Users/ path"
printf '        %s\n' "${HITS}"
exit 1
