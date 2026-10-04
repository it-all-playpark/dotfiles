#!/usr/bin/env bash
# sandbox-pg: 決まった Postgres コンテナを docker で起動・停止するだけの固定目的コマンド。
#
# Claude Code の sandbox から docker socket は使えない（socket を開けると API 全体＝ホスト権限を渡す）。
# このコマンドは settings.json の excludedCommands で sandbox 外で動くので、受け付ける入力を
# 「インスタンス名・ポート・サブコマンド」に絞り、それ以外の docker 操作をできないようにしている:
#   - イメージは digest 固定の公式 postgres 17。任意のイメージ・コマンド・docker 引数は受け付けない
#   - ホストのディレクトリは mount しない（データは名前付き volume）。ポートは 127.0.0.1 にだけ publish
#   - sandbox に渡すのは非 superuser の app ロールの URL だけ。superuser のパスワードはランダム生成して
#     どこにも出さず、初期化後に NULL にして TCP からはログインできなくする
#     （superuser は COPY ... TO PROGRAM でコンテナ内の任意実行ができ、コンテナの外向き通信が
#     sandbox の通信制限の抜け道になるため）
#   - 触るのは sandbox-pg- プレフィクスかつ管理ラベル付きのコンテナ・volume だけ
#   - docker CLI に渡す環境変数は固定（DOCKER_HOST / DOCKER_CONFIG などを呼び出し側から差し替えさせない）
#
# 使い方:
#   sandbox-pg up <name> [--port <port>]   起動して接続 URL を stdout に出す（起動済みなら URL を出すだけ）
#   sandbox-pg url <name>                  起動中のインスタンスの接続 URL を出す
#   sandbox-pg down <name>                 コンテナと volume を削除する（データは残らない）

set -euo pipefail

readonly IMAGE="docker.io/library/postgres:17@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f"
readonly PREFIX="sandbox-pg-"
readonly LABEL="sandbox-pg.managed"
readonly LABEL_PORT="sandbox-pg.port"
readonly LABEL_PASSWORD="sandbox-pg.app-password"
readonly APP_ROLE="app"
readonly APP_DB="app"
readonly DEFAULT_PORT=54320
readonly PORT_MIN=54320
readonly PORT_MAX=54399
readonly READY_TIMEOUT_SEC=60

usage() {
  cat >&2 <<EOF
usage: sandbox-pg up <name> [--port <port>]
       sandbox-pg url <name>
       sandbox-pg down <name>

  <name>  ^[a-z0-9-]{1,32}\$
  <port>  ${PORT_MIN}-${PORT_MAX} (default ${DEFAULT_PORT}), published on 127.0.0.1 only
EOF
  exit 2
}

die() {
  echo "sandbox-pg: $*" >&2
  exit 1
}

# docker CLI を固定の環境変数だけで呼ぶ。呼び出し側の DOCKER_HOST / DOCKER_CONTEXT / DOCKER_CONFIG
# （cli-plugins や hooks を読む）などを継承しない。PATH は nix の wrapper が runtimeInputs だけに固定している。
# superuser のパスワードは argv にも環境変数にも載せず、run の --env-file /dev/stdin で渡す。
dk() {
  env -i PATH="${PATH}" DOCKER_HOST="unix:///var/run/docker.sock" DOCKER_CONFIG="/var/empty" HOME="/var/empty" \
    docker "$@"
}

validate_name() {
  [[ ${1:-} =~ ^[a-z0-9-]{1,32}$ ]] || die 'invalid name: must match ^[a-z0-9-]{1,32}$'
}

validate_port() {
  [[ ${1:-} =~ ^[0-9]{5}$ ]] || die "invalid port: must be ${PORT_MIN}-${PORT_MAX}"
  ((10#$1 >= PORT_MIN && 10#$1 <= PORT_MAX)) || die "invalid port: must be ${PORT_MIN}-${PORT_MAX}"
}

random_hex() {
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
}

# inspect の結果を出す。対象が無ければ空、daemon に繋がらない等それ以外の失敗は止める。
inspect_or_empty() {
  local out
  if out="$(dk "$@" 2>&1)"; then
    echo "${out}"
  elif [[ ${out,,} != *"no such"* ]]; then
    die "docker $1 inspect failed: ${out}"
  fi
}

# コンテナの "<managed>|<running>|<port>|<password>" を出す。存在しなければ空。
container_state() {
  inspect_or_empty container inspect --format \
    "{{index .Config.Labels \"${LABEL}\"}}|{{.State.Running}}|{{index .Config.Labels \"${LABEL_PORT}\"}}|{{index .Config.Labels \"${LABEL_PASSWORD}\"}}" \
    "$1"
}

# volume の管理ラベルの値を出す（管理下なら true）。存在しなければ空。
volume_managed() {
  inspect_or_empty volume inspect --format "{{index .Labels \"${LABEL}\"}}" "$1"
}

print_url() {
  local port="$1" password="$2"
  [[ ${port} =~ ^[0-9]{5}$ ]] || die "unexpected port label"
  [[ ${password} =~ ^[0-9a-f]{48}$ ]] || die "unexpected app password label"
  echo "postgresql://${APP_ROLE}:${password}@127.0.0.1:${port}/${APP_DB}"
}

wait_ready() {
  local container="$1" i
  # 初期化中の一時サーバーは unix socket でしか待ち受けないので、TCP で応答したら本起動済み
  for ((i = 0; i < READY_TIMEOUT_SEC; i++)); do
    if dk exec "${container}" pg_isready -q -h 127.0.0.1 -p 5432 -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "${container} did not become ready within ${READY_TIMEOUT_SEC}s"
}

# app ロール（非 superuser・DB owner）を用意し、superuser の TCP ログインを塞ぐ。何度流しても同じ結果になる。
bootstrap_roles() {
  local container="$1" password="$2"
  dk exec -i -u postgres "${container}" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
SET client_min_messages = error;
SELECT 'CREATE ROLE ${APP_ROLE} LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_ROLE}')\gexec
ALTER ROLE ${APP_ROLE} WITH LOGIN NOSUPERUSER NOCREATEROLE CREATEDB NOREPLICATION NOBYPASSRLS PASSWORD '${password}';
REVOKE pg_execute_server_program, pg_read_server_files, pg_write_server_files FROM ${APP_ROLE};
SELECT 'CREATE DATABASE ${APP_DB} OWNER ${APP_ROLE}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${APP_DB}')\gexec
ALTER DATABASE ${APP_DB} OWNER TO ${APP_ROLE};
ALTER ROLE postgres PASSWORD NULL;
SQL
}

cmd_up() {
  local name="$1" port="$2"
  local container="${PREFIX}${name}" volume="${PREFIX}${name}-data"
  local state managed running label_port password vol

  state="$(container_state "${container}")"
  if [ -n "${state}" ]; then
    IFS='|' read -r managed running label_port password <<<"${state}"
    [ "${managed}" = "true" ] || die "${container} exists but is not managed by sandbox-pg; refusing to touch it"
    if [ -n "${port}" ] && [ "${label_port}" != "${port}" ]; then
      die "${container} already uses port ${label_port}; run 'sandbox-pg down ${name}' first to change it"
    fi
    port="${label_port}"
    if [ "${running}" != "true" ]; then
      echo "sandbox-pg: starting ${container}" >&2
      dk start "${container}" >/dev/null
      wait_ready "${container}"
      bootstrap_roles "${container}" "${password}"
    fi
    print_url "${port}" "${password}"
    return 0
  fi

  vol="$(volume_managed "${volume}")"
  case "${vol}" in
  true) ;;
  "") dk volume create --label "${LABEL}=true" "${volume}" >/dev/null ;;
  *) die "volume ${volume} exists but is not managed by sandbox-pg; refusing to touch it" ;;
  esac

  port="${port:-${DEFAULT_PORT}}"
  password="$(random_hex)"
  echo "sandbox-pg: creating ${container} on 127.0.0.1:${port}" >&2
  if ! dk run --detach \
    --name "${container}" \
    --label "${LABEL}=true" \
    --label "${LABEL_PORT}=${port}" \
    --label "${LABEL_PASSWORD}=${password}" \
    --env-file /dev/stdin \
    --publish "127.0.0.1:${port}:5432" \
    --mount "type=volume,source=${volume},target=/var/lib/postgresql/data" \
    --security-opt no-new-privileges \
    --pids-limit 512 \
    --restart no \
    "${IMAGE}" >/dev/null <<<"POSTGRES_PASSWORD=$(random_hex)"; then
    # 作りかけ（ポート衝突など）を片付ける。名前を先に取られていた場合は触らない
    state="$(container_state "${container}")"
    if [[ ${state} == "true|"* ]]; then
      dk rm --force "${container}" >/dev/null 2>&1 || true
    fi
    die "failed to start ${container}"
  fi
  wait_ready "${container}"
  bootstrap_roles "${container}" "${password}"
  print_url "${port}" "${password}"
}

cmd_url() {
  local name="$1"
  local container="${PREFIX}${name}"
  local state managed running label_port password

  state="$(container_state "${container}")"
  [ -n "${state}" ] || die "${container} does not exist; run 'sandbox-pg up ${name}'"
  IFS='|' read -r managed running label_port password <<<"${state}"
  [ "${managed}" = "true" ] || die "${container} exists but is not managed by sandbox-pg"
  [ "${running}" = "true" ] || die "${container} is not running; run 'sandbox-pg up ${name}'"
  print_url "${label_port}" "${password}"
}

cmd_down() {
  local name="$1"
  local container="${PREFIX}${name}" volume="${PREFIX}${name}-data"
  local state managed vol

  state="$(container_state "${container}")"
  if [ -n "${state}" ]; then
    IFS='|' read -r managed _ <<<"${state}"
    [ "${managed}" = "true" ] || die "${container} exists but is not managed by sandbox-pg; refusing to touch it"
    dk rm --force --volumes "${container}" >/dev/null
    echo "sandbox-pg: removed ${container}" >&2
  fi

  vol="$(volume_managed "${volume}")"
  case "${vol}" in
  true)
    dk volume rm "${volume}" >/dev/null
    echo "sandbox-pg: removed ${volume}" >&2
    ;;
  "") ;;
  *) die "volume ${volume} exists but is not managed by sandbox-pg; refusing to touch it" ;;
  esac
}

main() {
  [ "$#" -ge 2 ] || usage
  local sub="$1" name="$2"
  shift 2
  validate_name "${name}"

  case "${sub}" in
  up)
    # --port 省略時は既存インスタンスのポート、無ければ DEFAULT_PORT
    local port=""
    if [ "$#" -gt 0 ]; then
      [ "$#" -eq 2 ] && [ "$1" = "--port" ] || usage
      validate_port "$2"
      port="$((10#$2))"
    fi
    cmd_up "${name}" "${port}"
    ;;
  url)
    [ "$#" -eq 0 ] || usage
    cmd_url "${name}"
    ;;
  down)
    [ "$#" -eq 0 ] || usage
    cmd_down "${name}"
    ;;
  *) usage ;;
  esac
}

main "$@"
