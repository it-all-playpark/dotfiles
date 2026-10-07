#!/usr/bin/env bash
# agent-vault-server: launchd（gui ドメイン）から agent-vault server を起動する。
#
# なぜ要るか:
#   agent-vault の DB はマスターパスワードで暗号化されていて、起動のたびに渡す必要がある。
#   パスワードは login keychain に置き、ここで読んで --password-stdin で渡す（argv・env・ファイルに出さない）。
#   Keychain の解除は Aqua セッションでしか効かないので、gui ドメインの LaunchAgent から起動する（jev-broker と同じ）。
#
# server が立ったら MITM の CA 証明書を取り、システムの CA bundle と連結して AGENT_VAULT_CA_BUNDLE に書く。
# ~/.agent-vault（DB と CA 鍵）は sandbox から読めない（settings.json の denyRead）ので、
# sandbox 内のコマンドが信頼する CA は外に出す。claude-code/bin/claude がこの bundle を
# GIT_SSL_CAINFO / SSL_CERT_FILE / NODE_EXTRA_CA_CERTS に渡す。
#
# 環境変数（home-manager/programs/agent-vault.nix の launchd 定義が渡す）:
#   AGENT_VAULT_BIN               agent-vault の実体
#   AGENT_VAULT_KEYCHAIN_SERVICE  マスターパスワードの Keychain 項目（service）
#   AGENT_VAULT_KEYCHAIN_ACCOUNT  同（account）
#   AGENT_VAULT_CA_BUNDLE         書き出す CA bundle
#   SYSTEM_CA_BUNDLE              連結するシステムの CA bundle
#   AGENT_VAULT_SECURITY_BIN      既定 /usr/bin/security（テストで差し替える）
#   AGENT_VAULT_CA_WAIT_SECONDS   CA の取得を待つ秒数（既定 60）
set -euo pipefail

API_PORT=14321
PROXY_PORT=14322
SECURITY_BIN="${AGENT_VAULT_SECURITY_BIN:-/usr/bin/security}"

log() {
  printf '%s agent-vault-server: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

for v in AGENT_VAULT_BIN AGENT_VAULT_KEYCHAIN_SERVICE AGENT_VAULT_KEYCHAIN_ACCOUNT AGENT_VAULT_CA_BUNDLE SYSTEM_CA_BUNDLE; do
  if [ -z "${!v:-}" ]; then
    log "$v is not set"
    exit 2
  fi
done

# server が CA を出せるようになるまで待ち、システムの CA bundle に足して置き換える。
# 書き出しは一時ファイル経由（読み手が途中の bundle を掴まないように）
write_ca_bundle() {
  local ca="$AGENT_VAULT_CA_BUNDLE.ca.$$" tmp="$AGENT_VAULT_CA_BUNDLE.tmp.$$" i
  for ((i = 0; i < ${AGENT_VAULT_CA_WAIT_SECONDS:-60}; i++)); do
    if "$AGENT_VAULT_BIN" ca fetch --address "http://127.0.0.1:$API_PORT" -o "$ca" >/dev/null 2>&1 && [ -s "$ca" ]; then
      cat "$SYSTEM_CA_BUNDLE" "$ca" >"$tmp"
      mv -f "$tmp" "$AGENT_VAULT_CA_BUNDLE"
      rm -f "$ca"
      log "wrote CA bundle: $AGENT_VAULT_CA_BUNDLE"
      return 0
    fi
    sleep 1
  done
  rm -f "$ca" "$tmp"
  log "could not fetch the MITM CA from the server"
  return 1
}

if ! password="$("$SECURITY_BIN" find-generic-password -s "$AGENT_VAULT_KEYCHAIN_SERVICE" -a "$AGENT_VAULT_KEYCHAIN_ACCOUNT" -w)" || [ -z "$password" ]; then
  log "master password not found in keychain (service=$AGENT_VAULT_KEYCHAIN_SERVICE account=$AGENT_VAULT_KEYCHAIN_ACCOUNT)"
  exit 1
fi

mkdir -p "$(dirname "$AGENT_VAULT_CA_BUNDLE")"
write_ca_bundle &

exec "$AGENT_VAULT_BIN" server \
  --host 127.0.0.1 \
  --port "$API_PORT" \
  --mitm-port "$PROXY_PORT" \
  --password-stdin <<<"$password"
