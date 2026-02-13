# Codex Configuration (Managed)

This directory stores shared Codex configuration managed by dotfiles.

## Managed files

- `config.base.toml`: shared defaults merged into `~/.codex/config.toml`
- `config.local.toml.template`: template for local-only overrides/secrets
- `prompts/`, `rules/`, `policy/`: static prompt/rule/policy assets

## Runtime and secret separation

- Local-only file: `~/.codex/config.local.toml`
- Generated file: `~/.codex/config.toml` (rebuilt on each Home Manager activation)
- Runtime files such as `auth.json`, `history.jsonl`, `sessions/` are not managed here.

## Migration behavior

On first activation:

1. Existing `~/.codex/config.toml` is backed up.
2. `projects` / `mcp_servers` sections are extracted to `~/.codex/config.local.toml`.
3. New `~/.codex/config.toml` is generated from base + local.
