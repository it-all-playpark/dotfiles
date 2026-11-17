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

# Mac の ~/ghq 配下を守る denyWrite のエントリを box のパスに写す。写す先が無いエントリは empty。
# repo 単位のエントリ（~/ghq/*/*/*/ 起点の .git/config・.git/hooks 等）は /workspace 直下の repo に加えて
# checkout 自身にも写す（checkout が /workspace 直下以外にあっても Bash から書けないようにする）
def box_deny_write:
  if startswith("~/ghq/github.com/it-all-playpark/dotfiles/") then
    $checkout + "/" + ltrimstr("~/ghq/github.com/it-all-playpark/dotfiles/")
  elif startswith("~/ghq/*/*/*/") then
    ("/workspace/" + ltrimstr("~/ghq/*/*/"), $checkout + "/" + ltrimstr("~/ghq/*/*/*/"))
  elif startswith("~/ghq/*/*/") then
    "/workspace/" + ltrimstr("~/ghq/*/*/")
  elif startswith("~/ghq/**") then
    "/workspace/**" + ltrimstr("~/ghq/**")
  else
    empty
  end;

# Mac の ~/ghq 起点のパスを、box の Edit ルール用の絶対パスに写す。写す先が無いパスは empty。
# 権限ルールでは `//path` がファイルシステムの絶対パスで、`/path` は settings ファイル起点の相対になるので、
# 必ず `//` で始める（https://code.claude.com/docs/en/permissions の How path patterns match）。
# /workspace 配下は repo の深さを問わないよう `**` に写す。Write / NotebookEdit も Edit(...) ルールで判定される
def box_edit_path:
  if startswith("~/ghq/github.com/it-all-playpark/dotfiles/") then
    "/" + $checkout + "/" + ltrimstr("~/ghq/github.com/it-all-playpark/dotfiles/")
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
| .sandbox.filesystem.denyWrite |= (. + map(box_deny_write) + [$checkout + "/claude-code/*.md"] | dedup)

# 入力の deny は残し、box のパスに写した Edit の deny を足す（acceptEdits の Edit / Write が checkout の hooks・bin や
# /workspace 配下の repo の .git/hooks 等を承認なしで書けないようにする）
| .permissions.deny = ($deny + box_edit_deny($deny; $deny_write) + ["Edit(/" + $checkout + "/claude-code/*.md)"] | dedup)
| .permissions.defaultMode = "acceptEdits"
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
