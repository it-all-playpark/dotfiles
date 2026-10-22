#!/usr/bin/env bash
# Test suite for pretool-npx-guard.sh
#
# Usage: bash pretool-npx-guard.test.sh
#
# Exit 0 on all pass, non-zero otherwise.
#
# shellcheck disable=SC2016
# 単一引用符内の `$(…)` は意図的なリテラル（hook に生文字列として渡す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/pretool-npx-guard.sh"

if [[ ! -x ${HOOK} ]]; then
  echo "FAIL: hook not executable: ${HOOK}" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILURES=()

run_hook() {
  jq -n --arg cmd "$1" '{tool_name:"Bash", tool_input:{command:$cmd}}' | bash "$HOOK" 2>&1 || true
}

# run_reason_case <name> <command> <substring expected in permissionDecisionReason>
run_reason_case() {
  local name="$1"
  local cmd="$2"
  local want="$3"

  local reason
  reason=$(run_hook "$cmd" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)

  if [[ $reason == *"$want"* ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: reason does not contain '$want' (got: $reason) cmd=$cmd")
    printf "  \033[31mFAIL\033[0m %s (reason missing: %s)\n" "$name" "$want"
  fi
}

# run_case <name> <command> <expected: deny|pass>
run_case() {
  local name="$1"
  local cmd="$2"
  local expected="$3"

  local output
  output=$(run_hook "$cmd")

  local decision="pass"
  if [[ -n $output ]]; then
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || echo "pass")
  fi

  if [[ $decision == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILURES+=("$name: expected=$expected got=$decision cmd=$cmd")
    printf "  \033[31mFAIL\033[0m %s (expected=%s, got=%s)\n" "$name" "$expected" "$decision"
  fi
}

echo "=== pretool-npx-guard tests ==="

# --- リモートから取得しうる形 → deny ---
echo "[Remote fetch — should deny]"
run_case "bare npx biome" 'npx biome check .' "deny"
run_case "npx --no-install (no effect on npm 11)" 'npx --no-install biome' "deny"
run_case "npx -y actionlint" 'npx -y actionlint' "deny"
run_case "npx --no overridden by --yes" 'npx --no --yes cowsay hi' "deny"
run_case "npx --no overridden by -y" 'npx --no -y cowsay hi' "deny"
run_case "npx --no -- overridden by --yes" 'npx --no -- --yes cowsay hi' "deny"
run_case "pnpx --no (pnpm dlx has no --no)" 'pnpx --no -- biome check .' "deny"
# `--` が無いと <bin> より後ろのオプションも npm が読み、--no が打ち消される
run_case "npx --no without -- (trailing --yes)" 'npx --no cowsay --yes' "deny"
run_case "npx --no without -- (trailing -y)" 'npx --no cowsay -y' "deny"
run_case "npx --no without -- (no trailing flag)" 'npx --no biome check .' "deny"

# --- --no 付きと付いていない npx の混在 → 全体を deny（fail-closed） ---
echo "[Mixed --no and bare npx — should deny]"
run_case "--no then bare" 'npx --no -- biome check . && npx biome check .' "deny"
run_case "bare then --no" 'npx -y actionlint; npx --no -- biome check .' "deny"
run_case "--no then bare in substitution" 'npx --no -- biome check $(npx cowsay hi)' "deny"

# --- 許可形 → 素通し ---
echo "[Allowed forms — should pass through]"
run_case "npx --no -- biome" 'npx --no -- biome check .' "pass"
run_case "npx vitest run" 'npx vitest run' "pass"
run_case "absolute path npx --no --" '/usr/local/bin/npx --no -- biome check .' "pass"
run_case "two npx --no --" 'npx --no -- biome check . && npx --no -- tsc --noEmit' "pass"
run_case "vitest and npx --no --" 'npx vitest run && npx --no -- biome check .' "pass"

# --- deny 理由にローカル実行の形と代替を書く ---
echo "[Deny reason]"
run_reason_case "reason suggests npx --no --" 'npx biome check .' 'npx --no -- <bin>'
run_reason_case "reason suggests node_modules/.bin" 'npx biome check .' './node_modules/.bin/<bin>'
run_reason_case "reason suggests pnpm exec" 'npx biome check .' 'pnpm exec <bin>'
run_reason_case "reason suggests nix for remote tools" 'npx -y actionlint' 'リモート取得が要るツールは nix 等で入れる'

# --- 語が引数に入るだけでも deny（fail-closed。RULES.md の Tool routing はこれを前提に書く） ---
echo "[Word as argument — should deny]"
run_case "npx as grep search term" 'grep -rn npx claude-code/hooks' "deny"

# --- RULES.md の Tool routing に、npx を使わないローカル CLI の実行形と、語だけでも止まる旨がある ---
echo "[RULES.md Tool routing]"
RULES="${SCRIPT_DIR}/../RULES.md"
rules_line="$(awk '/^## Tool routing$/ { f = 1; next } /^## / { f = 0 } f && /pnpm exec/ && /\.\/node_modules\/\.bin/' "${RULES}")"
missing=()
for want in '`pnpm exec <bin>`' '`./node_modules/.bin/<bin>`' 'npx という語が引数に入るだけでも' 'hook が拒否する'; do
  case "${rules_line}" in
  *"${want}"*) ;;
  *) missing+=("${want}") ;;
  esac
done
if [[ -n ${rules_line} && ${#missing[@]} -eq 0 ]]; then
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m %s\n" "rules tool routing local cli"
else
  FAIL=$((FAIL + 1))
  FAILURES+=("rules tool routing local cli: line=${rules_line:-<none>} missing=${missing[*]:-}")
  printf "  \033[31mFAIL\033[0m %s\n" "rules tool routing local cli"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if ((FAIL > 0)); then
  printf '\n'
  printf 'Failures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
