# Repository Guidelines

## Project Structure & Module Organization
Configuration lives in a single Nix flake that coordinates both nix-darwin and home-manager. Key directories:
- `flake.nix` / `flake.lock`: top-level definitions for inputs, per-user home configurations, and the `update` apps.
- `darwin/`: macOS system modules (`default.nix`, `homebrew.nix`, ...) applied to the per-user host `MyMBP-<username>`.
- `home-manager/`: user-scoped modules; keep program-specific tweaks in `programs/` and link shared options through `home/default.nix`.
- `common/packages.nix`: curated package sets imported by both platforms.
Template files under `home-manager/home/file/*` should be copied to `.local` counterparts for secrets or machine overrides.

## Build, Test, and Development Commands
- `./setup.sh <username>` installs Nix if missing, enables flakes, then runs the update app for the chosen username.
- `nix run .#update <username>` refreshes flake inputs and switches both home-manager and nix-darwin for the active platform.
- `nix run .#update-all` iterates through every supported username, useful after shared module edits.
- `nix flake check` checks formatting (treefmt). It does not evaluate the darwin / home-manager configs; see Testing Guidelines.

## Coding Style & Naming Conventions
Prefer two-space indentation and trailing newlines in `.nix` files, mirroring the existing flake. Use lower-kebab-case filenames for modules (`google-cloud-sdk.nix`, `shell-common.nix`). Keep attribute names snake_case only when required by upstream modules. Group shared options into helper modules (see `home-manager/programs/common.nix`) and reserve `.local` files for untracked secrets.

## Testing Guidelines
Run `nix flake check` (formatting) and `bash tests/run-all.sh`. To catch syntax or option regressions, evaluate the configs the way CI does: `nix build --dry-run .#darwinConfigurations.MyMBP-<username>.system .#homeConfigurations.<username>-darwin.activationPackage` (use the `-linux-x86` / `-linux-arm` suffix for Linux home configs). When touching system modules, confirm `nix run .#update <username>` completes locally before opening a PR and note any manual steps.

## Commit & Pull Request Guidelines
Follow the Conventional Commit pattern (`fix(claude-code): describe change`). Scope names should match the component you touched (`home-manager`, `darwin`, `common`). For pull requests, include: 1) a concise summary of the motivation and affected hosts, 2) command output or notes showing the update or switch command succeeded, and 3) reminders for reviewers about any new secrets or templates they must create locally.
