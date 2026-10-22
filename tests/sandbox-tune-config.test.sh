#!/usr/bin/env bash
# tests/sandbox-tune-config.test.sh
# sandbox-tune.json の intended（sandbox-tune が remaining・recurring から外す意図した拒否・実行）を検証する。
#   - 各項目は id か kind のどちらか一方と、空でない reason を持つ（sandbox-tune の config が受け付ける形）
#   - RULES の Git 節どおりの host-exec の dotfiles-sync は型の id で intended にする。
#     kind（host_exec 全体）で書くと、直すべきほかの host-exec の実行まで remaining から消える
#   - 組み込み保護（.git/config 等）・人間が行うログイン（gws auth）・Bash からの .env.*.example 読み取りも型の id で intended にする。
#     .env.*.example は deny の Read(./.env.*) と RULES の「Read ツールで読む」が前提なので、その 2 つも確かめる
#   - 人間へのコピペ実行の依頼（request:request:bash）を直す RULES の host-exec の行と、人間に頼む例外がある
# Run from the repo root: bash tests/sandbox-tune-config.test.sh
# Requires: jq

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/sandbox-tune.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

echo "=== sandbox-tune.json intended tests ==="

FAILED=0

check() {
  local name="$1" filter="$2"
  if jq -e "${filter}" "${CONFIG}" >/dev/null; then
    echo "  PASS: ${name}"
  else
    echo "  FAIL: ${name}"
    FAILED=1
  fi
}

check "intended の各項目は id か kind の一方と空でない reason を持つ" \
  '.intended | length > 0 and all(.[]; ((has("id")) != (has("kind"))) and (.reason | type == "string" and length > 0))'

check "host-exec の dotfiles-sync を id で intended にしている" \
  '.intended[] | select(.id == "host_exec:ran:dotfiles-sync") | .reason | length > 0'

check "host_exec を kind で intended にしない" \
  '[.intended[] | select(.kind == "host_exec")] | length == 0'

check "設定では外せない組み込み保護と人間が行うログインを id で intended にしている" \
  '[.intended[].id // empty] as $ids
   | all("request:request:gws auth", "sandbox:path:~/ghq/github.com/it-all-playpark/dotfiles/.git/config"; IN($ids[]))'

check "Bash からの .env.*.example 読み取りの拒否を id で 2 つ以上 intended にしている" \
  '[.intended[].id // empty | select(endswith(".env.example"))] | length >= 2'

# .env.*.example の intended は、deny の Read(./.env.*) を残したまま RULES の「Read ツールで読む」で避けることが前提。
# deny を外したり RULES の行を消したりすると、intended が直すべき拒否を remaining から隠すことになる。
SETTINGS="${REPO_ROOT}/claude-code/settings.json"
if jq -e '.permissions.deny | index("Read(./.env.*)")' "${SETTINGS}" >/dev/null; then
  echo "  PASS: settings.json の permissions.deny に Read(./.env.*) が残っている"
else
  echo "  FAIL: settings.json の permissions.deny に Read(./.env.*) が無い"
  FAILED=1
fi

sandbox_section="$(awk '/^## Sandbox$/ { in_s = 1; next } /^## / { in_s = 0 } in_s' "${REPO_ROOT}/claude-code/RULES.md")"
# shellcheck disable=SC2016 # 意図的: RULES.md のバッククォートを文字列として探す
if grep -qF -- '- `.env.*.example` は Read ツールで読む' <<<"${sandbox_section}"; then
  echo "  PASS: RULES.md の Sandbox 節に .env.*.example を Read ツールで読む行がある"
else
  echo "  FAIL: RULES.md の Sandbox 節に .env.*.example を Read ツールで読む行が無い"
  FAILED=1
fi

# request:request:bash（sandbox の外が要るコマンドを人間にコピペ実行で頼む）は、RULES の host-exec の行で直す。
# 人間に頼む例外（対話的なログイン・RULES が人間の操作と決めたもの）も同じ行に書く
# shellcheck disable=SC2016 # 意図的: RULES.md のバッククォートを文字列として探す
host_exec_line="$(grep -F -- '- sandbox の外が要るコマンドは、人間に `!` やコピペで実行を頼まず host-exec' <<<"${sandbox_section}" || true)"
if [ -n "${host_exec_line}" ] &&
  grep -qF '対話的なログイン' <<<"${host_exec_line}" &&
  grep -qF 'RULES が人間の操作と決めたもの' <<<"${host_exec_line}"; then
  echo "  PASS: RULES.md の Sandbox 節に、人間にコピペ実行を頼まず host-exec を使い、例外を書いた行がある"
else
  echo "  FAIL: RULES.md の Sandbox 節に、人間にコピペ実行を頼まず host-exec を使い、例外（対話的なログイン・RULES が人間の操作と決めたもの）を書いた行が無い"
  FAILED=1
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "FAIL: sandbox-tune-config"
  exit 1
fi
echo "PASS: sandbox-tune-config"
