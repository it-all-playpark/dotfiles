# exaをlsとして利用
abbr ls exa --icons --git
abbr lt exa -T -L 3 -a -I \"node_modules\|.git\|.cache\" --icons
abbr ltl exa -T -L 3 -a -I \"node_modules\|.git\|.cache\" -l --icons

# batをcatとして利用
abbr cat bat

# nvimをvimとして利用
abbr vim nvim

# 選択した過去の実行コマンドをクリップボードにコピー
abbr h echo -n \"\$\(history \| peco\)\" \| pbcopy

# 選択したローカルリポジトリリストへの移動をgと定義
abbr g cd \"\$\(ghq list --full-path \| peco\)\"

# git
# ローカルブランチを選択してコピー
abbr B echo -n \"\$\(git branch -av \| peco --prompt \"GIT BRANCH\>\" \| sd \"\\\*\" \"\" \|awk \'\{print \$1\}\'\)\" \| pbcopy
abbr S git switch \"\$\(git branch -av \| peco --prompt \"GIT BRANCH\>\" \| sd \"\\\*\" \"\" \|awk \'\{print \$1\}\'\)\"

# 訪れたことのあるディレクトリリストへの移動をzlと定義
abbr zl cd \"\$\(z -l \| awk \'\{print \$2\}\' \| peco\)\"
abbr zf cd \"\$\(z -l \| awk \'\{print \$2\}\' \| fzf\)\"

# カレントディレクトリのパスをクリップボードにコピー 
abbr pwdc echo -n \"\$\(pwd\)\" \| pbcopy

# docker
# finch利用時にdockerコマンドをfinchに変換
#abbr docker finch
# 選択した起動中コンテナに入る
abbr d docker exec -it \"\$\(docker ps \| peco \| awk \'\{print \$1\}\'\)\" sh
# 選択したlogを表示する
abbr dl docker logs \"\$\(docker ps -a \| peco \| awk \'\{print \$1\}\'\)\"
# 選択したコンテナを削除する
abbr dr docker rm \"\$\(docker ps -a \| peco \| awk \'\{print \$1\}\'\)\"
# 選択したコンテナイメージを削除する
abbr dir docker image rm \"\$\(docker image ls \| peco \| awk \'\{print \$3\}\'\)\"
abbr dp docker ps

# docker composeの略記
abbr dc docker compose
abbr dcb docker compose build --no-cache
abbr dcu docker compose up -d
abbr dcd docker compose down
abbr dcp docker compose ps

# global ip確認
abbr ip echo -n \$\(dig myip.opendns.com @208.67.222.222 +short\) \| pbcopy \; pbpaste

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
