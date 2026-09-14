# IOSSim host device bridge

This crate is the only Rust-to-Swift boundary used by the macOS consumer
runtime. It pins [`jkcoxson/idevice`](https://github.com/jkcoxson/idevice) at
commit `1838db107d38701b4044361163aac049006c2627` (crate release 0.1.67, MIT).

The exported ABI uses opaque handles and owned result buffers. Every exported
entry point catches Rust panics in debug builds; release builds abort rather
than unwinding across the C boundary. Callers must free each result and close
each device handle exactly once. Handles bind a stable UDID, the observed
usbmux identifier, and a connection generation so a reconnect cannot silently
retarget work to another phone.

The bridge never logs pairing, signing, or Apple Account secrets. Its
diagnostic string is bounded and sanitized. Long operations accept a bounded
timeout; opened handles also support cooperative cancellation.
