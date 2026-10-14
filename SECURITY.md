# Security

CodexPro Smart is a local control surface, not a security boundary. The UI can request an external adapter to start, stop, reconnect, or inspect privileged local services. Review the adapter before enabling any mutating action.

Never publish real HTTP tokens, tunnel credentials, Cloudflare configuration, personal paths, logs, browser data, or connection URLs containing credentials. Use synthetic hostnames and token paths in examples.

The public snapshot deliberately excludes the live macOS LaunchAgents and the private control scripts. A reported issue should include only synthetic fixtures, the public commit, the enabled environment variables, and whether the issue is limited to the UI, the runner, or an external adapter.
