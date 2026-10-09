# Architecture Reference

## Flake Structure

- **flake.nix**: Central configuration
  - Users: `naramotoyuuji`, `yuji_naramoto`
  - Platforms: darwin / linux-x86 / linux-arm (auto-detect)
  - Outputs: homeConfigurations, darwinConfigurations, apps (update/update-all), formatter, devShells
  - Inputs: nixpkgs (unstable), home-manager, nix-darwin, treefmt-nix
  - Checks: `formatting` only (config evaluation runs as a separate CI step via `nix build --dry-run`)
- **treefmt.nix**: nixfmt, ruff-check, ruff-format, stylua, shfmt, json-sort-cli

## Directory Structure

```
.
├── flake.nix                   # Central Nix Flakes configuration
├── treefmt.nix                 # Formatter configuration
├── setup.sh                    # Initial setup script
├── common/
│   └── packages.nix            # Shared packages across platforms
├── lib/
│   └── cli-packages.nix        # CLI tool package list
├── darwin/
│   ├── default.nix             # macOS system settings (Dock, Finder, keyboard)
│   ├── homebrew.nix            # Homebrew brews / casks
│   ├── nix.nix
│   ├── agent-vault.nix
│   └── remote-access.nix
├── home-manager/
│   ├── default.nix
│   ├── home/
│   │   ├── default.nix         # Other user packages, launchd agents, activation scripts
│   │   └── file/               # Dotfiles symlinked to ~
│   │       ├── nvim/           # LazyVim config
│   │       ├── fish/
│   │       ├── git/
│   │       ├── ghostty/
│   │       ├── lazygit/
│   │       ├── mise/
│   │       └── ...
│   └── programs/               # Modular program configurations
│       ├── fish.nix / zsh.nix / shell-common.nix / common.nix
│       ├── git.nix / neovim.nix / yazi.nix / google-cloud-sdk.nix
│       ├── agent-vault.nix / jev-broker.nix / pg-broker.nix   # Claude Code sandbox helpers
│       ├── cc-launch.nix / cca.nix / antigravity-cli.nix
│       └── uc-handoff.nix
├── claude-code/                # Claude Code config (settings, hooks, bin, RULES.md)
├── codex/                      # Codex AI agent config
└── scripts/
    └── setup-skills.sh         # Skills symlink setup (Codex, Antigravity)
```

## Template Files

Local configurations use `.template` files (copy and customize, not tracked by git):

| Template | Location |
|----------|----------|
| Git local config | `home-manager/home/file/git/config.local.template` |
| Fish local config | `home-manager/home/file/fish/config.fish.local.template` |
| mycli local | `home-manager/home/file/.myclirc.local.template` |
| cc-launch projects | `home-manager/home/file/cc-launch/projects.tsv.template` |
| mise env | `home-manager/home/file/mise/.env.template` |
| Codex local config | `codex/config.local.toml.template` |

## Package Management

- **CLI tools**: Managed by Nix (`lib/cli-packages.nix`, `common/packages.nix`, `home-manager/home/default.nix`)
- **GUI apps**: Managed by Homebrew casks on macOS (`darwin/homebrew.nix`)

## Agent Skills

Skills are in a separate repository: [it-all-playpark/skills](https://github.com/it-all-playpark/skills)

`scripts/setup-skills.sh` creates symlinks for:

- Codex (`~/.codex/skills`)
- Antigravity (`~/.gemini/antigravity/skills`)

## Keybinding Layout

All navigation keybindings use **大西配列 (Onishi layout)** instead of hjkl:

| Key | Direction | hjkl equivalent |
|-----|-----------|-----------------|
| `t` | left | `h` |
| `n` | down | `j` |
| `r` | up | `k` |
| `s` | right | `l` |

This applies to: Neovim, zellij, and other tools configured in this repo.
