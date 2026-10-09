#!/usr/bin/env bash
# agent-vault-managed-env: claude-code/bin/claude（wrapper）が付ける env を、Claude Code の managed settings の
# drop-in（managed-settings.d/50-agent-vault.json）に書き出す。launchd（system ドメイン、root）から
# RunAtLoad・StartInterval・WatchPaths（token ファイルと CA bundle）で起動する（darwin/agent-vault.nix）。
#
# なぜ要るか:
#   Desktop の Code タブ・scheduled task・IDE が起動する claude は PATH の wrapper を通らないので、
#   HTTPS_PROXY も CLAUDE_GH_VAULT も付かず、sandbox 内の git / gh が GitHub に認証できない。
#   ファイルの managed settings はどの起動でも読まれ、変更は起動中のセッションにも反映される。
#
# 判定と出力は wrapper と同じ:
#   token ファイルが空でなく、CA bundle が空でなく、127.0.0.1:<port> が listen している → proxy・CA・
#   CLAUDE_GH_VAULT と GIT_CONFIG_*（0: github.com の credential helper を空、1: branch.autoSetupMerge=false、
#   2: push.default=current）。それ以外 → GIT_CONFIG_*（0: branch.autoSetupMerge=false、1: push.default=current）
#   だけ。index は GIT_CONFIG_COUNT が無い状態で wrapper を起動したときと同じにする（wrapper 経由の CLI では
#   managed の値が同じ値で上書きするだけになる）。
#   HTTPS_PROXY を固定で書くと、agent-vault が落ちている間は本体の通信（api.anthropic.com 等）も止まるので、
#   毎回 port を確かめて書き換える（fail-open）。
#
# あわせて、settings.json の sandbox.excludedCommands のうち ~/ を含むエントリを対象ユーザーのホームに展開し、
# 別の drop-in（managed-settings.d/60-home-paths.json）に書く。excludedCommands は Claude が打ったコマンド文字列と
# そのまま照合する（~ / $HOME を展開しない）ので、絶対パスで呼ばれるスクリプトには絶対パスのエントリが要る。
# settings.json は全ユーザー共通なので ~/ で書き、ユーザーごとの絶対パスはここで作る。excludedCommands は設定元を
# またいで連結され、managed は信頼される設定元なので、settings.json に直書きしたのと同じに効く。
# settings.json はユーザーが書けるので、開いたファイルが対象ユーザーの通常ファイルのときだけ読む（token と同じ）。
# JSON として壊れている（git 操作の途中など）ときは前回の drop-in を残し、settings.json が無い・対象ユーザーの
# ファイルでないときは drop-in を消す（sandbox 外で動かす許可を settings.json の実態より長く残さない）。
#
# 書き出し: 同じ dir の一時ファイル（名前が .json で終わらないので読まれない）に書き、root:wheel 0640 + 対象ユーザーだけの
# 読み取り ACL にしてから mv で置き換える（壊れた JSON の drop-in があると Claude Code は起動しない）。内容が同じなら書き換えない。
# proxy token は argv に出さない（root のプロセスの argv は他のユーザーからも見える）。jq には env で渡す。
#
# 環境変数（darwin/agent-vault.nix の launchd 定義が渡す。テスト・一時上書き用。名前と既定値は wrapper と同じ）:
#   AGENT_VAULT_PROXY_TOKEN_FILE  既定 $HOME/.agent-vault/proxy-token
#   AGENT_VAULT_CA_BUNDLE         既定 $HOME/.local/state/agent-vault/ca-bundle.pem
#   AGENT_VAULT_PROXY_PORT        既定 14322
#   AGENT_VAULT_VAULT             既定 default
#   AGENT_VAULT_TOKEN_OWNER       token ファイルの所有者でなければならないユーザー（既定 実行ユーザー）
#   AGENT_VAULT_MANAGED_SETTINGS  書き出す drop-in（既定 /Library/Application Support/ClaudeCode/managed-settings.d/50-agent-vault.json）
#   CLAUDE_USER_SETTINGS          ~/ を展開する settings.json（既定 $HOME/.claude/settings.json）
#   CLAUDE_USER_HOME              ~/ の展開先（既定 $HOME）
#   CLAUDE_HOME_PATHS_MANAGED_SETTINGS  書き出す drop-in（既定 AGENT_VAULT_MANAGED_SETTINGS と同じ dir の 60-home-paths.json）
set -euo pipefail

token_file="${AGENT_VAULT_PROXY_TOKEN_FILE:-$HOME/.agent-vault/proxy-token}"
ca_bundle="${AGENT_VAULT_CA_BUNDLE:-$HOME/.local/state/agent-vault/ca-bundle.pem}"
port="${AGENT_VAULT_PROXY_PORT:-14322}"
vault="${AGENT_VAULT_VAULT:-default}"
token_owner="${AGENT_VAULT_TOKEN_OWNER:-$(id -un)}"
out="${AGENT_VAULT_MANAGED_SETTINGS:-/Library/Application Support/ClaudeCode/managed-settings.d/50-agent-vault.json}"

log() {
  printf '%s agent-vault-managed-env: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

token=""
# root で動くので、token ファイルは対象ユーザーが所有する通常ファイルのときだけ読む。
# ユーザーが書ける場所にあるので、root 専用ファイルへの symlink にされると中身が drop-in（ユーザーが読める）に漏れる。
# パスで検査してから読むと間に差し替えられる（TOCTOU）ので、先に fd を開き、その fd の種別・所有者を確かめて
# 同じ fd から読む（/dev/fd/N の stat は開いた先のファイルを返す）。開く前の -f は FIFO で open が止まるのを避けるため。
owner_uid="$(id -u "$token_owner")"
if [ ! -L "$token_file" ] && [ -f "$token_file" ] && exec 3<"$token_file"; then
  if [ "$(/usr/bin/stat -f '%u %HT' /dev/fd/3)" = "$owner_uid Regular File" ]; then
    token="$(tr -d '[:space:]' <&3)"
  fi
  exec 3<&-
fi

if [ -n "$token" ] && [ -s "$ca_bundle" ] && (: <>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  state="with agent-vault"
  # shellcheck disable=SC2016 # 意図的: jq の式（$ENV は jq が展開する）
  filter='{env: {
    HTTPS_PROXY: $ENV.MANAGED_PROXY,
    HTTP_PROXY: $ENV.MANAGED_PROXY,
    NO_PROXY: "localhost,127.0.0.1,::1",
    NODE_EXTRA_CA_CERTS: $ENV.MANAGED_CA_BUNDLE,
    SSL_CERT_FILE: $ENV.MANAGED_CA_BUNDLE,
    GIT_SSL_CAINFO: $ENV.MANAGED_CA_BUNDLE,
    CLAUDE_GH_VAULT: "1",
    GIT_CONFIG_COUNT: "3",
    GIT_CONFIG_KEY_0: "credential.https://github.com.helper",
    GIT_CONFIG_VALUE_0: "",
    GIT_CONFIG_KEY_1: "branch.autoSetupMerge",
    GIT_CONFIG_VALUE_1: "false",
    GIT_CONFIG_KEY_2: "push.default",
    GIT_CONFIG_VALUE_2: "current"
  }}'
else
  state="without agent-vault"
  filter='{env: {
    GIT_CONFIG_COUNT: "2",
    GIT_CONFIG_KEY_0: "branch.autoSetupMerge",
    GIT_CONFIG_VALUE_0: "false",
    GIT_CONFIG_KEY_1: "push.default",
    GIT_CONFIG_VALUE_1: "current"
  }}'
fi

tmps=()
trap 'rm -f ${tmps[@]+"${tmps[@]}"}' EXIT

# new_tmp <drop-in>: 同じ dir に一時ファイルを作り TMP に入れる
new_tmp() {
  local dir
  dir="$(dirname "$1")"
  mkdir -p "$dir"
  TMP="$(mktemp "$dir/.$(basename "$1").XXXXXX")"
  tmps+=("$TMP")
}

# install_dropin <tmp> <drop-in> <state>: 内容が同じなら何もしない。違えば権限を整えて置き換える
install_dropin() {
  if [ -f "$2" ] && cmp -s "$1" "$2"; then
    return 0
  fi
  # macOS の標準ユーザーは全員 primary group が staff なので、group は wheel にして対象ユーザーだけに ACL で読ませる。
  # ACL は BSD の chmod でしか付けられない（nix の coreutils の chmod は +a を知らない）ので絶対パスで呼ぶ。
  chmod 0640 "$1"
  chown root:wheel "$1"
  /bin/chmod +a "user:$token_owner allow read" "$1"
  mv -f "$1" "$2"
  log "wrote $2 ($3)"
}

new_tmp "$out"
tmp="$TMP"

MANAGED_PROXY="http://$token:$vault@127.0.0.1:$port" MANAGED_CA_BUNDLE="$ca_bundle" \
  jq -n "$filter" >"$tmp"
unset token
install_dropin "$tmp" "$out" "$state"

settings="${CLAUDE_USER_SETTINGS:-$HOME/.claude/settings.json}"
user_home="${CLAUDE_USER_HOME:-$HOME}"
paths_out="${CLAUDE_HOME_PATHS_MANAGED_SETTINGS:-$(dirname "$out")/60-home-paths.json}"

# remove_paths_dropin <reason>: settings.json を読めないときは drop-in を消す（sandbox 外で動かす許可なので、
# settings.json を消した・差し替えたあとまで前回の内容を効かせない）
remove_paths_dropin() {
  if [ -e "$paths_out" ]; then
    rm -f "$paths_out"
    log "removed $paths_out: $1"
  fi
}

# settings.json は repo への symlink なのでたどる。開いた先が対象ユーザーの通常ファイルかを fd で確かめる
if [ -f "$settings" ] && exec 4<"$settings"; then
  if [ "$(/usr/bin/stat -f '%u %HT' /dev/fd/4)" = "$owner_uid Regular File" ]; then
    new_tmp "$paths_out"
    # shellcheck disable=SC2016 # 意図的: jq の式（$home は jq の変数）
    if jq --arg home "$user_home" '{sandbox: {excludedCommands: [
      .sandbox.excludedCommands[]? | strings | select(test("(^| )~/"))
      | sub("(?<p>^| )~/"; "\(.p)\($home)/")]}}' <&4 >"$TMP"; then
      install_dropin "$TMP" "$paths_out" "excludedCommands from $settings"
    else
      log "skipped $paths_out: $settings is not valid JSON"
    fi
  else
    remove_paths_dropin "$settings is not a regular file owned by $token_owner"
  fi
  exec 4<&-
else
  remove_paths_dropin "$settings is missing"
fi
