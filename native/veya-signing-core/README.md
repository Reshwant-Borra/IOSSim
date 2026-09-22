# Veya signing core

This crate owns Veya's in-process iOS payload signing boundary. It inventories
an immutable bundle, validates the caller's expected signable graph, prepares a
same-volume candidate, signs it with `isideload-apple-codesign` 0.29.11, and
reopens every Mach-O for independent structural verification.

Private-key bytes exist only in `Zeroizing` memory owned by the request. They
are never serialized into receipts or diagnostics.

