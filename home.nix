{ config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "naramotoyuuji";
  home.homeDirectory = "/Users/naramotoyuuji";

  home.stateVersion = "24.05"; # Please read the comment before changing.

  home.packages = with pkgs; [
    act
    bat
    eza
    fastfetch
    fd
    ffmpegthumbnailer
    ffmpeg
    fzf
    gh
    ghq
    google-cloud-sdk
    delta
    jq
    lastpass-cli
    lazydocker
    lazygit
    mise
    mycli
    pandoc
    poppler
    procs
    rip2
    ripgrep
    ripgrep-all
    sd
    starship
    tbls
    tldr
    tree-sitter
    unar
    yazi
    zoxide
  ];

  home.sessionVariables = {
    # EDITOR = "emacs";
  };


  # シェル有効化など
  programs.zsh.enable = false;

  programs.fish = {
    enable = true;
    shellInit = ''
      # PATH設定
      fish_add_path ~/.nix-profile/bin /nix/var/nix/profiles/default/bin /opt/homebrew/bin /opt/homebrew/sbin /usr/bin/php ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/Library/Android/sdk ~/.local/share/mise/shims

      starship init fish | source
      zoxide init fish | source
      mise activate fish | source
      
      # ローカル設定を読み込む
      if test -f ~/.config/fish/config.fish.local
          source ~/.config/fish/config.fish.local
      end
    '';
    functions = {
      # yaziでカレントディレクトリを変更
      yy = ''
        set tmp (mktemp -t "yazi-cwd.XXXXXX")
        yazi $argv --cwd-file="$tmp"
        if set cwd (cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
          cd -- "$cwd"
        end
        rm -f -- "$tmp"
      '';
    };
    shellAbbrs = {
      # ezaをlsとして利用
      ls = ''eza --icons --git --time-style relative -la'';
      lt = ''eza --icons --git --time-style relative --tree -aI "node_modules|.git|.cache"'';
      ltl = ''eza --icons --git --time-style relative --tree -alI "node_modules|.git|.cache"'';
      # batをcatとして利用
      cat = ''bat'';
      # ripをrmとして利用
      rm = ''rip'';
      # 選択した過去の実行コマンドをクリップボードにコピー
      h = ''echo -n $(history | fzf +s --layout=reverse) | pbcopy'';
      # 選択したローカルリポジトリリストへの移動をgと定義
      g = ''cd "$(ghq list --full-path | fzf --layout=reverse --preview 'eza --icons --git --time-style relative -la {1}')"'';
      # git
      # ローカルブランチを選択してコピー
      B = ''echo -n "$(git branch -av | fzf --layout=reverse --prompt "GIT BRANCH>"| sd "\*" "" |awk '{print $1}')" | pbcopy'';
      S = ''git switch "$(git branch -av | fzf --layout=reverse --prompt "GIT BRANCH>" | sd "\*" "" |awk '{print $1}')"'';
      # gh
      # githubブラウザページを開く
      ghb = ''gh browse'';
      # lazigit
      lg = ''lazygit'';
      # lazydocker
      ld = ''lazydocker'';
      # yazi
      y = ''yazi'';
      # カレントディレクトリのパスをクリップボードにコピー 
      pwdc = ''echo -n "$(pwd)" | pbcopy'';
      # カレントディレクトリ配下の指定したディレクトリ配下のファイルパスと中身を一括取得
      fl = ''fd --type f . "$(eza -DR | sd ':$' \'\' | grep '^./' | fzf)" -x sh -c 'echo "==== $1 ===="; cat "$1"' _ {};'';
      flc = ''fd --type f . "$(eza -DR | sd ':$' \'\' | grep '^./' | fzf)" -x sh -c 'echo "==== $1 ===="; cat "$1"' _ {} | pbcopy;'';
      # MySqlのDBを選択して接続
      mdb = ''cat ~/.myclirc ~/.myclirc.local > ~/.myclirc_combined ; mycli --myclirc=~/.myclirc_combined "$(mycli --list-dsn --myclirc=~/.myclirc_combined | fzf --layout=reverse --prompt 'DSN>')" ; rm ~/.myclirc_combined'';
      # lastpassでuser/passなどをクリップボードにコピー
      lp = ''lpass show $(lpass ls -l | fzf | awk "{print $5}" | sd ']$' \'\') | fzf | awk '{print $2}'| sd 'n' \'\' | pbcopy ; pbpaste'';
      # docker
      # finch利用時にdockerコマンドをfinchに変換
      #docker="finch
      # 選択した起動中コンテナに入る
      d = ''docker exec -it $(docker ps | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs {1}'| awk '{print $1}') sh'';
      # 選択したlogを表示する
      dl = ''docker logs --follow --tail=100 $(docker ps -a | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs --details {1}' | awk '{print $1}')'';
      # 選択したコンテナを削除する
      dr = ''docker rm $(docker ps -a | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs {1}'| awk '{print $1}')'';
      # 選択したコンテナイメージを削除する
      dir = ''docker image rm $(docker image ls | fzf --layout=reverse --prompt "Docker Image>" --preview 'docker image inspect {3}'| awk '{print $3}')'';
      # 選択したコンテナボリュームを削除する
      dvr = ''docker volume rm $(docker volume ls | fzf --layout=reverse --prompt "Docker Volume>" --preview 'docker volume inspect {2}'| awk '{print $2}')'';
      dp = ''docker ps'';
      # docker composeの略記
      dc = ''docker compose'';
      dcb = ''docker compose build --no-cache'';
      dcu = ''docker compose up -d'';
      dcd = ''docker compose down'';
      dcp = ''docker compose ps'';
      # gcloud
      # config切り替え
      gca = ''gcloud config configurations activate $(gcloud config configurations list | fzf --layout=reverse --prompt 'config>' | awk '{print $1}')'';
      # global ip確認
      ip = ''echo -n $(dig myip.opendns.com @208.67.222.222 +short) | pbcopy ; pbpaste'';
    };
  };

  programs.neovim = {
    enable = true;
    vimAlias = true;
  };

  home.file = {
    ".gitconfig".source = ./settings/.gitconfig;
    ".gitconfig.local.template".source = ./settings/.gitconfig.local.template;
    ".zshrc".source = ./settings/.zshrc;
    ".tmux.conf".source = ./settings/.tmux.conf;
    ".myclirc".source = ./settings/.myclirc;
    ".myclirc.local.template".source = ./settings/.myclirc.local.template;
    ".config/nvim" = {
      source = ./settings/nvim;
      recursive = true;
    };
    ".config/mise" = {
      source = ./settings/mise;
      recursive = true;
    };
    ".config/yazi" = {
      source = ./settings/yazi;
      recursive = true;
    };
    ".warp" = {
      source = ./settings/.warp;
      recursive = true;
    };
  };

}
