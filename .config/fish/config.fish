# exaをlsとして利用
abbr -a ls exa --icons --git
abbr -a lt exa -T -L 3 -a -I \"node_modules\|.git\|.cache\" --icons
abbr -a ltl exa -T -L 3 -a -I \"node_modules\|.git\|.cache\" -l --icons

# batをcatとして利用
abbr -a cat bat

# nvimをvimとして利用
abbr -a vim nvim

# 選択した過去の実行コマンドをクリップボードにコピー
abbr -a h echo -n \"\$\(history \| peco\)\" \| pbcopy

# 選択したローカルリポジトリリストへの移動をgと定義
abbr -a g cd \"\$\(ghq list --full-path \| peco\)\"

# git
# ローカルブランチを選択してコピー
abbr -a B echo -n \"\$\(git branch -av \| peco --prompt \"GIT BRANCH\>\" \| sd \"\\\*\" \"\" \|awk \'\{print \$1\}\'\)\" \| pbcopy
abbr -a S git switch \"\$\(git branch -av \| peco --prompt \"GIT BRANCH\>\" \| sd \"\\\*\" \"\" \|awk \'\{print \$1\}\'\)\"

# 訪れたことのあるディレクトリリストへの移動をzlと定義
abbr -a zl cd \"\$\(z -l \| awk \'\{print \$2\}\' \| peco\)\"
abbr -a zf cd \"\$\(z -l \| awk \'\{print \$2\}\' \| fzf\)\"

# カレントディレクトリのパスをクリップボードにコピー 
abbr -a pwdc echo -n \"\$\(pwd\)\" \| pbcopy

# docker
# finch利用時にdockerコマンドをfinchに変換
#abbr -a docker finch
# 選択した起動中コンテナに入る
abbr -a d docker exec -it \"\$\(docker ps \| peco \| awk \'\{print \$1\}\'\)\" sh
# 選択したlogを表示する
abbr -a dl docker logs \"\$\(docker ps -a \| peco \| awk \'\{print \$1\}\'\)\"
# 選択したコンテナを削除する
abbr -a dr docker rm \"\$\(docker ps -a \| peco \| awk \'\{print \$1\}\'\)\"
# 選択したコンテナイメージを削除する
abbr -a dir docker image rm \"\$\(docker image ls \| peco \| awk \'\{print \$3\}\'\)\"
abbr -a dp docker ps

# docker composeの略記
abbr -a dc docker compose
abbr -a dcb docker compose build --no-cache
abbr -a dcu docker compose up -d
abbr -a dcd docker compose down
abbr -a dcp docker compose ps

# global ip確認
abbr -a ip echo -n \$\(dig myip.opendns.com @208.67.222.222 +short\) \| pbcopy \; pbpaste

# 接続Wifi情報確認
alias airport='/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport'

set LDFLAGS "-L/opt/homebrew/opt/mysql@5.7/lib"
set CPPFLAGS "-I/opt/homebrew/opt/mysql@5.7/include"

# pyenv
# pyenv init
status --is-interactive; and source (pyenv init -|psub)
# python version
set -g PY_VERSION $(pyenv version | awk '{print $1}')

# PATH設定
set -gx fish_user_paths /opt/homebrew/bin /usr/bin/php ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/flutter/bin ~/Library/Android/sdk ~/.pyenv/versions/$PY_VERSION/bin ~/.volta/bin ~/.cargo/bin $fish_user_paths
# 重複を削除
set -U fish_user_paths (echo $fish_user_paths | tr ' ' '\n' | sort -u)

# thefuck
thefuck --alias | source

# starship
starship init fish | source
