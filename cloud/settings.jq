# cloud/settings.jq
# claude-code/settings.json（Mac 版）から Claude Code のクラウドセッション用の user settings を作る変換定義。
# cloud/setup.sh と tests/cloud-settings.test.sh が同じこのファイルを使う:
#   jq --arg dotfiles <クラウド上の dotfiles の checkout パス> \
#      --arg path <セッションの PATH として後ろに続ける値> \
#      --argjson hook_files <~/.claude/hooks に置く hook のファイル名の配列> \
#      -f cloud/settings.jq claude-code/settings.json
#
# sandbox は外す: クラウドのコンテナ自体が使い捨ての隔離環境で、外向き通信は環境の egress proxy が
# 許可ホストに絞っている。Mac 版の sandbox 設定（Seatbelt・docker-vm・agent-vault 前提）はクラウドでは成り立たない。
# permissions の deny と安全用の hook は外さない。

# macOS にしか無いパス・コマンドを含む値
def mac_only:
  test("/Library/|/opt/homebrew|osascript|moshi|\\.orbstack|\\.lima");

# checkout パス。末尾の `/` は取り除く
def dotfiles: $dotfiles | sub("/+$"; "");

# hook の command が参照する ~/.claude/hooks/ のファイル名（参照していなければ null）
def hook_file:
  (.command // "") | (capture("\\.claude/hooks/(?<f>[A-Za-z0-9._-]+)") | .f) // null;

if ($dotfiles | startswith("/") | not) then error("dotfiles は絶対パスで渡す: \($dotfiles)") else . end

# sandbox を外す（理由は冒頭）
| del(.sandbox)

# macOS 専用の値を除く
| .permissions.additionalDirectories |= map(select(mac_only | not))
| .env |= with_entries(select((.value | type == "string" and mac_only) | not))

# hook は、command が参照するファイルが dotfiles の claude-code/hooks/ にある（= setup が ~/.claude/hooks に置く）ものだけ残す。
# osascript・moshi-hook・herdr のような、クラウドに実体が無い hook はここで落ちる
| .hooks |= (
    map_values(
      map(.hooks |= map(select(hook_file as $f | $f != null and ($hook_files | index($f)) != null)))
      | map(select(.hooks | length > 0))
    )
    | with_entries(select(.value | length > 0))
  )

# macOS の /private/tmp は Linux では /tmp
| walk(if type == "string" and startswith("/private/tmp/") then "/tmp/" + ltrimstr("/private/tmp/") else . end)

# SessionStart で dockerd を起動する（最大 30 秒 socket を待つので、timeout はそれより長くする）
| .hooks.SessionStart += [
    {
      hooks: [
        {
          type: "command",
          command: "bash \"\(dotfiles)/cloud/hooks/session-start.sh\"",
          statusMessage: "dockerd を起動中...",
          timeout: 40
        }
      ]
    }
  ]

# settings の env は $PATH を展開しないので、PATH は全体を書く。cloud/bin を claude-code/bin より前に置き、
# 同名のコマンド（pg-broker 等）はクラウド版が先に解決されるようにする
| .env.PATH = "\(dotfiles)/cloud/bin:\(dotfiles)/claude-code/bin:\($path)"
# claude-code/bin/docker（Mac の sandbox 用 shim）は繋ぎ先が明示されていれば実体の docker に素通しする。
# 明示しないと、クラウドに無い docker-vm を探して落ちる
| .env.DOCKER_HOST = "unix:///var/run/docker.sock"
