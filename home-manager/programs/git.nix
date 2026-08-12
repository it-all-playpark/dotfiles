{ pkgs, ... }:
{
  # Office を git diff で読めるようにする textconv ドライバ。
  # リポジトリ側は .gitattributes に `*.docx diff=office` のように書くだけで、
  # 実体（どのコマンドを呼ぶか）はこちらのマシン側設定で与える。
  # 未導入の環境では diff driver が見つからず、従来どおり
  # "Binary files differ" に戻るだけなので、他の人の clone を壊さない。
  home.packages = [
    (pkgs.writeShellApplication {
      name = "git-textconv";
      # 変換ツール本体（office-oxide / undoc / anydoc）は runtimeInputs に固定せず
      # 実行時に PATH から探す。mise や cargo install など導入方法を選ばないためで、
      # 見つからない場合はスクリプト側がその旨を1行出して exit 0 する。
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

      # cachetextconv は変換結果を git notes にキャッシュする。
      # 数百件の Office ファイルを持つリポジトリで git log -p を回すと
      # 毎回全件再変換することになるため、有効にしておく。
      diff.office = {
        textconv = "git-textconv office";
        cachetextconv = true;
      };
      diff.slides = {
        textconv = "git-textconv slides";
        cachetextconv = true;
      };
      # pdfdoc は anydoc に依存する。anydoc 未導入の間は .gitattributes 側で
      # *.pdf に割り当てないこと（割り当てると差分が変換失敗メッセージに変わり、
      # "Binary files differ" より情報が減る）。
      diff.pdfdoc = {
        textconv = "git-textconv pdf";
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
