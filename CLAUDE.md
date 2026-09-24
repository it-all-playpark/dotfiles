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

Run `nix run .#update` after changing the nix config (the paths above, `darwin/`, `home-manager/`, `common/`, `flake.nix`).

`claude-code/` needs **no** update: `~/.claude/settings.json`, `CLAUDE.md`, `RULES.md`, the hooks, etc. are symlinks into this repo, so changes take effect as soon as they are merged or checked out. The one exception is a **new file** under `claude-code/hooks/` (or `bin/`): activation symlinks those one file at a time, so the new file is missing from `~/.claude/hooks/` until the next activation. A settings.json entry that runs a new hook must therefore exit 0 when the file is missing (`python3 missing.py` exits 2, and exit 2 from a PreToolUse hook blocks every Bash call). Until then, a single `ln -s` links the file.

> **agent 実行時の注意**: `nix run .#update` は内部で `sudo darwin-rebuild` を呼ぶため sandbox/permission で拒否される。**apply は人間が実行**し、agent は `nix fmt` / `nix flake check` / `nix eval` までを検証範囲とする。

## Critical Notes

- **大西配列**: Navigation keys are `tnrs` (not `hjkl`) across Neovim, zellij, etc.

## Reference

- Architecture details: `claudedocs/architecture.md`
