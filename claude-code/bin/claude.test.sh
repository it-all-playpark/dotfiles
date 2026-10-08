#!/usr/bin/env bash
# claude-code/bin/claude.test.sh
# Claude Code 本体の上流 proxy を agent-vault に向ける wrapper (bin/claude) のテスト。
#
# Usage: bash claude-code/bin/claude.test.sh
#
# $TMPDIR 配下に一時 HOME を作り、shim dir ($HOME_T/.claude/bin、実運用と同じ位置) から実物の
# bin/claude を symlink して呼ぶ。fake の claude（受け取った env と argv を 1 行ずつ出す。FAKE_GIT があれば
# git credential fill も実行する）を別 dir に置く。
# agent-vault の proxy port の代わりに、python3 で 127.0.0.1 の空き port を listen する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/claude"

if [[ ! -x $WRAPPER ]]; then
  echo "FAIL: wrapper not executable: $WRAPPER" >&2
  exit 1
fi

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-wrapper-test.XXXXXX")"
LISTENER_PID=""
cleanup() {
  if [[ -n $LISTENER_PID ]]; then
    kill "$LISTENER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0
FAILURES=()

pass() {
  printf "  \033[32mPASS\033[0m %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31mFAIL\033[0m %s\n" "$1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  FAILURES+=("$1: $2")
}

contains() {
  case "$1" in
  *"$2"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------
HOME_T="$TMPROOT/home"
FAKE_BIN="$TMPROOT/fake-bin"
SHIM_BIN="$HOME_T/.claude/bin"
UTIL_BIN="$TMPROOT/util-bin"
TOKEN_FILE="$HOME_T/.agent-vault/proxy-token"
CA_BUNDLE="$HOME_T/.local/state/agent-vault/ca-bundle.pem"
mkdir -p "$FAKE_BIN" "$SHIM_BIN" "$UTIL_BIN" "$(dirname "$TOKEN_FILE")" "$(dirname "$CA_BUNDLE")"

# wrapper のシェバン（#!/usr/bin/env bash）と内部で使うコマンドだけを置いた dir
for cmd in bash env tr readlink dirname; do
  ln -s "$(command -v "$cmd")" "$UTIL_BIN/$cmd"
done

cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
for v in HTTPS_PROXY HTTP_PROXY NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE GIT_SSL_CAINFO CLAUDE_GH_VAULT \
  GIT_CONFIG_COUNT; do
  printf '%s=%s\n' "$v" "${!v-<unset>}"
done
i=0
while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  k="GIT_CONFIG_KEY_$i" v="GIT_CONFIG_VALUE_$i"
  printf 'git_config=%s=%s\n' "${!k}" "${!v}"
  i=$((i + 1))
done
printf 'argc=%s\n' "$#"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
# FAKE_GIT があれば、子プロセス（sandbox 内の git に相当）として github.com と他ホストの資格情報を引く
if [ -n "${FAKE_GIT:-}" ]; then
  for host in github.com example.com; do
    printf 'protocol=https\nhost=%s\npath=octo/repo.git\n\n' "$host" |
      "$FAKE_GIT" credential fill >/dev/null 2>&1 || true
  done
fi
# FAKE_GIT_SCRIPT があれば、子プロセス（sandbox 内のコマンドに相当）として実行する
if [ -n "${FAKE_GIT_SCRIPT:-}" ]; then
  bash "$FAKE_GIT_SCRIPT"
fi
EOF
chmod +x "$FAKE_BIN/claude"
ln -s "$WRAPPER" "$SHIM_BIN/claude"

# ~/.config/git/config.local の `gh auth setup-git` 形の credential helper。呼ばれたら印を残す
HELPER_MARK="$TMPROOT/helper-called"
cat >"$FAKE_BIN/gh-credential" <<EOF
#!/bin/sh
printf called >"$HELPER_MARK"
printf 'username=x\npassword=y\n'
EOF
chmod +x "$FAKE_BIN/gh-credential"
# github.com 以外のホストの helper（osxkeychain 等に相当）。呼ばれたら印を残す
OTHER_HELPER_MARK="$TMPROOT/other-helper-called"
cat >"$FAKE_BIN/other-credential" <<EOF
#!/bin/sh
printf called >"$OTHER_HELPER_MARK"
printf 'username=x\npassword=y\n'
EOF
chmod +x "$FAKE_BIN/other-credential"
mkdir -p "$HOME_T/.config/git"
printf '[include]\n\tpath = config.local\n[credential "https://example.com"]\n\thelper = !%s\n' \
  "$FAKE_BIN/other-credential" >"$HOME_T/.config/git/config"
printf '[credential "https://github.com"]\n\thelper =\n\thelper = !%s auth git-credential\n' \
  "$FAKE_BIN/gh-credential" >"$HOME_T/.config/git/config.local"

printf '  tok_123\n' >"$TOKEN_FILE"
printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' >"$CA_BUNDLE"

# agent-vault の代わりに listen する。port は空きを OS に選ばせる
python3 -I -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(16)
print(s.getsockname()[1], flush=True)
time.sleep(600)
' >"$TMPROOT/port" &
LISTENER_PID=$!
for _ in $(seq 1 50); do
  [[ -s "$TMPROOT/port" ]] && break
  sleep 0.1
done
OPEN_PORT="$(cat "$TMPROOT/port")"
CLOSED_PORT="$(python3 -I -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

# run_wrapper [args...]
#   RUN_ENV (配列) で env を足す。結果は OUT / ERR / RC に入る。
RUN_ENV=()
run_wrapper() {
  set +e
  OUT="$(env -i HOME="$HOME_T" PATH="$SHIM_BIN:$FAKE_BIN:$UTIL_BIN" \
    AGENT_VAULT_PROXY_PORT="$OPEN_PORT" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "$SHIM_BIN/claude" "$@" 2>"$TMPROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMPROOT/err")"
}

echo "=== claude (agent-vault wrapper) tests ==="

# ---------------------------------------------------------------------------
# 1. token・CA bundle があり port が開いている → proxy と CA の env を付けて実体へ
# ---------------------------------------------------------------------------
RUN_ENV=()
run_wrapper --bg "do it"
if [[ $RC -eq 0 ]] &&
  contains "$OUT" "HTTPS_PROXY=http://tok_123:default@127.0.0.1:$OPEN_PORT" &&
  contains "$OUT" "HTTP_PROXY=http://tok_123:default@127.0.0.1:$OPEN_PORT" &&
  contains "$OUT" "NO_PROXY=localhost,127.0.0.1,::1" &&
  contains "$OUT" "NODE_EXTRA_CA_CERTS=$CA_BUNDLE" &&
  contains "$OUT" "SSL_CERT_FILE=$CA_BUNDLE" &&
  contains "$OUT" "GIT_SSL_CAINFO=$CA_BUNDLE" &&
  contains "$OUT" "CLAUDE_GH_VAULT=1" &&
  contains "$OUT" $'GIT_CONFIG_COUNT=3\ngit_config=credential.https://github.com.helper=\ngit_config=branch.autoSetupMerge=false\ngit_config=push.default=current\n' &&
  contains "$OUT" $'argc=2\narg=[--bg]\narg=[do it]' && [[ -z $ERR ]]; then
  pass "01_active_vault_sets_proxy_and_ca_env"
else
  fail "01_active_vault_sets_proxy_and_ca_env" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 2. AGENT_VAULT_VAULT で vault 名（proxy URL の password 部）を変えられる
# ---------------------------------------------------------------------------
RUN_ENV=("AGENT_VAULT_VAULT=work")
run_wrapper
if [[ $RC -eq 0 ]] && contains "$OUT" "HTTPS_PROXY=http://tok_123:work@127.0.0.1:$OPEN_PORT"; then
  pass "02_vault_name_override"
else
  fail "02_vault_name_override" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 3. HTTPS_PROXY が既にある（sandbox 内から呼んだ claude 等）→ 触らない
# ---------------------------------------------------------------------------
RUN_ENV=("HTTPS_PROXY=http://localhost:9999")
run_wrapper
if [[ $RC -eq 0 ]] && contains "$OUT" "HTTPS_PROXY=http://localhost:9999" &&
  contains "$OUT" "HTTP_PROXY=<unset>" && contains "$OUT" "SSL_CERT_FILE=<unset>" &&
  contains "$OUT" "CLAUDE_GH_VAULT=<unset>" && [[ -z $ERR ]]; then
  pass "03_preset_https_proxy_is_kept"
else
  fail "03_preset_https_proxy_is_kept" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 4. token ファイルが無い（agent-vault 未設定）→ env を付けず、警告も出さない
# ---------------------------------------------------------------------------
RUN_ENV=("AGENT_VAULT_PROXY_TOKEN_FILE=$TMPROOT/missing-token")
run_wrapper
if [[ $RC -eq 0 ]] && contains "$OUT" "HTTPS_PROXY=<unset>" &&
  contains "$OUT" "NODE_EXTRA_CA_CERTS=<unset>" && [[ -z $ERR ]]; then
  pass "04_no_token_file_passthrough"
else
  fail "04_no_token_file_passthrough" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 5. port が閉じている（agent-vault が落ちている）→ env を付けず、1 行警告
# ---------------------------------------------------------------------------
RUN_ENV=("AGENT_VAULT_PROXY_PORT=$CLOSED_PORT")
run_wrapper
if [[ $RC -eq 0 ]] && contains "$OUT" "HTTPS_PROXY=<unset>" && contains "$OUT" "CLAUDE_GH_VAULT=<unset>" &&
  contains "$OUT" $'GIT_CONFIG_COUNT=2\ngit_config=branch.autoSetupMerge=false\ngit_config=push.default=current\n' &&
  contains "$ERR" "not listening on 127.0.0.1:$CLOSED_PORT" &&
  contains "$ERR" "cannot authenticate to GitHub"; then
  pass "05_closed_port_passthrough_with_warning"
else
  fail "05_closed_port_passthrough_with_warning" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 6. CA bundle が無い（server がまだ CA を書いていない）→ env を付けず、1 行警告
# ---------------------------------------------------------------------------
RUN_ENV=("AGENT_VAULT_CA_BUNDLE=$TMPROOT/missing-ca.pem")
run_wrapper
if [[ $RC -eq 0 ]] && contains "$OUT" "HTTPS_PROXY=<unset>" &&
  contains "$ERR" "CA bundle not found: $TMPROOT/missing-ca.pem" &&
  contains "$ERR" "cannot authenticate to GitHub"; then
  pass "06_missing_ca_bundle_passthrough_with_warning"
else
  fail "06_missing_ca_bundle_passthrough_with_warning" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 7. PATH に実体が無い → 自分を再帰で呼ばずに 127
# ---------------------------------------------------------------------------
set +e
OUT="$(env -i HOME="$HOME_T" PATH="$SHIM_BIN:$UTIL_BIN" "$SHIM_BIN/claude" 2>"$TMPROOT/err")"
RC=$?
set -e
ERR="$(cat "$TMPROOT/err")"
if [[ $RC -eq 127 ]] && contains "$ERR" "real 'claude' not found"; then
  pass "07_missing_real_claude_exits_127"
else
  fail "07_missing_real_claude_exits_127" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 8. agent-vault 経由のセッションの git は github.com の credential helper（config.local の
#    gh auth git-credential）を呼ばず、他ホストの helper は呼ぶ。agent-vault が使えないときは従来どおり
# ---------------------------------------------------------------------------
REAL_GIT="$(command -v git)"
GIT_ENV=("FAKE_GIT=$REAL_GIT" "GIT_CONFIG_NOSYSTEM=1" "GIT_TERMINAL_PROMPT=0")
rm -f "$HELPER_MARK" "$OTHER_HELPER_MARK"
RUN_ENV=("${GIT_ENV[@]}")
run_wrapper
vault_called="no" vault_other="no"
[[ -e $HELPER_MARK ]] && vault_called="yes"
[[ -e $OTHER_HELPER_MARK ]] && vault_other="yes"
rm -f "$HELPER_MARK" "$OTHER_HELPER_MARK"
RUN_ENV=("${GIT_ENV[@]}" "AGENT_VAULT_PROXY_PORT=$CLOSED_PORT")
run_wrapper
plain_called="no"
[[ -e $HELPER_MARK ]] && plain_called="yes"
if [[ $vault_called == "no" && $vault_other == "yes" && $plain_called == "yes" ]]; then
  pass "08_vault_session_git_skips_only_github_credential_helper"
else
  fail "08_vault_session_git_skips_only_github_credential_helper" \
    "helper called: vault github=$vault_called (want no) vault other=$vault_other (want yes) no-vault github=$plain_called (want yes)"
fi

# ---------------------------------------------------------------------------
# 9. 既にある GIT_CONFIG_* は消さず、その後ろに積む
# ---------------------------------------------------------------------------
RUN_ENV=("GIT_CONFIG_COUNT=1" "GIT_CONFIG_KEY_0=safe.directory" "GIT_CONFIG_VALUE_0=/x")
run_wrapper
if [[ $RC -eq 0 ]] &&
  contains "$OUT" $'GIT_CONFIG_COUNT=4\ngit_config=safe.directory=/x\ngit_config=credential.https://github.com.helper=\ngit_config=branch.autoSetupMerge=false\ngit_config=push.default=current\n'; then
  pass "09_appends_to_existing_git_config_env"
else
  fail "09_appends_to_existing_git_config_env" "rc=$RC out=$OUT err=$ERR"
fi

# ---------------------------------------------------------------------------
# 10. セッション内の git は upstream を .git/config に書かない（sandbox が起動元 repo の .git/config を
#     write deny にするため）。origin/main から切った branch も、素の `git push origin` で同名 branch に届く
# ---------------------------------------------------------------------------
GW="$TMPROOT/gitwork"
mkdir -p "$GW"
cat >"$TMPROOT/git-upstream.sh" <<EOF
set -e
g() { "$REAL_GIT" -c user.name=t -c user.email=t@example.com "\$@"; }
cd "$GW"
g init -q --bare remote.git
g init -q -b main work
cd work
g commit -q --allow-empty -m init
g remote add origin ../remote.git
g push -q origin main
g worktree add -q -b feat ../wt origin/main
if g config --get branch.feat.merge >/dev/null; then echo upstream=set; else echo upstream=none; fi
cd ../wt
g commit -q --allow-empty -m feat
if g push -q origin 2>/dev/null; then echo push=ok; else echo push=failed; fi
if g --git-dir=../remote.git rev-parse -q --verify refs/heads/feat >/dev/null; then
  echo remote_feat=yes
else
  echo remote_feat=no
fi
EOF
RUN_ENV=("FAKE_GIT_SCRIPT=$TMPROOT/git-upstream.sh" "GIT_CONFIG_NOSYSTEM=1" "GIT_TERMINAL_PROMPT=0")
run_wrapper
if [[ $RC -eq 0 ]] && contains "$OUT" "upstream=none" && contains "$OUT" "push=ok" &&
  contains "$OUT" "remote_feat=yes"; then
  pass "10_session_git_writes_no_upstream_and_pushes_same_name"
else
  fail "10_session_git_writes_no_upstream_and_pushes_same_name" "rc=$RC out=$OUT err=$ERR"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
echo "PASS: claude (agent-vault wrapper)"
