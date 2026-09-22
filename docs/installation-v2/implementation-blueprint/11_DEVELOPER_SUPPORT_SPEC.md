# Developer Support / DDI Specification

## Provider boundary

```swift
protocol DeveloperSupportProvider: Sendable {
  func resolve(osBuild: String, productType: String) async throws -> DeveloperSupportCandidate
}
protocol DeveloperSupportMounter: Sendable {
  func status(device: DeviceConnection) async throws -> MountObservation
  func personalizeAndMount(_ candidate: DeveloperSupportCandidate,
                           on device: DeviceConnection) async throws -> MountReceipt
}
```

`DeveloperSupportCoordinator` keeps policy; `DevelopmentDeveloperSupportProvider` is debug/qualification-only. A new production provider must resolve exact iOS build from a signed Veya catalog or bundled/cache artifact. Development mirrors, Xcode paths, and arbitrary URLs are forbidden in production.

## Candidate validation

The candidate record contains provider ID, exact OS build/product family, manifest version, source provenance, expected sizes/hashes, signature/provenance result, acquired time, and quarantine state. Downloads land in `DeveloperSupport/quarantine/<digest>`, are size/hash/schema validated, and atomically promoted to the content-addressed cache. A near-version match is never accepted.

Personalization inputs and TSS responses are bound to device ECID/build/candidate digest/generation. Secrets are redacted. Mount success requires both image-mounter status and a fresh developer-service connection; a successful API return alone is insufficient.

## States

`missing -> acquiring -> quarantined -> validated -> personalizationRequired -> mounting -> mounted -> serviceProven`; failures distinguish provider unavailable, exact build absent, integrity, TSS, locked device, Developer Mode, disconnect, and protocol drift.

Production sourcing remains an external blocker until a licensed, reliable exact-build catalog and update SLA are demonstrated. Implementation of interfaces/cache/tests may proceed, but Build 12 cannot claim broad OS support; its supported-build manifest must name the physically proven build(s).

