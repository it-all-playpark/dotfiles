#!/usr/bin/env bash
# tests/cloud-gh-shim.test.sh
# cloud/bin/gh（クラウドセッション用の gh shim）が、CLAUDE_CODE_REMOTE=true のときだけ `gh pr` / `gh issue` を
# REST（実体の `gh api`）に変換し、GraphQL 版と同じ形の出力・exit code を返すことを確かめる。
# Run from the repo root: bash tests/cloud-gh-shim.test.sh
# Requires: git, jq（実体の gh があれば --json の field 一覧も突き合わせる。無ければその項目だけ SKIP）
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

# 実体の gh（--json の field 一覧の突き合わせ用）は、偽の gh を PATH に足す前に解決しておく
REAL_GH="$(command -v gh 2>/dev/null || true)"

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

# ---- fixture: acme/app の PR 5（draft・conflict・check 失敗）/ 6（保留）/ 7（全部成功）-----------------

pr_fixture() { # <番号> <head sha> <mergeable> <mergeable_state> <draft>
  jq -n --argjson n "$1" --arg sha "$2" --argjson mergeable "$3" --arg mstate "$4" --argjson draft "$5" '{
    number: $n, state: "open", title: "Add x", body: "Body\ntext", draft: $draft,
    html_url: "https://github.com/acme/app/pull/\($n)",
    created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-02T00:00:00Z", closed_at: null, merged_at: null,
    mergeable: $mergeable, mergeable_state: $mstate, merge_commit_sha: "m1", merged_by: null,
    additions: 3, deletions: 1, changed_files: 2, maintainer_can_modify: true,
    user: {login: "alice", node_id: "U_1", id: 1, type: "User"},
    head: {ref: "feat", sha: $sha, repo: {node_id: "R_1", name: "app", full_name: "acme/app"},
      user: {login: "acme", node_id: "O_1"}},
    base: {ref: "main", sha: "def456", repo: {full_name: "acme/app"}},
    labels: [{node_id: "L_1", name: "bug", description: null, color: "ff0000"}],
    assignees: [{login: "bob", node_id: "U_2", id: 2, type: "User"}],
    requested_reviewers: [{login: "carol"}], requested_teams: [], milestone: null, auto_merge: null
  }'
}
pr_fixture 5 abc123 false dirty true | fixture repos_acme_app_pulls_5
pr_fixture 6 sha6 true clean false | fixture repos_acme_app_pulls_6
pr_fixture 7 sha7 null unknown false | fixture repos_acme_app_pulls_7

fixture repos_acme_app_commits_abc123_check-runs <<'EOF'
{"total_count": 2, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"},
  {"name": "lint", "status": "completed", "conclusion": "failure", "details_url": "https://ci/lint",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:00:30Z"}
]}
EOF
fixture repos_acme_app_commits_abc123_status <<'EOF'
{"state": "success", "statuses": [
  {"context": "deploy/preview", "state": "success", "description": "Ready", "target_url": "https://preview",
   "created_at": "2026-01-01T00:02:00Z"}
]}
EOF
fixture repos_acme_app_commits_sha6_check-runs <<'EOF'
{"total_count": 2, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"},
  {"name": "e2e", "status": "in_progress", "conclusion": null, "details_url": "https://ci/e2e",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": null}
]}
EOF
echo '{"state": "pending", "statuses": []}' | fixture repos_acme_app_commits_sha6_status
fixture repos_acme_app_commits_sha7_check-runs <<'EOF'
{"total_count": 2, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "success", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"},
  {"name": "docs", "status": "completed", "conclusion": "skipped", "details_url": "https://ci/docs",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:00:00Z"}
]}
EOF
echo '{"state": "pending", "statuses": []}' | fixture repos_acme_app_commits_sha7_status

# PR 5: bob は APPROVED のあと CHANGES_REQUESTED、dave は APPROVED。PR 6: dave の APPROVED だけ。PR 7: review なし
fixture repos_acme_app_pulls_5_reviews <<'EOF'
[
  {"node_id": "PRR_1", "user": {"login": "bob", "type": "User"}, "state": "APPROVED", "body": "",
   "submitted_at": "2026-01-01T01:00:00Z", "commit_id": "abc123", "author_association": "MEMBER"},
  {"node_id": "PRR_2", "user": {"login": "dave", "type": "User"}, "state": "APPROVED", "body": "lgtm",
   "submitted_at": "2026-01-01T02:00:00Z", "commit_id": "abc123", "author_association": "MEMBER"},
  {"node_id": "PRR_3", "user": {"login": "bob", "type": "User"}, "state": "CHANGES_REQUESTED", "body": "fix",
   "submitted_at": "2026-01-01T03:00:00Z", "commit_id": "abc123", "author_association": "MEMBER"}
]
EOF
fixture repos_acme_app_pulls_6_reviews <<'EOF'
[
  {"node_id": "PRR_4", "user": {"login": "dave", "type": "User"}, "state": "APPROVED", "body": "lgtm",
   "submitted_at": "2026-01-01T02:00:00Z", "commit_id": "sha6", "author_association": "MEMBER"}
]
EOF
echo '[]' | fixture repos_acme_app_pulls_7_reviews
# PR 8: head は sha8。APPROVED は古い commit に対するもの、check はキャンセルで、commit status は 2 ページ
pr_fixture 8 sha8 true clean false | fixture repos_acme_app_pulls_8
fixture repos_acme_app_pulls_8_reviews <<'EOF'
[
  {"node_id": "PRR_5", "user": {"login": "dave", "type": "User"}, "state": "APPROVED", "body": "lgtm",
   "submitted_at": "2026-01-01T02:00:00Z", "commit_id": "old8", "author_association": "MEMBER"}
]
EOF
fixture repos_acme_app_commits_sha8_check-runs <<'EOF'
{"total_count": 1, "check_runs": [
  {"name": "build", "status": "completed", "conclusion": "cancelled", "details_url": "https://ci/build",
   "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:01:05Z"}
]}
EOF
fixture repos_acme_app_commits_sha8_status <<'EOF'
{"state": "success", "statuses": [{"context": "ci/a", "state": "success", "created_at": "2026-01-01T00:02:00Z"}]}
{"state": "failure", "statuses": [{"context": "ci/b", "state": "failure", "created_at": "2026-01-01T00:02:00Z"}]}
EOF
# PR 66: API 応答の number がパス成分を含む。PR 67: changed_files より files が少ない（REST の打ち切り）
pr_fixture '"../../x"' sha6 true clean false | fixture repos_acme_app_pulls_66
pr_fixture 67 sha6 true clean false | jq '.changed_files = 3001' | fixture repos_acme_app_pulls_67
echo '[{"filename": "a", "additions": 1, "deletions": 0, "status": "added"}]' | fixture repos_acme_app_pulls_67_files
fixture repos_acme_app_issues_5_comments <<'EOF'
[
  {"node_id": "IC_1", "user": {"login": "github-actions[bot]", "type": "Bot"}, "author_association": "NONE",
   "body": "hello", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z",
   "html_url": "https://github.com/acme/app/pull/5#issuecomment-1"}
]
EOF
fixture repos_acme_app_pulls_5_commits <<'EOF'
[
  {"sha": "abc123", "commit": {"message": "feat: add x\n\ndetails",
    "author": {"name": "Alice", "email": "alice@example.com", "date": "2026-01-01T00:00:00Z"},
    "committer": {"date": "2026-01-01T00:00:01Z"}}, "author": {"login": "alice", "node_id": "U_1"}}
]
EOF
fixture repos_acme_app_pulls_5_files <<'EOF'
[
  {"filename": "src/a.ts", "additions": 3, "deletions": 0, "status": "added"},
  {"filename": "docs/b.md", "additions": 0, "deletions": 1, "status": "modified"}
]
EOF
# branch → PR の解決と pr list（closed の 4 は merge 済み）
fixture repos_acme_app_pulls <<'EOF'
[
  {"number": 4, "state": "closed", "title": "Old", "draft": false, "merged_at": "2025-12-01T00:00:00Z",
   "html_url": "https://github.com/acme/app/pull/4", "user": {"login": "bob", "type": "User"},
   "head": {"ref": "feat", "sha": "old"}, "base": {"ref": "main", "sha": "def456"}, "labels": []},
  {"number": 5, "state": "open", "title": "Add x", "draft": true, "merged_at": null,
   "html_url": "https://github.com/acme/app/pull/5", "user": {"login": "alice", "type": "User"},
   "head": {"ref": "feat", "sha": "abc123"}, "base": {"ref": "main", "sha": "def456"},
   "labels": [{"node_id": "L_1", "name": "bug", "description": null, "color": "ff0000"}]}
]
EOF

# ---- fixture: issue 12 と一覧 -------------------------------------------------------------------------

fixture repos_acme_app_issues_12 <<'EOF'
{"number": 12, "state": "closed", "state_reason": "completed", "title": "Bug", "body": null,
 "html_url": "https://github.com/acme/app/issues/12",
 "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-02T00:00:00Z", "closed_at": "2026-01-02T00:00:00Z",
 "user": {"login": "alice", "node_id": "U_1", "id": 1, "type": "User"},
 "labels": [{"node_id": "L_1", "name": "bug", "description": "Broken", "color": "ff0000"}],
 "assignees": [], "milestone": {"number": 3, "title": "v1", "description": null, "due_on": null},
 "sub_issues_summary": {"total": 2, "completed": 1, "percent_completed": 50}}
EOF
fixture repos_acme_app_issues_12_comments <<'EOF'
[
  {"node_id": "IC_2", "user": {"login": "bob", "type": "User"}, "author_association": "MEMBER",
   "body": "me too", "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:05:00Z",
   "html_url": "https://github.com/acme/app/issues/12#issuecomment-2"}
]
EOF
fixture repos_acme_app_issues_12_sub_issues <<'EOF'
[
  {"node_id": "I_13", "number": 13, "title": "Part", "html_url": "https://github.com/acme/app/issues/13",
   "state": "open", "repository_url": "https://api.github.com/repos/acme/app"}
]
EOF
echo '[]' | fixture repos_acme_app_issues_12_dependencies_blocked_by
echo '[]' | fixture repos_acme_app_issues_12_dependencies_blocking
# REST の issues は PR（pull_request を持つ）も返す
fixture repos_acme_app_issues <<'EOF'
[
  {"number": 12, "state": "open", "state_reason": null, "title": "Bug", "body": "b",
   "html_url": "https://github.com/acme/app/issues/12", "user": {"login": "alice", "type": "User"},
   "labels": [], "assignees": [], "milestone": null},
  {"number": 5, "state": "open", "title": "Add x", "pull_request": {"url": "x"},
   "html_url": "https://github.com/acme/app/pull/5", "user": {"login": "alice", "type": "User"},
   "labels": [], "assignees": [], "milestone": null},
  {"number": 11, "state": "open", "state_reason": null, "title": "Idea", "body": "i",
   "html_url": "https://github.com/acme/app/issues/11", "user": {"login": "bob", "type": "User"},
   "labels": [], "assignees": [], "milestone": null}
]
EOF
echo '{"items": [{"number": 11, "state": "open", "title": "Idea", "html_url": "https://github.com/acme/app/issues/11"}]}' |
  fixture search_issues
echo '[{"number": 3, "title": "v1"}, {"number": 4, "title": "v2"}]' | fixture repos_acme_app_milestones
echo '{"default_branch": "trunk"}' | fixture repos_acme_app
echo '{"login": "me-user"}' | fixture user
echo '{"html_url": "https://github.com/acme/app/pull/9"}' | fixture POST_repos_acme_app_pulls
echo '{"html_url": "https://github.com/acme/app/issues/20"}' | fixture POST_repos_acme_app_issues
echo '{"html_url": "https://github.com/acme/app/pull/5#issuecomment-9"}' | fixture POST_repos_acme_app_issues_5_comments
echo '{"html_url": "https://github.com/acme/app/issues/12#issuecomment-8"}' | fixture POST_repos_acme_app_issues_12_comments

echo "=== cloud gh shim tests ==="

echo "--- AC-1: クラウドでだけ変換し、それ以外は実体に引数をそのまま渡す ---"
run_in "${NOGIT}" "" pr view 5 -R acme/app --json number --jq '.number | tostring'
expect_only_log "CLAUDE_CODE_REMOTE が無ければ実体の gh に argv をそのまま渡す" \
  "[pr][view][5][-R][acme/app][--json][number][--jq][.number | tostring]"
run_in "${NOGIT}" false pr view 5 -R acme/app --json number
expect_only_log "CLAUDE_CODE_REMOTE=false でも実体にそのまま渡す" "[pr][view][5][-R][acme/app][--json][number]"
cloud pr view 5 -R acme/app --json number
expect_only_log "CLAUDE_CODE_REMOTE=true では REST（gh api）に変換する" "[api][-X][GET][repos/acme/app/pulls/5]"
expect_json "変換した結果を返す" '{"number": 5}'

echo "--- AC-2: pr view / issue view の --json ---"
shim_fields() { # <pr|issue> — shim が --json で受け付ける field（1 行 1 つ、sort 済み）
  cloud "$1" view --json
  printf '%s\n' "${ERR}" | tail -n +2 | tr -d ' ' | sort
}
# process substitution は Claude の sandbox で /dev/fd が塞がれるので一時ファイル経由
printf '%s\n' projectCards projectItems closingIssuesReferences closedByPullRequestsReferences reactionGroups id fullDatabaseId >"${WORK}/excluded"
for kind in pr issue; do
  # 実体の gh も field を付けない --json に使える field の一覧を返す（ネットワークには出ない）
  real_out="$(cd "${NOGIT}" && env -u CLAUDE_CODE_REMOTE "${REAL_GH:-false}" "${kind}" view --json 2>&1 || true)"
  if [ -z "${REAL_GH}" ] || [[ ${real_out} != "Specify one or more"* ]]; then
    echo "  SKIP: 実体の gh が無いので ${kind} view の field 一覧は突き合わせない"
    continue
  fi
  want="$(printf '%s\n' "${real_out}" | tail -n +2 | tr -d ' ' | grep -vxF -f "${WORK}/excluded" | sort)"
  got="$(shim_fields "${kind}")"
  if [ "${got}" = "${want}" ]; then
    pass "${kind} view: shim の field の表 = 実体の gh の field − 除外"
  else
    fail "${kind} view: field の表が実体の gh とずれている" "want: $(echo "${want}" | tr '\n' ' ') / got: $(echo "${got}" | tr '\n' ' ')"
  fi
done

cloud pr view 5 -R acme/app --json number,title,state,isDraft,url,body,headRefName,headRefOid,baseRefName,baseRefOid,mergeable,mergeStateStatus,additions,deletions,changedFiles,isCrossRepository,closed,mergedAt,author,labels,assignees,reviewRequests,mergeCommit,potentialMergeCommit,headRepository,headRepositoryOwner
expect_json "pr view: PR 本体の field" '{
  "headRepository": {"id": "R_1", "name": "app", "nameWithOwner": "acme/app"},
  "headRepositoryOwner": {"id": "O_1", "name": "", "login": "acme"},
  "number": 5, "title": "Add x", "state": "OPEN", "isDraft": true, "url": "https://github.com/acme/app/pull/5",
  "body": "Body\ntext", "headRefName": "feat", "headRefOid": "abc123", "baseRefName": "main", "baseRefOid": "def456",
  "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY", "additions": 3, "deletions": 1, "changedFiles": 2,
  "isCrossRepository": false, "closed": false, "mergedAt": null,
  "author": {"id": "U_1", "is_bot": false, "login": "alice", "name": ""},
  "labels": [{"id": "L_1", "name": "bug", "description": "", "color": "ff0000"}],
  "assignees": [{"id": "U_2", "login": "bob", "name": "", "databaseId": 2}],
  "reviewRequests": [{"__typename": "User", "login": "carol"}],
  "mergeCommit": null, "potentialMergeCommit": {"oid": "m1"}
}'
cloud pr view 6 -R acme/app --json mergeable,mergeStateStatus,isDraft
expect_json "pr view: mergeable true → MERGEABLE" '{"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "isDraft": false}'
cloud pr view 7 -R acme/app --json mergeable,mergeStateStatus
expect_json "pr view: mergeable null → UNKNOWN" '{"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"}'

cloud pr view 5 -R acme/app --json headRefOid,statusCheckRollup
expect_json "pr view: statusCheckRollup は check-runs と commit statuses から組み立てる" '{
  "headRefOid": "abc123",
  "statusCheckRollup": [
    {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "workflowName": "",
     "detailsUrl": "https://ci/build", "startedAt": "2026-01-01T00:00:00Z", "completedAt": "2026-01-01T00:01:05Z"},
    {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE", "workflowName": "",
     "detailsUrl": "https://ci/lint", "startedAt": "2026-01-01T00:00:00Z", "completedAt": "2026-01-01T00:00:30Z"},
    {"__typename": "StatusContext", "context": "deploy/preview", "state": "SUCCESS", "targetUrl": "https://preview",
     "startedAt": "2026-01-01T00:02:00Z"}
  ]
}'
expect_log "statusCheckRollup: check-runs を読む" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc123/check-runs][-f][per_page=100]"
expect_log "statusCheckRollup: commit statuses を読む" "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc123/status][-f][per_page=100]"

cloud pr view 5 -R acme/app --json reviewDecision,latestReviews --jq '[.reviewDecision, (.latestReviews | map(.author.login + "=" + .state) | join(","))] | join(" ")'
expect_out "pr view: reviewer ごとの最新の判定に CHANGES_REQUESTED があれば CHANGES_REQUESTED" "CHANGES_REQUESTED dave=APPROVED,bob=CHANGES_REQUESTED"
cloud pr view 6 -R acme/app --json reviewDecision
expect_json "pr view: APPROVED だけなら APPROVED" '{"reviewDecision": "APPROVED"}'
cloud pr view 7 -R acme/app --json reviewDecision
expect_json "pr view: review が無く依頼が残っていれば REVIEW_REQUIRED" '{"reviewDecision": "REVIEW_REQUIRED"}'
cloud pr view 8 -R acme/app --json reviewDecision
expect_json "pr view: 今の head より古い commit への APPROVED だけなら REVIEW_REQUIRED" '{"reviewDecision": "REVIEW_REQUIRED"}'

cloud pr view 5 -R acme/app --json comments,commits,files
expect_json "pr view: comments / commits / files" '{
  "comments": [{"id": "IC_1", "author": {"login": "app/github-actions"}, "authorAssociation": "NONE", "body": "hello",
    "createdAt": "2026-01-01T00:00:00Z", "includesCreatedEdit": false, "isMinimized": false, "minimizedReason": "",
    "reactionGroups": [], "url": "https://github.com/acme/app/pull/5#issuecomment-1", "viewerDidAuthor": false}],
  "commits": [{"authoredDate": "2026-01-01T00:00:00Z", "committedDate": "2026-01-01T00:00:01Z",
    "authors": [{"email": "alice@example.com", "id": "U_1", "login": "alice", "name": "Alice"}],
    "messageHeadline": "feat: add x", "messageBody": "details", "oid": "abc123"}],
  "files": [{"path": "src/a.ts", "additions": 3, "deletions": 0, "changeType": "ADDED"},
    {"path": "docs/b.md", "additions": 0, "deletions": 1, "changeType": "MODIFIED"}]
}'

cloud pr view 5 -R acme/app --json headRefName -q .headRefName
expect_out "pr view: -q は文字列を生で出す" "feat"
cloud pr view 5 -R acme/app --json number,url --jq '"\(.number) \(.url)"'
expect_out "pr view: --jq" "5 https://github.com/acme/app/pull/5"

cloud pr view feat -R acme/app --json number
expect_json "pr view <branch>: open の PR を選ぶ" '{"number": 5}'
expect_log "pr view <branch>: head で PR を引く" \
  "[api][-X][GET][repos/acme/app/pulls][-f][head=acme:feat][-f][state=all][-f][per_page=100]"

for kind in pr issue; do
  n=5
  [ "${kind}" = pr ] || n=12
  all="$(shim_fields "${kind}" | paste -sd, -)"
  cloud "${kind}" view "${n}" -R acme/app --json "${all}"
  got="$(printf '%s' "${OUT}" | jq -r 'keys | sort | join(",")' 2>/dev/null || true)"
  if [ "${RC}" -eq 0 ] && [ -n "${all}" ] && [ "${got}" = "$(printf '%s' "${all}" | tr ',' '\n' | sort | paste -sd, -)" ]; then
    pass "${kind} view: 表の field を全部指定すると全部のキーが返る"
  else
    fail "${kind} view: 表の field が全部は返らない" "exit ${RC} / keys: ${got} / stderr: ${ERR}"
  fi
done

cloud issue view 12 -R acme/app --json number,title,state,stateReason,closed,closedAt,body,url,author,labels,milestone,comments,subIssues,subIssuesSummary,parent,isPinned,issueType
expect_json "issue view: 主要 field" '{
  "number": 12, "title": "Bug", "state": "CLOSED", "stateReason": "COMPLETED", "closed": true,
  "closedAt": "2026-01-02T00:00:00Z", "body": "", "url": "https://github.com/acme/app/issues/12",
  "author": {"id": "U_1", "is_bot": false, "login": "alice", "name": ""},
  "labels": [{"id": "L_1", "name": "bug", "description": "Broken", "color": "ff0000"}],
  "milestone": {"number": 3, "title": "v1", "description": "", "dueOn": null},
  "comments": [{"id": "IC_2", "author": {"login": "bob"}, "authorAssociation": "MEMBER", "body": "me too",
    "createdAt": "2026-01-01T00:00:00Z", "includesCreatedEdit": true, "isMinimized": false, "minimizedReason": "",
    "reactionGroups": [], "url": "https://github.com/acme/app/issues/12#issuecomment-2", "viewerDidAuthor": false}],
  "subIssues": {"nodes": [{"id": "I_13", "number": 13, "title": "Part", "url": "https://github.com/acme/app/issues/13",
    "state": "OPEN", "repository": {"nameWithOwner": "acme/app"}}], "totalCount": 1},
  "subIssuesSummary": {"total": 2, "completed": 1, "percentCompleted": 50},
  "parent": null, "isPinned": false, "issueType": null
}'
cloud issue view 12 -R acme/app --json blockedBy,blocking --jq '[.blockedBy.totalCount, .blocking.totalCount, (.blocking.nodes | length)]'
expect_out "issue view: blockedBy / blocking は {nodes, totalCount}" '[0,0,0]'
cloud issue view 12 -R acme/app --json labels --jq '[.labels[].name]'
expect_out "issue view: --jq" '["bug"]'

echo "--- AC-3: pr checks ---"
cloud pr checks 5 -R acme/app
expect_rc "pr checks: 失敗があれば exit 1" 1
expect_out "pr checks: check-runs と commit statuses を 1 行ずつ出す" \
  "$(printf 'build\tpass\t1m5s\thttps://ci/build\t\ndeploy/preview\tpass\t\thttps://preview\tReady\nlint\tfail\t30s\thttps://ci/lint\t')"
expect_log "pr checks: head sha の check-runs を読む" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc123/check-runs][-f][per_page=100]"
expect_log "pr checks: head sha の commit statuses を読む" "[api][-X][GET][--paginate][--slurp][repos/acme/app/commits/abc123/status][-f][per_page=100]"
cloud pr checks 6 -R acme/app
expect_rc "pr checks: 失敗が無く保留があれば exit 8" 8
cloud pr checks 7 -R acme/app
expect_rc "pr checks: 成功と skip だけなら exit 0" 0
cloud pr checks 8 -R acme/app
expect_rc "pr checks: 成功とキャンセルだけでも exit 1" 1
expect_out "pr checks: 2 ページ目の commit status も読む" "$(printf 'build\tcancel\t1m5s\thttps://ci/build\t\nci/a\tpass\t\t\t\nci/b\tfail\t\t\t')"
cloud pr checks 5 -R acme/app --json name,state,bucket,link
if [ "${RC}" -eq 1 ] && [ "$(printf '%s' "${OUT}" | jq -S -c .)" = "$(jq -S -c . <<<'[
  {"name": "build", "state": "SUCCESS", "bucket": "pass", "link": "https://ci/build"},
  {"name": "deploy/preview", "state": "SUCCESS", "bucket": "pass", "link": "https://preview"},
  {"name": "lint", "state": "FAILURE", "bucket": "fail", "link": "https://ci/lint"}]')" ]; then
  pass "pr checks --json: 結果を出したうえで exit 1"
else
  fail "pr checks --json" "exit ${RC} / got: ${OUT} / stderr: ${ERR}"
fi
cloud pr checks 6 -R acme/app --json name,state,bucket --jq '.[] | select(.bucket == "pending") | .name + " " + .state'
expect_rc "pr checks --json: 保留があれば exit 8" 8
expect_out "pr checks --json --jq: 実行中の check は pending" "e2e IN_PROGRESS"

echo "--- AC-4: PR の書き込み系 ---"
printf 'from file\n' >"${WORK}/body.md"
cloud pr create -R acme/app --draft --base main --head feat --title "T 1" --body "B"
expect_out "pr create: 作成した PR の URL を 1 行で出す" "https://github.com/acme/app/pull/9"
expect_log "pr create: POST pulls" "[api][-X][POST][repos/acme/app/pulls][--input][-]"
expect_log "pr create: title / body / head / base / draft" 'body {"title":"T 1","body":"B","head":"feat","base":"main","draft":true}'
cloud pr create -R acme/app --head feat --title T --body-file "${WORK}/body.md"
expect_log "pr create: --body-file を読み、--base が無ければ default branch、--draft が無ければ draft: false" \
  'body {"title":"T","body":"from file","head":"feat","base":"trunk","draft":false}'

cloud pr edit 5 -R acme/app --title "New" --body-file "${WORK}/body.md" --add-label a,b --remove-label "needs review"
expect_rc "pr edit" 0
expect_log "pr edit: PATCH pulls/{n}" "[api][-X][PATCH][repos/acme/app/pulls/5][--input][-]"
expect_log "pr edit: title / body" 'body {"title":"New","body":"from file"}'
expect_log "pr edit --add-label: POST issues/{n}/labels" "[api][-X][POST][repos/acme/app/issues/5/labels][--input][-]"
expect_log "pr edit --add-label: labels" 'body {"labels":["a","b"]}'
expect_log "pr edit --remove-label: DELETE issues/{n}/labels/{name}" "[api][-X][DELETE][repos/acme/app/issues/5/labels/needs%20review]"
cloud pr edit 5 -R acme/app --body "only body"
expect_log "pr edit --body: title は送らない" 'body {"body":"only body"}'

cloud pr comment 5 -R acme/app --body "hi"
expect_log "pr comment: POST issues/{n}/comments" "[api][-X][POST][repos/acme/app/issues/5/comments][--input][-]"
expect_log "pr comment --body" 'body {"body":"hi"}'
cloud pr comment 5 -R acme/app --body-file "${WORK}/body.md"
expect_log "pr comment --body-file" 'body {"body":"from file"}'

cloud pr ready 5 -R acme/app
expect_rc "pr ready" 0
expect_only_log "pr ready: POST pulls/{n}/ccr/ready_for_review" "[api][-X][POST][repos/acme/app/pulls/5/ccr/ready_for_review]"
cloud pr ready 5 -R acme/app --undo
expect_only_log "pr ready --undo: POST pulls/{n}/ccr/convert_to_draft" "[api][-X][POST][repos/acme/app/pulls/5/ccr/convert_to_draft]"

cloud pr diff 5 -R acme/app
expect_only_log "pr diff: diff の media type で pulls/{n} を読む" \
  "[api][-X][GET][-H][Accept: application/vnd.github.v3.diff][repos/acme/app/pulls/5]"
cloud pr diff 5 -R acme/app --name-only
expect_out "pr diff --name-only: 変更ファイルを 1 行ずつ出す" "$(printf 'src/a.ts\ndocs/b.md')"

cloud pr review 5 -R acme/app --comment --body "note"
expect_rc "pr review --comment" 0
expect_log "pr review: POST pulls/{n}/reviews" "[api][-X][POST][repos/acme/app/pulls/5/reviews][--input][-]"
expect_log "pr review --comment --body" 'body {"event":"COMMENT","body":"note"}'

echo "--- AC-5: issue の書き込み系と list ---"
cloud issue create -R acme/app --title "T" --body "B" --label bug --label "help wanted" --assignee @me --milestone v2
expect_out "issue create: issue の URL を 1 行で出す" "https://github.com/acme/app/issues/20"
expect_log "issue create: POST issues" "[api][-X][POST][repos/acme/app/issues][--input][-]"
expect_log "issue create: label / assignee（@me は login に）/ milestone（名前 → 番号）" \
  'body {"title":"T","body":"B","labels":["bug","help wanted"],"assignees":["me-user"],"milestone":4}'
cloud issue create -R acme/app --title "T" --body-file "${WORK}/body.md"
expect_log "issue create --body-file: 指定しない label 等は送らない" 'body {"title":"T","body":"from file"}'

cloud issue comment 12 -R acme/app --body-file "${WORK}/body.md"
expect_out "issue comment: コメントの URL を出す" "https://github.com/acme/app/issues/12#issuecomment-8"
expect_log "issue comment: POST issues/{n}/comments" "[api][-X][POST][repos/acme/app/issues/12/comments][--input][-]"
expect_log "issue comment --body-file" 'body {"body":"from file"}'

cloud issue edit 12 -R acme/app --body-file "${WORK}/body.md" --add-label triage
expect_rc "issue edit" 0
expect_log "issue edit: PATCH issues/{n}" "[api][-X][PATCH][repos/acme/app/issues/12][--input][-]"
expect_log "issue edit --body-file" 'body {"body":"from file"}'
expect_log "issue edit --add-label" 'body {"labels":["triage"]}'

cloud issue close 12 -R acme/app --reason "not planned"
expect_rc "issue close" 0
expect_log "issue close: PATCH issues/{n}" "[api][-X][PATCH][repos/acme/app/issues/12][--input][-]"
expect_log "issue close --reason" 'body {"state":"closed","state_reason":"not_planned"}'

cloud issue list -R acme/app --state open --label self-improve --json number,title,state
expect_json "issue list --json: PR を除いた issue を返す" \
  '[{"number": 12, "title": "Bug", "state": "OPEN"}, {"number": 11, "title": "Idea", "state": "OPEN"}]'
expect_only_log "issue list: GET issues（state / labels）" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/issues][-f][per_page=100][-f][state=open][-f][labels=self-improve]"
cloud issue list -R acme/app --limit 1 --json number --jq '.[].number'
expect_out "issue list --limit / --jq" "12"
cloud issue list -R acme/app --label self-improve --state all --search "in:title Idea" --json number
expect_json "issue list --search: REST の search を使う" '[{"number": 11}]'
expect_only_log "issue list --search: GET search/issues" \
  '[api][-X][GET][search/issues][-f][q=repo:acme/app is:issue label:"self-improve" in:title Idea][-f][per_page=30]'

cloud pr list -R acme/app --head feat --state all --json number,state,url,headRefName,isDraft
expect_json "pr list --json" '[
  {"number": 4, "state": "MERGED", "url": "https://github.com/acme/app/pull/4", "headRefName": "feat", "isDraft": false},
  {"number": 5, "state": "OPEN", "url": "https://github.com/acme/app/pull/5", "headRefName": "feat", "isDraft": true}]'
expect_only_log "pr list: GET pulls（state / head）" \
  "[api][-X][GET][--paginate][--slurp][repos/acme/app/pulls][-f][per_page=100][-f][state=all][-f][head=acme:feat]"
cloud pr list -R acme/app --state all --label bug --json number,mergeable
expect_json "pr list: label で絞り、一覧に無い field は PR ごとに読む" '[{"number": 5, "mergeable": "CONFLICTING"}]'

echo "--- 入力と API 応答の検証 ---"
# expect_refused <名前> <ログに出てはいけない文字列> — 0 以外で終わり、その呼び出しに届かない
expect_refused() {
  if [ "${RC}" -ne 0 ] && [ -n "${ERR}" ] && ! grep -qF -- "$2" "${LOG}"; then
    pass "$1"
  else
    fail "$1" "exit ${RC} / log: $(tr '\n' ' ' <"${LOG}") / stderr: ${ERR}"
  fi
}
cloud pr view 66 -R acme/app --json comments
expect_refused "API 応答の number が整数でなければ、そこから先の API を呼ばない" "/comments"
cloud issue list -R acme/app --search x --limit "x[\$(touch ${WORK}/pwned)]" --json number
expect_refused "issue list: 数でない --limit は API を呼ぶ前に拒否する" "search/issues"
if [ -e "${WORK}/pwned" ]; then
  fail "issue list: --limit の値を算術式で評価しない" "${WORK}/pwned が作られた"
else
  pass "issue list: --limit の値を算術式で評価しない"
fi
cloud pr list -R acme/app --limit 0x10 --json number
expect_refused "pr list: 数でない --limit を拒否する" "repos/acme/app/pulls"
cloud pr comment https://evil.example/acme/app/pull/5 --body hi
expect_refused "PR の URL のホストが接続先と違えば拒否する" "comments"
cloud pr view 5 -R 'acme/app?x=1' --json number
expect_refused "-R の repo 名に URL の区切り文字があれば拒否する" "repos/acme"
cloud pr view 5 -R github.com/acme/app --json number
expect_only_log "-R HOST/owner/repo（接続先のホスト）は受ける" "[api][-X][GET][repos/acme/app/pulls/5]"
cloud pr diff 67 -R acme/app --name-only
expect_refused "pr diff --name-only: 一覧が changed_files に足りなければ止める" "__never__"
expect_out "pr diff --name-only: 一部だけの一覧を出さない" ""
cloud pr view 67 -R acme/app --json files
expect_refused "pr view --json files: 一覧が changed_files に足りなければ止める" "__never__"

echo "--- AC-6: 未対応は exit 2、対象外は素通し ---"
cloud pr merge 5 -R acme/app --squash
expect_unsupported "未対応のサブコマンド（pr merge）" "pr merge"
cloud issue reopen 12 -R acme/app
expect_unsupported "未対応のサブコマンド（issue reopen）" "issue reopen"
cloud pr view 5 -R acme/app --json number --web
expect_unsupported "未対応のフラグ（pr view --web）" "--web"
cloud pr create -R acme/app --fill
expect_unsupported "未対応のフラグ（pr create --fill）" "--fill"
cloud pr review 5 -R acme/app --approve
expect_unsupported "未対応のフラグ（pr review --approve）" "--approve"
cloud pr view 5 -R acme/app --json number,projectItems
expect_unsupported "未対応の --json field（pr view）" "projectItems"
cloud issue view 12 -R acme/app --json closedByPullRequestsReferences
expect_unsupported "未対応の --json field（issue view）" "closedByPullRequestsReferences"
cloud pr view 5 -R acme/app
expect_unsupported "--json の無い pr view" "pr view"

cloud api graphql -f query='{viewer{login}}'
expect_only_log "gh api は実体に素通し" "[api][graphql][-f][query={viewer{login}}]"
cloud run list --limit 3
expect_only_log "gh run は実体に素通し" "[run][list][--limit][3]"
cloud auth status
expect_only_log "gh auth は実体に素通し" "[auth][status]"
cloud --version
expect_only_log "サブコマンドの無い呼び出しは実体に素通し" "[--version]"

echo "--- AC-7: repo の決め方 ---"
cloud pr view 5 --repo acme/app --json number
expect_only_log "--repo owner/repo" "[api][-X][GET][repos/acme/app/pulls/5]"
cloud pr view 5 --json number -R acme/app
expect_only_log "-R はサブコマンドの後ろでも受ける" "[api][-X][GET][repos/acme/app/pulls/5]"
cloud -R acme/app issue view 12 --json number
expect_only_log "-R はコマンドの前でも受ける" "[api][-X][GET][repos/acme/app/issues/12]"

origin_repo() { # <名前> <origin の URL> — その origin を持つ git repo を作ってパスを出す
  local dir="${WORK}/$1"
  git init -q "${dir}"
  git -C "${dir}" remote add origin "$2"
  printf '%s' "${dir}"
}
run_in "$(origin_repo https https://github.com/acme/app.git)" true pr view 5 --json number
expect_only_log "origin（https）から owner/repo を決める" "[api][-X][GET][repos/acme/app/pulls/5]"
run_in "$(origin_repo ssh git@github.com:acme/app.git)" true issue view 12 --json number
expect_only_log "origin（ssh）から owner/repo を決める" "[api][-X][GET][repos/acme/app/issues/12]"
run_in "$(origin_repo proxy http://local_proxy@127.0.0.1:18080/git/acme/app)" true pr view 5 --json number
expect_only_log "origin（クラウドの git proxy）から owner/repo を決める" "[api][-X][GET][repos/acme/app/pulls/5]"
run_in "${WORK}/https" true pr view 6 -R other/thing --json number
expect_only_log "-R は origin より優先する" "[api][-X][GET][repos/other/thing/pulls/6]"
cloud pr view 5 --json number
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
