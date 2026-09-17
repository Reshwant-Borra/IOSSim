# Artifact identity and provenance

## Identity chain

```text
Git commit + dependency lock digests + release configuration
  -> build invocation/toolchain identities
  -> component hashes/signatures/schemas
  -> assembled app tree hash
  -> DMG hash + mounted app tree hash
  -> signed release manifest
  -> immutable release URL/update entry
```

Every support bundle and GUI About panel shows product version, build, short commit, channel, DMG/release-manifest hash prefix, distribution class, helper/bridge/payload versions, and schema set. Support can identify the binary without filenames supplied by a user.

## Hash methodology used in this research

The app tree hash iterates sorted relative regular-file paths, adds the UTF-8 relative path and NUL, then either `symlink\0` plus target or file bytes, followed by NUL. Dot-prefixed files/directories are excluded by the research utility. The assembled and mounted retest apps both produced `42fe6b9a861c88ff902b8926ab2972aa8dfb885c87b2202400315391479862c2`; `diff -qr` found no differences. Main/helper/bridge SHA-256 values also matched. `CONFIRMED_LOCAL_IOSSIM_ARTIFACT`

Release V2 strengthens this by defining inclusion of every bundle entry, mode, symlink target, extended attribute policy, and code-signature bytes. The pre-DMG and mounted comparison uses the same versioned normalizer. DMG identity remains raw SHA-256.

## Provenance policy

- Dirty builds are local-only and record a source-tree digest; they cannot become public by renaming or copying a sidecar.
- Public release commits and signed tags are immutable and remotely reachable.
- Toolchain versions, SDK build, Swift/Rust versions, Xcode component hashes where practical, and environment allowlist are stored as attestation.
- Payload provenance separately records payload source commit/tree because payloads may be rebuilt before the Mac app.
- Sidecars are output, never authority. The signed manifest derived from final mounted bytes is authority.
- A schema/architecture/payload/source mismatch fails release even when signatures/notarization pass.
