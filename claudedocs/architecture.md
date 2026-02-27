# Architecture Reference

## Flake Structure

- **flake.nix**: Central configuration
  - Users: `naramotoyuuji`, `yuji_naramoto`
  - Platforms: darwin / linux-x86 / linux-arm (auto-detect)
  - Outputs: homeConfigurations, darwinConfigurations, apps (update/update-all), formatter, devShells
  - Inputs: nixpkgs (unstable), home-manager, nix-darwin, claude-code-overlay, treefmt-nix
- **treefmt.nix**: nixfmt, ruff-check, ruff-format, stylua, shfmt

## Directory Structure

```
.
├── flake.nix                   # Central Nix Flakes configuration
├── treefmt.nix                 # Formatter configuration
├── setup.sh                    # Initial setup script
├── common/
│   └── packages.nix            # Shared packages across platforms
├── darwin/
│   └── default.nix             # macOS system settings (Dock, Finder, keyboard, Homebrew casks)
├── home-manager/
│   ├── default.nix
│   ├── home/
│   │   ├── default.nix         # User packages
│   │   └── file/               # Dotfiles symlinked to ~
│   │       ├── .tmux.conf
│   │       ├── nvim/           # LazyVim config
│   │       ├── fish/
│   │       ├── git/
│   │       ├── ghostty/
│   │       ├── zed/
│   │       ├── lazygit/
│   │       ├── mise/
│   │       └── ...
│   └── programs/               # Modular program configurations
│       ├── fish.nix
│       ├── git.nix
│       ├── neovim.nix
│       ├── zsh.nix
│       ├── yazi.nix
│       ├── google-cloud-sdk.nix
│       ├── shell-common.nix
│       └── common.nix
├── claude-code/                # Claude Code project config (hooks, modes, settings)
├── codex/                      # Codex AI agent config
├── openclaw/                   # OpenClaw config (symlinked from ~/.openclaw)
└── scripts/
    └── setup-skills.sh         # Skills symlink setup (Claude Code, OpenClaw, Codex, Antigravity)
```

## Template Files

Local configurations use `.template` files (copy and customize, not tracked by git):

| Template | Location |
|----------|----------|
| Git local config | `home-manager/home/file/git/config.local.template` |
| Fish local config | `home-manager/home/file/fish/config.fish.local.template` |
| MCP servers | `home-manager/home/file/.mcpservers.json.template` |
| mycli local | `home-manager/home/file/.myclirc.local.template` |
| mise env | `home-manager/home/file/mise/.env.template` |
| Codex local config | `codex/config.local.toml.template` |

## Package Management

- **CLI tools**: Managed by Nix (`common/packages.nix`, `home-manager/home/default.nix`)
- **GUI apps**: Managed by Homebrew casks on macOS (`darwin/default.nix`)

## Agent Skills

Skills are in a separate repository: [it-all-playpark/skills](https://github.com/it-all-playpark/skills)

`scripts/setup-skills.sh` creates symlinks for:

- Claude Code (`~/.claude/skills`)
- OpenClaw (`~/.openclaw/skills`)
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

This applies to: Neovim, tmux (copy-mode), and other tools configured in this repo.
