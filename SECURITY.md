# Security Policy

## Supported versions

Security fixes target the latest tagged release and the `main` branch. Older
releases may not receive patches.

## Reporting a vulnerability

Please do not publish exploit details, credentials, device identifiers, or raw
radio captures in an issue or pull request.

If GitHub shows **Security → Report a vulnerability** for this repository, use
that private form. Otherwise, open an issue titled **Security report
coordination request** with only the affected version, affected component, and
a non-sensitive summary. A maintainer can then arrange a private channel for
the technical details.

Before sharing logs, remove authentication material, BLE addresses and device
UUIDs, board serial numbers, user- or device-assigned names, local network
addresses, and filesystem paths. Prefer a minimal `.replay` fixture containing
only the protocol bytes needed to reproduce the problem.
