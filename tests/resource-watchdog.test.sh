#!/usr/bin/env bash
# tests/resource-watchdog.test.sh
# メモリ逼迫時に mem-triage の safe_kill だけを止め、ディスク逼迫時に docker-vm の dangling image と build cache を
# prune する resource-watchdog
# （home-manager/programs/resource-watchdog.nix / home-manager/home/file/resource-watchdog/resource_watchdog.py）を確かめる。
# Run from anywhere: bash tests/resource-watchdog.test.sh
# Requires: python3, jq。nix（daemon に届くときだけ。届かなければ tier-2 を skip）
#
# tier-1: resource_watchdog.py を一時ディレクトリの HOME で走らせる。本物のプロセスは kill せず、本物の docker も呼ばない
#         （mem-triage・kill・ps・osascript・df・docker はスタブ）
# tier-2: launchd agent の評価結果

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/home-manager/home/file/resource-watchdog/resource_watchdog.py"
RULES="${REPO_ROOT}/claude-code/RULES.md"

PASS=0
FAIL=0
SKIP=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

skip() {
  echo "  SKIP: $1 ($2)"
  SKIP=$((SKIP + 1))
}

tmpbase="${TMPDIR:-/tmp}"
TMPROOT="$(mktemp -d "${tmpbase%/}/resource-watchdog-test.XXXXXX")"
trap 'rm -rf "${TMPROOT}"' EXIT

# 117 文字を超えるコマンドライン。mem-triage は 117 文字 + "..." に切り詰めて出す
LONG_ARGS="node /opt/servers/orphan-b/dist/index.js --stdio --workspace /very/long/path/to/a/workspace/directory/that/goes/on/and/on/and/on/and/on/for/a/while"
INSTALL_REL=".claude/plugins/cache/playpark/playpark-skills/abc123"

# ---------------------------------------------------------------------------
# スタブ。どれも WD_CASE（ケースごとのディレクトリ）に呼ばれた記録を残す
# ---------------------------------------------------------------------------
STUBS="${TMPROOT}/stubs"
mkdir -p "${STUBS}"

# mem-triage: n 回目の呼び出しで triage-<n>.json を返す（無ければ最後にあったもの）
cat >"${STUBS}/mem-triage" <<'EOF'
#!/bin/bash
n=$(($(cat "${WD_CASE}/triage.calls" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${WD_CASE}/triage.calls"
printf '%s\n' "$*" >>"${WD_CASE}/triage.args"
while [ "${n}" -gt 1 ] && [ ! -f "${WD_CASE}/triage-${n}.json" ]; do n=$((n - 1)); done
cat "${WD_CASE}/triage-${n}.json"
EOF

cat >"${STUBS}/kill" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${WD_CASE}/kill.log"
EOF

# ps -o ppid=,tty=,args= -p <pid>: ps/<pid> があればその中身、無ければ「そんな pid は無い」
cat >"${STUBS}/ps" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "-o ppid=,tty=,args= -p" ] || exit 2
cat "${WD_CASE}/ps/$4" 2>/dev/null || exit 1
EOF

# osascript: 呼び出しごとに notify/<n>/ を作り、argv を 1 引数 1 ファイルで残す（改行を含む引数もそのまま残る）
cat >"${STUBS}/osascript" <<'EOF'
#!/bin/bash
n=$(($(ls "${WD_CASE}/notify" 2>/dev/null | wc -l) + 1))
mkdir -p "${WD_CASE}/notify/${n}"
i=0
for a in "$@"; do
  i=$((i + 1))
  printf '%s' "${a}" >"${WD_CASE}/notify/${n}/${i}"
done
EOF

# df -Pk /System/Volumes/Data: n 回目の呼び出しで df-<n>（空きの GB）を返す（無ければ最後にあったもの。
# 1 つも無ければ 1000GB = 逼迫していない）
cat >"${STUBS}/df" <<'EOF'
#!/bin/bash
[ "$*" = "-Pk /System/Volumes/Data" ] || exit 2
n=$(($(cat "${WD_CASE}/df.calls" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${WD_CASE}/df.calls"
while [ "${n}" -gt 1 ] && [ ! -f "${WD_CASE}/df-${n}" ]; do n=$((n - 1)); done
gb="$(cat "${WD_CASE}/df-${n}" 2>/dev/null || echo 1000)"
echo "Filesystem     1024-blocks      Used  Available Capacity Mounted on"
echo "/dev/disk3s1    1948455240 412455240 $((gb * 1024 * 1024))      22% /System/Volumes/Data"
EOF

# docker: watchdog は環境を引き継がずに呼ぶので WD_CASE は届かない。ケースのディレクトリは HOME（<case>/home）から
# 決める。argv と、受け取った DOCKER_CONFIG・BUILDX_CONFIG・DOCKER_HOST を残す。docker.fail があれば
# VM に届かないときと同じく非 0 で終わる
cat >"${STUBS}/docker" <<'EOF'
#!/bin/bash
case_dir="${HOME%/home}"
printf '%s\n' "$*" >>"${case_dir}/docker.log"
printf 'DOCKER_CONFIG=%s BUILDX_CONFIG=%s DOCKER_HOST=%s\n' "${DOCKER_CONFIG-}" "${BUILDX_CONFIG-}" "${DOCKER_HOST-}" \
  >>"${case_dir}/docker.env"
if [ -e "${case_dir}/docker.fail" ]; then
  echo "Cannot connect to the Docker daemon at $2. Is the docker daemon running?" >&2
  exit 1
fi
echo "Total reclaimed space: 0B"
EOF
chmod +x "${STUBS}"/*

# report <free_percent> [<4 番目の unit の name>]: mem-triage の JSON。
# units は mem の降順。safe_kill の orphan-a が最大で、safe_kill でないものは big-app > claude > node-dev > 4 番目
report() {
  jq -n --argjson free "$1" --arg fourth "${2:-fourth}" --arg long "${LONG_ARGS}" '
    def proc($pid; $name; $mem; $safe; $ppid; $tty; $args):
      {id: "pid:\($pid)", kind: "process", name: $name, mem: $mem, safe_kill: $safe, kill: "kill \($pid)",
       root: {pid: $pid, ppid: $ppid, tty: $tty, args: $args}};
    {
      summary: {free_percent: $free},
      units: [
        proc(201; "orphan-a"; "8G"; true; 1; "??"; "node /opt/servers/orphan-a.js --stdio"),
        {id: "app:big-app", kind: "app", name: "big-app", mem: "5G"},
        proc(300; "claude"; "2G"; false; 500; "ttys001"; "claude"),
        proc(301; "node-dev"; "1G"; false; 1; "??"; "node dev-server.js --port 3000"),
        proc(302; $fourth; "500M"; false; 501; "ttys002"; "fourth"),
        proc(202; "orphan-b"; "200M"; true; 1; "??"; ($long[:117] + "..."))
      ],
      safe_kill: [
        {pid: 201, name: "orphan-a", mem: "8G", args: "node /opt/servers/orphan-a.js --stdio", kill: "kill 201"},
        {pid: 202, name: "orphan-b", mem: "200M", args: ($long[:117] + "..."), kill: "kill 202"}
      ]
    }'
}

# new_case <name>: HOME になるディレクトリを作り、installed_plugins.json・mem-triage・ps の応答を置く。
# config と状態ファイルは置かない
new_case() {
  CASE="${TMPROOT}/$1"
  local install="${CASE}/home/${INSTALL_REL}"
  mkdir -p "${install}/bin" "${CASE}/ps"
  cp "${STUBS}/mem-triage" "${install}/bin/mem-triage"
  jq -n --arg p "${install}" '{version: 2, plugins: {"playpark-skills@playpark": [{scope: "user", installPath: $p}]}}' \
    >"${CASE}/home/.claude/plugins/installed_plugins.json"
  printf '    1 ??       node /opt/servers/orphan-a.js --stdio\n' >"${CASE}/ps/201"
  printf '    1 ??       %s\n' "${LONG_ARGS}" >"${CASE}/ps/202"
  printf '  500 ttys001  claude\n' >"${CASE}/ps/300"
  printf '    1 ??       node dev-server.js --port 3000\n' >"${CASE}/ps/301"
  printf '  501 ttys002  fourth\n' >"${CASE}/ps/302"
}

# run_wd: 実行する。終了コードは RC、stdout + stderr は ${CASE}/out.log。
# DOCKER_HOST は「呼び出し元の環境を docker に引き継がない」ことを確かめるために入れておく
run_wd() {
  RC=0
  env -i PATH="${PATH}" HOME="${CASE}/home" WD_CASE="${CASE}" \
    RESOURCE_WATCHDOG_KILL="${STUBS}/kill" \
    RESOURCE_WATCHDOG_PS="${STUBS}/ps" \
    RESOURCE_WATCHDOG_OSASCRIPT="${STUBS}/osascript" \
    RESOURCE_WATCHDOG_DF="${STUBS}/df" \
    RESOURCE_WATCHDOG_DOCKER="${STUBS}/docker" \
    RESOURCE_WATCHDOG_RECHECK_DELAY=0 \
    DOCKER_HOST="unix:///from/the/caller.sock" \
    python3 -I -B "${SCRIPT}" >"${CASE}/out.log" 2>&1 || RC=$?
}

kills() { cat "${CASE}/kill.log" 2>/dev/null || true; }
triage_calls() { cat "${CASE}/triage.calls" 2>/dev/null || echo 0; }
df_calls() { cat "${CASE}/df.calls" 2>/dev/null || echo 0; }
prunes() { cat "${CASE}/docker.log" 2>/dev/null || true; }
notifications() { find "${CASE}/notify" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }
# notifications_titled <title>: その title（osascript の 7 番目の引数）の通知の数
notifications_titled() {
  local d count=0
  for d in "${CASE}"/notify/*/; do
    if [ "$(cat "${d}7" 2>/dev/null || true)" = "$1" ]; then
      count=$((count + 1))
    fi
  done
  echo "${count}"
}
# notification_body <title>: その title の最初の通知の本文
notification_body() {
  local d
  for d in "${CASE}"/notify/*/; do
    if [ "$(cat "${d}7" 2>/dev/null || true)" = "$1" ]; then
      cat "${d}8"
      return
    fi
  done
}
state() { echo "RC=${RC} kills=[$(kills | tr '\n' ',')] triage_calls=$(triage_calls) df_calls=$(df_calls) prunes=[$(prunes | tr '\n' ',')] notifications=$(notifications) log=$(tail -n 5 "${CASE}/out.log")"; }

ONLY_SAFE_KILL=$'-TERM 201\n-TERM 202'
MEM_TITLE="resource-watchdog: メモリ逼迫"
DISK_TITLE="resource-watchdog: ディスク逼迫"

echo "=== resource-watchdog tests ==="
echo ""
echo "--- tier-1: resource_watchdog.py ---"

# ---------------------------------------------------------------------------
# kills_only_safe_kill_below_threshold（AC-2）: free_percent が既定の閾値 20 未満なら、safe_kill[] の pid
# （201・202）にだけ SIGTERM を送る。safe_kill に無い unit の pid（300・301・302）には送らない。
# 202 は mem-triage が切り詰めたコマンドラインと ps の全文を前方一致で照合する。
# 測り直しで回復していれば通知しない
# ---------------------------------------------------------------------------
echo "- kills_only_safe_kill_below_threshold"
new_case kills
report 19 >"${CASE}/triage-1.json"
report 50 >"${CASE}/triage-2.json"
run_wd
if [ "${RC}" -eq 0 ] && [ "$(kills)" = "${ONLY_SAFE_KILL}" ] && [ "$(triage_calls)" = 2 ] && [ "$(notifications)" = 0 ]; then
  pass "kills_only_safe_kill_below_threshold"
else
  fail "kills_only_safe_kill_below_threshold" "$(state)"
fi

# ---------------------------------------------------------------------------
# skips_kill_when_process_changed: SIGTERM を送る直前に、その pid の今の ppid・tty・コマンドラインが
# mem-triage の出力と違えば（pid の再利用）、その pid には送らずログに残す。一致する 202 には送る
# ---------------------------------------------------------------------------
echo "- skips_kill_when_process_changed"
new_case reused
report 19 >"${CASE}/triage-1.json"
report 50 >"${CASE}/triage-2.json"
printf '  777 ttys009  vim notes.txt\n' >"${CASE}/ps/201"
run_wd
if [ "${RC}" -eq 0 ] && [ "$(kills)" = "-TERM 202" ] && grep -q 'pid=201' "${CASE}/out.log"; then
  pass "skips_kill_when_process_changed"
else
  fail "skips_kill_when_process_changed" "$(state)"
fi

# ---------------------------------------------------------------------------
# noop_at_or_above_threshold（AC-3 / AC-7 の既定値）: config が無ければ閾値は 20。free_percent が 20 以上なら
# kill も通知もせず、測り直しもしない
# ---------------------------------------------------------------------------
echo "- noop_at_or_above_threshold"
bad=""
for free in 20 40; do
  new_case "noop-${free}"
  report "${free}" >"${CASE}/triage-1.json"
  run_wd
  if [ "${RC}" -ne 0 ] || [ -n "$(kills)" ] || [ "$(notifications)" != 0 ] || [ "$(triage_calls)" != 1 ]; then
    bad="${bad} free=${free}: $(state)"
  fi
done
if [ -z "${bad}" ]; then
  pass "noop_at_or_above_threshold"
else
  fail "noop_at_or_above_threshold" "${bad}"
fi

# ---------------------------------------------------------------------------
# notifies_top3_without_killing（AC-4）: kill の後に測り直した free_percent がまだ閾値未満なら、safe_kill 以外の
# units[] の上位 3 件（name と mem）を 1 回通知する。4 番目と safe_kill の unit は載せない。
# 通知した候補は kill しない（kill は safe_kill の 2 件のまま）
# ---------------------------------------------------------------------------
echo "- notifies_top3_without_killing"
new_case notify
report 19 >"${CASE}/triage-1.json"
report 18 >"${CASE}/triage-2.json"
run_wd
body="$(cat "${CASE}/notify/1/8" 2>/dev/null || true)"
if [ "${RC}" -eq 0 ] && [ "$(kills)" = "${ONLY_SAFE_KILL}" ] && [ "$(notifications)" = 1 ] &&
  [[ ${body} == *"big-app (5G) / claude (2G) / node-dev (1G)" ]] &&
  [[ ${body} != *fourth* ]] && [[ ${body} != *orphan* ]] && [[ ${body} == *"18%"* ]]; then
  pass "notifies_top3_without_killing"
else
  fail "notifies_top3_without_killing" "body=${body} $(state)"
fi

# ---------------------------------------------------------------------------
# notification_rate_limit（AC-5）: 通知した時刻を状態ファイル ~/.local/state/resource-watchdog/last-notified に
# 残す。逼迫が続いても 30 分以内は 2 回目を出さず、30 分を過ぎたらまた出す（上のケースの続き）
# ---------------------------------------------------------------------------
echo "- notification_rate_limit"
state_file="${CASE}/home/.local/state/resource-watchdog/last-notified"
now="$(date +%s)"
recorded="$(cat "${state_file}" 2>/dev/null || echo 0)"
run_wd
after_second="$(notifications)"
echo "$((now - 1700))" >"${state_file}"
run_wd
after_28min="$(notifications)"
echo "$((now - 1801))" >"${state_file}"
run_wd
after_30min="$(notifications)"
if [ "$((now - recorded))" -ge 0 ] && [ "$((now - recorded))" -le 60 ] &&
  [ "${after_second}" = 1 ] && [ "${after_28min}" = 1 ] && [ "${after_30min}" = 2 ] &&
  [ "$(($(cat "${state_file}") - now))" -ge 0 ]; then
  pass "notification_rate_limit"
else
  fail "notification_rate_limit" "recorded=${recorded} now=${now} second=${after_second} 28min=${after_28min} 30min=${after_30min}"
fi

# ---------------------------------------------------------------------------
# notifies_when_nothing_to_kill: safe_kill が空なら kill するものが無いので、測り直さずに最初の計測で
# 候補を通知する（kill は 1 件も送らない）
# ---------------------------------------------------------------------------
echo "- notifies_when_nothing_to_kill"
new_case nothing-to-kill
report 19 | jq '.safe_kill = [] | del(.units[] | select(.safe_kill))' >"${CASE}/triage-1.json"
run_wd
body="$(cat "${CASE}/notify/1/8" 2>/dev/null || true)"
if [ "${RC}" -eq 0 ] && [ -z "$(kills)" ] && [ "$(triage_calls)" = 1 ] && [ "$(notifications)" = 1 ] &&
  [[ ${body} == *"big-app (5G) / claude (2G) / node-dev (1G)" ]]; then
  pass "notifies_when_nothing_to_kill"
else
  fail "notifies_when_nothing_to_kill" "body=${body} $(state)"
fi

# ---------------------------------------------------------------------------
# resolves_mem_triage_from_install_path（AC-6）: 実行する mem-triage は installed_plugins.json の
# playpark-skills の installPath の下の bin/mem-triage。cache に別の版があっても、installPath が指す方だけを呼ぶ
# ---------------------------------------------------------------------------
echo "- resolves_mem_triage_from_install_path"
new_case resolve
report 19 >"${CASE}/triage-1.json"
report 50 >"${CASE}/triage-2.json"
other="${CASE}/home/.claude/plugins/cache/playpark/playpark-skills/zzz999"
mkdir -p "${other}/bin"
# shellcheck disable=SC2016 # 意図的: ${WD_CASE} はスタブの実行時に展開する
printf '#!/bin/bash\ntouch "${WD_CASE}/other-version-called"\necho "{}"\n' >"${other}/bin/mem-triage"
chmod +x "${other}/bin/mem-triage"
run_wd
if [ "${RC}" -eq 0 ] && [ "$(triage_calls)" = 2 ] && [ ! -e "${CASE}/other-version-called" ] && [ "$(kills)" = "${ONLY_SAFE_KILL}" ]; then
  pass "resolves_mem_triage_from_install_path"
else
  fail "resolves_mem_triage_from_install_path" "$(state)"
fi

# ---------------------------------------------------------------------------
# unresolvable_mem_triage_does_nothing（AC-6）: installPath が無い・JSON が不正・スクリプトが無い・installPath が
# plugins ディレクトリの外を指す（sandbox から書ける場所かもしれない）ときは、kill も通知もせず、
# 理由をログに書いて終了 0 で終わる
# ---------------------------------------------------------------------------
echo "- unresolvable_mem_triage_does_nothing"
bad=""
for why in no_install_path invalid_json no_script outside_plugins_dir; do
  new_case "unresolvable-${why}"
  report 5 >"${CASE}/triage-1.json"
  plugins_json="${CASE}/home/.claude/plugins/installed_plugins.json"
  case "${why}" in
  no_install_path)
    echo '{"version": 2, "plugins": {"playpark-skills@playpark": [{"scope": "user"}]}}' >"${plugins_json}"
    want="installPath が無い"
    ;;
  invalid_json)
    echo '{"plugins": ' >"${plugins_json}"
    want="を読めない"
    ;;
  no_script)
    rm "${CASE}/home/${INSTALL_REL}/bin/mem-triage"
    want="mem-triage が無い"
    ;;
  outside_plugins_dir)
    mkdir -p "${CASE}/writable/bin"
    cp "${STUBS}/mem-triage" "${CASE}/writable/bin/mem-triage"
    jq -n --arg p "${CASE}/writable" '{plugins: {"playpark-skills@playpark": [{installPath: $p}]}}' >"${plugins_json}"
    want="の外を指している"
    ;;
  esac
  run_wd
  if [ "${RC}" -ne 0 ] || [ -n "$(kills)" ] || [ "$(notifications)" != 0 ] || [ "$(triage_calls)" != 0 ] ||
    ! grep -qF "${want}" "${CASE}/out.log"; then
    bad="${bad} ${why}: $(state)"
  fi
done
if [ -z "${bad}" ]; then
  pass "unresolvable_mem_triage_does_nothing"
else
  fail "unresolvable_mem_triage_does_nothing" "${bad}"
fi

# ---------------------------------------------------------------------------
# config_overrides_threshold（AC-7）: ~/.config/resource-watchdog/config の free_percent_threshold で閾値を
# 上書きできる。free 40 は既定（20）では何もしない（noop_at_or_above_threshold）が、閾値 50 なら kill する
# ---------------------------------------------------------------------------
echo "- config_overrides_threshold"
new_case config-threshold
report 40 >"${CASE}/triage-1.json"
report 60 >"${CASE}/triage-2.json"
mkdir -p "${CASE}/home/.config/resource-watchdog"
printf '# 空きがこれ未満なら逼迫\nfree_percent_threshold = 50\n' >"${CASE}/home/.config/resource-watchdog/config"
run_wd
if [ "${RC}" -eq 0 ] && [ "$(kills)" = "${ONLY_SAFE_KILL}" ] && [ "$(notifications)" = 0 ]; then
  pass "config_overrides_threshold"
else
  fail "config_overrides_threshold" "$(state)"
fi

# ---------------------------------------------------------------------------
# config_disabled_calls_nothing（AC-7 / #473 AC-5）: enabled=false なら、メモリもディスクも逼迫していても
# mem-triage・kill・df・docker・通知を一切呼ばずに終了 0 で終わる
# ---------------------------------------------------------------------------
echo "- config_disabled_calls_nothing"
new_case config-disabled
report 5 >"${CASE}/triage-1.json"
echo 1 >"${CASE}/df-1"
mkdir -p "${CASE}/home/.config/resource-watchdog"
echo 'enabled=false' >"${CASE}/home/.config/resource-watchdog/config"
run_wd
if [ "${RC}" -eq 0 ] && [ "$(triage_calls)" = 0 ] && [ -z "$(kills)" ] && [ "$(notifications)" = 0 ] &&
  [ "$(df_calls)" = 0 ] && [ -z "$(prunes)" ]; then
  pass "config_disabled_calls_nothing"
else
  fail "config_disabled_calls_nothing" "$(state)"
fi

# ---------------------------------------------------------------------------
# notification_passes_names_as_argv_data（AC-9）: unit の name にダブルクォート・バックスラッシュ・$(…)・
# バッククォート・改行・AppleScript の式が入っていても、osascript に渡すスクリプト（-e の 3 行）は固定のままで、
# name は最後の引数（通知の本文）にそのままの文字列で入る。埋め込んだコマンドは実行されない
# ---------------------------------------------------------------------------
echo "- notification_passes_names_as_argv_data"
new_case hostile
canary="${CASE}/canary"
hostile="ev\"il\\ \$(touch ${canary}-subst) \`touch ${canary}-backtick\`
\" & (do shell script \"touch ${canary}-applescript\") & \"; touch ${canary}-semicolon"
# 4 番目だと通知に載らないので、safe_kill 以外を 3 件に絞る
report 19 "${hostile}" | jq 'del(.units[] | select(.name == "node-dev"))' >"${CASE}/triage-1.json"
run_wd
argv_dir="${CASE}/notify/1"
got_script="$(cat "${argv_dir}/1" "${argv_dir}/2" "${argv_dir}/3" "${argv_dir}/4" "${argv_dir}/5" "${argv_dir}/6" 2>/dev/null || true)"
want_script="-eon run argv-edisplay notification (item 2 of argv) with title (item 1 of argv)-eend run"
body="$(cat "${argv_dir}/8" 2>/dev/null || true)"
argc="$(find "${argv_dir}" -type f 2>/dev/null | wc -l | tr -d ' ')"
canaries="$(find "${CASE}" -name 'canary*' | wc -l | tr -d ' ')"
if [ "${RC}" -eq 0 ] && [ "$(notifications)" = 1 ] && [ "${argc}" = 8 ] && [ "${got_script}" = "${want_script}" ] &&
  [[ ${body} == *"${hostile} (500M)"* ]] && [ "${canaries}" = 0 ] && [ "$(kills)" = "${ONLY_SAFE_KILL}" ]; then
  pass "notification_passes_names_as_argv_data"
else
  fail "notification_passes_names_as_argv_data" "argc=${argc} script=${got_script} body=${body} canaries=${canaries} $(state)"
fi

echo ""
echo "--- tier-1: ディスクの段（#473） ---"

DISK_STATE_REL="home/.local/state/resource-watchdog"

# ---------------------------------------------------------------------------
# disk_prunes_and_notifies_below_threshold（#473 AC-1）: Data ボリュームの空きが既定の閾値 50GB 未満なら、
# sandbox-docker VM の docker socket に向けて dangling image の prune と build cache の prune を 1 回ずつ呼び
# （-a・volume・system prune は呼ばない）、掃除の前（49GB）と後（60GB）の空きを 1 回通知する。
# docker には watchdog 専用の DOCKER_CONFIG・BUILDX_CONFIG を渡し、呼び出し元の DOCKER_HOST は引き継がない。
# メモリは逼迫していないので kill もメモリの通知も無い
# ---------------------------------------------------------------------------
echo "- disk_prunes_and_notifies_below_threshold"
new_case disk-prune
report 50 >"${CASE}/triage-1.json"
echo 49 >"${CASE}/df-1"
echo 60 >"${CASE}/df-2"
run_wd
host="unix://${CASE}/home/.lima/sandbox-docker/sock/docker.sock"
want_prunes="--host ${host} image prune --force
--host ${host} builder prune --force"
want_env="DOCKER_CONFIG=${CASE}/${DISK_STATE_REL}/docker-config BUILDX_CONFIG=${CASE}/${DISK_STATE_REL}/buildx DOCKER_HOST="
body="$(notification_body "${DISK_TITLE}")"
if [ "${RC}" -eq 0 ] && [ "$(prunes)" = "${want_prunes}" ] &&
  [ "$(sort -u "${CASE}/docker.env" 2>/dev/null || true)" = "${want_env}" ] &&
  [ -d "${CASE}/${DISK_STATE_REL}/docker-config" ] && [ -d "${CASE}/${DISK_STATE_REL}/buildx" ] &&
  [ "$(notifications)" = 1 ] && [ "$(notifications_titled "${DISK_TITLE}")" = 1 ] &&
  [[ ${body} == *"49.0GB"*"60.0GB"* ]] && [ -z "$(kills)" ]; then
  pass "disk_prunes_and_notifies_below_threshold"
else
  fail "disk_prunes_and_notifies_below_threshold" "body=${body} env=$(cat "${CASE}/docker.env" 2>/dev/null || true) $(state)"
fi

# ---------------------------------------------------------------------------
# disk_noop_at_or_above_threshold（#473 AC-2 / AC-5 の既定値）: config が無ければ閾値は 50GB。空きが 50GB 以上なら
# prune も通知も呼ばず、測り直しもせず、ディスクの状態ファイルも作らない
# ---------------------------------------------------------------------------
echo "- disk_noop_at_or_above_threshold"
bad=""
for gb in 50 60; do
  new_case "disk-noop-${gb}"
  report 50 >"${CASE}/triage-1.json"
  echo "${gb}" >"${CASE}/df-1"
  run_wd
  if [ "${RC}" -ne 0 ] || [ -n "$(prunes)" ] || [ "$(notifications)" != 0 ] || [ "$(df_calls)" != 1 ] ||
    [ -e "${CASE}/${DISK_STATE_REL}/disk-last-notified" ]; then
    bad="${bad} gb=${gb}: $(state)"
  fi
done
if [ -z "${bad}" ]; then
  pass "disk_noop_at_or_above_threshold"
else
  fail "disk_noop_at_or_above_threshold" "${bad}"
fi

# ---------------------------------------------------------------------------
# disk_prune_failure_keeps_memory_stage（#473 AC-3）: docker-vm に届かない（prune が非 0 で終わる）ときも、
# メモリの段は safe_kill の 2 件に SIGTERM を送り、測り直して候補を通知する。prune が失敗した理由
# （docker の stderr）はログに残る。メモリの状態ファイルは今までどおり時刻 1 行だけで、ディスクの通知時刻は入らない
# ---------------------------------------------------------------------------
echo "- disk_prune_failure_keeps_memory_stage"
new_case disk-prune-fails
report 19 >"${CASE}/triage-1.json"
report 18 >"${CASE}/triage-2.json"
echo 10 >"${CASE}/df-1"
touch "${CASE}/docker.fail"
run_wd
body="$(notification_body "${MEM_TITLE}")"
mem_state="$(cat "${CASE}/${DISK_STATE_REL}/last-notified" 2>/dev/null || true)"
if [ "${RC}" -eq 0 ] && [ "$(kills)" = "${ONLY_SAFE_KILL}" ] && [ "$(triage_calls)" = 2 ] &&
  [ "$(notifications_titled "${MEM_TITLE}")" = 1 ] &&
  [[ ${body} == *"18%"*"big-app (5G) / claude (2G) / node-dev (1G)" ]] &&
  [ "$(prunes | wc -l | tr -d ' ')" = 2 ] &&
  grep -q 'prune できない: docker image prune --force が終了 1: Cannot connect to the Docker daemon' "${CASE}/out.log" &&
  grep -q 'prune できない: docker builder prune --force が終了 1: Cannot connect to the Docker daemon' "${CASE}/out.log" &&
  [[ ${mem_state} =~ ^[0-9]+$ ]]; then
  pass "disk_prune_failure_keeps_memory_stage"
else
  fail "disk_prune_failure_keeps_memory_stage" "body=${body} mem_state=${mem_state} $(state)"
fi

# ---------------------------------------------------------------------------
# disk_notification_rate_limit（#473 AC-4）: ディスクの通知時刻は、メモリの状態ファイル（last-notified）とは別の
# ~/.local/state/resource-watchdog/disk-last-notified に残す。メモリの状態ファイルが「さっき通知した」でも
# ディスクの通知は出て、メモリの状態ファイルは 1 バイトも変わらない。逼迫が続いても 30 分以内は 2 回目を出さず
# （prune は毎回呼ぶ）、30 分を過ぎたらまた出す
# ---------------------------------------------------------------------------
echo "- disk_notification_rate_limit"
new_case disk-rate-limit
report 50 >"${CASE}/triage-1.json"
echo 10 >"${CASE}/df-1"
mem_state_file="${CASE}/${DISK_STATE_REL}/last-notified"
disk_state_file="${CASE}/${DISK_STATE_REL}/disk-last-notified"
mkdir -p "${CASE}/${DISK_STATE_REL}"
now="$(date +%s)"
echo "${now}" >"${mem_state_file}"
cp "${mem_state_file}" "${CASE}/last-notified.orig"
run_wd
after_first="$(notifications_titled "${DISK_TITLE}")"
recorded="$(cat "${disk_state_file}" 2>/dev/null || echo 0)"
run_wd
after_second="$(notifications_titled "${DISK_TITLE}")"
echo "$((now - 1700))" >"${disk_state_file}"
run_wd
after_28min="$(notifications_titled "${DISK_TITLE}")"
echo "$((now - 1801))" >"${disk_state_file}"
run_wd
after_30min="$(notifications_titled "${DISK_TITLE}")"
if [ "${after_first}" = 1 ] && [[ ${recorded} =~ ^[0-9]+$ ]] &&
  [ "$((recorded - now))" -ge 0 ] && [ "$((recorded - now))" -le 60 ] &&
  [ "${after_second}" = 1 ] && [ "${after_28min}" = 1 ] && [ "${after_30min}" = 2 ] &&
  [ "$(($(cat "${disk_state_file}") - now))" -ge 0 ] && [ "$(prunes | wc -l | tr -d ' ')" = 8 ] &&
  cmp -s "${mem_state_file}" "${CASE}/last-notified.orig" && [ "$(notifications)" = 2 ]; then
  pass "disk_notification_rate_limit"
else
  fail "disk_notification_rate_limit" "recorded=${recorded} now=${now} first=${after_first} second=${after_second} 28min=${after_28min} 30min=${after_30min} mem_state=$(cat "${mem_state_file}") $(state)"
fi

# ---------------------------------------------------------------------------
# config_overrides_disk_threshold（#473 AC-5）: config の disk_free_min_gb で閾値を上書きできる。空き 60GB は
# 既定（50）では何もしない（disk_noop_at_or_above_threshold）が、閾値 100 なら prune して通知する
# ---------------------------------------------------------------------------
echo "- config_overrides_disk_threshold"
new_case config-disk-threshold
report 50 >"${CASE}/triage-1.json"
echo 60 >"${CASE}/df-1"
mkdir -p "${CASE}/home/.config/resource-watchdog"
printf '# 空きがこれ未満なら逼迫\ndisk_free_min_gb = 100\n' >"${CASE}/home/.config/resource-watchdog/config"
run_wd
if [ "${RC}" -eq 0 ] && [ "$(prunes | wc -l | tr -d ' ')" = 2 ] && [ "$(notifications_titled "${DISK_TITLE}")" = 1 ]; then
  pass "config_overrides_disk_threshold"
else
  fail "config_overrides_disk_threshold" "$(state)"
fi

echo ""
echo "--- RULES.md ---"

# ---------------------------------------------------------------------------
# rules_resource_watchdog（AC-8）: RULES.md の「プロセス調査」の項のすぐ下の 1 行に、resource-watchdog（launchd）が
# mem-triage の safe_kill だけを自動で SIGTERM すること、agent が自分の判断で kill しないルールは変わらないことが
# 書かれている
# ---------------------------------------------------------------------------
echo "- rules_resource_watchdog"
rules_line="$(awk '/^- プロセス調査:/ { f = 1; next } f && /^  - / { print; next } f { exit }' "${RULES}")"
missing=()
# shellcheck disable=SC2016 # 意図的: RULES.md のバッククォートを文字列として探す
for want in "launchd" "resource-watchdog" 'mem-triage の `safe_kill`' "だけを自動で SIGTERM" \
  "agent が自分の判断で kill しないルールは変わらない"; do
  case "${rules_line}" in
  *"${want}"*) ;;
  *) missing+=("${want}") ;;
  esac
done
if [ "$(printf '%s\n' "${rules_line}" | grep -c .)" = 1 ] && [ "${#missing[@]}" -eq 0 ]; then
  pass "rules_resource_watchdog"
else
  fail "rules_resource_watchdog" "line=${rules_line:-<none>} missing=${missing[*]:-}"
fi

echo ""
echo "--- tier-2: home-manager (nix) ---"

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
else
  system=""
fi

if [ "${system}" != "aarch64-darwin" ]; then
  skip "launchd_agent_runs_every_120s" "nix daemon unreachable or not aarch64-darwin"
  skip "launchd_agent_passes_nix_store_docker" "nix daemon unreachable or not aarch64-darwin"
else
  # ---------------------------------------------------------------------------
  # launchd_agent_runs_every_120s（AC-1）: home-manager/programs/default.nix が import する module が
  # launchd agent com.playpark.resource-watchdog を定義し、120 秒ごとに resource_watchdog.py を起動する。
  # ログは ~/.local/state/resource-watchdog.out.log / .err.log
  # ---------------------------------------------------------------------------
  echo "- launchd_agent_runs_every_120s"
  # path: で評価する（git の flake は untracked の新規ファイルを見ないので、commit 前でも走るように）
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"path:${REPO_ROOT}\";
      hm = flake.homeConfigurations.\"naramotoyuuji-darwin\";
      agent = hm.config.launchd.agents.resource-watchdog;
      home = hm.config.home.homeDirectory;
    in {
      inherit (agent) enable;
      inherit (agent.config) Label StartInterval;
      out = agent.config.StandardOutPath == \"\${home}/.local/state/resource-watchdog.out.log\";
      err = agent.config.StandardErrorPath == \"\${home}/.local/state/resource-watchdog.err.log\";
      script = hm.pkgs.lib.last agent.config.ProgramArguments;
      docker = agent.config.EnvironmentVariables.RESOURCE_WATCHDOG_DOCKER;
    }
  " >"${TMPROOT}/agent.json" 2>"${TMPROOT}/nix.err" || echo '{}' >"${TMPROOT}/agent.json"
  got="$(jq -c '{enable, Label, StartInterval, out, err}' "${TMPROOT}/agent.json")"
  script="$(jq -r '.script // empty' "${TMPROOT}/agent.json")"
  if [ "${got}" = '{"enable":true,"Label":"com.playpark.resource-watchdog","StartInterval":120,"out":true,"err":true}' ] &&
    [ -n "${script}" ] && cmp -s "${script}" "${SCRIPT}"; then
    pass "launchd_agent_runs_every_120s"
  else
    fail "launchd_agent_runs_every_120s" "got=${got} script=${script:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi

  # ---------------------------------------------------------------------------
  # launchd_agent_passes_nix_store_docker（#473）: watchdog が prune に使う docker CLI は nix store のもの
  # （docker-vm の wrapper でも、PATH の docker でもない）
  # ---------------------------------------------------------------------------
  echo "- launchd_agent_passes_nix_store_docker"
  docker="$(jq -r '.docker // empty' "${TMPROOT}/agent.json")"
  if [[ ${docker} =~ ^/nix/store/[^/]+/bin/docker$ ]]; then
    pass "launchd_agent_passes_nix_store_docker"
  else
    fail "launchd_agent_passes_nix_store_docker" "docker=${docker:-<none>} err=$(tail -n 3 "${TMPROOT}/nix.err")"
  fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
echo "PASS: resource-watchdog"
