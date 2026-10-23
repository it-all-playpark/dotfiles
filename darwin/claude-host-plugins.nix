{
  pkgs,
  lib,
  username,
  ...
}:
let
  # PC ごとに読み込まないプラグイン。claude-code/settings.json の enabledPlugins は 3 台で共有なので、
  # PC ごとの差分は managed settings の drop-in（70-host-plugins.json）で false に上書きする。
  # enabledPlugins は設定元をまたいでキーごとにマージされ、managed が user より強いので、ここに書いたものだけが
  # その PC で無効になる（その PC では /plugin enable でも有効にできない。戻すときはここから外して switch する）。
  # mosh-paste は mosh で入られる側（Mac Studio と yuji_naramoto の MacBook）でだけ動けばよく、入る側の
  # naramotoyuuji の MacBook では切る。
  studio = [ "meeting@playpark" ];
  byUser = {
    naramotoyuuji = [ "mosh-paste@playpark" ];
    yuji_naramoto = [ "meeting@playpark" ];
  };

  dropin =
    disabled:
    pkgs.writeText "70-host-plugins.json" (
      builtins.toJSON {
        enabledPlugins = lib.genAttrs disabled (_: false);
      }
    );
  # 書く drop-in のパス。空なら drop-in を消す
  dropinFor = disabled: if disabled == [ ] then "" else "${dropin disabled}";
  out = "/Library/Application Support/ClaudeCode/managed-settings.d/70-host-plugins.json";
in
{
  # Mac Studio は remote-access.nix と同じく LocalHostName/ComputerName の *Studio* で判定し、それ以外はユーザー名で決める。
  # nix-darwin は決まった名前の activation script しか実行しないので postActivation に入れる。
  system.activationScripts.postActivation.text = ''
    HOST_PLUGINS_DROPIN=${dropinFor (byUser.${username} or [ ])}
    case "$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true) $(/usr/sbin/scutil --get ComputerName 2>/dev/null || true)" in
      *Studio*) HOST_PLUGINS_DROPIN=${dropinFor studio} ;;
    esac
    if [ -n "$HOST_PLUGINS_DROPIN" ]; then
      echo "claude-host-plugins: writing ${out}"
      /bin/mkdir -p "$(/usr/bin/dirname "${out}")"
      /usr/bin/install -m 0644 -o root -g wheel "$HOST_PLUGINS_DROPIN" "${out}"
    else
      /bin/rm -f "${out}"
    fi
  '';
}
