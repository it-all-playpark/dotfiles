if status is-interactive
    # Commands to run in interactive sessions can go here
end


# exaをlsとして利用
alias ls='command exa --icons --git'
alias lt='command exa -T -L 3 -a -I "node_modules|.git|.cache" --icons'
alias ltl='command exa -T -L 3 -a -I "node_modules|.git|.cache" -l --icons'

# batをcatとして利用
alias cat='command bat'

# nvimをvimとして利用
alias vim='command nvim'

# 選択した過去の実行コマンドをクリップボードにコピー
alias h='echo -n "$(history | peco)" | pbcopy ; fish_clipboard_paste'

# 選択したローカルリポジトリリストへの移動をgと定義
alias g='set p "$(ghq list --full-path | peco)"; cd $p'

# git
# ローカルブランチを選択してコピー
alias B='echo -n $(git branch -av | peco --prompt "GIT BRANCH>" | head -n 1 | sed -e "s/^\*\s*//g"|awk "{print \$1}")|pbcopy'
alias S='git switch $(git branch -v | peco --prompt "GIT BRANCH>" | head -n 1 | sed -e "s/^\*\s*//g"|awk "{print \$1}")'

# VS Codeのworkspaseを開く
alias ws='set p "$(z -l | awk \'{print $2}\' | peco --query workspaces )"; set f "$(ls $p | awk \'{print $2}\' | peco)"; code -r $p/$f'

# 訪れたことのあるディレクトリリストへの移動をzlと定義
alias zl='set p "$(z -l | awk \'{print $2}\' | peco)"; cd $p'
alias zf='set p "$(z -l | awk \'{print $2}\' | fzf)"; cd $p'

# カレントディレクトリのパスをクリップボードにコピー 
alias pwdc='echo -n "$(pwd)" | pbcopy'

# docker
# 選択した起動中コンテナに入る
alias d='docker exec -it $(docker ps | peco | awk "{print \$1}") sh'
# 選択したlogを表示する
alias dl='docker logs $(docker ps -a| peco | awk "{print \$1}")'
alias dir='docker image rm $(docker image ls | peco | awk "{print \$3}")'
alias dp='docker ps'

# docker composeの略記
alias dc='docker compose'
alias dcb='docker compose build --no-cache'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dcp='docker compose ps'

# 接続Wifi情報確認
alias airport='/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport'

set -x fish_user_paths /opt/homebrew/bin /usr/bin/php /opt/homebrew/opt/mysql@5.7/bin ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/flutter/bin $fish_user_paths
set -U fish_user_paths (echo $fish_user_paths | tr ' ' '\n' | sort -u)

set LDFLAGS "-L/opt/homebrew/opt/mysql@5.7/lib"
set CPPFLAGS "-I/opt/homebrew/opt/mysql@5.7/include"


# flutterのパス通す
# export PATH="$PATH:~/flutter/bin"
export ANDROID_HOME="~/Library/Android/sdk/"

set -Ux PYENV_ROOT $HOME/.pyenv
set -Ux PATH $PYENV_ROOT/versions/3.11.2/bin $PATH
status --is-interactive; and source (pyenv init -|psub)



# pnpm
set -gx PNPM_HOME ~/Library/pnpm
set -gx PATH "$PNPM_HOME" $PATH
# pnpm end

# thefuck
thefuck --alias | source

# starship
starship init fish | source
