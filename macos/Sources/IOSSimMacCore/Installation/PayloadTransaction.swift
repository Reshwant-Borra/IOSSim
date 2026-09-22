import CryptoKit
import Foundation

// M7 profile → sign → install transaction (spec 09) as two engine domains:
//   .payload      immutable staged copy → in-process sign → independent verify → promote
//   .application  install the active signed payload → fresh device inventory proof → promote
// The active record of each domain is untouched until its candidate is proven, so every failure
// leaves the known-good payload/application in place. Nothing here invokes /usr/bin/codesign.

/// Everything needed to sign except the private key, bound to the journal's current key/certificate/profiles.
public struct PayloadSigningPlan: Sendable {
    /// One shipped bundle (main app, XCTest runner) signed as its own root.
    public struct Component: Sendable {
        /// Stable role key (`main`, `runner`); also the install order.
        public let role: String
        public let sourceBundle: URL
        /// Final root bundle identifier after the per-team rewrite.
        public let bundleIdentifier: String
        /// Info.plist edits applied to the staged copy before signing: bundle-relative plist path → key → value.
        /// The shipped source is never edited, and only these string values may differ after the rewrite.
        public let infoPlistRewrites: [String: [String: String]]
        public let profiles: [String: Data]
        public let entitlements: [String: [String: SigningEntitlementValue]]

        public init(role: String, sourceBundle: URL, bundleIdentifier: String, infoPlistRewrites: [String: [String: String]],
                    profiles: [String: Data], entitlements: [String: [String: SigningEntitlementValue]]) {
            self.role = role
            self.sourceBundle = sourceBundle
            self.bundleIdentifier = bundleIdentifier
            self.infoPlistRewrites = infoPlistRewrites
            self.profiles = profiles
            self.entitlements = entitlements
        }
    }

    public let components: [Component]
    /// Digest of the approved shipped source (artifact manifest), not of a staged copy.
    public let sourceDigest: String
    public let certificateChainDER: [Data]
    public let keyID: String
    public let teamIdentifier: String

    public init(components: [Component], sourceDigest: String, certificateChainDER: [Data], keyID: String, teamIdentifier: String) {
        self.components = components
        self.sourceDigest = sourceDigest
        self.certificateChainDER = certificateChainDER
        self.keyID = keyID
        self.teamIdentifier = teamIdentifier
    }

    /// Changes whenever the approved source, certificate, profiles, entitlements, identifiers, or key change.
    public var binding: String {
        var hasher = SHA256()
        func add(_ value: String) { hasher.update(data: Data("\(value.utf8.count):\(value)|".utf8)) }
        add(sourceDigest); add(keyID); add(teamIdentifier)
        certificateChainDER.forEach { add(VeyaSigningKeyStore.sha256($0)) }
        for component in components {
            add(component.role); add(component.bundleIdentifier)
            for (path, edits) in component.infoPlistRewrites.sorted(by: { $0.key < $1.key }) {
                add(path)
                for (key, value) in edits.sorted(by: { $0.key < $1.key }) { add(key); add(value) }
            }
            for (id, profile) in component.profiles.sorted(by: { $0.key < $1.key }) { add(id); add(VeyaSigningKeyStore.sha256(profile)) }
            if let entitlements = try? JSONEncoder.sorted.encode(component.entitlements) { add(VeyaSigningKeyStore.sha256(entitlements)) }
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public protocol PayloadSigningPlanProviding: Sendable {
    /// Throws a `VeyaFailure` when prerequisites (certificate/profile) are not ready.
    func plan(journal: InstallationJournal) async throws -> PayloadSigningPlan
}

public protocol PayloadSigning: Sendable {
    func inspect(_ bundle: URL) throws -> SigningBundleGraph
    func sign(_ request: InProcessSigningRequest, keyID: String, installationID: UUID) async throws -> InProcessSigningReceipt
    func verify(_ bundle: URL) throws -> InProcessVerificationReceipt
}

/// Production signer: packaged Rust signer + key store closure-scoped PKCS#8.
public struct InProcessPayloadSigning: PayloadSigning {
    private let signer: InProcessSigner
    private let keyStore: VeyaSigningKeyStore
    public init(signer: InProcessSigner, keyStore: VeyaSigningKeyStore) {
        self.signer = signer
        self.keyStore = keyStore
    }
    public func sign(_ request: InProcessSigningRequest, keyID: String, installationID: UUID) async throws -> InProcessSigningReceipt {
        try await signer.sign(request, keyID: keyID, installationID: installationID, keyStore: keyStore)
    }
    public func verify(_ bundle: URL) throws -> InProcessVerificationReceipt { try signer.verify(bundle) }
    public func inspect(_ bundle: URL) throws -> SigningBundleGraph { try signer.inspect(bundle) }
}

public enum PayloadFailure {
    static func make(_ number: Int, _ operation: String, _ message: String, retryable: Bool = false) -> VeyaFailure {
        // Constant, validated inputs; construction cannot fail.
        try! VeyaFailure(namespace: operation == "install" || operation == "inventory" ? .install : .signing, number: number, operation: operation, safeMessage: message,
                         retryable: retryable, underlyingSubsystem: "payloadTransaction")
    }
    public static let stagingUnsafe = make(20, "stage", "The payload staging area is unsafe or unavailable.")
    public static let signingFailed = make(21, "sign", "The payload could not be signed.")
    /// Same failure, carrying the signer's constant category code (never a path or message) for diagnosis.
    static func signingFailed(_ native: InProcessSignerFailure) -> VeyaFailure {
        let category: String
        switch native {
        case .native(let code) where code.hasPrefix("VEYA-SIGN-") && code.count <= 32
            && code.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" }): category = code
        case .native: category = "native"
        default: category = String(describing: native)
        }
        return (try? VeyaFailure(namespace: .signing, number: 21, operation: "sign", safeMessage: signingFailed.safeMessage,
                                 underlyingSubsystem: "veya-signing-core/\(category)")) ?? signingFailed
    }
    public static let verificationFailed = make(22, "verify", "The signed payload failed independent verification.")
    public static let payloadNotReady = make(23, "install", "No proven signed payload is available to install.")
    public static let inventoryUnavailable = make(24, "inventory", "The device application inventory could not be read.", retryable: true)
    public static let inventoryMismatch = make(25, "inventory", "The device does not report the expected application after install.")
    public static let sourceGraphChanged = make(26, "stage", "The staged payload differs from the approved Veya payload.")
}

public struct PayloadDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .payload
    private let rootURL: URL
    private let repository: InstallationJournalRepository
    private let planProvider: any PayloadSigningPlanProviding
    private let signing: any PayloadSigning
    private let now: @Sendable () -> Date

    /// `rootURL` is the Veya state root; candidates live in `staging/<generation>/` beneath it.
    public init(rootURL: URL, repository: InstallationJournalRepository, planProvider: any PayloadSigningPlanProviding,
                signing: any PayloadSigning, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootURL = rootURL
        self.repository = repository
        self.planProvider = planProvider
        self.signing = signing
        self.now = now
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        let plan: PayloadSigningPlan
        do {
            plan = try await planProvider.plan(journal: journal)
        } catch let failure as VeyaFailure {
            return try DomainObservation(domain: domain, state: failure.retryable ? .retryableFailure : .terminalFailure,
                                         capturedAt: now(), failure: failure)
        }
        if let candidate = journal.candidateResource(for: domain) {
            guard verified(candidate) else {
                return try DomainObservation(domain: domain, state: .invalid, resource: candidate.identity,
                                             capturedAt: now(), safeReason: PayloadFailure.verificationFailed.code)
            }
            let proved = journal.evidence.contains { candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, ownership: .privateKeyControl, capturedAt: now())
        }
        guard let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now())
        }
        guard verified(active) else {
            return try DomainObservation(domain: domain, state: .invalid, resource: active.identity,
                                         capturedAt: now(), safeReason: PayloadFailure.verificationFailed.code)
        }
        // New certificate/profile/key/source/identifiers: the signed payload is stale and is re-signed as a candidate.
        let state: DomainObservationState = active.metadata["binding"] == plan.binding ? .satisfied : .stale
        return try DomainObservation(domain: domain, state: state, resource: active.identity,
                                     ownership: .privateKeyControl, capturedAt: now())
    }

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        switch context.planned.kind {
        case .proveCandidate, .promoteCandidate:
            guard let candidate = context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation, candidate: candidate)
        case .revokeOwnedCertificate:
            throw InstallationStateFailure.transitionUnavailable(domain)
        case .createCandidate, .replaceCandidate:
            break
        }
        let journal = try await repository.load()
        StateContentFiles.collectUnreferenced("staging", domain: domain, journal: journal, root: rootURL)
        let plan = try await planProvider.plan(journal: journal)
        guard !plan.components.isEmpty, Set(plan.components.map(\.role)).count == plan.components.count else {
            throw PayloadFailure.sourceGraphChanged
        }
        let generation = context.planned.generation
        let relativeStage = "staging/\(generation.rawValue)"
        let stage = rootURL.appendingPathComponent(relativeStage, isDirectory: true)
        let sources = stage.appendingPathComponent("source", isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: rootURL.appendingPathComponent("staging", isDirectory: true),
                                            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // A leftover directory for this new generation belongs to an attempt the journal never recorded.
            if fileManager.fileExists(atPath: stage.path) { try fileManager.removeItem(at: stage) }
            try fileManager.createDirectory(at: sources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw PayloadFailure.stagingUnsafe
        }
        defer { try? fileManager.removeItem(at: sources) }
        var metadata = ["binding": plan.binding, "teamIdentifier": plan.teamIdentifier, "roles": plan.components.map(\.role).joined(separator: ",")]
        var parts: [String] = []
        do {
            for component in plan.components {
                let name = component.sourceBundle.lastPathComponent
                let source = sources.appendingPathComponent(name)
                // Immutable same-volume copy: the shipped source is never an input to mutation.
                do { try fileManager.copyItem(at: component.sourceBundle, to: source) } catch { throw PayloadFailure.stagingUnsafe }
                let expected = try approvedGraph(for: component, stagedCopy: source)
                let receipt: InProcessSigningReceipt
                do {
                    receipt = try await signing.sign(
                        InProcessSigningRequest(inputBundle: source, outputBundle: stage.appendingPathComponent(name, isDirectory: true),
                                                certificateChainDER: plan.certificateChainDER, profiles: component.profiles,
                                                entitlements: component.entitlements, expected: expected),
                        keyID: plan.keyID, installationID: context.installationID
                    )
                } catch let failure as VeyaFailure {
                    throw failure
                } catch let native as InProcessSignerFailure {
                    throw PayloadFailure.signingFailed(native)
                } catch {
                    throw PayloadFailure.signingFailed
                }
                metadata["path.\(component.role)"] = name
                metadata["bundle.\(component.role)"] = component.bundleIdentifier
                metadata["inventory.\(component.role)"] = "sha256:" + receipt.outputInventorySha256
                parts.append("\(component.role)=\(receipt.outputInventorySha256)")
            }
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
        let record = try ResourceRecord(
            id: "payload-\(generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: plan.components[0].bundleIdentifier,
                                       digest: Self.digest(parts)),
            lifecycle: .candidate,
            generation: generation,
            ownership: .privateKeyControl,
            createdAt: now(),
            observedAt: now(),
            relativeLocation: relativeStage,
            metadata: metadata
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: generation, candidate: record)
    }

    /// Applies the plan's Info.plist edits to the staged copy and approves the resulting graph: the signable
    /// nodes (paths and kinds) must be exactly those of the shipped source, and the root must carry the
    /// planned identifier. Only planned string values can differ.
    private func approvedGraph(for component: PayloadSigningPlan.Component, stagedCopy: URL) throws -> ExpectedSigningBundleGraph {
        let pristine: SigningBundleGraph
        do { pristine = try signing.inspect(component.sourceBundle) } catch { throw PayloadFailure.sourceGraphChanged }
        for (relative, edits) in component.infoPlistRewrites {
            guard (try? InstallationSafeValue.validateRelativePath(relative)) != nil, relative.hasSuffix("Info.plist") else {
                throw PayloadFailure.sourceGraphChanged
            }
            let url = stagedCopy.appendingPathComponent(relative)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url),
                  var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw PayloadFailure.sourceGraphChanged
            }
            for (key, value) in edits { plist[key] = value }
            do {
                try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url, options: .atomic)
            } catch {
                throw PayloadFailure.stagingUnsafe
            }
        }
        let staged: SigningBundleGraph
        do { staged = try signing.inspect(stagedCopy) } catch { throw PayloadFailure.sourceGraphChanged }
        func shape(_ graph: SigningBundleGraph) -> [String] { graph.expected.signableNodes.map { "\($0.kind):\($0.relativePath)" } }
        guard staged.rootBundleId == component.bundleIdentifier, shape(staged) == shape(pristine) else {
            throw PayloadFailure.sourceGraphChanged
        }
        return staged.expected
    }

    static func digest(_ parts: [String]) -> String {
        VeyaSigningKeyStore.sha256(Data(parts.sorted().joined(separator: "\n").utf8))
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
        var machOs = 0
        var parts: [String] = []
        for (role, url) in bundles(of: candidate) {
            let verification: InProcessVerificationReceipt
            do { verification = try signing.verify(url) } catch { throw PayloadFailure.verificationFailed }
            guard "sha256:" + verification.inventorySha256 == candidate.metadata["inventory.\(role)"] else {
                throw PayloadFailure.verificationFailed
            }
            machOs += verification.verifiedMachos.count
            parts.append("\(role)=\(verification.inventorySha256)")
        }
        guard !parts.isEmpty, Self.digest(parts) == candidate.identity.digest else { throw PayloadFailure.verificationFailed }
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("payload-proof|\(candidate.id)|\(candidate.generation.rawValue)|\(candidate.identity.digest ?? "-")".utf8)),
            kind: "payloadIndependentVerification",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            provenance: "veya-signing-core",
            attributes: ["machOCount": String(machOs)]
        )
    }

    /// Roles of a payload record in install order.
    static func roles(of record: ResourceRecord) -> [String] {
        (record.metadata["roles"] ?? "").split(separator: ",").map(String.init)
    }

    /// Role → signed bundle for a payload record; empty unless every bundle is inside `staging/`.
    func bundles(of record: ResourceRecord) -> [(role: String, url: URL)] {
        guard let relative = record.relativeLocation, relative.hasPrefix("staging/") else { return [] }
        var result: [(role: String, url: URL)] = []
        for role in Self.roles(of: record) {
            guard let name = record.metadata["path.\(role)"], !name.contains("/"), name != "..", name != "." else { return [] }
            result.append((role, rootURL.appendingPathComponent(relative, isDirectory: true).appendingPathComponent(name, isDirectory: true)))
        }
        return result
    }

    private func verified(_ record: ResourceRecord) -> Bool {
        let bundles = bundles(of: record)
        guard !bundles.isEmpty else { return false }
        var parts: [String] = []
        for (role, url) in bundles {
            guard let receipt = try? signing.verify(url), "sha256:" + receipt.inventorySha256 == record.metadata["inventory.\(role)"] else {
                return false
            }
            parts.append("\(role)=\(receipt.inventorySha256)")
        }
        return Self.digest(parts) == record.identity.digest
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Installs the active signed payload (every component, in role order). Install is irreversible; after
/// interruption the device inventory, never the install call's return value, decides the outcome.
/// Proof is bound to the device connection.
public struct ApplicationDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .application
    private let payload: PayloadDomain
    private let repository: InstallationJournalRepository
    private let applications: any NativeApplicationServicing
    private let device: @Sendable () async throws -> IOSSimDeviceIdentity
    private let now: @Sendable () -> Date

    public init(payload: PayloadDomain, repository: InstallationJournalRepository,
                applications: any NativeApplicationServicing,
                device: @escaping @Sendable () async throws -> IOSSimDeviceIdentity,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.payload = payload
        self.repository = repository
        self.applications = applications
        self.device = device
        self.now = now
    }

    /// Expected device identity of one installed component: bundle, version and team.
    private struct Expectation: Equatable {
        let role: String
        let url: URL
        let bundleIdentifier: String
        let version: String
        let teamIdentifier: String

        func matches(_ app: NativeInstalledApplication) -> Bool {
            app.bundleIdentifier == bundleIdentifier && app.version == version && app.teamIdentifier == teamIdentifier
        }
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        let generation = scope.connectionGeneration
        guard let signed = journal.activeResource(for: .payload), let expectations = try? expectations(for: signed) else {
            // Planner order reaches this domain only after `.payload` is satisfied.
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now(), connectionGeneration: generation)
        }
        let installed: [NativeInstalledApplication]
        do {
            installed = try await applications.inventory(on: try await device())
        } catch {
            return try DomainObservation(domain: domain, state: .retryableFailure, capturedAt: now(),
                                         connectionGeneration: generation, failure: PayloadFailure.inventoryUnavailable)
        }
        let matches = expectations.allSatisfy { expected in installed.contains(where: expected.matches) }
        let identity = try ResourceIdentity(domain: domain, resourceID: signed.identity.resourceID, digest: signed.identity.digest)
        if let candidate = journal.candidateResource(for: domain) {
            guard matches, candidate.identity == identity else {
                return try DomainObservation(domain: domain, state: .invalid, resource: candidate.identity, capturedAt: now(),
                                             connectionGeneration: generation, safeReason: PayloadFailure.inventoryMismatch.code)
            }
            let proved = journal.evidence.contains {
                candidate.evidenceIDs.contains($0.id) && $0.generation == candidate.generation
                    && $0.connectionGeneration == generation
            }
            return try DomainObservation(domain: domain, state: proved ? .candidateProved : .candidateUnproved,
                                         resource: candidate.identity, ownership: .activePayloadCorroboration,
                                         capturedAt: now(), connectionGeneration: generation)
        }
        guard let active = journal.activeResource(for: domain) else {
            return try DomainObservation(domain: domain, state: .missing, capturedAt: now(), connectionGeneration: generation)
        }
        // A re-signed payload (new digest) must be reinstalled; a device that lost or changed an app is invalid.
        let state: DomainObservationState = active.identity != identity ? .stale : (matches ? .satisfied : .invalid)
        return try DomainObservation(domain: domain, state: state, resource: active.identity,
                                     ownership: .activePayloadCorroboration, capturedAt: now(),
                                     connectionGeneration: generation,
                                     safeReason: state == .invalid ? PayloadFailure.inventoryMismatch.code : nil)
    }

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        switch context.planned.kind {
        case .proveCandidate, .promoteCandidate:
            guard let candidate = context.candidate else { throw InstallationStateFailure.candidateMissing(domain) }
            return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: candidate.generation, candidate: candidate)
        case .revokeOwnedCertificate:
            throw InstallationStateFailure.transitionUnavailable(domain)
        case .createCandidate, .replaceCandidate:
            break
        }
        let journal = try await repository.load()
        guard let signed = journal.activeResource(for: .payload) else { throw PayloadFailure.payloadNotReady }
        let expectations = try expectations(for: signed)
        let target = try await device()
        var metadata: [String: String] = ["teamIdentifier": signed.metadata["teamIdentifier"] ?? ""]
        for expected in expectations {
            // Reuses the native install path: it verifies inventory after the call and reconciles an
            // interrupted response against a fresh inventory before reporting failure.
            _ = try await NativeApplicationManager(service: applications).installOrUpgradeReceipt(
                appURL: expected.url,
                expectedBundleIdentifier: expected.bundleIdentifier,
                expectedTeamIdentifier: expected.teamIdentifier,
                on: target
            )
            metadata["bundle.\(expected.role)"] = expected.bundleIdentifier
            metadata["version.\(expected.role)"] = expected.version
        }
        metadata["roles"] = expectations.map(\.role).joined(separator: ",")
        let record = try ResourceRecord(
            id: "application-\(context.planned.generation.rawValue)",
            identity: ResourceIdentity(domain: domain, resourceID: signed.identity.resourceID, digest: signed.identity.digest),
            lifecycle: .candidate,
            generation: context.planned.generation,
            ownership: .activePayloadCorroboration,
            createdAt: now(),
            observedAt: now(),
            metadata: metadata
        )
        return try TransitionReceipt(operation: context.planned.kind.rawValue, generation: record.generation, candidate: record)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        guard let candidate = receipt.candidate ?? context.candidate, let team = candidate.metadata["teamIdentifier"] else {
            throw InstallationStateFailure.candidateMissing(domain)
        }
        let roles = PayloadDomain.roles(of: candidate)
        let installed: [NativeInstalledApplication]
        do { installed = try await applications.inventory(on: try await device()) } catch { throw PayloadFailure.inventoryUnavailable }
        guard !roles.isEmpty, roles.allSatisfy({ role in
            installed.contains {
                $0.bundleIdentifier == candidate.metadata["bundle.\(role)"] && $0.version == candidate.metadata["version.\(role)"]
                    && $0.teamIdentifier == team
            }
        }) else {
            throw PayloadFailure.inventoryMismatch
        }
        return try Evidence(
            id: VeyaSigningKeyStore.sha256(Data("application-proof|\(candidate.id)|\(candidate.generation.rawValue)|\(context.scope.connectionGeneration ?? 0)".utf8)),
            kind: "deviceInventoryAfterInstall",
            generation: candidate.generation,
            subject: candidate.identity,
            capturedAt: now(),
            connectionGeneration: context.scope.connectionGeneration,
            provenance: "installation-proxy-inventory",
            attributes: ["components": String(roles.count)]
        )
    }

    private func expectations(for signed: ResourceRecord) throws -> [Expectation] {
        guard let team = signed.metadata["teamIdentifier"] else { throw PayloadFailure.payloadNotReady }
        let bundles = payload.bundles(of: signed)
        guard !bundles.isEmpty else { throw PayloadFailure.payloadNotReady }
        return try bundles.map { role, url in
            guard let bundle = signed.metadata["bundle.\(role)"],
                  let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")),
                  info["CFBundleIdentifier"] as? String == bundle,
                  let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) else {
                throw PayloadFailure.payloadNotReady
            }
            return Expectation(role: role, url: url, bundleIdentifier: bundle, version: version, teamIdentifier: team)
        }
    }
}
