# Repository Guidelines

## Project Structure & Module Organization
Configuration lives in a single Nix flake that coordinates both nix-darwin and home-manager. Key directories:
- `flake.nix` / `flake.lock`: top-level definitions for inputs, per-user home configurations, and the `update` apps.
- `darwin/default.nix`: macOS system modules applied to host `MyMBP`.
- `home-manager/`: user-scoped modules; keep program-specific tweaks in `programs/` and link shared options through `home/default.nix`.
- `common/packages.nix`: curated package sets imported by both platforms.
Template files under `home-manager/home/file/*` should be copied to `.local` counterparts for secrets or machine overrides.

## Build, Test, and Development Commands
- `./setup.sh <username>` installs Nix if missing, enables flakes, then runs the update app for the chosen username.
- `nix run .#update <username>` refreshes flake inputs and switches both home-manager and nix-darwin for the active platform.
- `nix run .#update-all` iterates through every supported username, useful after shared module edits.
- `nix flake check` verifies that all Nix modules evaluate before you commit.

## Coding Style & Naming Conventions
Prefer two-space indentation and trailing newlines in `.nix` files, mirroring the existing flake. Use lower-kebab-case filenames for modules (`google-cloud-sdk.nix`, `shell-common.nix`). Keep attribute names snake_case only when required by upstream modules. Group shared options into helper modules (see `home-manager/programs/common.nix`) and reserve `.local` files for untracked secrets.

## Testing Guidelines
Always run `nix flake check` to catch syntax or option regressions. For activation dry runs, evaluate `nix run home-manager -- switch --flake .#<username>-darwin -- --dry-run` on macOS or replace the suffix with `-linux-x86` / `-linux-arm` as appropriate. When touching system modules, confirm `sudo nix run nix-darwin -- switch --flake .#MyMBP` completes locally before opening a PR and note any manual steps.

## Commit & Pull Request Guidelines
Follow the existing Conventional Commit pattern with emojis (`feat: 🎸 describe change`). Scope names should match the component you touched (`home-manager`, `darwin`, `common`). For pull requests, include: 1) a concise summary of the motivation and affected hosts, 2) command output or notes showing the update or switch command succeeded, and 3) reminders for reviewers about any new secrets or templates they must create locally.
