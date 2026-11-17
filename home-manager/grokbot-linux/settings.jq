# home-manager/grokbot-linux/settings.jq
# claude-code/settings.json（Mac 版）から Grok Bot の box（Linux）用の settings を作る変換定義。
# nix の build（home-manager/grokbot-linux/default.nix）と tests/grokbot-linux-settings.test.sh が同じこのファイルを使う:
#   jq --arg checkout <box 上の dotfiles の checkout パス> -f settings.jq claude-code/settings.json

# macOS にしか無いパス・コマンドを含む値
def mac_only:
  test("/Library/|/opt/homebrew|osascript|moshi|\\.orbstack|\\.lima/|docker-proxy|/private/tmp/claude-[0-9]+");

# 配列から macOS 専用の文字列を除く（配列以外はそのまま）
def drop_mac_only:
  if type == "array" then map(select((type == "string" and mac_only) | not)) else . end;

# box 上の dotfiles の checkout パス。末尾の `/` は取り除く（残すと、下で足す `/` と重なって deny のパスに `//` が
# 混じり、実パスに一致しなくなる）
def checkout: $checkout | sub("/+$"; "");

# box 構成の入力になる checkout のファイル（checkout 起点の相対パス）。sandbox 内から書き換えられると、
# 次の `home-manager switch` で box の構成（この変換定義と生成される settings を含む）に反映される
def box_config_inputs: ["home-manager/grokbot-linux", "claude-code/settings.json", "flake.nix"];

# Mac の ~/ghq 配下を守る denyWrite のエントリを box のパスに写す。写す先が無いエントリは empty。
# repo 単位のエントリ（~/ghq/*/*/*/ 起点の .git/config・.git/hooks 等）は /workspace 直下の repo に加えて
# checkout 自身にも写す（checkout が /workspace 直下以外にあっても Bash から書けないようにする）。
# box の作業 repo は /workspace 直下（/workspace/<repo>）に置く前提: `/workspace/*/...` に写したエントリは深さ 1 の
# repo だけを守り、それより深い場所（/workspace/<dir>/<repo> 等）に置いた repo は守らない。
# 深さを問わない `**` のエントリ（~/ghq/**/.githooks 等）は checkout 直下の具体パスに写す: Linux の sandbox（bubblewrap）は
# denyWrite の glob を展開せず、文字どおりのパスだけを塞ぐ（#501。`/workspace/**/.githooks` は効かなかった）
def box_deny_write:
  if startswith("~/ghq/github.com/it-all-playpark/dotfiles/") then
    checkout + "/" + ltrimstr("~/ghq/github.com/it-all-playpark/dotfiles/")
  elif startswith("~/ghq/*/*/*/") then
    ("/workspace/" + ltrimstr("~/ghq/*/*/"), checkout + "/" + ltrimstr("~/ghq/*/*/*/"))
  elif startswith("~/ghq/*/*/") then
    "/workspace/" + ltrimstr("~/ghq/*/*/")
  elif startswith("~/ghq/**/") then
    checkout + "/" + ltrimstr("~/ghq/**/")
  else
    empty
  end;

# Mac の ~/ghq 起点のパスを、box の Edit ルール用の絶対パスに写す。写す先が無いパスは empty。
# 権限ルールでは `//path` がファイルシステムの絶対パスで、`/path` は settings ファイル起点の相対になるので、
# 必ず `//` で始める（https://code.claude.com/docs/en/permissions の How path patterns match）。
# /workspace 配下は repo の深さを問わないよう `**` に写す。Write / NotebookEdit も Edit(...) ルールで判定される
def box_edit_path:
  if startswith("~/ghq/github.com/it-all-playpark/dotfiles/") then
    "/" + checkout + "/" + ltrimstr("~/ghq/github.com/it-all-playpark/dotfiles/")
  elif startswith("~/ghq/*/*/") then
    "//workspace/**/" + ltrimstr("~/ghq/*/*/")
  elif startswith("~/ghq/**") then
    "//workspace/**" + ltrimstr("~/ghq/**")
  else
    empty
  end;

# box で足す Edit の deny: 入力の ~/ghq 起点の Edit ルールと、~/ghq 起点の denyWrite（Bash にしか効かない）を
# Edit ルールでも塞ぐ。denyWrite のエントリはファイルかディレクトリか決めずに、そのパスと配下（/**）の両方を塞ぐ
def box_edit_deny($deny; $deny_write):
  ($deny | map(select(startswith("Edit(~/ghq")) | ltrimstr("Edit(") | rtrimstr(")") | box_edit_path | "Edit(" + . + ")"))
  + ($deny_write | map(select(startswith("~/ghq")) | box_edit_path | ("Edit(" + . + ")", "Edit(" + . + "/**)")));

# 重複を除く（並び順は保つ）
def dedup:
  reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end);

if ($checkout | startswith("/") | not) then error("checkout は絶対パスで渡す: \($checkout)") else . end

| .permissions.deny as $deny
| .sandbox.network.allowedDomains as $domains
| .sandbox.filesystem.denyWrite as $deny_write

# macOS 専用の値を除く
| .sandbox |= walk(drop_mac_only)
| .permissions.additionalDirectories |= drop_mac_only
| .env |= with_entries(select((.key | mac_only) or (.value | type == "string" and mac_only) | not))
| .hooks |= (
    map_values(
      map(.hooks |= map(select((.command // "") | mac_only | not)))
      | map(select(.hooks | length > 0))
    )
    | with_entries(select(.value | length > 0))
  )

# 無効にする meeting plugin 用の値を除く
| .sandbox.filesystem.allowWrite -= ["~/Documents/meetings"]
| .sandbox.excludedCommands |= map(select(startswith("meeting ") | not))

# macOS の /private/tmp は Linux では /tmp
| walk(if type == "string" and startswith("/private/tmp/") then "/tmp/" + ltrimstr("/private/tmp/") else . end)

# box でも sandbox を必ず効かせる
| .sandbox.enabled = true
| .sandbox.failIfUnavailable = true
| .sandbox.network.strictAllowlist = true
| .sandbox.network.allowedDomains = (
    $domains + ["api.stripe.com", "stripe.com", "api.vercel.com", "vercel.com", "ai-gateway.vercel.sh"] | dedup
  )
# activation が ~/.claude へ symlink する指示書（checkout の claude-code/*.md。CLAUDE / RULES / MCP_* / MODE_* 等）は
# Bash（denyWrite）と Edit / Write（Edit の deny）の両方で塞ぐ。書き換えると以後の全 session と subagent が読むグローバル指示が変わる
# box 構成の入力（box_config_inputs）も同じ 2 つで塞ぐ。Edit の deny は denyWrite を写すときと同じく、そのパスと配下（/**）
# Linux の sandbox で効かない `**` 入りのエントリ（Mac 版から引き継いだ ~/ghq/**/...）は、具体パスに写したうえで残さない
| .sandbox.filesystem.denyWrite |= (
    . + map(box_deny_write) + [checkout + "/claude-code/*.md"] + (box_config_inputs | map(checkout + "/" + .))
    | map(select(contains("**") | not))
    | dedup
  )

# 入力の deny は残し、box のパスに写した Edit の deny を足す（acceptEdits の Edit / Write が checkout の hooks・bin や
# /workspace 配下の repo の .git/hooks 等を承認なしで書けないようにする）
| .permissions.deny = (
    $deny
    + box_edit_deny($deny; $deny_write)
    + ["Edit(/" + checkout + "/claude-code/*.md)"]
    + (box_config_inputs | map("/" + checkout + "/" + . | ("Edit(" + . + ")", "Edit(" + . + "/**)")))
    | dedup
  )
| .permissions.defaultMode = "acceptEdits"
# Workflow は許可が無いと承認ダイアログに script 全文が出て、巨大な script は承認できない（dev-flow が止まる）
| .permissions.allow |= ((. // []) + ["Workflow"] | dedup)
| .permissions.additionalDirectories |= (. + ["/workspace"] | dedup)

| .enabledPlugins += {
    "playpark-core@playpark": true,
    "dev-flow@playpark": true,
    "playpark-skills@playpark": true,
    "security-guidance@claude-plugins-official": true,
    "vercel@claude-plugins-official": true,
    "stripe@claude-plugins-official": true,
    "host-exec@playpark": false,
    "meeting@playpark": false,
    "bg-sessions@playpark": false,
    "mosh-paste@playpark": false
  }
