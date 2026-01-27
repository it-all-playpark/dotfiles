# Claude Code Authentication

## Setting up your API Key

To use Claude Code in this DevContainer, you need to configure your Anthropic API key.

### Option 1: Environment Variable (Recommended)

1. Get your API key from https://console.anthropic.com/
2. Set it in your host environment:
   ```bash
   export ANTHROPIC_API_KEY="your-api-key-here"
   ```
3. Rebuild the DevContainer

### Option 2: DevContainer Environment File

1. Copy `.devcontainer/.env.example` to `.devcontainer/.env`
2. Add your API key to the `.env` file
3. Rebuild the DevContainer

### Option 3: VS Code Settings

1. Open VS Code settings
2. Search for "Remote > Containers: Environment Variables"
3. Add `ANTHROPIC_API_KEY` with your API key value

## Security Notes

- Never commit your API key to version control
- The `.env` file is gitignored by default
- Use environment-specific keys for different projects

## Troubleshooting

- Run `echo $ANTHROPIC_API_KEY` to verify the key is set
- Run `claude --version` to test the CLI
- Check ${HOME_DIR}/.zshrc for the export statement

For more help, see: https://docs.anthropic.com/en/docs/claude-code
