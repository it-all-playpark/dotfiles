# lib/hermes-claude-code-pkg.nix
#
# @anthropic-ai/claude-code の Nix derivation を返す。
#
# 優先順 (案A → 案B):
#   案A: pkgs.claude-code が nixpkgs に存在する場合はそれを使用 (再現性最高、layer 最小)
#   案B: 存在しない場合は pkgs.buildNpmPackage で hermetic build を構築
#   案C (禁止): extraCommands 内 npm install -g は image の再現性を壊すため使用しない
#
# 使用例 (flake.nix の dockerTools.buildLayeredImage.contents 内):
#   (import ./lib/hermes-claude-code-pkg.nix { inherit pkgs; })
#
# 案A の場合、`claude` バイナリは derivation の ${out}/bin/claude に置かれ、
# dockerTools.buildLayeredImage が /bin/claude にリンクする。
# PATH への追加は不要 (buildLayeredImage が自動で /bin を構成する)。
{
  pkgs,
}:

if pkgs ? claude-code then
  # 案A: nixpkgs に claude-code derivation が存在する (推奨)
  # nix search nixpkgs claude-code で確認済み (2026-05-27 時点: 2.1.148)
  pkgs.claude-code
else
  throw ''
    hermes-claude-code-pkg: pkgs.claude-code が nixpkgs に見つかりません。
    nixpkgs channel を更新するか、lib/hermes-claude-code-pkg.nix を
    buildNpmPackage ベースの 案B 実装に切り替えてください。
    (案C: extraCommands 内 npm install -g は禁止)
  ''
