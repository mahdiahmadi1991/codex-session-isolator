# Security Policy

## Supported versions

Security fixes are applied to the `main` branch and included in the latest release.

## Reporting a vulnerability

Please do not open public issues for security vulnerabilities.

Report privately to the repository owner with:

- affected file(s)
- reproduction steps
- potential impact
- suggested mitigation (if known)

You will receive acknowledgment and triage as soon as possible.

## Security commitments

- We prioritize fixes for data-loss, arbitrary command execution, and secret exposure risks.
- Managed file writes are scoped to explicit target paths.
- Wizard maintains safety backups before overwriting managed files.
