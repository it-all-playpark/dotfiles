# 現在の日付を取得
set -l current_date (date "+%Y%m%d")

# 最後に更新した日付を取得
set -l last_update_date (cat ~/.config/fish/fisher_last_update_date.txt)

# 日付が異なる場合のみ更新
if test "$current_date" != "$last_update_date"
    fisher update
    echo $current_date >~/.config/fish/fisher_last_update_date.txt
end

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

# 接続Wifi情報確認
alias airport='/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport'

set -x fish_user_paths /opt/homebrew/bin /usr/bin/php /opt/homebrew/opt/mysql@5.7/bin ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/flutter/bin $fish_user_paths
set -U fish_user_paths (echo $fish_user_paths | tr ' ' '\n' | sort -u)

set LDFLAGS "-L/opt/homebrew/opt/mysql@5.7/lib"
set CPPFLAGS "-I/opt/homebrew/opt/mysql@5.7/include"


# flutterのパス通す
# export PATH="$PATH:~/flutter/bin"
set -gx ANDROID_HOME ~/Library/Android/sdk/

set -Ux PYENV_ROOT $HOME/.pyenv
set -Ux PATH $PYENV_ROOT/versions/3.11.2/bin $PATH
status --is-interactive; and source (pyenv init -|psub)

# pnpm
set -gx PNPM_HOME ~/Library/pnpm
set -gx PATH "$PNPM_HOME" $PATH

# volta
set -gx VOLTA_HOME "$HOME/.volta"
set -gx PATH "$VOLTA_HOME/bin" $PATH

# thefuck
thefuck --alias | source

# starship
starship init fish | source
