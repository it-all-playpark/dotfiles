# Codex Configuration (Managed)

This directory stores shared Codex configuration managed by dotfiles.

## Managed files

- `config.base.toml`: shared defaults merged into `~/.codex/config.toml`
- `config.local.toml.template`: template for local-only overrides/secrets
- `prompts/`, `policy/`: static assets synced as symlinks
- `rules/default.rules`: baseline template copied once to `~/.codex/rules/default.rules`

## Runtime and secret separation

- Local-only files: `~/.codex/config.local.toml`, `~/.codex/rules/default.rules`
- Generated file: `~/.codex/config.toml` (rebuilt on each Home Manager activation)
- Runtime files such as `auth.json`, `history.jsonl`, `sessions/` are not managed here.

## Migration behavior

On first activation:

1. Existing `~/.codex/config.toml` is backed up.
2. `projects` / `mcp_servers` sections are extracted to `~/.codex/config.local.toml`.
3. New `~/.codex/config.toml` is generated from base + local.

## Reducing approval prompts

- `trust_level = "trusted"` only marks a project as trusted. It does not disable approvals by itself.
- Prompt frequency is mainly controlled by:
  - `approval_policy`
  - `sandbox_mode`
  - `sandbox_workspace_write.network_access`
- In this dotfiles baseline, these values are set for low-friction project work:
  - `approval_policy = "on-failure"`
  - `sandbox_mode = "workspace-write"`
  - `sandbox_workspace_write.network_access = true`
- Prefix rules are literal prefix matches. `["git", "push"]` does not match `git -C <path> push ...`.
- `~/.codex/rules/default.rules` is local-only and copied only once. If you already have a local rules file, updates in `dotfiles/codex/rules/default.rules` will not overwrite it automatically.
