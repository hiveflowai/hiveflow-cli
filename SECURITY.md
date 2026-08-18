# Security Policy

## Reporting Security Vulnerabilities

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, report them via email to **security@hiveflow.ai**.

We will acknowledge your report within 48 hours and provide a more detailed response within 7 days indicating the next steps in handling your report.

## Security Updates

Critical security issues will be patched within 7 days of confirmation and released as a patch version.

Users are encouraged to:
- Keep `@hiveflow/cli` updated to the latest version
- Review the [changelog](https://github.com/hiveflowai/hiveflow-cli/releases) for security-related updates
- Subscribe to repository notifications for security advisories

## Supported Versions

We support the latest major version with security updates:

| Version | Supported          |
| ------- | ------------------ |
| 0.4.x   | :white_check_mark: |
| < 0.4   | :x:                |

## Known Security Considerations

### Installation Script

The install script (`curl https://hiveflow.ai/install.sh | bash`) downloads and executes code. Always review the script before running:

```bash
# Review before installing
curl https://hiveflow.ai/install.sh | less

# Or use npm (verifies package signature)
npm install -g @hiveflow/cli
```

### API Keys and Tokens

- Never commit `.hiveflow/config.json` (contains API keys)
- Use environment variables for CI/CD: `HIVEFLOW_API_TOKEN`, `ANTHROPIC_API_KEY`
- Rotate tokens if accidentally exposed

### Remote Control Feature

When using `/remote control`, your CLI session streams to Hiveflow backend over HTTPS. Only enable in trusted environments.
