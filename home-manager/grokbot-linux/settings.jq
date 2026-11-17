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

# Mac の ~/ghq 配下を守る denyWrite のエントリを box のパスに写す。写す先が無いエントリは empty
def box_deny_write:
  if startswith("~/ghq/github.com/it-all-playpark/dotfiles/") then
    $checkout + "/" + ltrimstr("~/ghq/github.com/it-all-playpark/dotfiles/")
  elif startswith("~/ghq/*/*/") then
    "/workspace/" + ltrimstr("~/ghq/*/*/")
  elif startswith("~/ghq/**") then
    "/workspace/**" + ltrimstr("~/ghq/**")
  else
    empty
  end;

# 重複を除く（並び順は保つ）
def dedup:
  reduce .[] as $x ([]; if index($x) == null then . + [$x] else . end);

.permissions.deny as $deny
| .sandbox.network.allowedDomains as $domains

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
| .sandbox.filesystem.denyWrite |= (. + map(box_deny_write) | dedup)

| .permissions.deny = $deny
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
