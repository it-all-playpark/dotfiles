{ ... }:
{
  programs.git = {
    enable = true;
    includes = [
      { path = "config.local"; }
    ];
    settings = {
      init.default-branch = "main";
      hub.protocol = "ssh";
    };
  };

  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      features = "decorations";
      side-by-side = true;
      interactive = {
        keep-plus-minus-markers = false;
        diff-filter = "delta --color-only --features=interactive";
      };
      decorations = {
        commit-decoration-style = "blue ol";
        commit-style = "raw";
        file-style = "omit";
        hunk-header-decoration-style = "blue box";
        hunk-header-file-style = "red";
        hunk-header-line-number-style = "#067a00";
        hunk-header-style = "file line-number syntax";
      };
    };
  };
}
