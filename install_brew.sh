#!/bin/bash

echo "installing homebrew..."
which brew >/dev/null 2>&1 || /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"

echo "run brew doctor..."
which brew >/dev/null 2>&1 && brew doctor

echo "run brew update..."
which brew >/dev/null 2>&1 && brew update

echo "ok. run brew upgrade..."
brew upgrade


formulas=(
    act
    bat
    bpytop
    eza
    fastfetch
    fd
    ffmpegthumbnailer
    ffmpeg
    fish
    fisher
    fzf
    gh
    ghq
    git
    git-delta
    jq
    lastpass-cli
    lazydocker
    lazygit
    mas
    mise
    neovim
    pandoc
    poppler
    procs
    rip
    ripgrep
    ripgrep-all
    sd
    starship
    tldr
    tree-sitter
    unar
    yazi
    zoxide
)

echo "brew tap"
# brew tap thirdparty
brew tap homebrew/cask-fonts

echo "brew install formula"
for formula in "${formulas[@]}"; do
    brew install $formula || brew upgrade $formula
done

# install gui up
casks=(
    arc
    box-drive
    box-tools
    cheatsheet
    coteditor
    cursor
    deepl
    docker
    font-hack-nerd-font
    google-chrome
    google-drive
    google-japanese-ime
    hhkb-keymap-tool
    lastpss
    monitorcontrol
    microsoft-teams
    onedrive
    postman
    raycast
    sequel-ace
    setapp
    slack
    warp
    zoom
)

echo "brew casks"
for cask in "${casks[@]}"; do
    brew install --cask $cask
done


stores=(
    497799835
    462054704
    462058435
    462062816
    784801555
    1295203466
    985367838
)


echo "app stores"
for store in "${stores[@]}"; do
    mas install $store
done


brew cleanup

echo "brew installed"

