# CLAUDE.md

Nix Flakes dotfiles for macOS (nix-darwin + home-manager). Multi-user, multi-platform.

## Commands

```bash
nix run .#update              # Apply config (default: naramotoyuuji)
nix run .#update <username>   # Apply config for specific user
nix run .#update-all          # Apply all users
nix fmt                       # Format all files
nix flake check               # Check formatting (CI)
```

Pre-commit hook (treefmt + shellcheck) auto-installs via `nix develop`.

## Edit Paths

| What | Where |
|------|-------|
| System settings | `darwin/default.nix` |
| User packages | `home-manager/home/default.nix` |
| Program configs | `home-manager/programs/` |
| Dotfiles | `home-manager/home/file/` |
| Shared packages | `common/packages.nix` |

Always run `nix run .#update` after changes.

## Critical Notes

- **大西配列**: Navigation keys are `tnrs` (not `hjkl`) across Neovim, tmux, etc.
- **OpenClaw**: `openclaw/openclaw.json` を直接編集すること。`openclaw config set` は `${ENV_VAR}` を展開してしまうため使用禁止。

## Reference

- Architecture details: `claudedocs/architecture.md`
