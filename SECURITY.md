# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose local
credentials, arbitrary files, or network access. Use the repository's
**Security > Advisories > New draft security advisory** flow and include
reproduction details and the affected version.

## Credential handling

The GUI does not add a second credential store or intentionally read provider
secrets. DeepSeek Harness continues to read its own local configuration and
credential files, and the dsh child process inherits the environment it needs.
The GUI captures dsh stdout/stderr for the on-screen and disk logs, so do not
print keys, tokens, or other secrets from dsh or its plugins. Do not add keys,
tokens, credential files, or unredacted logs to issues, pull requests, or
commits.

The GUI/WebView layer only targets loopback addresses. DeepSeek Harness may
still make outbound requests to model providers and other endpoints selected
in the user's dsh configuration.
