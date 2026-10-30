#!/usr/bin/env bash
# docker-vm（home-manager/programs/sandbox-docker.nix）の本体。受けた引数（先頭の --host 等のグローバルオプションを
# 含む）を変えずに docker へ exec する。build（build / buildx build / image build）のときは、その前に Dockerfile が
# 参照するイメージ（# syntax=・FROM・COPY --from・RUN --mount の from）のうち `image inspect` で見つからないもの
# （--platform 指定時はすべて）を、
# 同じグローバルオプション（同じ接続先）と同じ環境（DOCKER_CONFIG）で pull しておく。
# BuildKit はレジストリのトークンを session の auth provider、つまり Mac 側の docker CLI で取りにいく。その証明書の
# 検証は sandbox から閉じてある macOS の trustd に回るので、手元に無いイメージを使う build は sandbox 内で落ちる。
# pull なら VM の dockerd がトークンを取るので通る。
# Dockerfile は repo の中身で信用しない入力として扱う: 読んだ参照は eval せず、1 つの引数として docker に渡す。
# 決められないもの（stdin・URL の context、読めない Dockerfile）は何もせず渡す。compose の build は拾わない
set -uo pipefail

warn() {
  echo "docker-vm: $*" >&2
}

args=("$@")
n="${#args[@]}"
i=0

# 1. サブコマンドより前のグローバルオプション。inspect / pull にも同じものを付ける
global=()
while [ "${i}" -lt "${n}" ]; do
  case "${args[i]}" in
  -H | --host | -c | --context | --config | -l | --log-level | --tlscacert | --tlscert | --tlskey)
    global+=("${args[i]}" "${args[i + 1]-}")
    i=$((i + 2))
    ;;
  -*)
    global+=("${args[i]}")
    i=$((i + 1))
    ;;
  *) break ;;
  esac
done

case "${args[i]-}" in
build) i=$((i + 1)) ;;
buildx | image)
  if [ "${args[i + 1]-}" != build ]; then
    exec docker "$@"
  fi
  i=$((i + 2))
  ;;
*) exec docker "$@" ;;
esac

# 2. build のオプション。値を取るものは値を読み飛ばし、残りの非オプションを context とする
dockerfile=""
platform=""
pull=0
contexts=()
build_args=()
named_contexts=()
while [ "${i}" -lt "${n}" ]; do
  a="${args[i]}"
  v="${args[i + 1]-}"
  i=$((i + 1))
  case "${a}" in
  --)
    contexts+=("${args[@]:i}")
    break
    ;;
  -f | --file)
    dockerfile="${v}"
    i=$((i + 1))
    ;;
  --file=*) dockerfile="${a#*=}" ;;
  -f?*) dockerfile="${a#-f}" ;;
  --platform)
    platform="${v}"
    i=$((i + 1))
    ;;
  --platform=*) platform="${a#*=}" ;;
  --build-arg)
    build_args+=("${v}")
    i=$((i + 1))
    ;;
  --build-arg=*) build_args+=("${a#*=}") ;;
  --build-context)
    named_contexts+=("${v%%=*}")
    i=$((i + 1))
    ;;
  --build-context=*)
    v="${a#*=}"
    named_contexts+=("${v%%=*}")
    ;;
  --pull | --pull=*)
    case "${a}" in
    --pull=false | --pull=0) ;;
    *) pull=1 ;;
    esac
    ;;
  --add-host | --allow | --annotation | --attest | --builder | --cache-from | --cache-to | --call | --cgroup-parent | \
    --cpu-period | --cpu-quota | --cpu-shares | --cpuset-cpus | --cpuset-mems | --iidfile | --isolation | --label | \
    --memory | --memory-swap | --metadata-file | --network | --no-cache-filter | --output | --progress | --provenance | \
    --sbom | --secret | --security-opt | --shm-size | --ssh | --tag | --target | --ulimit | -t | -o | -m | -c)
    i=$((i + 1))
    ;;
  -*) ;;
  *) contexts+=("${a}") ;;
  esac
done

if [ "${pull}" = 1 ]; then
  warn "--pull では Mac 側の docker CLI がレジストリのトークンを取りにいくので、sandbox 内では失敗しうる（先に docker-vm pull して --pull を外す）"
  exec docker "$@"
fi

if [ "${#contexts[@]}" -ne 1 ]; then
  exec docker "$@"
fi
context="${contexts[0]}"
case "${context}" in
- | *://* | git@* | github.com/*) exec docker "$@" ;;
esac
case "${dockerfile}" in
-) exec docker "$@" ;;
"") dockerfile="${context}/Dockerfile" ;;
esac
if [ ! -f "${dockerfile}" ] || [ ! -r "${dockerfile}" ]; then
  exec docker "$@"
fi

# 3. Dockerfile を命令の列にする。先頭の parser directive から # syntax= を取り、行継続（行末の \）をつなぎ、
#    コメント行と空行を捨てる
syntax=""
directives=1
instructions=()
cur=""
while IFS= read -r line || [ -n "${line}" ]; do
  line="${line%$'\r'}"
  if [ "${directives}" = 1 ]; then
    if [[ ${line} =~ ^#[[:space:]]*([A-Za-z]+)[[:space:]]*=[[:space:]]*([^[:space:]]*) ]]; then
      if [ "${BASH_REMATCH[1],,}" = syntax ]; then
        syntax="${BASH_REMATCH[2]}"
      fi
      continue
    fi
    directives=0
  fi
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  case "${trimmed}" in
  "" | "#"*) continue ;;
  *\\)
    cur+="${trimmed%\\} "
    continue
    ;;
  esac
  instructions+=("${cur}${trimmed}")
  cur=""
done <"${dockerfile}"
if [ -n "${cur}" ]; then
  instructions+=("${cur}")
fi

# 4. 最初の FROM より前の ARG（meta ARG）を --build-arg と既定値で決め、参照の $VAR / ${VAR} を展開する。
#    値の決まらない変数（既定値も --build-arg も無い・${VAR:-x} 等の形）を含む参照は展開できない
meta_names=()
meta_values=()
meta_get() {
  local k
  for k in "${!meta_names[@]}"; do
    if [ "${meta_names[k]}" = "$1" ]; then
      REPLY="${meta_values[k]}"
      return 0
    fi
  done
  return 1
}

expand() {
  local s="$1" out="" name
  while [[ ${s} == *'$'* ]]; do
    out+="${s%%\$*}"
    s="${s#*\$}"
    if [[ ${s} =~ ^\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]] || [[ ${s} =~ ^([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      s="${BASH_REMATCH[2]}"
      meta_get "${name}" || return 1
      out+="${REPLY}"
    else
      return 1
    fi
  done
  REPLY="${out}${s}"
}

# 参照を pull の候補に足す。それより前のステージ名・--build-context の名前・scratch・ステージ番号は除く
stages=()
refs=()
add_ref() {
  local ref s
  if ! expand "$1"; then
    warn "展開できない変数を含むイメージ参照なので pull しない: $1"
    return
  fi
  ref="${REPLY}"
  if [ -z "${ref}" ] || [ "${ref,,}" = scratch ] || [[ ${ref} =~ ^[0-9]+$ ]]; then
    return
  fi
  for s in "${stages[@]}" "${named_contexts[@]}" "${refs[@]}"; do
    if [ "${s,,}" = "${ref,,}" ]; then
      return
    fi
  done
  refs+=("${ref}")
}

if [ -n "${syntax}" ]; then
  add_ref "${syntax}"
fi

seen_from=0
for ins in "${instructions[@]}"; do
  read -r -a words <<<"${ins}"
  case "${words[0],,}" in
  arg)
    if [ "${seen_from}" = 1 ]; then
      continue
    fi
    for w in "${words[@]:1}"; do
      name="${w%%=*}"
      [[ ${name} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      value=""
      found=0
      for b in "${build_args[@]}"; do
        if [ "${b}" = "${name}" ]; then
          # --build-arg NAME（値なし）は docker CLI と同じく環境変数から取る
          if value="$(printenv "${name}")"; then
            found=1
          fi
        elif [ "${b%%=*}" = "${name}" ]; then
          value="${b#*=}"
          found=1
        fi
      done
      if [ "${found}" = 0 ] && [ "${w}" != "${name}" ]; then
        value="${w#*=}"
        case "${value}" in
        \"*\" | \'*\') value="${value:1:${#value}-2}" ;;
        esac
        if expand "${value}"; then
          value="${REPLY}"
          found=1
        fi
      fi
      if [ "${found}" = 1 ]; then
        meta_names+=("${name}")
        meta_values+=("${value}")
      fi
    done
    ;;
  from)
    seen_from=1
    k=1
    while [[ ${words[k]-} == --* ]]; do
      k=$((k + 1))
    done
    if [ -n "${words[k]-}" ]; then
      add_ref "${words[k]}"
    fi
    as="${words[k + 1]-}"
    if [ "${as,,}" = as ] && [ -n "${words[k + 2]-}" ]; then
      stages+=("${words[k + 2]}")
    fi
    ;;
  copy | run)
    for w in "${words[@]:1}"; do
      case "${w}" in
      --from=*) add_ref "${w#--from=}" ;;
      --mount=*)
        IFS=, read -r -a kvs <<<"${w#--mount=}"
        for kv in "${kvs[@]}"; do
          if [ "${kv%%=*}" = from ]; then
            add_ref "${kv#from=}"
          fi
        done
        ;;
      --*) ;;
      *) break ;;
      esac
    done
    ;;
  esac
done

# 5. VM に無いものだけを pull する。pull の出力は build の stdout（-q のイメージ ID 等）に混ぜない。
# --platform があるときは inspect を使わず常に pull する: inspect は別プラットフォーム版しか無くても（--platform を
# 付けても）見つかったと返すので、指定のプラットフォームが無いまま build が元の障害で落ちる。既にあれば pull は
# manifest の確認だけで済む
pull_opts=()
if [ -n "${platform}" ]; then
  pull_opts=(--platform "${platform}")
fi
for ref in "${refs[@]}"; do
  if [ -z "${platform}" ] && docker "${global[@]}" image inspect -- "${ref}" >/dev/null 2>&1; then
    continue
  fi
  if ! docker "${global[@]}" pull "${pull_opts[@]}" -- "${ref}" >&2; then
    warn "pull に失敗した（build はそのまま続ける）: ${ref}"
  fi
done

exec docker "$@"
