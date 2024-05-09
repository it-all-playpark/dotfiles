# ezaをlsとして利用
abbr ls eza --icons --git --time-style relative -la
abbr lt eza --icons --git --time-style relative --tree -aI \"node_modules\|.git\|.cache\"
abbr ltl eza --icons --git --time-style relative --tree -alI \"node_modules\|.git\|.cache\"

# batをcatとして利用
abbr cat bat

# nvimをvimとして利用
abbr vim nvim

# ripをrmとして利用
abbr rm rip

# 選択した過去の実行コマンドをクリップボードにコピー
abbr h echo -n \$\(history \| fzf +s --layout=reverse\) \| pbcopy

# 選択したローカルリポジトリリストへの移動をgと定義
abbr g cd \"\$\(ghq list --full-path \| fzf --layout=reverse --preview \'eza --icons --git --time-style relative -la \{1\}\'\)\"

# git
# ローカルブランチを選択してコピー
abbr B echo -n \"\$\(git branch -av \| fzf --layout=reverse --prompt \"GIT BRANCH\>\"\| sd \"\\\*\" \"\" \|awk \'\{print \$1\}\'\)\" \| pbcopy
abbr S git switch \"\$\(git branch -av \| fzf --layout=reverse --prompt \"GIT BRANCH\>\" \| sd \"\\\*\" \"\" \|awk \'\{print \$1\}\'\)\"

# lazigit
abbr lg lazygit

# lazydocker
abbr ld lazydocker

# カレントディレクトリのパスをクリップボードにコピー 
abbr pwdc echo -n \"\$\(pwd\)\" \| pbcopy

# docker
# finch利用時にdockerコマンドをfinchに変換
#abbr docker finch
# 選択した起動中コンテナに入る
abbr d docker exec -it \$\(docker ps \| fzf --layout=reverse --prompt \"Docker Container\>\" --preview-window \'bottom:70%\' --preview \'docker logs \{1\}\'\| awk \'\{print \$1\}\'\) sh
# 選択したlogを表示する
abbr dl docker logs --details \$\(docker ps -a \| fzf --layout=reverse --prompt \"Docker Container\>\" --preview-window \'bottom:70%\' --preview \'docker logs --details \{1\}\' \| awk \'\{print \$1\}\'\)
# 選択したコンテナを削除する
abbr dr docker rm \$\(docker ps \| fzf --layout=reverse --prompt \"Docker Container\>\" --preview-window \'bottom:70%\' --preview \'docker logs \{1\}\'\| awk \'\{print \$1\}\'\)
# 選択したコンテナイメージを削除する
abbr dir docker image rm \$\(docker image ls \| fzf --layout=reverse --prompt \"Docker Image\>\" --preview \'docker image inspect \{3\}\'\| awk \'\{print \$3\}\'\)
# 選択したコンテナボリュームを削除する
abbr dvr docker volume rm \$\(docker volume ls \| fzf --layout=reverse --prompt \"Docker Volume\>\" --preview \'docker volume inspect \{2\}\'\| awk \'\{print \$2\}\'\)
abbr dp docker ps

# docker composeの略記
abbr dc docker compose
abbr dcb docker compose build --no-cache
abbr dcu docker compose up -d
abbr dcd docker compose down
abbr dcp docker compose ps

# global ip確認
abbr ip echo -n \$\(dig myip.opendns.com @208.67.222.222 +short\) \| pbcopy \; pbpaste

# yazi
abbr y yazi
# yaziでカレントディレクトリを変更
function yy
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    yazi $argv --cwd-file="$tmp"
    if set cwd (cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
        cd -- "$cwd"
    end
    rm -f -- "$tmp"
end

# PATH設定
set -gx fish_user_paths /opt/homebrew/bin /opt/homebrew/sbin /usr/bin/php ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/Library/Android/sdk ~/.local/share/mise/shims $fish_user_paths
# 重複を削除
set -U fish_user_paths (echo $fish_user_paths | tr ' ' '\n' | sort -u)

# zoxide
zoxide init fish | source

# starship
starship init fish | source

# mise
mise activate fish | source
