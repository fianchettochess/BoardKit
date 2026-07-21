# Contributing to BoardKit

Thank you for helping improve BoardKit. Keep each pull request focused, add or
update tests for behavior changes, and run `swift test` before submitting it.

## Capture logs and privacy

Submit the smallest `.replay` fixture that demonstrates the behavior. Do not
commit raw PacketLogger, btsnoop, pcap, phone, or application logs. Those files
can contain unrelated traffic and identifiers that the `.replay` format does
not need.

Before committing a fixture or transcript, remove:

- Bluetooth MAC addresses, OS-assigned device UUIDs, serial numbers, pairing
  material, and user- or device-assigned names;
- account identifiers, tokens, session URLs, IP addresses, hostnames, local
  filesystem paths, and unrelated application traffic;
- timestamps and metadata that are not required by the regression.

Inspect the staged diff before pushing. Sanitizing a later commit does not
remove sensitive data from earlier Git history. If a credential is committed,
stop using it and rotate it rather than relying on a follow-up deletion.

Document the board model, relevant firmware version, capture method, and the
expected decoded events in the test or fixture comments. Synthetic or reduced
fixtures are preferred when they preserve the failing protocol behavior.

## Source provenance

Contributions must be original or distributed under terms compatible with this
repository. When another implementation informed an adapter, record its URL,
revision, license, and how it informed the work in the adapter's source header.
Distinguish materially adapted implementation sources from protocol or behavior
references without making unsupported provenance or licensing claims. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the attributions currently
supported by checked-in evidence.
