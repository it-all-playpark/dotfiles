{ pkgs, ... }:
{
  # システムパッケージの例
  environment.systemPackages = with pkgs; [ vim git ];
  # nix-daemon の有効化
  services.nix-daemon.enable = true;
  # unfree パッケージの許可
  nixpkgs.config.allowUnfree = true;
  # デフォルトシェルとして zsh を有効に
  programs.zsh.enable = true;
  # システムの stateVersion（変更時は注意）
  system.stateVersion = 5;
}
