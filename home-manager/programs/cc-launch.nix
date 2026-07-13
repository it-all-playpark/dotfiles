{ pkgs, ... }:
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "cc-launch";
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        ghq
        git
        gnugrep
        gnused
        lsof
        procps
        zellij
      ];
      text = builtins.readFile ../../scripts/cc-launch;
    })
  ];
}
