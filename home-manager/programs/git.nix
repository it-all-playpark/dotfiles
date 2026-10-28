{ pkgs, ... }:
{
  # Office ファイル（docx/doc/xlsx/xls/pptx）を git diff で読めるようにする
  # textconv ドライバ。変換には office-oxide を使う。
  # リポジトリ側は .gitattributes に `*.docx diff=office` のように書くだけで、
  # 実体（どのコマンドを呼ぶか）はこちらのマシン側設定で与える。
  # 未導入の環境では diff driver が見つからず、従来どおり
  # "Binary files differ" に戻るだけなので、他の人の clone を壊さない。
  home.packages = [
    (pkgs.writeShellApplication {
      name = "git-textconv";
      # office-oxide は runtimeInputs に固定せず実行時に PATH から探す
      # （mise 管理のため）。見つからない場合はスクリプト側が
      # その旨を1行出して exit 0 する。
      text = builtins.readFile ../../scripts/git-textconv;
    })
  ];

  programs.git = {
    enable = true;
    includes = [
      { path = "config.local"; }
    ];
    signing.format = "openpgp";
    settings = {
      init.default-branch = "main";
      hub.protocol = "ssh";
      pull.rebase = true;

      # it-all-playpark の repo は SSH の remote でも HTTPS で通信する。
      # 各 repo の .git/config（起動元 repo のものは Claude Code の sandbox が書かせない）を
      # 書き換えずに、既存の clone と今後の ghq get の両方に効かせる。
      # sandbox 内の git は ~/.ssh を読めず、agent-vault が HTTPS に認証を付ける経路しか通らない。
      url."https://github.com/it-all-playpark/".insteadOf = [
        "ssh://git@github.com/it-all-playpark/"
        "git@github.com:it-all-playpark/"
      ];
      # sandbox 外の端末で HTTPS の push / fetch に gh の token を使う。
      # 空の helper で osxkeychain 等の既定を消してから gh を足す（gh auth setup-git と同じ形）。
      # sandbox 内では claude wrapper（claude-code/bin/claude）がこの helper を env で空にする
      # gh は shim（~/.claude/bin/gh → account-exec）経由で呼び、repo の org に応じた GH_CONFIG_DIR を付けさせる
      # （絶対パスの gh だと常に ~/.config/gh のアカウントになり、別アカウントの private repo が not found になる）。
      # PATH の先頭に nix の gh を置くのは、PATH に gh の無い GUI の git クライアントでも shim が実体を見つけられるようにするため
      credential."https://github.com".helper = [
        ""
        "!PATH=\"${pkgs.gh}/bin:$PATH\" \"$HOME/.claude/bin/gh\" auth git-credential"
      ];

      # cachetextconv は変換結果を git notes にキャッシュする。
      # 数百件の Office ファイルを持つリポジトリで git log -p を回すと
      # 毎回全件再変換することになるため、有効にしておく。
      diff.office = {
        textconv = "git-textconv office";
        cachetextconv = true;
      };
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
