#!/usr/bin/env bats
# tests/sandbox-pg.bats
# Unit tests for lib/sandbox-pg/sandbox-pg.sh (docker を stub して、組み立てる docker 引数と入力検証を確かめる)
# Run from the repo root: bats tests/sandbox-pg.bats
#
# sandbox-pg は docker CLI を「PATH 以外の環境変数を捨てて」呼ぶので、stub は環境変数ではなく
# STUB_DIR 内のファイルで振る舞いを切り替える（STUB_DIR のパスは stub 本体に埋め込む）。
#   container_state : container inspect の出力（無ければ No such container）
#   volume_label    : volume inspect の出力（無ければ no such volume）
#   daemon_down     : あれば全呼び出しが daemon 接続エラー
#   run_fail        : あれば run が失敗
# 記録: calls（1 呼び出し 1 行、printf %q）、run_env / run_stdin（run 時の環境変数と stdin）、psql_stdin（psql に流した SQL）

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/lib/sandbox-pg/sandbox-pg.sh"

setup() {
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-pg-test.XXXXXX")"
  STUB_DIR="${WORK_DIR}/stub"
  mkdir -p "${STUB_DIR}/bin"
  cat >"${STUB_DIR}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
S="${STUB_DIR}"
EOF
  cat >>"${STUB_DIR}/bin/docker" <<'EOF'
printf '%q ' "$@" >>"${S}/calls"
printf '\n' >>"${S}/calls"
if [ -e "${S}/daemon_down" ]; then
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
  exit 1
fi
case "$1 ${2:-}" in
  "container inspect")
    if [ -e "${S}/container_state" ]; then cat "${S}/container_state"; exit 0; fi
    echo "Error response from daemon: No such container: ${!#}" >&2
    exit 1
    ;;
  "volume inspect")
    if [ -e "${S}/volume_label" ]; then cat "${S}/volume_label"; exit 0; fi
    echo "Error response from daemon: get ${!#}: no such volume" >&2
    exit 1
    ;;
  "volume create" | "volume rm") echo "${!#}" ;;
  run\ *)
    env >"${S}/run_env"
    cat >"${S}/run_stdin"
    [ -e "${S}/run_fail" ] && { echo "port is already allocated" >&2; exit 125; }
    echo "0123456789abcdef"
    ;;
  exec\ *)
    case " $* " in
      *" psql "*) cat >"${S}/psql_stdin" ;;
    esac
    ;;
  *) ;;
esac
EOF
  chmod +x "${STUB_DIR}/bin/docker"
  export PATH="${STUB_DIR}/bin:${PATH}"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

run_pg() {
  run bash "${SCRIPT}" "$@"
}

calls() {
  cat "${STUB_DIR}/calls" 2>/dev/null || true
}

run_call() {
  grep '^run ' "${STUB_DIR}/calls"
}

# `! cmd` は bats の途中行では失敗にならないので、否定はこれで書く
refute() {
  if "$@"; then
    echo "expected to fail: $*" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 入力検証
# ---------------------------------------------------------------------------

@test "no args prints usage and exits 2" {
  run_pg
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"usage: sandbox-pg"* ]]
}

@test "unknown subcommand is rejected without calling docker" {
  for sub in run exec rm ps logs psql; do
    run_pg "${sub}" foo
    [ "${status}" -eq 2 ]
  done
  [ -z "$(calls)" ]
}

@test "invalid names are rejected without calling docker" {
  # shellcheck disable=SC2016 # 意図的に非展開: コマンド置換の文字列そのものを名前として渡す
  for name in "Foo" "a;b" "../x" "a b" 'a$(id)' "a/b" "a_b" "" "$(printf 'a%.0s' {1..33})"; do
    run_pg up "${name}"
    [ "${status}" -ne 0 ]
  done
  [ -z "$(calls)" ]
}

@test "32-char name is accepted" {
  run_pg up "$(printf 'a%.0s' {1..32})"
  [ "${status}" -eq 0 ]
}

@test "ports outside 54320-54399 or non-numeric are rejected" {
  for port in 54319 54400 5432 80 abc "54320;id" "-1" "054320" ""; do
    run_pg up foo --port "${port}"
    [ "${status}" -ne 0 ]
  done
  [ -z "$(calls)" ]
}

@test "extra or unknown arguments are rejected" {
  run_pg up foo --port 54321 --privileged
  [ "${status}" -eq 2 ]
  run_pg up foo --image evil:latest
  [ "${status}" -eq 2 ]
  run_pg url foo extra
  [ "${status}" -eq 2 ]
  run_pg down foo --all
  [ "${status}" -eq 2 ]
  [ -z "$(calls)" ]
}

# ---------------------------------------------------------------------------
# up（新規作成）で組み立てる docker 引数
# ---------------------------------------------------------------------------

@test "up uses the digest-pinned official postgres 17 image" {
  run_pg up foo
  [ "${status}" -eq 0 ]
  run_call | grep -Eq ' docker\.io/library/postgres:17@sha256:[0-9a-f]{64} $'
}

@test "up mounts no host directory, only the prefixed named volume" {
  run_pg up foo
  [ "${status}" -eq 0 ]
  local rc
  rc="$(run_call)"
  [[ "${rc}" != *"--volume"* ]]
  [[ "${rc}" != *" -v "* ]]
  [[ "${rc}" != *"type=bind"* ]]
  [[ "${rc}" != *"type=tmpfs"* ]]
  [ "$(grep -o -- '--mount' <<<"${rc}" | wc -l | tr -d ' ')" = "1" ]
  [[ "${rc}" == *"--mount type=volume\\,source=sandbox-pg-foo-data\\,target=/var/lib/postgresql/data "* ]]
  grep -q '^volume create --label sandbox-pg.managed=true sandbox-pg-foo-data' "${STUB_DIR}/calls"
}

@test "up publishes only on 127.0.0.1" {
  run_pg up foo --port 54321
  [ "${status}" -eq 0 ]
  local rc
  rc="$(run_call)"
  [[ "${rc}" == *"--publish 127.0.0.1:54321:5432 "* ]]
  [ "$(grep -o -- '--publish' <<<"${rc}" | wc -l | tr -d ' ')" = "1" ]
  [[ "${rc}" != *" -p "* ]]
  [[ "${rc}" != *"--network"* ]]
  [[ "${rc}" != *"--privileged"* ]]
  [[ "${rc}" == *"--security-opt no-new-privileges "* ]]
}

@test "up returns a non-superuser app URL and keeps the superuser password out of argv and output" {
  run_pg up foo
  [ "${status}" -eq 0 ]
  local url su_pw app_pw
  url="$(tail -n 1 <<<"${output}")"
  [[ "${url}" =~ ^postgresql://app:([0-9a-f]{48})@127\.0\.0\.1:54320/app$ ]]
  app_pw="${BASH_REMATCH[1]}"

  # superuser のパスワードは run の stdin（--env-file /dev/stdin）だけに載り、argv・環境変数・出力・SQL には出ない
  [ "$(wc -l <"${STUB_DIR}/run_stdin" | tr -d ' ')" = "1" ]
  su_pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "${STUB_DIR}/run_stdin")"
  [[ "${su_pw}" =~ ^[0-9a-f]{48}$ ]]
  [ "${su_pw}" != "${app_pw}" ]
  [[ "$(run_call)" == *"--env-file /dev/stdin "* ]]
  refute grep -qE -- '(--env|-e) ' <<<"$(run_call | sed 's#--env-file /dev/stdin ##')"
  refute grep -q "${su_pw}" "${STUB_DIR}/calls"
  refute grep -q "${su_pw}" "${STUB_DIR}/run_env"
  [[ "${output}" != *"${su_pw}"* ]]
  refute grep -q "${su_pw}" "${STUB_DIR}/psql_stdin"

  # URL のパスワードは app ロールに設定したもの（ラベルにも同じ値）
  grep -q "ALTER ROLE app WITH LOGIN NOSUPERUSER NOCREATEROLE CREATEDB NOREPLICATION NOBYPASSRLS PASSWORD '${app_pw}';" "${STUB_DIR}/psql_stdin"
  [[ "$(run_call)" == *"--label sandbox-pg.app-password=${app_pw} "* ]]
}

@test "up bootstrap SQL drops server-file/program roles and disables superuser TCP login" {
  run_pg up foo
  [ "${status}" -eq 0 ]
  grep -q '^REVOKE pg_execute_server_program, pg_read_server_files, pg_write_server_files FROM app;$' "${STUB_DIR}/psql_stdin"
  grep -q '^ALTER ROLE postgres PASSWORD NULL;$' "${STUB_DIR}/psql_stdin"
  grep -q "CREATE DATABASE app OWNER app" "${STUB_DIR}/psql_stdin"
  refute grep -qi 'SUPERUSER PASSWORD\|GRANT pg_\|WITH SUPERUSER' "${STUB_DIR}/psql_stdin"
  grep -q '^exec -i -u postgres sandbox-pg-foo psql ' "${STUB_DIR}/calls"
}

@test "docker is called with a fixed environment regardless of the caller's DOCKER_* vars" {
  DOCKER_HOST="tcp://evil.example:2375" DOCKER_CONTEXT="evil" DOCKER_CONFIG="${WORK_DIR}/evil" \
    BASH_ENV="${WORK_DIR}/evil.sh" FOO_SECRET=leak run_pg up foo
  [ "${status}" -eq 0 ]
  grep -qx 'DOCKER_HOST=unix:///var/run/docker.sock' "${STUB_DIR}/run_env"
  grep -qx 'DOCKER_CONFIG=/var/empty' "${STUB_DIR}/run_env"
  grep -qx 'HOME=/var/empty' "${STUB_DIR}/run_env"
  # 渡すのは固定の 4 つだけ（PWD / SHLVL / _ は stub の bash 自身が足す）
  local names
  names="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${STUB_DIR}/run_env" | tr -d '=' | sort | tr '\n' ' ')"
  refute grep -qvxE 'PATH|DOCKER_HOST|DOCKER_CONFIG|HOME|PWD|OLDPWD|SHLVL|_' <<<"$(tr ' ' '\n' <<<"${names}" | sed '/^$/d')"
}

@test "every container/volume name touched has the sandbox-pg- prefix" {
  run_pg up foo
  [ "${status}" -eq 0 ]
  echo "container_state" >/dev/null
  printf 'true|true|54320|%s\n' "$(printf 'a%.0s' {1..48})" >"${STUB_DIR}/container_state"
  echo "true" >"${STUB_DIR}/volume_label"
  run_pg down foo
  [ "${status}" -eq 0 ]
  # 各呼び出しの最後の引数（対象名）か --name の値を集めて、プレフィクス外が無いことを見る
  local targets
  targets="$(grep -E '^(container inspect|volume inspect|volume create|volume rm|rm|start) ' "${STUB_DIR}/calls" | awk '{print $NF}')"
  [ -n "${targets}" ]
  refute grep -v '^sandbox-pg-foo\(-data\)\?$' <<<"${targets}"
  grep -q -- '--name sandbox-pg-foo ' "${STUB_DIR}/calls"
}

@test "up fails when the run fails and cleans only its own container" {
  touch "${STUB_DIR}/run_fail"
  run_pg up foo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"failed to start sandbox-pg-foo"* ]]
  # container_state は存在しない（stub）ので、他人のコンテナを rm しない
  refute grep -q '^rm ' "${STUB_DIR}/calls"
}

# ---------------------------------------------------------------------------
# 既存インスタンス・管理外リソース
# ---------------------------------------------------------------------------

@test "up on a running managed instance just prints its URL" {
  local pw
  pw="$(printf 'b%.0s' {1..48})"
  printf 'true|true|54333|%s\n' "${pw}" >"${STUB_DIR}/container_state"
  run_pg up foo
  [ "${status}" -eq 0 ]
  [ "${output}" = "postgresql://app:${pw}@127.0.0.1:54333/app" ]
  refute grep -q '^run ' "${STUB_DIR}/calls"
}

@test "up on a stopped managed instance starts it and re-applies the role bootstrap" {
  local pw
  pw="$(printf 'c%.0s' {1..48})"
  printf 'true|false|54320|%s\n' "${pw}" >"${STUB_DIR}/container_state"
  run_pg up foo
  [ "${status}" -eq 0 ]
  grep -q '^start sandbox-pg-foo $' "${STUB_DIR}/calls"
  grep -q "PASSWORD '${pw}'" "${STUB_DIR}/psql_stdin"
  refute grep -q '^run ' "${STUB_DIR}/calls"
}

@test "up with a different port on an existing instance is rejected" {
  printf 'true|true|54320|%s\n' "$(printf 'a%.0s' {1..48})" >"${STUB_DIR}/container_state"
  run_pg up foo --port 54321
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already uses port 54320"* ]]
}

@test "up refuses an unmanaged container with the same name" {
  echo '<no value>|true|<no value>|<no value>' >"${STUB_DIR}/container_state"
  run_pg up foo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not managed by sandbox-pg"* ]]
  refute grep -qE '^(run|rm|start|exec) ' "${STUB_DIR}/calls"
}

@test "up refuses an unmanaged volume with the same name" {
  echo '<no value>' >"${STUB_DIR}/volume_label"
  run_pg up foo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"volume sandbox-pg-foo-data exists but is not managed"* ]]
  refute grep -qE '^(run|volume create) ' "${STUB_DIR}/calls"
}

@test "down removes the managed container and volume" {
  printf 'true|true|54320|%s\n' "$(printf 'a%.0s' {1..48})" >"${STUB_DIR}/container_state"
  echo "true" >"${STUB_DIR}/volume_label"
  run_pg down foo
  [ "${status}" -eq 0 ]
  grep -q '^rm --force --volumes sandbox-pg-foo $' "${STUB_DIR}/calls"
  grep -q '^volume rm sandbox-pg-foo-data $' "${STUB_DIR}/calls"
}

@test "down refuses an unmanaged container and removes nothing" {
  echo '<no value>|true|<no value>|<no value>' >"${STUB_DIR}/container_state"
  echo "true" >"${STUB_DIR}/volume_label"
  run_pg down foo
  [ "${status}" -ne 0 ]
  refute grep -qE '^(rm|volume rm) ' "${STUB_DIR}/calls"
}

@test "down refuses an unmanaged volume" {
  echo '<no value>' >"${STUB_DIR}/volume_label"
  run_pg down foo
  [ "${status}" -ne 0 ]
  refute grep -q '^volume rm ' "${STUB_DIR}/calls"
}

@test "down on a missing instance is a no-op" {
  run_pg down foo
  [ "${status}" -eq 0 ]
  refute grep -qE '^(rm|volume rm) ' "${STUB_DIR}/calls"
}

@test "url prints the URL of a running managed instance" {
  local pw
  pw="$(printf 'd%.0s' {1..48})"
  printf 'true|true|54399|%s\n' "${pw}" >"${STUB_DIR}/container_state"
  run_pg url foo
  [ "${status}" -eq 0 ]
  [ "${output}" = "postgresql://app:${pw}@127.0.0.1:54399/app" ]
}

@test "url rejects a stopped, missing, or unmanaged instance" {
  run_pg url foo
  [ "${status}" -ne 0 ]
  printf 'true|false|54320|%s\n' "$(printf 'a%.0s' {1..48})" >"${STUB_DIR}/container_state"
  run_pg url foo
  [ "${status}" -ne 0 ]
  echo '<no value>|true|<no value>|<no value>' >"${STUB_DIR}/container_state"
  run_pg url foo
  [ "${status}" -ne 0 ]
}

@test "url rejects malformed labels instead of printing them" {
  printf 'true|true|54320|%s\n' "x@evil.example:1/" >"${STUB_DIR}/container_state"
  run_pg url foo
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"evil.example"*"postgresql://"* ]]
}

@test "daemon errors are reported, not treated as a missing instance" {
  touch "${STUB_DIR}/daemon_down"
  run_pg url foo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Cannot connect to the Docker daemon"* ]]
  run_pg up foo
  [ "${status}" -ne 0 ]
  refute grep -q '^run ' "${STUB_DIR}/calls"
  run_pg down foo
  [ "${status}" -ne 0 ]
}

# ---------------------------------------------------------------------------
# nix パッケージ
# ---------------------------------------------------------------------------

@test "nix package pins PATH to runtimeInputs" {
  grep -q 'inheritPath = false;' "${REPO_ROOT}/lib/sandbox-pg/default.nix"
  grep -q 'callPackage ./sandbox-pg { }' "${REPO_ROOT}/lib/cli-packages.nix"
}
