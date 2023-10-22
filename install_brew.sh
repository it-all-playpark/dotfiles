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
    bat
    dat
    exa
    fd
    fish
    fisher
    gh
    git
    git-delta
    jq
    lastpass-cli
    lazygit
    mas
    navi
    neovim
    neofetch
    npm
    peco
    procs
    pstree
    pyenv
    starship
    thefuck
    tldr
    tmux
    tree
    tree-sitter
    yarn
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
    alfred
    box-drive
    box-tools
    cheatsheet
    coteditor
    deepl
    docker
    dropbox
    font-hack-nerd-font
    google-chrome
    google-drive
    google-japanese-ime
    hhkb-keymap-tool
    lastpss
    lunar
    microsoft-teams
    onedrive
    postman
    safari-technology-preview
    sequel-ace
    setapp
    slack
    visual-studio-code
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

