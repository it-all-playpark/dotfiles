# PATH設定
fish_add_path ~/.nix-profile/bin /nix/var/nix/profiles/default/bin /opt/homebrew/bin /opt/homebrew/sbin /usr/bin/php ~/ghq/github.com/astj/ghq-migrator ~/google-cloud-sdk/bin ~/Library/Android/sdk ~/.local/share/mise/shims

starship init fish | source
zoxide init fish | source
mise activate fish | source

# ローカル設定を読み込む
if test -f ~/.config/fish/config.fish.local
    source ~/.config/fish/config.fish.local
end
