import Foundation

public protocol DeveloperSupportBuildProviding: Sendable {
    var descriptor: DeveloperSupportProviderDescriptor { get }
    func artifact(productVersion: String, buildVersion: String) async throws -> DeveloperSupportArtifact?
}

extension ExistingAppleCacheProvider: DeveloperSupportBuildProviding {
    public func artifact(productVersion: String, buildVersion: String) async throws -> DeveloperSupportArtifact? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var matches: [DeveloperSupportArtifact] = []
        for root in roots {
            let buildRoot = root.appendingPathComponent(buildVersion, isDirectory: true)
            let identities = (try? FileManager.default.contentsOfDirectory(
                at: buildRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for identityRoot in identities {
                let metadata = identityRoot.appendingPathComponent("iossim-developer-support.json")
                guard let data = try? Data(contentsOf: metadata), data.count <= 1_048_576,
                      let artifact = try? decoder.decode(DeveloperSupportArtifact.self, from: data),
                      artifact.productVersion == productVersion,
                      artifact.buildVersion == buildVersion,
                      !artifact.buildIdentity.isEmpty else { continue }
                try DeveloperSupportIntegrity.validateFiles(artifact, expectedBuildVersion: buildVersion)
                matches.append(artifact)
            }
        }
        let unique = Dictionary(grouping: matches, by: { "\($0.imageSHA256):\($0.buildManifestSHA256)" })
            .compactMap(\.value.first)
        guard unique.count <= 1 else { throw DeveloperSupportFailure.wrongBuildIdentity }
        return unique.first
    }
}

public protocol DeveloperServicesPreparing: Sendable {
    func prepare(
        device: IOSSimDeviceIdentity,
        context: DeveloperServicesProofContext,
        progress: @escaping @Sendable (ConsumerProvisioningStage) async -> Void
    ) async throws -> DeveloperServicesReadinessReceipt
}

public struct DeveloperServicesProofContext: Codable, Equatable, Sendable {
    public let releaseIdentity: String
    public let pairingGeneration: UInt64?
    public let targetBundleIdentifier: String

    public init(releaseIdentity: String, pairingGeneration: UInt64?, targetBundleIdentifier: String) {
        self.releaseIdentity = releaseIdentity
        self.pairingGeneration = pairingGeneration
        self.targetBundleIdentifier = targetBundleIdentifier
    }
}

/// One setup-side owner for DDI, CoreDeviceProxy, software tunnel, RSD,
/// RemoteXPC and AppService readiness. Live sockets remain session-scoped in
/// the Rust call; only the safe receipt is returned to Swift.
public actor NativeDeveloperServicesCoordinator: DeveloperServicesPreparing {
    private let transport: DynamicNativeDeviceTransport
    private let providers: [any DeveloperSupportBuildProviding]
    private let providerPolicy: DeveloperSupportProviderPolicy

    public init(
        transport: DynamicNativeDeviceTransport = DynamicNativeDeviceTransport(),
        providers: [any DeveloperSupportBuildProviding] = [ExistingAppleCacheProvider()],
        providerPolicy: DeveloperSupportProviderPolicy = .publicProduction
    ) {
        self.transport = transport
        self.providers = providers
        self.providerPolicy = providerPolicy
    }

    public func prepare(
        device: IOSSimDeviceIdentity,
        context: DeveloperServicesProofContext,
        progress: @escaping @Sendable (ConsumerProvisioningStage) async -> Void = { _ in }
    ) async throws -> DeveloperServicesReadinessReceipt {
        guard !context.releaseIdentity.isEmpty,
              NativeApplicationPathPolicy.isValidBundleIdentifier(context.targetBundleIdentifier) else {
            throw NativeDeviceBridgeError.invalidIdentity
        }
        let inspection = try await transport.inspect(device, timeout: .seconds(12))
        // AMFI's status action is advisory on newer iOS builds: iOS 26.6.2 can
        // report `disabled` after the user has enabled Developer Mode while the
        // complete CoreDevice/RSD/AppService readiness probe succeeds. Use the
        // typed live readiness result as the authority. A genuine Developer
        // Mode gate is still returned by that probe as `.developerModeRequired`.
        _ = inspection.developerMode
        do {
            let receipt = try transport.developerServicesReadiness(on: inspection.identity)
            guard receipt.transportReady else {
                throw NativeDeviceBridgeError.developerServicesNotReady(
                    "developer_services: incomplete readiness receipt"
                )
            }
            return try operationalReceipt(
                transportReceipt: receipt,
                inspection: inspection,
                context: context,
                developerSupportIdentity: developerSupportIdentity(inspection: inspection, artifact: nil)
            )
        } catch NativeDeviceBridgeError.ddiRequired {
            await progress(.ddiRequired)
            guard let productVersion = inspection.osVersion,
                  let buildVersion = inspection.osBuild,
                  !productVersion.isEmpty, !buildVersion.isEmpty else {
                throw DeveloperSupportFailure.wrongBuildIdentity
            }
            var selected: DeveloperSupportArtifact?
            await progress(.ddiAcquisitionStarted)
            for provider in providers where providerPolicy.permits(provider.descriptor) {
                try providerPolicy.validate(provider.descriptor)
                if let artifact = try await provider.artifact(
                    productVersion: productVersion,
                    buildVersion: buildVersion
                ) {
                    guard providerPolicy.permits(artifact.provenance.provider) else { continue }
                    try providerPolicy.validate(artifact.provenance.provider)
                    selected = artifact
                    break
                }
            }
            guard let selected else { throw DeveloperSupportFailure.noApprovedSource }
            try DeveloperSupportIntegrity.validateFiles(selected, expectedBuildVersion: buildVersion)
            await progress(.ddiAcquisitionSucceeded)
            await progress(.ddiPersonalizationStarted)
            await progress(.ddiMountStarted)
            do {
                try transport.mountDeveloperSupport(on: inspection.identity, artifact: selected)
            } catch NativeDeviceBridgeError.protocolFailure(let detail)
                where detail.localizedCaseInsensitiveContains("http")
                    || detail.localizedCaseInsensitiveContains("tss") {
                throw DeveloperSupportFailure.tssUnavailable
            } catch {
                throw DeveloperSupportFailure.mountRejected
            }
            await progress(.ddiPersonalizationSucceeded)
            await progress(.ddiMountSucceeded)
            let receipt = try transport.developerServicesReadiness(on: inspection.identity)
            guard receipt.transportReady else { throw DeveloperSupportFailure.serviceMapUnavailable }
            return try operationalReceipt(
                transportReceipt: receipt,
                inspection: inspection,
                context: context,
                developerSupportIdentity: developerSupportIdentity(inspection: inspection, artifact: selected)
            )
        }
    }

    private func operationalReceipt(
        transportReceipt: DeveloperServicesReadinessReceipt,
        inspection: NativeDeviceInspection,
        context: DeveloperServicesProofContext,
        developerSupportIdentity: String
    ) throws -> DeveloperServicesReadinessReceipt {
        let launch = try transport.launchApplication(
            on: inspection.identity,
            bundleIdentifier: context.targetBundleIdentifier,
            timeout: .seconds(60)
        )
        guard launch.bundleIdentifier == context.targetBundleIdentifier,
              launch.appServiceConnected, launch.pid > 0 else {
            throw NativeDeviceBridgeError.launchRejected("appservice: launch receipt did not identify the requested application")
        }
        return DeveloperServicesReadinessReceipt(
            coreDeviceProxyReady: transportReceipt.coreDeviceProxyReady,
            softwareTunnelReady: transportReceipt.softwareTunnelReady,
            rsdReady: transportReceipt.rsdReady,
            remoteXPCReady: transportReceipt.remoteXPCReady,
            appServiceReady: transportReceipt.appServiceReady,
            launchFeatureReady: transportReceipt.launchFeatureReady,
            ddiMounted: transportReceipt.ddiMounted,
            schemaVersion: DeveloperServicesReadinessReceipt.currentSchemaVersion,
            deviceUDIDHash: DeveloperServicesReadinessReceipt.hash(inspection.identity.udid),
            usbmuxIdentifier: inspection.identity.usbmuxIdentifier,
            connection: inspection.identity.connection,
            connectionGeneration: inspection.identity.connectionGeneration,
            developerSupportIdentity: developerSupportIdentity,
            pairingGeneration: context.pairingGeneration,
            releaseIdentity: context.releaseIdentity,
            sessionIdentifier: UUID().uuidString,
            targetBundleIdentifier: context.targetBundleIdentifier,
            launchReceipt: launch,
            observedAt: Date()
        )
    }

    private func developerSupportIdentity(
        inspection: NativeDeviceInspection,
        artifact: DeveloperSupportArtifact?
    ) -> String {
        let build = inspection.osBuild ?? "unknown-build"
        if let artifact {
            return "\(build):\(artifact.buildIdentity):\(artifact.imageSHA256)"
        }
        return "\(build):active-device-service-map"
    }
}
