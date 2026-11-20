#!/usr/bin/env bash
# tests/cloud-gh-shim.test.sh
# cloud/bin/gh（クラウドセッション用の gh shim）が、CLAUDE_CODE_REMOTE=true のときだけ、dev-flow 系が使う形の
# `gh pr` / `gh issue` を REST（実体の `gh api`）に変換して GraphQL 版と同じ形の出力・exit code を返し、
# それ以外の形を exit 2 で止めることを確かめる。
# Run from the repo root: bash tests/cloud-gh-shim.test.sh
# Requires: git, jq
#
# 実ネットワークには出ない。PATH の shim の次に偽の gh を置き、偽の gh は受け取った argv（と --input - の body）を
# ログに書いて、fixture の REST 応答を返す。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_DIR="${REPO_ROOT}/cloud/bin"
PASS=0
FAIL=0
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cloud-gh-shim-test.XXXXXX")"
WORK="$(cd "${WORK}" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

FAKE="${WORK}/fake-gh"
FIX="${WORK}/fixtures"
LOG="${WORK}/gh.log"
NOGIT="${WORK}/nogit"
mkdir -p "${FAKE}" "${FIX}" "${NOGIT}"

origin_repo() { # <名前> <origin の URL> — その origin を持つ git repo を作ってパスを出す
  local dir="${WORK}/$1"
  git init -q "${dir}"
  git -C "${dir}" remote add origin "$2"
  printf '%s' "${dir}"
}
# origin が acme/app の git repo（--repo を取らない pr checks / pr diff はここから呼ぶ）
ORIGIN="$(origin_repo https https://github.com/acme/app.git)"

# 偽の gh: argv を [a][b]… の 1 行でログに書く。api なら path（と method）に対応する fixture を返す。
# --input - の body は "body <JSON>" の行でログに足す。--slurp は実体と同じくページの配列で包む。
# fixture が無い GET は 404、GET 以外は {} を返す
cat >"${FAKE}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf '[%s]' "$@"
  printf '\n'
} >>"${GH_LOG}"
[ "${1:-}" = api ] || exit 0
shift
method=GET
path=""
slurp=0
input=0
while [ $# -gt 0 ]; do
  case "$1" in
  -X)
    method="$2"
    shift 2
    ;;
  -H | -f) shift 2 ;;
  --input)
    input=1
    shift 2
    ;;
  --paginate) shift ;;
  --slurp)
    slurp=1
    shift
    ;;
  *)
    path="$1"
    shift
    ;;
  esac
done
if [ "${input}" = 1 ]; then
  printf 'body %s\n' "$(cat)" >>"${GH_LOG}"
fi
name="${path//\//_}"
[ "${method}" = GET ] || name="${method}_${name}"
if [ -f "${GH_FIX}/${name}.json" ]; then
  if [ "${slurp}" = 1 ]; then
    jq -c -s . "${GH_FIX}/${name}.json"
  else
    cat "${GH_FIX}/${name}.json"
  fi
elif [ "${method}" = GET ]; then
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
else
  echo '{}'
fi
EOF
chmod +x "${FAKE}/gh"

RUN_PATH="${SHIM_DIR}:${FAKE}:${PATH}"

# run_in <cwd> <CLAUDE_CODE_REMOTE の値（空なら未設定）> <gh の引数...>
# ログを空にしてから shim を呼び、OUT / ERR / RC に結果を入れる
OUT=""
ERR=""
RC=0
run_in() {
  local dir="$1" remote="$2"
  shift 2
  : >"${LOG}"
  RC=0
  if [ -n "${remote}" ]; then
    OUT="$(cd "${dir}" && env -u GH_REPO CLAUDE_CODE_REMOTE="${remote}" GH_LOG="${LOG}" GH_FIX="${FIX}" \
      PATH="${RUN_PATH}" gh "$@" 2>"${WORK}/err")" || RC=$?
  else
    OUT="$(cd "${dir}" && env -u GH_REPO -u CLAUDE_CODE_REMOTE GH_LOG="${LOG}" GH_FIX="${FIX}" \
      PATH="${RUN_PATH}" gh "$@" 2>"${WORK}/err")" || RC=$?
  fi
  ERR="$(cat "${WORK}/err")"
}

# クラウド（CLAUDE_CODE_REMOTE=true）で、git repo の外から呼ぶ
cloud() {
  run_in "${NOGIT}" true "$@"
}

# クラウドで、origin が acme/app の git repo から呼ぶ
cloud_origin() {
  run_in "${ORIGIN}" true "$@"
}

# expect_rc <名前> <exit code> — 直前の呼び出しの exit code
expect_rc() {
  if [ "${RC}" -eq "$2" ]; then
    pass "$1 (exit $2)"
  else
    fail "$1" "exit ${RC}（期待 $2） / stderr: ${ERR}"
  fi
}

# expect_json <名前> <期待 JSON> — OUT がキー順を除いて期待 JSON と同じ
expect_json() {
  local got want
  got="$(printf '%s' "${OUT}" | jq -S -c . 2>/dev/null || true)"
  want="$(printf '%s' "$2" | jq -S -c .)"
  if [ "${RC}" -eq 0 ] && [ "${got}" = "${want}" ]; then
    pass "$1"
  else
    fail "$1" "exit ${RC} / got: ${OUT} / want: ${want} / stderr: ${ERR}"
  fi
}

expect_out() {
  if [ "${OUT}" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "got: ${OUT} / want: $2 / stderr: ${ERR}"
  fi
}

# expect_log <名前> <行> — 偽の gh のログにその行（argv 1 回分、または body）がある
expect_log() {
  if grep -qxF -- "$2" "${LOG}"; then
    pass "$1"
  else
    fail "$1" "ログに無い: $2 / log: $(tr '\n' ' ' <"${LOG}") / stderr: ${ERR}"
  fi
}

# expect_only_log <名前> <行> — 偽の gh が 1 回だけ、その argv で呼ばれた
expect_only_log() {
  if [ "$(cat "${LOG}")" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "got: $(tr '\n' ' ' <"${LOG}") / want: $2 / stderr: ${ERR}"
  fi
}

# expect_unsupported <名前> <stderr に出るはずの要素名> — exit 2・stderr 1 行・偽の gh は呼ばれない
expect_unsupported() {
  local lines
  lines="$(printf '%s\n' "${ERR}" | wc -l | tr -d ' ')"
  if [ "${RC}" -eq 2 ] && [ "${lines}" -eq 1 ] && [[ ${ERR} == *"$2"* ]] && [ ! -s "${LOG}" ]; then
    pass "$1"
  else
    fail "$1" "exit ${RC} / stderr(${lines} 行): ${ERR} / log: $(tr '\n' ' ' <"${LOG}")"
  fi
}

fixture() { # <名前> — stdin の JSON を fixture に書く
  cat >"${FIX}/$1.json"
}

# ---- fixture: acme/app の PR 5（conflict・check 失敗）/ 6（保留）/ 7（全部成功）------------------------

pr_fixture() { # <番号> <head sha> <mergeable> <mergeable_state>
  jq -n --argjson n "$1" --arg sha "$2" --argjson mergeable "$3" --arg mstate "$4" '{
    number: $n, state: "open", title: "Add x", body: "Body\ntext",
    html_url: "https://github.com/acme/app/pull/\($n)",
    mergeable: $mergeable, mergeable_state: $mstate, additions: 3, deletions: 1, changed_files: 2,
    user: {login: "alice", node_id: "U_1", id: 1, type: "User"},
    head: {ref: "feat", sha: $sha},
    base: {ref: "main", sha: "def4560000000000000000000000000000000000"}
  }'
}
pr_fixture 5 abc1230000000000000000000000000000000000 false dirty | fixture repos_acme_app_pulls_5
pr_fixture 6 6666666666666666666666666666666666666666 true clean | fixture repos_acme_app_pulls_6
pr_fixture 7 7777777777777777777777777777777777777777 null unknown | fixture repos_acme_app_pulls_7

fixture repos_acme_app_commits_abc1230000000000000000000000000000000000_check-runs <<'EOF'
{"total_count": 2, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"},
  {"name": "lint", "status": "completed", "conclusion": "failure", "details_url": "https://ci/lint",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:00:30Z"}
]}
EOF
fixture repos_acme_app_commits_abc1230000000000000000000000000000000000_status <<'EOF'
{"state": "success", "statuses": [
  {"context": "deploy/preview", "state": "success", "description": "Ready", "target_url": "https://preview",
   "created_at": "2026-01-01T00:02:00Z"}
]}
EOF
fixture repos_acme_app_commits_6666666666666666666666666666666666666666_check-runs <<'EOF'
{"total_count": 2, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"},
  {"name": "e2e", "status": "in_progress", "conclusion": null, "details_url": "https://ci/e2e",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": null}
]}
EOF
echo '{"state": "pending", "statuses": []}' | fixture repos_acme_app_commits_6666666666666666666666666666666666666666_status
fixture repos_acme_app_commits_7777777777777777777777777777777777777777_check-runs <<'EOF'
{"total_count": 2, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"},
  {"name": "docs", "status": "completed", "conclusion": "skipped", "details_url": "https://ci/docs",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:00:00Z"}
]}
EOF
echo '{"state": "pending", "statuses": []}' | fixture repos_acme_app_commits_7777777777777777777777777777777777777777_status

# PR 8: check はキャンセルで、commit status は 2 ページ（2 ページ目に失敗）
pr_fixture 8 8888888888888888888888888888888888888888 true clean | fixture repos_acme_app_pulls_8
fixture repos_acme_app_commits_8888888888888888888888888888888888888888_check-runs <<'EOF'
{"total_count": 1, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "cancelled", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"}
]}
EOF
fixture repos_acme_app_commits_8888888888888888888888888888888888888888_status <<'EOF'
{"state": "success", "statuses": [{"context": "ci/a", "state": "success", "created_at": "2026-01-01T00:02:00Z"}]}
{"state": "failure", "statuses": [{"context": "ci/b", "state": "failure", "created_at": "2026-01-01T00:02:00Z"}]}
EOF
# PR 9: check はキャンセルだけ（失敗も保留も無い）
pr_fixture 9 9999999999999999999999999999999999999999 true clean | fixture repos_acme_app_pulls_9
fixture repos_acme_app_commits_9999999999999999999999999999999999999999_check-runs <<'EOF'
{"total_count": 1, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "cancelled", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"}
]}
EOF
echo '{"state": "pending", "statuses": []}' | fixture repos_acme_app_commits_9999999999999999999999999999999999999999_status
# PR 10: check 名にタブと改行（成功の行を偽造しようとする名前）
pr_fixture 10 aaaa000000000000000000000000000000000000 true clean | fixture repos_acme_app_pulls_10
fixture repos_acme_app_commits_aaaa000000000000000000000000000000000000_check-runs <<'EOF'
{"total_count": 1, "check_runs": [
  {"name": "lint\tpass\t\t\t\nrequired", "status": "completed", "conclusion": "failure", "details_url": "https://ci/lint",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:00:30Z"}
]}
EOF
echo '{"state": "pending", "statuses": []}' | fixture repos_acme_app_commits_aaaa000000000000000000000000000000000000_status
# PR 67: changed_files より files が少ない（REST の打ち切り）
pr_fixture 67 6767676767676767676767676767676767676767 true clean | jq '.changed_files = 3001' | fixture repos_acme_app_pulls_67
echo '{"files": [{"filename": "a", "additions": 1, "deletions": 0, "status": "added"}]}' |
  fixture repos_acme_app_compare_def4560000000000000000000000000000000000...6767676767676767676767676767676767676767
# PR 68: API 応答の head.sha が URL の区切り文字を含む
pr_fixture 68 '6666666666666666666666666666666666666666/../../x?' true clean | fixture repos_acme_app_pulls_68
# PR 69: head.sha がブランチ名の形。PR 70: base.sha が短縮 SHA の形（どちらも 40 桁の 16 進ではない）
pr_fixture 69 feature true clean | fixture repos_acme_app_pulls_69
pr_fixture 70 6666666666666666666666666666666666666666 true clean | jq '.base.sha = "def4560"' |
  fixture repos_acme_app_pulls_70
fixture repos_acme_app_issues_5_comments <<'EOF'
[
  {"node_id": "IC_1", "user": {"login": "github-actions[bot]", "type": "Bot"}, "author_association": "NONE",
   "body": "hello", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
   "html_url": "https://github.com/acme/app/pull/5#issuecomment-1"}
]
EOF
# 変更ファイルは PR 番号ではなく base / head の SHA の比較（compare）から読む
fixture repos_acme_app_compare_def4560000000000000000000000000000000000...abc1230000000000000000000000000000000000 <<'EOF'
{"files": [
  {"filename": "src/a.ts", "additions": 3, "deletions": 0, "status": "added"},
  {"filename": "docs/b.md", "additions": 0, "deletions": 1, "status": "modified"}
]}
EOF
# pr list（closed の 4 は merge 済み、3 は merge せずに閉じた）
fixture repos_acme_app_pulls <<'EOF'
[
  {"number": 3, "state": "closed", "merged_at": null,
   "head": {"ref": "feat", "sha": "3333333333333333333333333333333333333333"}, "base": {"ref": "main"}},
  {"number": 4, "state": "closed", "merged_at": "2025-12-01T00:00:00Z",
   "head": {"ref": "feat", "sha": "4444444444444444444444444444444444444444"}, "base": {"ref": "main"}},
  {"number": 5, "state": "open", "merged_at": null,
   "head": {"ref": "feat", "sha": "abc1230000000000000000000000000000000000"}, "base": {"ref": "main"}}
]
EOF

# ---- fixture: issue 12 と一覧 -------------------------------------------------------------------------

fixture repos_acme_app_issues_12 <<'EOF'
{"number": 12, "state": "closed", "state_reason": "completed", "title": "Bug", "body": null,
 "html_url": "https://github.com/acme/app/issues/12",
 "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-02T00:00:00Z", "closed_at": "2026-01-02T00:00:00Z",
 "user": {"login": "alice", "node_id": "U_1", "id": 1, "type": "User"},
 "labels": [{"node_id": "L_1", "name": "bug", "description": "Broken", "color": "ff0000"}],
 "assignees": [{"login": "bob", "node_id": "U_2", "id": 2, "type": "User"}],
 "milestone": {"number": 3, "title": "v1", "description": null, "due_on": null}}
EOF
fixture repos_acme_app_issues_12_comments <<'EOF'
[
  {"node_id": "IC_2", "user": {"login": "bob", "type": "User"}, "author_association": "MEMBER",
   "body": "me too", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:05:00Z",
   "html_url": "https://github.com/acme/app/issues/12#issuecomment-2"}
]
EOF
# REST の issues は PR（pull_request を持つ）も返す
fixture repos_acme_app_issues <<'EOF'
[
  {"number": 12, "state": "closed", "title": "Bug", "body": "b", "closed_at": "2026-01-02T00:00:00Z"},
  {"number": 5, "state": "open", "title": "Add x", "body": "p", "closed_at": null, "pull_request": {"url": "x"}},
  {"number": 11, "state": "open", "title": "Idea", "body": null, "closed_at": null}
]
EOF
# search は 2 ページ（100 件 + 50 件。先頭は issue 11）。偽の gh は --slurp で 2 ページの配列にする
{
  jq -c -n '{total_count: 150, items: ([{number: 11, state: "open", title: "Idea", body: null, closed_at: null}]
    + [range(1000; 1099) | {number: ., state: "open", title: "t", body: null, closed_at: null}])}'
  jq -c -n '{total_count: 150, items: [range(1099; 1149) | {number: ., state: "open", title: "t", body: null, closed_at: null}]}'
} | fixture search_issues
echo '[{"number": 3, "title": "v1"}, {"number": 4, "title": "v2"}]' | fixture repos_acme_app_milestones
echo '{"number": 9, "html_url": "https://github.com/acme/app/pull/9"}' | fixture POST_repos_acme_app_pulls
echo '{"html_url": "https://github.com/acme/app/issues/20"}' | fixture POST_repos_acme_app_issues
echo '{"html_url": "https://github.com/acme/app/pull/5#issuecomment-9"}' | fixture POST_repos_acme_app_issues_5_comments
echo '{"html_url": "https://github.com/acme/app/issues/12#issuecomment-8"}' | fixture POST_repos_acme_app_issues_12_comments

echo "=== cloud gh shim tests ==="

echo "--- AC-1: クラウドでだけ変換し、それ以外は実体に引数をそのまま渡す ---"
run_in "${NOGIT}" "" pr view 5 -R acme/app --json number --jq '.number | tostring'
expect_only_log "CLAUDE_CODE_REMOTE が無ければ実体の gh に argv をそのまま渡す" \
  "[pr][view][5][-R][acme/app][--json][number][--jq][.number | tostring]"
run_in "${NOGIT}" false pr ready 5
expect_only_log "CLAUDE_CODE_REMOTE=false でも実体にそのまま渡す" "[pr][ready][5]"
cloud pr view 5 --repo acme/app --json title
expect_only_log "CLAUDE_CODE_REMOTE=true では REST（gh api）に変換する" "[api][-X][GET][repos/acme/app/pulls/5]"
expect_json "変換した結果を返す" '{"title": "Add x"}'

echo "--- AC-2: pr view / issue view の --json ---"
cloud pr view 5 --repo acme/app --json url,headRefName,baseRefName,headRefOid,baseRefOid,title,body,comments,mergeable,mergeStateStatus,statusCheckRollup,files,additions,deletions
expect_json "pr view: 表の全 field" '{
  "url": "https://github.com/acme/app/pull/5", "headRefName": "feat", "baseRefName": "main",
  "headRefOid": "abc1230000000000000000000000000000000000", "baseRefOid": "def4560000000000000000000000000000000000",
  "title": "Add x", "body": "Body\ntext",
  "comments": [{"id": "IC_1", "author": {"login": "github-actions[bot]"}, "authorAssociation": "NONE", "body": "hello",
    "createdAt": "2026-01-01T00:00:00Z", "includesCreatedEdit": false, "isMinimized": false, "minimizedReason": "",
    "reactionGroups": [], "url": "https://github.com/acme/app/pull/5#issuecomment-1", "viewerDidAuthor": false}],
  "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY",
  "statusCheckRollup": [
    {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "workflowName": "",
     "detailsUrl": "https://ci/build", "startedAt": "2026-01-01T00:00:00Z", "completedAt": "2026-01-01T00:01:05Z"},
    {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE", "workflowName": "",
     "detailsUrl": "https://ci/lint", "startedAt": "2026-01-01T00:00:00Z", "completedAt": "2026-01-01T00:00:30Z"},
    {"__typename": "StatusContext", "context": "deploy/preview", "state": "SUCCESS", "targetUrl": "https://preview",
     "startedAt": "2026-01-01T00:02:00Z"}
  ],
  "files": [{"path": "src/a.ts", "additions": 3, "deletions": 0, "changeType": "ADDED"},
    {"path": "docs/b.md", "additions": 0, "deletions": 1, "changeType": "MODIFIED"}],
  "additions": 3, "deletions": 1
}'
expect_log "statusCheckRollup: check-runs を読む" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc1230000000000000000000000000000000000/check-runs][-f][per_page=100]"
expect_log "statusCheckRollup: commit statuses を読む" "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc1230000000000000000000000000000000000/status][-f][per_page=100]"
expect_log "files: PR 番号ではなく応答の base / head の SHA で変更ファイルを読む" \
  "[api][-X][GET][repos/acme/app/compare/def4560000000000000000000000000000000000...abc1230000000000000000000000000000000000]"
cloud pr view 6 --repo acme/app --json mergeable,mergeStateStatus,headRefOid
expect_json "pr view: mergeable true → MERGEABLE" \
  '{"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "6666666666666666666666666666666666666666"}'
expect_only_log "pr view: 指定されていない field の API は呼ばない" "[api][-X][GET][repos/acme/app/pulls/6]"
cloud pr view 7 --repo acme/app --json mergeable,mergeStateStatus
expect_json "pr view: mergeable null → UNKNOWN" '{"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"}'
cloud pr view 5 --repo acme/app --json headRefName -q .headRefName
expect_out "pr view: -q は文字列を生で出す" "feat"
cloud pr view 5 --repo acme/app --json url,title --jq '"\(.title) \(.url)"'
expect_out "pr view: --jq" "Add x https://github.com/acme/app/pull/5"

cloud issue view 12 --repo acme/app --json number,title,body,url,state,labels,assignees,milestone,comments,author,updatedAt
expect_json "issue view: 表の全 field" '{
  "number": 12, "title": "Bug", "body": "", "url": "https://github.com/acme/app/issues/12", "state": "CLOSED",
  "labels": [{"id": "L_1", "name": "bug", "description": "Broken", "color": "ff0000"}],
  "assignees": [{"id": "U_2", "login": "bob", "name": "", "databaseId": 2}],
  "milestone": {"number": 3, "title": "v1", "description": "", "dueOn": null},
  "comments": [{"id": "IC_2", "author": {"login": "bob"}, "authorAssociation": "MEMBER", "body": "me too",
    "createdAt": "2026-01-01T00:00:00Z", "includesCreatedEdit": true, "isMinimized": false, "minimizedReason": "",
    "reactionGroups": [], "url": "https://github.com/acme/app/issues/12#issuecomment-2", "viewerDidAuthor": false}],
  "author": {"id": "U_1", "is_bot": false, "login": "alice", "name": ""},
  "updatedAt": "2026-01-02T00:00:00Z"
}'
cloud issue view 12 --repo acme/app --json labels --jq '[.labels[].name]'
expect_out "issue view: --jq" '["bug"]'

echo "--- AC-3: pr checks ---"
cloud_origin pr checks 5
expect_rc "pr checks: 失敗があれば exit 1" 1
expect_out "pr checks: check-runs と commit statuses を 1 行ずつ出す" \
  "$(printf 'build\tpass\t1m5s\thttps://ci/build\t\ndeploy/preview\tpass\t\thttps://preview\tReady\nlint\tfail\t30s\thttps://ci/lint\t')"
expect_log "pr checks: head sha の check-runs を読む" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc1230000000000000000000000000000000000/check-runs][-f][per_page=100]"
expect_log "pr checks: head sha の commit statuses を読む" "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc1230000000000000000000000000000000000/status][-f][per_page=100]"
cloud_origin pr checks 6
expect_rc "pr checks: 失敗が無く保留があれば exit 8" 8
cloud_origin pr checks 7
expect_rc "pr checks: 成功と skip だけなら exit 0" 0
cloud_origin pr checks 8
expect_rc "pr checks: 2 ページ目の commit status の失敗で exit 1" 1
expect_out "pr checks: 2 ページ目の commit status も読む" "$(printf 'build\tcancel\t1m5s\thttps://ci/build\t\nci/a\tpass\t\t\t\nci/b\tfail\t\t\t')"
cloud_origin pr checks 9
expect_rc "pr checks: キャンセルだけなら実体の gh と同じく exit 0" 0
cloud_origin pr checks 10
expect_out "pr checks: check 名のタブ・改行はエスケープし、1 check = 1 行にする" \
  "$(printf 'lint\\tpass\\t\\t\\t\\nrequired\tfail\t30s\thttps://ci/lint\t')"

echo "--- AC-4: 書き込み系と pr diff / pr list / issue list ---"
printf 'from file\n' >"${WORK}/body.md"
cloud pr create --repo acme/app --draft --base main --head feat --title "T 1" --body-file "${WORK}/body.md" --label dev-flow
expect_out "pr create: 作成した PR の URL を 1 行で出す" "https://github.com/acme/app/pull/9"
expect_log "pr create: POST pulls" "[api][-X][POST][repos/acme/app/pulls][--input][-]"
expect_log "pr create: title / body / head / base / draft" 'body {"title":"T 1","body":"from file","head":"feat","base":"main","draft":true}'
expect_log "pr create --label: 作成した PR に POST issues/{n}/labels" "[api][-X][POST][repos/acme/app/issues/9/labels][--input][-]"
expect_log "pr create --label: labels" 'body {"labels":["dev-flow"]}'
cloud pr create --repo acme/app --base main --head feat --title T --body-file "${WORK}/body.md"
expect_only_log "pr create: --draft が無ければ draft: false、--label が無ければ label の API を呼ばない" \
  "$(printf '%s\n%s' "[api][-X][POST][repos/acme/app/pulls][--input][-]" 'body {"title":"T","body":"from file","head":"feat","base":"main","draft":false}')"

cloud pr edit 5 --repo acme/app --body-file "${WORK}/body.md"
expect_out "pr edit: PR の URL を出す" "https://github.com/acme/app/pull/5"
expect_only_log "pr edit: PATCH pulls/{n} に body だけを送る" \
  "$(printf '%s\n%s' "[api][-X][PATCH][repos/acme/app/pulls/5][--input][-]" 'body {"body":"from file"}')"

cloud pr comment 5 --repo acme/app --body-file "${WORK}/body.md"
expect_out "pr comment: コメントの URL を出す" "https://github.com/acme/app/pull/5#issuecomment-9"
expect_only_log "pr comment: POST issues/{n}/comments" \
  "$(printf '%s\n%s' "[api][-X][POST][repos/acme/app/issues/5/comments][--input][-]" 'body {"body":"from file"}')"

cloud_origin pr diff 5
expect_only_log "pr diff: diff の media type で pulls/{n} を読む" \
  "[api][-X][GET][-H][Accept: application/vnd.github.v3.diff][repos/acme/app/pulls/5]"

cloud pr list --repo acme/app --head feat --state all --limit 10 --json number,headRefName,headRefOid
expect_json "pr list --json" '[
  {"number": 3, "headRefName": "feat", "headRefOid": "3333333333333333333333333333333333333333"},
  {"number": 4, "headRefName": "feat", "headRefOid": "4444444444444444444444444444444444444444"},
  {"number": 5, "headRefName": "feat", "headRefOid": "abc1230000000000000000000000000000000000"}]'
expect_only_log "pr list: GET pulls（state / head）" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/pulls][-f][per_page=100][-f][state=all][-f][head=acme:feat]"
cloud pr list --repo acme/app --head feat --state merged --limit 20 --json number,headRefOid
expect_json "pr list --state merged: closed のうち merge 済みだけを返す" \
  '[{"number": 4, "headRefOid": "4444444444444444444444444444444444444444"}]'
expect_only_log "pr list --state merged: GET pulls（state=closed）" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/pulls][-f][per_page=100][-f][state=closed][-f][head=acme:feat]"
cloud pr list --repo acme/app --state all --limit 1 --json headRefName
expect_json "pr list --limit" '[{"headRefName": "feat"}]'

cloud issue create --repo acme/app --title "T" --body-file "${WORK}/body.md" --label bug --label "help wanted" --assignee bob --milestone v2
expect_out "issue create: issue の URL を 1 行で出す" "https://github.com/acme/app/issues/20"
expect_log "issue create: POST issues" "[api][-X][POST][repos/acme/app/issues][--input][-]"
expect_log "issue create: label / assignee / milestone（名前 → 番号）" \
  'body {"title":"T","body":"from file","labels":["bug","help wanted"],"assignees":["bob"],"milestone":4}'
cloud issue create --repo acme/app --title "T" --body-file "${WORK}/body.md"
expect_log "issue create: 指定しない label 等は送らない" 'body {"title":"T","body":"from file"}'

cloud issue comment 12 --repo acme/app --body-file "${WORK}/body.md"
expect_out "issue comment: コメントの URL を出す" "https://github.com/acme/app/issues/12#issuecomment-8"
expect_only_log "issue comment: POST issues/{n}/comments" \
  "$(printf '%s\n%s' "[api][-X][POST][repos/acme/app/issues/12/comments][--input][-]" 'body {"body":"from file"}')"

cloud issue list --repo acme/app --label self-improve --state all --limit 1000 --json number,title,body,closedAt
expect_json "issue list --json: PR を除いた issue を返す" '[
  {"number": 12, "title": "Bug", "body": "b", "closedAt": "2026-01-02T00:00:00Z"},
  {"number": 11, "title": "Idea", "body": "", "closedAt": null}]'
expect_only_log "issue list: GET issues（state / labels）" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/issues][-f][per_page=100][-f][state=all][-f][labels=self-improve]"
cloud issue list --repo acme/app --state all --limit 1 --json number
expect_json "issue list --limit" '[{"number": 12}]'
cloud issue list --repo acme/app --label self-improve --state open --search "in:title Idea" --limit 1 --json number
expect_json "issue list --search: REST の search を使う" '[{"number": 11}]'
expect_only_log "issue list --search: GET search/issues を全ページ読む" \
  '[api][-X][GET][--paginate][--slurp][search/issues][-f][per_page=100][-f][q=repo:acme/app is:issue is:open label:"self-improve" in:title Idea]'
cloud issue list --repo acme/app --search "in:title Idea" --limit 1000 --json number
if [ "${RC}" -eq 0 ] && [ "$(printf '%s' "${OUT}" | jq 'length')" = 150 ]; then
  pass "issue list --search: 101 件目以降（2 ページ目）も返す"
else
  fail "issue list --search: 101 件目以降（2 ページ目）も返す" "exit ${RC} / out: ${OUT:0:200} / stderr: ${ERR}"
fi

echo "--- AC-5: 表に無い形は exit 2、pr / issue 以外は素通し ---"
cloud pr ready 5
expect_unsupported "表に無いサブコマンド（pr ready）" "pr ready"
cloud pr review 5 --repo acme/app --comment --body note
expect_unsupported "表に無いサブコマンド（pr review）" "pr review"
cloud pr merge 5 --repo acme/app --squash
expect_unsupported "表に無いサブコマンド（pr merge）" "pr merge"
cloud issue close 12
expect_unsupported "表に無いサブコマンド（issue close）" "issue close"
cloud issue edit 12 --repo acme/app --add-label triage
expect_unsupported "表に無いサブコマンド（issue edit）" "issue edit"
cloud pr edit 5 --repo acme/app --add-label x
expect_unsupported "表に無いフラグ（pr edit --add-label）" "--add-label"
cloud pr edit 5 --repo acme/app --title New --body-file "${WORK}/body.md"
expect_unsupported "表に無いフラグ（pr edit --title）" "--title"
cloud pr comment 5 --repo acme/app --body hi
expect_unsupported "表に無いフラグ（pr comment --body）" "--body"
cloud pr create --repo acme/app --fill
expect_unsupported "表に無いフラグ（pr create --fill）" "--fill"
cloud pr view 5 -R acme/app --json title
expect_unsupported "表に無いフラグ（-R）" "-R"
cloud pr checks 5 --repo acme/app
expect_unsupported "表に無いフラグ（pr checks --repo）" "--repo"
cloud_origin pr checks 5 --json name
expect_unsupported "表に無いフラグ（pr checks --json）" "--json"
cloud_origin pr diff 5 --name-only
expect_unsupported "表に無いフラグ（pr diff --name-only）" "--name-only"
cloud issue view 12 --repo acme/app --json title -q .title
expect_unsupported "表に無いフラグ（issue view -q）" "-q"
cloud pr view 5 --repo acme/app --json title,reviewDecision
expect_unsupported "表に無い --json field（pr view reviewDecision）" "reviewDecision"
cloud pr list --repo acme/app --json number,state
expect_unsupported "表に無い --json field（pr list state）" "state"
cloud issue view 12 --repo acme/app --json closedByPullRequestsReferences
expect_unsupported "表に無い --json field（issue view）" "closedByPullRequestsReferences"
cloud issue list --repo acme/app --json number,labels
expect_unsupported "表に無い --json field（issue list labels）" "labels"
cloud pr view 5 --repo acme/app
expect_unsupported "--json の無い pr view" "--json"
cloud pr edit 5 --repo acme/app
expect_unsupported "--body-file の無い pr edit" "--body-file"
cloud pr create --repo acme/app --head feat --title T --body-file "${WORK}/body.md"
expect_unsupported "--base の無い pr create" "--base"
cloud pr view feat --repo acme/app --json title
expect_unsupported "番号でない PR の指定（branch）" "pr view feat"
cloud pr comment https://github.com/acme/app/pull/5 --body-file "${WORK}/body.md"
expect_unsupported "番号でない PR の指定（URL）" "https://github.com/acme/app/pull/5"
cloud pr view --repo acme/app --json title
expect_unsupported "番号の無い pr view" "pr view"

cloud api graphql -f query='{viewer{login}}'
expect_only_log "gh api は実体に素通し" "[api][graphql][-f][query={viewer{login}}]"
cloud run list --limit 3
expect_only_log "gh run は実体に素通し" "[run][list][--limit][3]"
cloud auth status
expect_only_log "gh auth は実体に素通し" "[auth][status]"
cloud label list --repo acme/app
expect_only_log "gh label は実体に素通し" "[label][list][--repo][acme/app]"
cloud --version
expect_only_log "サブコマンドの無い呼び出しは実体に素通し" "[--version]"

echo "--- 入力と API 応答の検証 ---"
# expect_refused <名前> <ログに出てはいけない文字列> — 0 以外で終わり、その呼び出しに届かない
expect_refused() {
  if [ "${RC}" -ne 0 ] && [ -n "${ERR}" ] && ! grep -qF -- "$2" "${LOG}"; then
    pass "$1"
  else
    fail "$1" "exit ${RC} / log: $(tr '\n' ' ' <"${LOG}") / stderr: ${ERR}"
  fi
}
cloud_origin pr checks 68
expect_refused "pr checks: API 応答の head.sha が SHA の形でなければ check の API を呼ばない" "/commits/"
cloud_origin pr checks 69
expect_refused "pr checks: head.sha がブランチ名の形なら check の API を呼ばない" "/commits/"
cloud pr view 69 --repo acme/app --json files
expect_refused "pr view --json files: head.sha がブランチ名の形なら compare を呼ばない" "/compare/"
cloud pr view 70 --repo acme/app --json files
expect_refused "pr view --json files: base.sha が 40 桁の 16 進でなければ compare を呼ばない" "/compare/"
cloud pr view 67 --repo acme/app --json files
expect_refused "pr view --json files: 一覧が changed_files に足りなければ止める" "__never__"
expect_out "pr view --json files: 一部だけの一覧を出さない" ""
cloud issue list --repo acme/app --search x --limit "x[\$(touch ${WORK}/pwned)]" --json number
expect_refused "issue list: 数でない --limit は API を呼ぶ前に拒否する" "search/issues"
if [ -e "${WORK}/pwned" ]; then
  fail "issue list: --limit の値を算術式で評価しない" "${WORK}/pwned が作られた"
else
  pass "issue list: --limit の値を算術式で評価しない"
fi
# shellcheck disable=SC2016 # jq のプログラム（$ENV は jq の変数）
SHIM_TEST_SECRET=s3cr3t cloud pr view 5 --repo acme/app --json title --jq '[env.SHIM_TEST_SECRET, $ENV.SHIM_TEST_SECRET]'
expect_out "--jq: プログラムから環境変数（GH_TOKEN 等）を読ませない" '[null,null]'
printf '{"k": "leaked"}\n' >"${WORK}/data.json"
cloud pr view 5 --repo acme/app --json title --jq "import \"${WORK}/data\" as \$d; \$d"
if [ "${RC}" -ne 0 ] && [ -z "${OUT}" ]; then
  pass "--jq: import で手元の JSON ファイルを読ませない"
else
  fail "--jq: import で手元の JSON ファイルを読ませない" "exit ${RC} / out: ${OUT}"
fi
run_in "${WORK}" true issue comment 12 --repo acme/app --body-file body.md
expect_out "--body-file: 相対パスのファイルを読む" "https://github.com/acme/app/issues/12#issuecomment-8"
cloud pr comment 5 --repo acme/app --body-file "${WORK}/missing.md"
expect_refused "--body-file: 読めないファイルなら API を呼ばずに失敗する" "body "
cloud pr list --repo acme/app --limit 0x10 --json number
expect_refused "pr list: 数でない --limit を拒否する" "repos/acme/app/pulls"
cloud pr view 5 --repo 'acme/app?x=1' --json title
expect_refused "--repo の repo 名に URL の区切り文字があれば拒否する" "repos/acme"
cloud pr view 5 --repo 'acme/app/../other' --json title
expect_refused "--repo が owner/repo の 2 成分でなければ拒否する" "repos/acme"

echo "--- AC-6: repo の決め方 ---"
cloud pr view 5 --repo acme/app --json title
expect_only_log "--repo owner/repo" "[api][-X][GET][repos/acme/app/pulls/5]"
cloud issue view 12 --json title --repo=acme/app
expect_only_log "--repo=owner/repo" "[api][-X][GET][repos/acme/app/issues/12]"

run_in "${ORIGIN}" true pr view 5 --json title
expect_only_log "origin（https）から owner/repo を決める" "[api][-X][GET][repos/acme/app/pulls/5]"
run_in "$(origin_repo ssh git@github.com:acme/app.git)" true issue view 12 --json title
expect_only_log "origin（ssh）から owner/repo を決める" "[api][-X][GET][repos/acme/app/issues/12]"
run_in "$(origin_repo proxy http://local_proxy@127.0.0.1:18080/git/acme/app)" true pr view 5 --json title
expect_only_log "origin（クラウドの git proxy）から owner/repo を決める" "[api][-X][GET][repos/acme/app/pulls/5]"
run_in "${ORIGIN}" true pr view 6 --repo other/thing --json title
expect_only_log "--repo は origin より優先する" "[api][-X][GET][repos/other/thing/pulls/6]"
cloud pr view 5 --json title
if [ "${RC}" -ne 0 ] && [ ! -s "${LOG}" ] && [ -n "${ERR}" ]; then
  pass "repo が決まらなければ API を呼ばずに失敗する"
else
  fail "repo が決まらないのに進んだ" "exit ${RC} / log: $(tr '\n' ' ' <"${LOG}") / stderr: ${ERR}"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -ne 0 ]; then
  printf '%s\n' "${ERRORS[@]}"
  exit 1
fi
