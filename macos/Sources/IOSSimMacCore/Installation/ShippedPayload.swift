import Foundation

// M7 routing: the approved iPhone payload shipped inside Veya.app (`DeviceArtifacts` + manifest) and the
// production signing plan derived from it and the journal's active key, certificate and profiles.

public enum ArtifactFailure {
    static func make(_ number: Int, _ message: String) -> VeyaFailure {
        // Constant, validated inputs; construction cannot fail.
        try! VeyaFailure(namespace: .artifact, number: number, operation: "verify", safeMessage: message,
                         userAction: "Reinstall Veya from its original download, then continue in Veya.",
                         underlyingSubsystem: "shippedPayload")
    }
    public static let damaged = make(30, "Veya's iPhone components are missing or damaged.")
    public static let unexpectedShape = make(31, "Veya's iPhone components do not have the expected structure.")
}

/// The shipped payload, hash-verified once per helper process (resources are immutable while it runs).
public final class ShippedPayload: @unchecked Sendable {
    public struct Component: Sendable {
        public let role: String
        public let url: URL
        public let sha256: String
    }

    static let roles = [("main", "iosMain"), ("runner", "locationControlRunner")]
    public let resourcesURL: URL
    private let lock = NSLock()
    private var verified: Result<[Component], VeyaFailure>?

    public init(resourcesURL: URL) {
        self.resourcesURL = resourcesURL
    }

    public func components() throws -> [Component] {
        try lock.withLock {
            if let verified { return try verified.get() }
            let result: Result<[Component], VeyaFailure>
            do { result = .success(try Self.load(resourcesURL)) } catch { result = .failure(error as? VeyaFailure ?? ArtifactFailure.damaged) }
            verified = result
            return try result.get()
        }
    }

    public var digest: String {
        get throws {
            VeyaSigningKeyStore.sha256(Data(try components().map { "\($0.role)=\($0.sha256)" }.joined(separator: "\n").utf8))
        }
    }

    private static func load(_ resourcesURL: URL) throws -> [Component] {
        let manifest: ArtifactManifest
        do {
            manifest = try ArtifactManifestLoader.load(resourcesURL: resourcesURL)
            try ArtifactManifestLoader.assertArtifactsVerified(resourcesURL: resourcesURL, manifest: manifest)
        } catch {
            throw ArtifactFailure.damaged
        }
        guard manifest.components.count == roles.count else { throw ArtifactFailure.unexpectedShape }
        return try roles.map { role, manifestRole in
            guard let component = manifest.components.first(where: { $0.role == manifestRole }) else {
                throw ArtifactFailure.unexpectedShape
            }
            return Component(role: role, url: resourcesURL.appendingPathComponent(component.relativePath, isDirectory: true),
                             sha256: component.sha256.lowercased())
        }
    }
}

/// `.artifact`: satisfied only while the shipped payload matches its manifest. Nothing can repair it in place.
public struct ArtifactDomain: InstallationObserver, InstallationTransition {
    public let domain: InstallationDomain = .artifact
    private let payload: ShippedPayload
    private let now: @Sendable () -> Date

    public init(payload: ShippedPayload, now: @escaping @Sendable () -> Date = { Date() }) {
        self.payload = payload
        self.now = now
    }

    public func observe(scope: InstallationScope, journal: InstallationJournal) async throws -> DomainObservation {
        do {
            return try DomainObservation(domain: domain, state: .satisfied,
                                         resource: ResourceIdentity(domain: domain, resourceID: "shipped-payload", digest: try payload.digest),
                                         capturedAt: now())
        } catch let failure as VeyaFailure {
            return try DomainObservation(domain: domain, state: .terminalFailure, capturedAt: now(), failure: failure)
        }
    }

    public func execute(_ context: TransitionContext) async throws -> TransitionReceipt {
        throw InstallationStateFailure.transitionUnavailable(domain)
    }

    public func prove(_ receipt: TransitionReceipt, in context: TransitionContext) async throws -> Evidence {
        throw InstallationStateFailure.transitionUnavailable(domain)
    }
}

/// Production `PayloadSigningPlanProviding`: shipped payload + active key, certificate and profiles. It is
/// purely local (no Apple or device access), so observing `.payload` never touches the network.
public struct ShippedPayloadPlanProvider: PayloadSigningPlanProviding {
    private let payload: ShippedPayload
    private let rootURL: URL

    public init(payload: ShippedPayload, rootURL: URL) {
        self.payload = payload
        self.rootURL = rootURL
    }

    public func plan(journal: InstallationJournal) async throws -> PayloadSigningPlan {
        let components = try payload.components()
        guard let key = journal.activeResource(for: .signingKey) else { throw CertificateFailure.noSigningKey }
        guard let certificate = journal.activeResource(for: .certificate),
              let team = certificate.metadata["teamIdentifier"],
              let der = CertificateDomain.activeDER(journal: journal, root: rootURL) else {
            throw AppleDomainFailure.certificateMissing
        }
        guard let profileRecord = journal.activeResource(for: .profile),
              profileRecord.metadata["certificate"] == certificate.identity.digest,
              let profiles = ProfileDomain.profiles(of: profileRecord, root: rootURL) else {
            throw AppleDomainFailure.profileMissing
        }
        let identifiers = try PersonalTeamBundleIdentifierSet(teamIdentifier: team)
        var planned: [PayloadSigningPlan.Component] = []
        for component in components {
            let bundle = component.role == "main" ? identifiers.main : identifiers.runner
            guard let profile = profiles[bundle] else { throw AppleDomainFailure.profileMissing }
            var rewrites = ["Info.plist": ["CFBundleIdentifier": bundle]]
            if component.role == "main" {
                rewrites["Info.plist"]?["IOSSimGate3RunnerBundleIdentifier"] = identifiers.runner
            } else {
                rewrites["PlugIns/\(try Self.testBundleName(in: component.url))/Info.plist"] = ["CFBundleIdentifier": identifiers.uiTests]
            }
            planned.append(PayloadSigningPlan.Component(
                role: component.role,
                sourceBundle: component.url,
                bundleIdentifier: bundle,
                infoPlistRewrites: rewrites,
                profiles: [bundle: profile],
                entitlements: [bundle: try Self.entitlements(profile, bundle: bundle, team: team)]
            ))
        }
        return PayloadSigningPlan(components: planned, sourceDigest: try payload.digest, certificateChainDER: [der],
                                  keyID: key.identity.resourceID, teamIdentifier: team)
    }

    /// The runner's single embedded XCTest bundle.
    static func testBundleName(in runner: URL) throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runner.appendingPathComponent("PlugIns").path)) ?? []
        let tests = names.filter { $0.hasSuffix(".xctest") }
        guard tests.count == 1 else { throw ArtifactFailure.unexpectedShape }
        return tests[0]
    }

    /// The exact entitlements Veya requests for `bundle`, as Xcode would sign them. The profile only
    /// grants (possibly wildcard) values; the signer refuses wildcard requests and re-checks every grant.
    static func entitlements(_ profile: Data, bundle: String, team: String) throws -> [String: SigningEntitlementValue] {
        guard let grants = (try? developmentProfileContent(profile))?["Entitlements"] as? [String: Any],
              grants["get-task-allow"] as? Bool == true else {
            throw AppleDomainFailure.profileInvalid
        }
        let applicationIdentifier = "\(team).\(bundle)"
        var result: [String: SigningEntitlementValue] = [
            "application-identifier": .string(applicationIdentifier),
            "com.apple.developer.team-identifier": .string(team),
            "get-task-allow": .bool(true),
        ]
        if grants["keychain-access-groups"] != nil {
            result["keychain-access-groups"] = .array([.string(applicationIdentifier)])
        }
        return result
    }
}
