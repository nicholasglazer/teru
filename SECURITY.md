# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in teru, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Email: nicholasglazer at protonmail dot com
3. Include: description, reproduction steps, and affected versions

You should receive a response within 72 hours.

## Scope

Security-relevant areas in teru:

- **PTY handling** -- child process spawning, file descriptor management
- **MCP server** -- IPC socket authentication, input validation
- **CustomPaneBackend** -- agent protocol input parsing
- **Session persistence** -- .tsess file deserialization
- **Config file parsing** -- teru.conf and theme file loading

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.3.x   | Yes       |
| < 0.3   | No        |
