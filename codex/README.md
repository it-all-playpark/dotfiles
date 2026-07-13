# Codex Configuration (Managed)

This directory stores shared Codex configuration managed by dotfiles.

## Managed files

- `config.base.toml`: shared defaults merged into `~/.codex/config.toml`
- `config.local.toml.template`: template for local-only overrides/secrets
- `prompts/`, `policy/`: static assets synced as symlinks
- `hooks/`: Codex hook scripts synced as symlinks for existing `~/.codex/hooks.json`
- `rules/default.rules`: baseline template copied once to `~/.codex/rules/default.rules`

## Runtime and secret separation

- Local-only files: `~/.codex/config.local.toml`, `~/.codex/rules/default.rules`
- Generated file: `~/.codex/config.toml` (rebuilt on each Home Manager activation)
- Runtime files such as `auth.json`, `history.jsonl`, `sessions/` are not managed here.
- `~/.codex/hooks.json` is runtime-managed because Codex stores hook trust hashes for it. Dotfiles only ensures referenced scripts under `~/.codex/hooks/` exist.

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
  - `~/.codex/rules/default.rules` entries with `decision = "prompt"`
- In this dotfiles baseline, these values are set for low-friction project work:
  - `approval_policy = "never"`
  - `sandbox_mode = "workspace-write"`
  - `sandbox_workspace_write.network_access = true`
- High-risk commands aligned with `claude-code/settings.json` deny/guard policy are mapped to `decision = "forbidden"` instead of `decision = "prompt"` so they are rejected without asking.
- Avoid `sandbox_mode = "danger-full-access"` as a shared default. Use it only per-invocation when an external sandbox already exists.
- Prefix rules are literal prefix matches. `["git", "push"]` does not match `git -C <path> push ...`.
- `~/.codex/rules/default.rules` is local-only and copied only once. If you already have a local rules file, updates in `dotfiles/codex/rules/default.rules` will not overwrite it automatically.

## Hook troubleshooting

Codex reports PreToolUse/PostToolUse failures when `~/.codex/hooks.json` references scripts that do not exist under `~/.codex/hooks/`. Home Manager activation now symlinks the supported hook scripts from `codex/hooks/` without replacing `hooks.json`, so existing trusted hashes remain valid.

Some lifecycle hooks are intentionally no-op placeholders until Codex-specific behavior is defined. They exist to keep stale runtime hook references from failing.
