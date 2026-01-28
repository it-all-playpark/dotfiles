# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Nix Flakes-based dotfiles repository for macOS that uses nix-darwin for system configuration and home-manager for user-level dotfiles management. The repository supports multiple users and platforms while maintaining reproducible environment setup.

## Common Development Commands

### Initial Setup
```bash
# Clone and setup for a specific user
./setup.sh <username>  # e.g., ./setup.sh naramotoyuuji
```

### Update Environment
```bash
# Update current user configuration (default: naramotoyuuji)
nix run .#update

# Update specific user
nix run .#update yuji_naramoto

# Update all users
nix run .#update-all
```

### Testing Changes
After making configuration changes, always run the update command to apply them. The system will automatically rebuild and switch to the new configuration.

## Architecture and Key Components

### Flake Structure
- **flake.nix**: Central configuration defining:
  - Multiple user support (naramotoyuuji, yuji_naramoto)
  - Platform detection (darwin/linux-x86/linux-arm)
  - Update scripts for easy maintenance
  - Integration of nix-darwin and home-manager

### Configuration Organization
- **darwin/**: macOS system-level settings (Dock, Finder, keyboard, Homebrew casks)
- **home-manager/**: User-level configurations
  - **home/file/**: Dotfiles that get symlinked to home directory
  - **programs/**: Modular program configurations (git, fish, zsh, neovim, etc.)
- **common/packages.nix**: Shared packages across all platforms

### Important Patterns
1. **Template Files**: Local configurations use `.template` files that should be copied and customized:
   - `git/config.local.template`
   - `fish/config.fish.local.template`
   - `.mcpservers.json.template`
   - `.myclirc.local.template`

2. **Package Management**: 
   - CLI tools: Managed by Nix
   - GUI applications: Managed by Homebrew casks on macOS

3. **Vim Configuration**: Uses LazyVim with custom plugins. Note: Keybindings are configured for "大西配列" (Onishi layout).

4. **Recent Changes**: The tmux configuration has been modified to use tnrs keys instead of hjkl for navigation.

5. **Agent Skills**: Skills have been moved to a separate repository ([it-all-playpark/skills](https://github.com/it-all-playpark/skills)). The `scripts/setup-skills.sh` script creates symlinks for Claude Code, Clawdbot, Codex, and Antigravity.

## Key Configuration Files

When modifying configurations:
- System settings: Edit `darwin/default.nix`
- User packages: Edit `home-manager/home/default.nix`
- Program configs: Edit files in `home-manager/programs/`
- Dotfiles: Add/modify files in `home-manager/home/file/`

Remember to run the update command after making changes to apply them to the system.