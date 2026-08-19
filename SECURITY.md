# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose local
credentials, arbitrary files, or network access. Use the repository's
**Security > Advisories > New draft security advisory** flow and include
reproduction details and the affected version.

## Credential handling

This wrapper does not store or transmit provider credentials. DeepSeek Harness
continues to read its own local configuration and credential files. Do not add
keys, tokens, or credential files to issues, pull requests, or commits.
