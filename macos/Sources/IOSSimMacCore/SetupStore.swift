import Foundation

@MainActor
public final class SetupStore: ObservableObject {
    @Published public private(set) var phase: SetupPhase = .welcome
    @Published public private(set) var status: DoctorStatus?
    @Published public private(set) var isRunning = false
    @Published public private(set) var isCriticalStage = false
    @Published public private(set) var completedInstallStages: Set<InstallStage> = []
    @Published public private(set) var lastError: SetupError?
    @Published public private(set) var logs: [EngineLogEntry] = []
    @Published public private(set) var selectedDeviceIdentifier: String?
    @Published public private(set) var deviceSelectionReason: DeviceSelectionReason = .noConnectedDevices
    @Published public private(set) var personalTeams: [PersonalTeamCandidate] = []
    @Published public private(set) var selectedTeamIdentifier: String?
    @Published public private(set) var provisioningManifest: ConsumerProvisioningManifest?
    @Published public private(set) var consumerStage: ConsumerProvisioningStage = .idle
    @Published public private(set) var lastSupportBundleURL: URL?
    @Published public private(set) var appleAuthorization = AppleAuthorizationSummary(
        method: .privateGrandSlamSRP,
        stage: .notStarted,
        sessionValid: false
    )
    @Published public private(set) var appleVerificationChallenge: AppleVerificationChallenge?
    @Published public private(set) var liveProvisioningCheckpoint: ApplePersonalTeamCheckpoint?

    public let engine: any IOSSimSetupEngine
    private let authorizationCoordinator: ExperimentalConsumerProvisioningCoordinator
    private let stateDiagnostics: ApplePersonalTeamDiagnosticsStore
    private let nativeArtifactStore: NativeProvisioningArtifactStore
    private let stateDiagnosticsEnabled: Bool
    public let nativeProvisioningExperiment: Bool
    private var task: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var activeOperationGeneration: UInt64?
    private let onboardingKey = "IOSSimMac.onboardingCompleted"
    private let selectedDeviceKey = "IOSSimMac.selectedDeviceIdentifier"
    private let selectedDeviceNameKey = "IOSSimMac.selectedDeviceName"
    private let selectedTeamKey = "IOSSimMac.selectedPersonalTeam"
    private let automaticRefreshKey = "IOSSimMac.automaticRefreshEnabled"
    private var automaticRefreshAttempted = false

    public init(
        engine: any IOSSimSetupEngine,
        authorizationCoordinator: ExperimentalConsumerProvisioningCoordinator? = nil,
        nativeProvisioningExperiment: Bool = ZeroXcodeCapabilityPolicy.livePersonalTeamExperimentEnabled,
        stateDiagnostics: ApplePersonalTeamDiagnosticsStore? = nil,
        nativeArtifactStore: NativeProvisioningArtifactStore = NativeProvisioningArtifactStore()
    ) {
        let diagnostics = stateDiagnostics ?? ApplePersonalTeamDiagnosticsStore()
        self.engine = engine
        self.nativeProvisioningExperiment = nativeProvisioningExperiment
        self.stateDiagnostics = diagnostics
        self.nativeArtifactStore = nativeArtifactStore
        stateDiagnosticsEnabled = nativeProvisioningExperiment || stateDiagnostics != nil
        self.authorizationCoordinator = authorizationCoordinator ?? .init(
            backend: nativeProvisioningExperiment
                ? LiveApplePersonalTeamBackend(diagnostics: diagnostics)
                : UnavailableExperimentalPersonalTeamBackend()
        )
        selectedDeviceIdentifier = UserDefaults.standard.string(forKey: selectedDeviceKey)
        selectedTeamIdentifier = UserDefaults.standard.string(forKey: selectedTeamKey)
    }

    public var onboardingCompleted: Bool {
        UserDefaults.standard.bool(forKey: onboardingKey)
    }

    public var selectedDevice: DetectedDevice? {
        guard let selectedDeviceIdentifier else { return nil }
        return status?.device.devices.first { $0.selectionIdentifier == selectedDeviceIdentifier }
    }

    public var selectedDeviceProvisioningReady: Bool {
        selectedDevice.map {
            $0.pairingState == "paired" && $0.developerModeStatus == "enabled" && $0.isLocked != true
        } ?? false
    }

    public var deviceSelectionRequired: Bool {
        guard let status else { return false }
        if status.device.devices.count > 1, selectedDeviceIdentifier == nil {
            return true
        }
        return DeviceSelectionPolicy.resolve(
            devices: status.device.devices,
            rememberedIdentifier: UserDefaults.standard.string(forKey: selectedDeviceKey),
            rememberedName: UserDefaults.standard.string(forKey: selectedDeviceNameKey)
        ).selectionRequired
    }

    public var disconnectedDeviceName: String? {
        guard case .rememberedDeviceDisconnected = deviceSelectionReason else { return nil }
        return UserDefaults.standard.string(forKey: selectedDeviceNameKey)
    }

    public var selectedTeam: PersonalTeamCandidate? {
        guard let selectedTeamIdentifier else { return nil }
        return personalTeams.first { $0.teamIdentifier == selectedTeamIdentifier }
    }

    public var refreshDueState: RefreshDueState {
        ConsumerRefreshPolicy.recommended.dueState(expiration: provisioningManifest?.earliestExpiration)
    }

    public var automaticRefreshEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: automaticRefreshKey) == nil
                || UserDefaults.standard.bool(forKey: automaticRefreshKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: automaticRefreshKey) }
    }

    public func bootstrap() {
        guard task == nil else { return }
        if onboardingCompleted {
            phase = .checkingMac
            refresh()
            Task { [weak self] in
                guard let self else { return }
                while self.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                self.runAutomaticRefreshIfDue()
            }
        }
    }

    public func getStarted() {
        guard !isRunning else { return }
        phase = .checkingMac
        refresh()
    }

    public func refresh() {
        runCancellable(stage: .checkingMac) { [self] generation in
            let next = try await engine.doctor()
            try requireCurrentOperation(generation)
            status = next
            applyDeviceSelection(from: next)
            try await updateConsumerContext(generation: generation)
            try requireCurrentOperation(generation)
            routeAfterDoctor(next)
        }
    }

    public func continueFromCurrentStatus() {
        guard let status, !isRunning else { return }
        if !status.mac.ready {
            runSetup()
            return
        }
        if selectedDeviceProvisioningReady {
            runProvisioning()
            return
        }
        phase = .checkingDevice
        refresh()
    }

    public func runRepair() {
        guard !isRunning else { return }
        phase = .checkingMac
        runCancellable(stage: .checkingMac) { [self] generation in
            let next = try await engine.doctor()
            try requireCurrentOperation(generation)
            status = next
            if !next.mac.ready {
                let result = try await engine.setup()
                try requireCurrentOperation(generation)
                logs.append(.init(stage: "setup", result: result))
            }
            applyDeviceSelection(from: next)
            try await updateConsumerContext(generation: generation)
            try requireCurrentOperation(generation)
            if selectedDeviceProvisioningReady {
                try await runProvisioningBody(operation: .repair, generation: generation)
            } else {
                routeAfterDoctor(next)
            }
        }
    }

    public func runUpdateComponents() {
        guard !isRunning else { return }
        phase = .installing
        completedInstallStages = [.prepare]
        runCritical { [self] generation in
            if engine.consumerProvisioningEnabled {
                try await runProvisioningBody(operation: .refresh, generation: generation)
                return
            }
            let buildResult = try await engine.build()
            try requireCurrentOperation(generation)
            logs.append(.init(stage: "build", result: buildResult))
            completedInstallStages.insert(.installIOSSim)
            completedInstallStages.insert(.installRuntime)
            let deviceResult = try await engine.provisionDevice(selectedDeviceIdentifier: try selectedDeviceIdentifierForOperation())
            try requireCurrentOperation(generation)
            logs.append(.init(stage: "device", result: deviceResult))
            completedInstallStages.insert(.verify)
            phase = .verifying
            let next = try await engine.doctor()
            try requireCurrentOperation(generation)
            status = next
            routeAfterDoctor(next)
        }
    }

    public func runConfirmedFreshInstall() {
        guard !isRunning else { return }
        phase = .installing
        completedInstallStages = [.prepare]
        runCritical { [self] generation in
            try await runProvisioningBody(operation: .install, allowFreshInstall: true, generation: generation)
        }
    }

    public func exportSupportBundle() {
        guard !isRunning else { return }
        runCancellable(stage: phase) { [self] generation in
            let url = try await engine.exportSupportBundle()
            try requireCurrentOperation(generation)
            lastSupportBundleURL = url
        }
    }

    public func setAutomaticRefreshEnabled(_ enabled: Bool) {
        automaticRefreshEnabled = enabled
    }

    private func runAutomaticRefreshIfDue() {
        guard !automaticRefreshAttempted,
              automaticRefreshEnabled,
              [.dueNow, .expired].contains(refreshDueState),
              selectedDevice != nil,
              selectedTeam != nil else { return }
        automaticRefreshAttempted = true
        runUpdateComponents()
    }

    public func cancelCurrentOperation() {
        guard !isCriticalStage else { return }
        activeOperationGeneration = nil
        task?.cancel()
        task = nil
        isRunning = false
    }

    public func showDashboard() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        phase = .complete
    }

    public func confirmRuntimeSetup() {
        guard !isRunning else { return }
        runCancellable(stage: .verifying) { [self] generation in
            if engine.consumerProvisioningEnabled {
                guard consumerProvisioningStateSupportsRuntimeSetup else {
                    throw ConsumerProvisioningFailure(
                        code: .runnerMappingMissing,
                        stage: .verifyingRuntimeReadiness,
                        userMessage: "IOSSim installation information is missing.",
                        remediation: "Complete IOSSim installation before finishing iPhone setup.",
                        developerDetail: "Runtime setup requires a valid provisioning manifest and deterministic runner mapping."
                    )
                }
                let manifest = try await engine.confirmRuntimeSetup()
                try requireCurrentOperation(generation)
                provisioningManifest = manifest
            }
            UserDefaults.standard.set(true, forKey: onboardingKey)
            let next = try await engine.doctor()
            try requireCurrentOperation(generation)
            status = next
            phase = .complete
        }
    }

    public func selectDevice(identifier: String) {
        guard let status,
              let device = status.device.devices.first(where: { $0.selectionIdentifier == identifier }) else {
            selectedDeviceIdentifier = nil
            return
        }
        selectedDeviceIdentifier = device.selectionIdentifier
        deviceSelectionReason = .rememberedDeviceConnected
        UserDefaults.standard.set(device.selectionIdentifier, forKey: selectedDeviceKey)
        UserDefaults.standard.set(device.name, forKey: selectedDeviceNameKey)
    }

    public func selectTeam(identifier: String) {
        guard personalTeams.contains(where: { $0.teamIdentifier == identifier }) else {
            selectedTeamIdentifier = nil
            return
        }
        selectedTeamIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: selectedTeamKey)
    }

    /// Accepts the SwiftUI `String` only at this boundary. The view clears its
    /// bindings immediately; this method converts the password to wipeable
    /// bytes before starting asynchronous work and never stores it in state.
    public func beginAppleAuthorization(account: String, password: String) {
        guard !isRunning, !account.isEmpty, !password.isEmpty else { return }
        let sensitivePassword = SensitiveInput(password)
        runCancellable(stage: .appleAccount) { [self] generation in
            let challenge = try await authorizationCoordinator.begin(
                account: account,
                password: sensitivePassword
            )
            try requireCurrentOperation(generation)
            let authorization = await authorizationCoordinator.authorization
            try requireCurrentOperation(generation)
            recordStateTransition(
                .authorizationResultReceived,
                generation: generation,
                authorization: authorization
            )
            appleVerificationChallenge = challenge
            appleAuthorization = authorization
            recordStateTransition(.authorizationStateUpdated, generation: generation)
            if challenge == nil {
                try await applyExperimentalTeams(generation: generation)
            } else {
                recordStateTransition(.uiStatePublished, generation: generation)
            }
        }
    }

    public func submitAppleVerification(code: String) {
        guard !isRunning, !code.isEmpty else { return }
        let sensitiveCode = SensitiveInput(code)
        runCancellable(stage: .appleAccount) { [self] generation in
            let challenge = try await authorizationCoordinator.verify(code: sensitiveCode)
            try requireCurrentOperation(generation)
            let authorization = await authorizationCoordinator.authorization
            try requireCurrentOperation(generation)
            recordStateTransition(
                .authorizationResultReceived,
                generation: generation,
                authorization: authorization
            )
            appleVerificationChallenge = challenge
            appleAuthorization = authorization
            recordStateTransition(.authorizationStateUpdated, generation: generation)
            if challenge == nil {
                try await applyExperimentalTeams(generation: generation)
            } else {
                recordStateTransition(.uiStatePublished, generation: generation)
            }
        }
    }

    private func applyExperimentalTeams(generation: UInt64) async throws {
        let discovered = await authorizationCoordinator.teams
        try requireCurrentOperation(generation)
        guard !discovered.isEmpty else { throw ExperimentalBackendError.noTeam }
        personalTeams = discovered.map {
            PersonalTeamCandidate(
                teamIdentifier: $0.id,
                teamDisplayName: $0.name,
                signingIdentityCommonName: "IOSSim managed",
                signingIdentityFingerprint: "pending",
                certificateSubjectTeamIdentifier: $0.id,
                personalTeam: $0.isPersonalTeam
            )
        }
        recordStateTransition(.teamStateUpdated, generation: generation)
        if let preferred = try? ExperimentalConsumerProvisioningCoordinator.preferredTeam(from: discovered) {
            selectTeam(identifier: preferred.id)
        }
        phase = .installing
        recordStateTransition(.setupStepAdvanced, generation: generation)
        recordStateTransition(.uiStatePublished, generation: generation)
        if nativeProvisioningExperiment {
            try await runLiveProvisioningThroughProfiles(generation: generation)
        }
    }

    private func runLiveProvisioningThroughProfiles(generation: UInt64) async throws {
        guard let selected = selectedDevice,
              let identifier = selectedDeviceIdentifier else {
            throw ExperimentalBackendError.deviceRegistrationFailed
        }
        let physicalUDID: String
        if let alreadyPhysical = try? validatedDeviceRegistrationIdentifier(
            identifier,
            source: .physicalUDID
        ) {
            physicalUDID = alreadyPhysical
        } else if let resolved = await AppleDeviceTool.signingDeviceIdentifier(
            matching: identifier,
            context: RuntimeProvisioningContext(resourcesURL: FileManager.default.temporaryDirectory)
        ) {
            physicalUDID = resolved
        } else {
            throw ExperimentalBackendError.invalidDeviceIdentifier
        }
        consumerStage = .preparingIdentities
        let availableTeams = await authorizationCoordinator.teams
        try requireCurrentOperation(generation)
        if let preferred = try? ExperimentalConsumerProvisioningCoordinator.preferredTeam(from: availableTeams),
           (try? await nativeArtifactStore.load(
               teamIdentifier: preferred.id,
               selectedDeviceIdentifier: physicalUDID
           )) != nil {
            try requireCurrentOperation(generation)
            selectedTeamIdentifier = preferred.id
            liveProvisioningCheckpoint = .provisioningReady
            consumerStage = .preparingArtifacts
            phase = .complete
            recordStateTransition(.setupStepAdvanced, generation: generation)
            recordStateTransition(.uiStatePublished, generation: generation)
            return
        }
        let prepared = try await authorizationCoordinator.prepareProvisioning(.init(
            selectedDeviceIdentifier: identifier,
            selectedDeviceRegistrationIdentifier: physicalUDID,
            deviceIdentifierSource: .physicalUDID,
            selectedDeviceName: selected.name,
            operation: .install
        ))
        try requireCurrentOperation(generation)
        try await nativeArtifactStore.save(
            prepared,
            selectedDeviceIdentifier: physicalUDID
        )
        try requireCurrentOperation(generation)
        selectedTeamIdentifier = prepared.team.id
        liveProvisioningCheckpoint = .provisioningReady
        consumerStage = .preparingArtifacts
        phase = .complete
        recordStateTransition(.setupStepAdvanced, generation: generation)
        recordStateTransition(.uiStatePublished, generation: generation)
    }

    private func runSetup() {
        phase = .checkingMac
        runCritical { [self] generation in
            let result = try await engine.setup()
            try requireCurrentOperation(generation)
            logs.append(.init(stage: "setup", result: result))
            let next = try await engine.doctor()
            try requireCurrentOperation(generation)
            status = next
            routeAfterDoctor(next)
        }
    }

    private func runProvisioning() {
        phase = .installing
        completedInstallStages = [.prepare]
        runCritical { [self] generation in
            try await runProvisioningBody(operation: .install, generation: generation)
        }
    }

    private func runProvisioningBody(
        operation: ConsumerProvisioningOperation,
        allowFreshInstall: Bool = false,
        generation: UInt64
    ) async throws {
        if engine.consumerProvisioningEnabled {
            let device = try selectedDeviceIdentifierForOperation()
            guard let team = selectedTeamIdentifier else {
                throw ConsumerProvisioningFailure(
                    code: .teamSelectionRequired,
                    stage: .waitingForTeamSelection,
                    userMessage: "IOSSim couldn't prepare Apple authorization.",
                    remediation: "Continue Apple authorization in IOSSim, then try again.",
                    developerDetail: "No Personal Team selected."
                )
            }
            consumerStage = .preparingIdentities
            let result = try await engine.consumerProvision(ConsumerProvisioningRequest(
                operation: operation,
                selectedDeviceIdentifier: device,
                selectedTeamIdentifier: team,
                allowFreshInstallAfterCrossTeamConflict: allowFreshInstall,
                backend: nativeProvisioningExperiment ? .nativePersonalTeam : .xcodeFallback
            ))
            try requireCurrentOperation(generation)
            provisioningManifest = result.manifest
            consumerStage = result.finalStage
            completedInstallStages = Set(InstallStage.allCases)
            phase = .runtimeSetup
            return
        }
        completedInstallStages.insert(.installIOSSim)
        let result = try await engine.provisionDevice(selectedDeviceIdentifier: try selectedDeviceIdentifierForOperation())
        try requireCurrentOperation(generation)
        logs.append(.init(stage: "device", result: result))
        completedInstallStages.insert(.installRuntime)
        phase = .verifying
        let next = try await engine.doctor()
        try requireCurrentOperation(generation)
        status = next
        completedInstallStages.insert(.verify)
        routeAfterDoctor(next)
    }

    private func routeAfterDoctor(_ status: DoctorStatus) {
        if nativeProvisioningExperiment,
           status.mac.ready,
           selectedDevice != nil,
           liveProvisioningCheckpoint != .provisioningReady {
            phase = .appleAccount
            return
        }
        let installationKnown = !engine.consumerProvisioningEnabled || consumerProvisioningStateSupportsRuntimeSetup
        let consumerRuntimeReady = !engine.consumerProvisioningEnabled
            || (consumerProvisioningStateSupportsRuntimeSetup && provisioningManifest?.runtimeSetupStatus == .ready)
        if (status.mac.ready && selectedDeviceProvisioningReady && status.runtimeActionChecks.isEmpty && installationKnown)
            || (onboardingCompleted && consumerRuntimeReady) {
            phase = .complete
            return
        }
        if !status.mac.ready {
            phase = .macActionRequired
            return
        }
        if engine.consumerProvisioningEnabled,
           selectedDeviceProvisioningReady,
           !consumerProvisioningStateSupportsRuntimeSetup {
            routeToConsumerProvisioning()
            return
        }
        switch StatusInterpreter.deviceReadiness(from: status) {
        case .noDevice, .multipleDevices:
            phase = .waitingForDevice
        case .trustRequired, .developerModeRequired, .unlockRequired:
            phase = .deviceActionRequired
        case .readyForInstall:
            routeToConsumerProvisioning()
        case .localDevVPNRequired, .pairingRequired:
            phase = .runtimeSetup
        case .complete:
            phase = .complete
            UserDefaults.standard.set(true, forKey: onboardingKey)
        }
    }

    private var consumerProvisioningStateSupportsRuntimeSetup: Bool {
        guard let manifest = provisioningManifest,
              manifest.schemaVersion == ConsumerProvisioningManifest.currentSchemaVersion,
              !manifest.teamID.isEmpty,
              let expected = try? PersonalTeamBundleIdentifierSet(teamIdentifier: manifest.teamID) else {
            return false
        }
        let source = ProtectedSourceBundleIdentifiers.default
        return manifest.sourceMainBundleID == source.main
            && manifest.installedMainBundleID == expected.main
            && manifest.sourceUITestBundleID == source.uiTests
            && manifest.installedUITestBundleID == expected.uiTests
            && manifest.sourceRunnerBundleID == source.runner
            && manifest.installedRunnerBundleID == expected.runner
            && manifest.mainProfile.teamIdentifier == manifest.teamID
            && manifest.mainProfile.bundleIdentifier == expected.main
            && manifest.runnerProfile.teamIdentifier == manifest.teamID
            && manifest.runnerProfile.bundleIdentifier == expected.runner
    }

    private func routeToConsumerProvisioning() {
        if engine.consumerProvisioningEnabled && (personalTeams.isEmpty || selectedTeam == nil) {
            phase = .appleAccount
        } else {
            phase = .installing
        }
    }

    private func updateConsumerContext(generation: UInt64) async throws {
        guard engine.consumerProvisioningEnabled else { return }
        let manifest = try await engine.consumerProvisioningStatus()
        try requireCurrentOperation(generation)
        provisioningManifest = manifest
        guard let selectedDeviceIdentifier else {
            personalTeams = []
            selectedTeamIdentifier = nil
            return
        }
        if nativeProvisioningExperiment {
            do {
                if try await authorizationCoordinator.resume() {
                    try requireCurrentOperation(generation)
                    appleAuthorization = await authorizationCoordinator.authorization
                    try requireCurrentOperation(generation)
                    recordStateTransition(.authorizationResultReceived, generation: generation)
                    recordStateTransition(.authorizationStateUpdated, generation: generation)
                    try await applyExperimentalTeams(generation: generation)
                }
            } catch ExperimentalBackendError.sessionExpired {
                try requireCurrentOperation(generation)
                appleAuthorization = await authorizationCoordinator.authorization
                try requireCurrentOperation(generation)
                recordStateTransition(
                    .authorizationStateUpdated,
                    generation: generation,
                    safeErrorCode: appleAuthorization.safeErrorCode
                )
            }
            return
        }
        let discovered = try await engine.discoverPersonalTeams(selectedDeviceIdentifier: selectedDeviceIdentifier)
        try requireCurrentOperation(generation)
        personalTeams = discovered
        let remembered = UserDefaults.standard.string(forKey: selectedTeamKey)
        if let remembered, personalTeams.contains(where: { $0.teamIdentifier == remembered }) {
            selectedTeamIdentifier = remembered
        } else if personalTeams.filter(\.personalTeam).count == 1,
                  let personal = personalTeams.first(where: \.personalTeam) {
            selectTeam(identifier: personal.teamIdentifier)
        } else if personalTeams.count == 1 {
            selectTeam(identifier: personalTeams[0].teamIdentifier)
        } else if let manifest = provisioningManifest,
                  personalTeams.contains(where: { $0.teamIdentifier == manifest.teamID }) {
            selectTeam(identifier: manifest.teamID)
        } else {
            selectedTeamIdentifier = nil
        }
    }

    private func applyDeviceSelection(from status: DoctorStatus) {
        let remembered = UserDefaults.standard.string(forKey: selectedDeviceKey)
        let rememberedName = UserDefaults.standard.string(forKey: selectedDeviceNameKey)
        let result = DeviceSelectionPolicy.resolve(
            devices: status.device.devices,
            rememberedIdentifier: remembered,
            rememberedName: rememberedName
        )
        selectedDeviceIdentifier = result.selectedIdentifier
        deviceSelectionReason = result.reason
        if let selectedDevice = status.device.devices.first(where: { $0.selectionIdentifier == result.selectedIdentifier }) {
            UserDefaults.standard.set(selectedDevice.selectionIdentifier, forKey: selectedDeviceKey)
            UserDefaults.standard.set(selectedDevice.name, forKey: selectedDeviceNameKey)
        }
    }

    private func selectedDeviceIdentifierForOperation() throws -> String {
        guard let status else {
            throw selectionFailure("DEVICE_SELECTION_REQUIRED: refresh device status before provisioning.")
        }
        let liveMatches = status.device.devices.filter { $0.selectionIdentifier == selectedDeviceIdentifier }
        guard let selected = liveMatches.first, liveMatches.count == 1 else {
            if status.device.devices.isEmpty {
                let name = UserDefaults.standard.string(forKey: selectedDeviceNameKey) ?? "this iPhone"
                throw selectionFailure("IPHONE_DISCONNECTED: Reconnect \(name) or choose another device.")
            }
            throw selectionFailure("DEVICE_SELECTION_REQUIRED: choose one connected iPhone before provisioning.")
        }
        return selected.selectionIdentifier
    }

    private func selectionFailure(_ message: String) -> ProcessFailure {
        ProcessFailure(
            commandName: "device-selection",
            result: ProcessResult(exitCode: 2, stdout: "", stderr: message)
        )
    }

    private func runCancellable(
        stage: SetupPhase,
        operation: @escaping @MainActor (UInt64) async throws -> Void
    ) {
        run(stage: stage, critical: false, operation: operation)
    }

    private func runCritical(operation: @escaping @MainActor (UInt64) async throws -> Void) {
        run(stage: phase, critical: true, operation: operation)
    }

    private func run(
        stage: SetupPhase,
        critical: Bool,
        operation: @escaping @MainActor (UInt64) async throws -> Void
    ) {
        guard task == nil else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        activeOperationGeneration = generation
        phase = stage
        isRunning = true
        isCriticalStage = critical
        lastError = nil
        recordStateTransition(.errorStateCleared, generation: generation)
        recordStateTransition(.uiStatePublished, generation: generation)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(generation)
            } catch is CancellationError {
                guard self.activeOperationGeneration == generation else {
                    self.recordStateTransition(
                        .staleResultIgnored,
                        generation: generation,
                        currentGeneration: false
                    )
                    return
                }
                self.lastError = nil
            } catch let failure as ProcessFailure {
                guard self.activeOperationGeneration == generation else { return }
                self.lastError = Self.friendlyError(commandName: failure.commandName, result: failure.result)
                self.logs.append(.init(stage: failure.commandName, result: failure.result))
                self.phase = .failed
                self.recordStateTransition(
                    .uiStatePublished,
                    generation: generation,
                    safeErrorCode: "PROCESS_FAILURE"
                )
            } catch let failure as ConsumerProvisioningFailure {
                guard self.activeOperationGeneration == generation else { return }
                self.lastError = SetupError(
                    headline: failure.userMessage,
                    recovery: failure.remediation,
                    details: "\(failure.code.rawValue): \(failure.developerDetail)"
                )
                let waitingForDevice = failure.code == .deviceUnavailable || failure.stage == .waitingForDevice
                self.consumerStage = waitingForDevice ? .waitingForDevice : .failed
                self.phase = waitingForDevice ? .waitingForDevice : .failed
                self.recordStateTransition(
                    .uiStatePublished,
                    generation: generation,
                    safeErrorCode: failure.code.rawValue
                )
            } catch let failure as ExperimentalBackendError {
                guard self.activeOperationGeneration == generation else { return }
                let authorization = await self.authorizationCoordinator.authorization
                guard self.activeOperationGeneration == generation else { return }
                self.appleAuthorization = authorization
                self.recordStateTransition(
                    .authorizationStateUpdated,
                    generation: generation,
                    safeErrorCode: authorization.safeErrorCode
                )
                if authorization.sessionValid,
                   !self.personalTeams.isEmpty,
                   failure != .sessionExpired {
                    self.lastError = Self.experimentalProvisioningError(failure)
                    self.consumerStage = .failed
                    self.phase = .failed
                } else {
                    self.lastError = Self.appleAuthorizationError(failure)
                    self.phase = failure == .verificationExpired ? .appleAccount : .failed
                }
                self.recordStateTransition(
                    .uiStatePublished,
                    generation: generation,
                    safeErrorCode: failure.safeCode
                )
            } catch {
                guard self.activeOperationGeneration == generation else { return }
                self.lastError = SetupError(
                    headline: "IOSSim could not complete this step.",
                    recovery: "Check your setup and try again.",
                    details: Redactor.redact(String(describing: error))
                )
                self.phase = .failed
                self.recordStateTransition(
                    .uiStatePublished,
                    generation: generation,
                    safeErrorCode: "UNEXPECTED_ERROR"
                )
            }
            guard self.activeOperationGeneration == generation else { return }
            self.isRunning = false
            self.isCriticalStage = false
            self.task = nil
            self.activeOperationGeneration = nil
        }
    }

    private func requireCurrentOperation(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard activeOperationGeneration == generation else { throw CancellationError() }
    }

    private func recordStateTransition(
        _ transition: SetupStateTransition,
        generation: UInt64,
        authorization: AppleAuthorizationSummary? = nil,
        safeErrorCode: String? = nil,
        currentGeneration: Bool? = nil
    ) {
        guard stateDiagnosticsEnabled else { return }
        let authorization = authorization ?? appleAuthorization
        stateDiagnostics.recordSetupTransition(
            transition,
            adapterVersion: authorization.clientIdentityVersion ?? "setup-state-v1",
            generationID: generation,
            setupPhase: phase,
            authorizationStage: authorization.stage,
            sessionValid: authorization.sessionValid,
            personalTeamAvailable: !personalTeams.isEmpty,
            errorPresent: lastError != nil,
            currentGeneration: currentGeneration ?? (activeOperationGeneration == generation),
            safeErrorCode: safeErrorCode
        )
    }

    private static func appleAuthorizationError(_ failure: ExperimentalBackendError) -> SetupError {
        switch failure {
        case .badPassword:
            return SetupError(
                headline: "Apple couldn't verify that account.",
                recovery: "Check your Apple Account and password, then try again.",
                details: failure.safeCode
            )
        case .verificationExpired:
            return SetupError(
                headline: "That Apple verification code expired.",
                recovery: "Request or enter a new verification code.",
                details: failure.safeCode
            )
        case .sessionExpired:
            return SetupError(
                headline: "Apple authorization needs to be refreshed.",
                recovery: "Continue with Apple to authorize IOSSim again.",
                details: failure.safeCode
            )
        default:
            return SetupError(
                headline: "IOSSim couldn't prepare Apple authorization.",
                recovery: "Try again. IOSSim will not change your other development certificates or apps.",
                details: failure.safeCode
            )
        }
    }

    private static func experimentalProvisioningError(_ failure: ExperimentalBackendError) -> SetupError {
        let recovery: String
        switch failure {
        case .certificateLimit:
            recovery = "Remove an unused Apple Development certificate from your Personal Team, then try again."
        case .missingPrivateKey:
            recovery = "Restore the IOSSim signing key on this Mac or reset only IOSSim's managed signing identity."
        case .deviceLimit:
            recovery = "Remove an unused registered device from your Personal Team, then try again."
        case .appIDLimit:
            recovery = "Remove an unused App ID from your Personal Team, then try again."
        case .appIDCollision:
            recovery = "Resolve the conflicting Personal Team App ID, then try again."
        default:
            recovery = "Keep the iPhone connected and unlocked, then try Personal Team provisioning again."
        }
        return SetupError(
            headline: "Apple authorization succeeded, but IOSSim couldn't prepare Personal Team provisioning.",
            recovery: recovery,
            details: failure.safeCode
        )
    }

    private static func friendlyError(commandName: String, result: ProcessResult) -> SetupError {
        let lower = result.combinedOutput.lowercased()
        if lower.contains("locked") {
            return SetupError(
                headline: "IOSSim could not install on this iPhone.",
                recovery: "Unlock your iPhone and try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("iphone_disconnected") || lower.contains("iphone disconnected") {
            return SetupError(
                headline: "iPhone Disconnected",
                recovery: "Reconnect the selected iPhone or choose another device.",
                details: result.combinedOutput
            )
        }
        if lower.contains("device_selection_required") {
            return SetupError(
                headline: "Choose an iPhone",
                recovery: "Select the connected iPhone you want IOSSim to set up, then try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("device_not_in_profile") || lower.contains("artifact_eligibility") {
            return SetupError(
                headline: "This iPhone is not authorized for this IOSSim build.",
                recovery: "Use an iPhone included in the bundled provisioning profile or create a new signed build for this device.",
                details: result.combinedOutput
            )
        }
        if lower.contains("developer mode") {
            return SetupError(
                headline: "Developer Mode is required.",
                recovery: "Enable Developer Mode on your iPhone, then try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("development team") || lower.contains("signing") {
            return SetupError(
                headline: "IOSSim couldn't prepare Apple authorization.",
                recovery: "Continue Apple authorization in IOSSim, then try again.",
                details: result.combinedOutput
            )
        }
        if lower.contains("bundled runtime damaged") || lower.contains("bundled artifact") || lower.contains("artifact manifest") {
            return SetupError(
                headline: "Bundled runtime damaged.",
                recovery: "Required IOSSim components are missing from this application. Reinstall IOSSim.",
                details: result.combinedOutput
            )
        }
        if lower.contains("apple development support required") || lower.contains("devicectl") || lower.contains("xcrun") {
            return SetupError(
                headline: "Apple development support required.",
                recovery: "Install or select Apple's developer tools required for iPhone discovery and app installation.",
                details: result.combinedOutput
            )
        }
        if lower.contains("permission denied") || result.exitCode == 126 {
            return SetupError(
                headline: "IOSSim could not start its setup helper.",
                recovery: "The development helper could not be launched. Open Diagnostics for the executable and repository checks.",
                details: result.combinedOutput.isEmpty ? "Exit code \(result.exitCode)" : result.combinedOutput
            )
        }
        return SetupError(
            headline: "IOSSim could not complete \(commandName).",
            recovery: "Try again after addressing the details below.",
            details: result.combinedOutput.isEmpty ? "Exit code \(result.exitCode)" : result.combinedOutput
        )
    }
}
