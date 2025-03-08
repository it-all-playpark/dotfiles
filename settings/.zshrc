# ezaをlsとして利用
alias ls="eza --icons --git --time-style relative -la"
alias lt="eza --icons --git --time-style relative --tree -aI 'node_modules|.git|.cache'"
alias ltl="eza --icons --git --time-style relative --tree -alI 'node_modules|.git|.cache'"

# batをcatとして利用
alias cat="bat"

# nvimをvimとして利用
alias vim="nvim"

# 選択した過去の実行コマンドをクリップボードにコピー
alias h="echo -n \$(fc -l -n | fzf +s --layout=reverse) | pbcopy"

# 選択したローカルリポジトリリストへの移動をgと定義
alias g="cd \$(ghq list --full-path | fzf --layout=reverse --preview 'eza --icons --git --time-style relative -la {}')"

# git
# ローカルブランチを選択してコピー
alias B="echo -n \$(git branch -av | fzf --layout=reverse --prompt 'GIT BRANCH>' | sed 's/\*//' | awk '{print \$1}') | pbcopy"
alias S="git switch \$(git branch -av | fzf --layout=reverse --prompt 'GIT BRANCH>' | sed 's/\*//' | awk '{print \$1}')"

# lazigit
alias lg="lazygit"

# lazydocker
alias ld="lazydocker"

# カレントディレクトリのパスをクリップボードにコピー
alias pwdc="echo -n \$(pwd) | pbcopy"

# docker
# finch利用時にdockerコマンドをfinchに変換
# alias docker="finch"
# 選択した起動中コンテナに入る
alias d="docker exec -it \$(docker ps | fzf --layout=reverse --prompt 'Docker Container>' --preview-window 'bottom:70%' --preview 'docker logs {1}' | awk '{print \$1}') sh"
# 選択したlogを表示する
alias dl="docker logs --details \$(docker ps -a | fzf --layout=reverse --prompt 'Docker Container>' --preview-window 'bottom:70%' --preview 'docker logs --details {1}' | awk '{print \$1}')"
# 選択したコンテナを削除する
alias dr="docker rm \$(docker ps | fzf --layout=reverse --prompt 'Docker Container>' --preview-window 'bottom:70%' --preview 'docker logs {1}' | awk '{print \$1}')"
# 選択したコンテナイメージを削除する
alias dir="docker image rm \$(docker image ls | fzf --layout=reverse --prompt 'Docker Image>' --preview 'docker image inspect {3}' | awk '{print \$3}')"
# 選択したコンテナボリュームを削除する
alias dvr="docker volume rm \$(docker volume ls | fzf --layout=reverse --prompt 'Docker Volume>' --preview 'docker volume inspect {2}' | awk '{print \$2}')"
alias dp="docker ps"

# docker composeの略記
alias dc="docker compose"
alias dcb="docker compose build --no-cache"
alias dcu="docker compose up -d"
alias dcd="docker compose down"
alias dcp="docker compose ps"

# yaziでカレントディレクトリを変更
function yy() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
	yazi "$@" --cwd-file="$tmp"
	if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
		cd -- "$cwd"
	fi
	rm -f -- "$tmp"
}
# global ip確認
alias ip="echo -n \$(dig myip.opendns.com @208.67.222.222 +short) | pbcopy; pbpaste"

# PATH設定
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin/php:~/ghq/github.com/astj/ghq-migrator:~/google-cloud-sdk/bin:~/flutter/bin:~/Library/Android/sdk:~/.cargo/bin:$PATH"

# zoxide
eval "$(zoxide init zsh)"

# starship
eval "$(starship init zsh)"

# mise
mise activate zsh
