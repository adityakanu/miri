@preconcurrency import AVFoundation
import MiriCore
import MiriIPC
import SwiftUI

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let didFinish: @Sendable () -> Void
    init(didFinish: @escaping @Sendable () -> Void) { self.didFinish = didFinish }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { didFinish() }
}

private final class RecordingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func reset() { lock.withLock { data.removeAll(keepingCapacity: true) } }
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func take() -> Data { lock.withLock { let result = data; data.removeAll(keepingCapacity: true); return result } }
}

private final class AudioChunkPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?

    func open() -> AsyncStream<Data> {
        let stream = AsyncStream<Data> { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
        return stream
    }

    func yield(_ data: Data) { _ = lock.withLock { continuation?.yield(data) } }
    func finish() {
        let current = lock.withLock { let value = continuation; continuation = nil; return value }
        current?.finish()
    }
}

@MainActor final class AppController: NSObject, ObservableObject {
    @Published var state: InteractionState = .idle
    @Published var lastStatus = "Miri is ready"
    @Published var targets: [TargetDefinition] = []
    @Published var activeTargetID: String?
    @Published var microphonePermission = MicrophonePermissions.current
    @Published var inputMode: MiriInputMode = .pushToTalk
    @Published var audioDiagnostics: String?
    @Published var targetStatuses: [String: TargetStatus] = [:]
    @Published var lastAgentResponse: String?
    @Published var lastAgentName: String?
    @Published var codexThreads: [CodexThreadSummary] = []
    @Published var isRefreshingCodexThreads = false
    @Published var activeHotkey = "option+space"
    @Published var agentSpeechMuted = false
    @Published var outboxEntries: [OutboxEntry] = []
    @Published var speechHealth = "Speech models starting"
    @Published var pendingAgentPrompt: String?
    /// Agents muted individually. Muting silences spoken notifications only;
    /// the HUD still shows that the agent is blocked.
    @Published var mutedTargetIDs: Set<String> = []
    @Published var codexIntegrationStatus = "Checking Codex integration…"
    @Published var sttBackend: STTBackend = .parakeet
    @Published var sttTestStatus: String?
    @Published var parakeetInstalled = ParakeetTranscriber.isInstalled
    @Published var voiceInstalled = FluidSpeechSynthesizer.isInstalled
    @Published var isInstallingParakeet = false
    private var machine = InteractionMachine()
    private let policy = StatusPolicy()
    private let configurationStore = ConfigurationStore()
    private let parakeet = ParakeetTranscriber()
    private let synth = FluidSpeechSynthesizer()
    private let capture = MicrophoneCapture()
    private let recordingBuffer = RecordingBuffer()
    private let audioPipe = AudioChunkPipe()
    private let pcmPlayer = try? SpeechPCMPlayer()
    private let overlay = StatusOverlayController()
    private let adapterRegistry = AdapterRegistry()
    private let logger = MiriLogger()
    private let performance = PerformanceRecorder()
    private let launchStartedAt = Date()
    private var didRecordColdStart = false
    private lazy var delivery = DeliveryCoordinator(adapters: adapterRegistry)
    private let synthesizer = AVSpeechSynthesizer()
    private lazy var speechDelegate = SpeechDelegate { [weak self] in Task { @MainActor in self?.speechFinished() } }
    private var server: ControlSocketServer?
    private var hotkeys: GlobalHotKeyController?
    private var hotkeyNames: [UInt32: String] = [:]
    private var router = TargetRouter(registry: .init(targets: []))
    private var currentConfiguration = MiriConfiguration()
    private var recordingSnapshot: RecordingTargetSnapshot?
    /// The exact request this utterance answers, captured when recording began.
    private var recordingRequestID: String?
    private var recordingSessionID: String?
    private var speechSessionID: String?
    private var speechInterruptible = true
    private var speechPriority = 0
    private var onboardingWindow: NSWindow?
    private var adapterEventTasks: [String: Task<Void, Never>] = [:]
    private var adapterSetupTask: Task<Void, Never>?
    private var configuredTargetIDs: Set<String> = []
    private var responseBuffers: [String: String] = [:]
    private var finalResponses: [String: String] = [:]
    private var agentCompletionTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var overlayDismissTask: Task<Void, Never>?
    private var audioDeviceObserver: AudioDeviceObserver?
    private var audioSenderTask: Task<Void, Never>?
    private var hotkeyPressedAt: Date?
    private var recordingReleasedAt: Date?
    private var speechRequestedAt: Date?
    private var hotkeyIsHeld = false
    private var listeningAttemptID: UUID?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var speechTimeoutTask: Task<Void, Never>?
    private var attention = AttentionQueue()
    /// Real observed presence per target, keyed by target ID. Recorded from
    /// agent events and from deliveries, so the HUD reflects what actually
    /// happened rather than one fabricated timestamp per configured target.
    private var sessionPresence: [String: SessionPresence] = [:]

    override init() {
        // Block every model download for the process before anything can load
        // a model. Only an explicitly consented install lifts this, and only
        // for the duration of that one load. See ModelDownloadGate.
        ModelDownloadGate.blockDownloadsAtLaunch()
        super.init(); synthesizer.delegate = speechDelegate
        logger.log("application started")
        let server = ControlSocketServer { [weak self] request in await self?.speak(request) ?? .init(accepted: false, message: "Miri is unavailable") }
        self.server = server
        do { try server.start(); logger.log("control socket started") }
        catch { lastStatus = "Control socket failed: \(error.localizedDescription)"; logger.log(.error, lastStatus) }
        do {
            let hotkeys = try GlobalHotKeyController { [weak self] event in self?.hotKeyEvent(event) }
            self.hotkeys = hotkeys
        } catch { lastStatus = "Hotkey unavailable: \(error.localizedDescription)"; logger.log(.error, lastStatus) }
        audioDeviceObserver = AudioDeviceObserver { [weak self] change in self?.audioDeviceChanged(change) }
        Task { await setUp() }
    }

    private func setUp() async {
        do {
            let loaded = try await configurationStore.load()
            var configuration = loaded.configuration
            if configuration.targets.isEmpty {
                let clipboard = TargetDefinition(id: "clipboard", name: "Clipboard", adapter: "clipboard")
                configuration.defaultTarget = clipboard.id; configuration.targets = [clipboard]
                try await configurationStore.write(configuration)
            }
            apply(configuration)
            refreshCodexIntegrationStatus()
            logger.log("configuration loaded; targets=\(configuration.targets.count)")
            await configurationStore.startWatching()
            Task { [weak self] in
                guard let self else { return }
                for await event in await configurationStore.events() {
                    await MainActor.run {
                        if case .loaded(let result) = event { self.apply(result.configuration) }
                        if case .diagnostics(let diagnostics) = event {
                            self.lastStatus = diagnostics.first?.description ?? "Invalid configuration"
                            self.logger.log(.error, "configuration reload failed: \(self.lastStatus)")
                        }
                    }
                }
            }
        } catch { lastStatus = error.localizedDescription; logger.log(.error, "setup failed: \(error.localizedDescription)") }
        showOnboardingIfNeeded()
    }


    private func apply(_ configuration: MiriConfiguration) {
        let previousDefault = currentConfiguration.defaultTarget
        currentConfiguration = configuration
        targets = configuration.targets
        let enabledTargetIDs = Set(configuration.targets.filter(\.enabled).map(\.id))
        if activeTargetID == nil || !enabledTargetIDs.contains(activeTargetID!) || activeTargetID == previousDefault {
            activeTargetID = configuration.defaultTarget
        }
        inputMode = MiriInputMode.supported(configurationValue: configuration.inputMode)
        if case .string(let value)? = configuration.sections["hotkeys"]?["active_target"] { activeHotkey = value }
        else { activeHotkey = "option+space" }
        configureHotkeys(for: configuration.targets.filter(\.enabled))
        if case .string(let provider)? = configuration.sections["stt"]?["provider"] { sttBackend = STTBackend.supported(configurationValue: provider) }
        else { sttBackend = .parakeet }
        if sttBackend == .parakeet {
            Task { [weak self] in await self?.loadParakeetIfInstalled() }
        }
        func sttString(_ key: String) -> String? {
            if case .string(let value)? = configuration.sections["stt"]?[key] { return value }
            return nil
        }
        if case .string(let display)? = configuration.sections["ui"]?["display"], let id = UInt32(display) { overlay.setPinnedDisplay(id) }
        else { overlay.setPinnedDisplay(nil) }
        switch configuration.sections["audio"]?["speech_volume"] {
        case .number(let value)?: pcmPlayer?.volume = Float(value)
        case .integer(let value)?: pcmPlayer?.volume = Float(value)
        default: break
        }
        router = TargetRouter(registry: .init(targets: configuration.targets), defaultTargetID: configuration.defaultTarget)
        reconfigureAdapters(configuration.targets.filter(\.enabled))
    }

    private func reconfigureAdapters(_ enabledTargets: [TargetDefinition]) {
        adapterSetupTask?.cancel()
        adapterEventTasks.values.forEach { $0.cancel() }
        adapterEventTasks.removeAll()
        let oldTargetIDs = configuredTargetIDs
        configuredTargetIDs = Set(enabledTargets.map(\.id))
        adapterSetupTask = Task { [weak self] in
            guard let self else { return }
            for targetID in oldTargetIDs { await self.adapterRegistry.unregister(targetID: targetID) }
            guard !Task.isCancelled else { return }
            for target in enabledTargets {
                guard !Task.isCancelled else { return }
                await self.connectAdapter(for: target)
            }
        }
    }

    private func connectAdapter(for target: TargetDefinition) async {
        guard let adapter = makeAdapter(for: target) else {
            targetStatuses[target.id] = .failed
            lastStatus = "\(target.name): required executable or endpoint was not found"
            logger.log(.error, "target unavailable id=\(target.id) adapter=\(target.adapter)")
            return
        }
        await adapterRegistry.register(adapter, for: target.id)
        targetStatuses[target.id] = .connecting
        adapterEventTasks[target.id] = Task { [weak self] in
            for await event in adapter.events() {
                guard !Task.isCancelled else { return }
                self?.handleAgentEvent(event, target: target)
            }
        }
        do {
            try await adapter.connect()
            guard !Task.isCancelled else { await adapter.disconnect(); return }
            targetStatuses[target.id] = .ready
            logger.log("target connected id=\(target.id) adapter=\(target.adapter)")
            if activeTargetID == target.id { lastStatus = "\(target.name) is ready" }
            if target.adapter == "codex", codexThreads.isEmpty { await refreshCodexThreads() }
        } catch {
            targetStatuses[target.id] = .failed
            lastStatus = "\(target.name): \(error.localizedDescription)"
            logger.log(.error, "target connection failed id=\(target.id): \(error.localizedDescription)")
        }
    }

    private func handleAgentEvent(_ event: AgentEvent, target: TargetDefinition) {
        noteAgentActivity(target)
        switch event {
        case .status(let status):
            targetStatuses[target.id] = status
            // A disconnected or failed agent is no longer waiting on an
            // answer; leaving its requests pending would let a later utterance
            // approve something nothing is listening for.
            if status == .disconnected || status == .failed {
                attention.removeAll(targetID: target.id)
                pendingAgentPrompt = attention.pending().first?.request.title
            }
            if status == .busy, activeTargetID == target.id { presentOverlay(.waiting(target: target.name)) }
        case .responseDelta(let delta):
            responseBuffers[target.id, default: ""] += delta
            lastStatus = "\(target.name) is responding…"
            if state != .speaking { presentOverlay(.waiting(target: target.name)) }
            scheduleAgentCompletionFallback(for: target)
        case .responseCompleted(let response):
            finalResponses[target.id] = response
            lastAgentResponse = response
            lastAgentName = target.name
            scheduleAgentCompletionFallback(for: target, delay: 2)
        case .interactionRequested(let request):
            attention.add(.init(request: request, target: target, adapterBacked: true))
            pendingAgentPrompt = request.title
            lastStatus = "\(request.title). Hold \(activeHotkey) and say approve request or deny request."
            logger.log("agent interaction requested target=\(target.id) kind=\(request.kind.rawValue)")
            Task { await speakAgentResponse("\(request.title). Say approve request or deny request.", target: target.name, targetID: target.id) }
        case .interactionResolved(let requestID):
            // Answered elsewhere or withdrawn: stop offering it.
            attention.remove(id: requestID)
            pendingAgentPrompt = attention.pending().first?.request.title
        case .completed:
            completeAgentTurn(target)
        case .failed(let message):
            agentCompletionTimeoutTasks.removeValue(forKey: target.id)?.cancel()
            responseBuffers.removeValue(forKey: target.id); finalResponses.removeValue(forKey: target.id)
            attention.removeAll(targetID: target.id)
            pendingAgentPrompt = attention.pending().first?.request.title
            targetStatuses[target.id] = .failed
            lastStatus = "\(target.name): \(message)"
            logger.log(.error, "agent turn failed target=\(target.id): \(message)")
            if state == .idle { presentOverlay(.error(message: message)); dismissOverlay(after: 3) }
        }
    }

    private func scheduleAgentCompletionFallback(for target: TargetDefinition, delay: TimeInterval = 30) {
        agentCompletionTimeoutTasks.removeValue(forKey: target.id)?.cancel()
        agentCompletionTimeoutTasks[target.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.responseBuffers[target.id]?.isEmpty == false || self.finalResponses[target.id]?.isEmpty == false else { return }
                self.logger.log(.warning, "agent completion event timed out; finalizing buffered response target=\(target.id)")
                self.completeAgentTurn(target)
            }
        }
    }

    private func completeAgentTurn(_ target: TargetDefinition) {
        agentCompletionTimeoutTasks.removeValue(forKey: target.id)?.cancel()
        let streamed = responseBuffers.removeValue(forKey: target.id) ?? ""
        let response = finalResponses.removeValue(forKey: target.id) ?? streamed
        guard targetStatuses[target.id] != .ready || !response.isEmpty else { return }
        targetStatuses[target.id] = .ready
        lastAgentResponse = response.isEmpty ? nil : response
        lastAgentName = target.name
        if response.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            let spokenQuestion = AgentSpeechFormatter.spokenText(from: response, maxCharacters: agentSpeechLimit) ?? "\(target.name) needs your answer"
            let request = AgentInteractionRequest(kind: .question, title: spokenQuestion)
            attention.add(.init(request: request, target: target, adapterBacked: false))
            pendingAgentPrompt = spokenQuestion
            activeTargetID = target.id
            lastStatus = "\(target.name) needs your answer. Hold \(activeHotkey) to reply."
        } else { lastStatus = "\(target.name) completed successfully" }
        logger.log("agent turn completed target=\(target.id) response_characters=\(response.count)")
        if shouldSpeakAgentResponses, let spoken = AgentSpeechFormatter.spokenText(from: response, maxCharacters: agentSpeechLimit) {
            Task { await self.speakAgentResponse(spoken, target: target.name, targetID: target.id) }
        } else {
            presentOverlay(.delivered(target: target.name)); dismissOverlay(after: 1.2)
        }
        Task {
            if let outcome = await delivery.drainQueue(for: target.id) { await handleDrainedQueue(outcome, target: target) }
            await refreshOutbox()
        }
    }


    /// True when transcription runs in-process on the ANE, so the Python
    /// worker is not involved in the recording path at all.
    private var usesParakeet: Bool { sttBackend == .parakeet }

    private var shouldSpeakAgentResponses: Bool {
        if agentSpeechMuted { return false }
        if case .boolean(let value)? = currentConfiguration.sections["tts"]?["speak_agent_responses"] { return value }
        return true
    }

    private var agentSpeechLimit: Int {
        if case .integer(let value)? = currentConfiguration.sections["tts"]?["agent_response_max_characters"] { return max(40, min(value, 180)) }
        return 180
    }

    func refreshCodexThreads() async {
        guard !isRefreshingCodexThreads else { return }
        guard let executable = findExecutable("codex") else {
            lastStatus = "Codex executable not found"
            return
        }
        let workingDirectory = currentConfiguration.targets.first(where: { $0.adapter == "codex" })?.workingDirectory.map(expand) ?? FileManager.default.currentDirectoryPath
        let adapter = CodexAppServerAdapter(
            id: "thread-catalog",
            executable: executable,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            opensThread: false
        )
        isRefreshingCodexThreads = true
        defer { isRefreshingCodexThreads = false; Task { await adapter.disconnect() } }
        do {
            try await adapter.connect()
            codexThreads = try await adapter.listThreads(limit: 30)
            logger.log("Codex thread catalog refreshed count=\(codexThreads.count)")
        } catch {
            lastStatus = "Codex threads: \(error.localizedDescription)"
            logger.log(.error, lastStatus)
        }
    }

    func addCodexThread(_ thread: CodexThreadSummary) {
        if let existing = currentConfiguration.targets.first(where: { $0.session == thread.id }) {
            selectTarget(existing.id); return
        }
        var id = "codex-\(thread.id.prefix(8))"
        var suffix = 2
        while currentConfiguration.targets.contains(where: { $0.id == id }) {
            id = "codex-\(thread.id.prefix(8))-\(suffix)"; suffix += 1
        }
        let shortName = String(thread.displayName.prefix(48))
        let target = TargetDefinition(
            id: id,
            name: "Codex – \(shortName)",
            agent: "codex",
            adapter: "codex",
            workingDirectory: thread.workingDirectory,
            session: thread.id
        )
        currentConfiguration.targets.append(target)
        currentConfiguration.defaultTarget = id
        activeTargetID = id
        Task {
            do {
                try await configurationStore.write(currentConfiguration)
                lastStatus = "Added \(target.name)"
            } catch {
                lastStatus = "Could not add Codex thread: \(error.localizedDescription)"
                logger.log(.error, lastStatus)
            }
        }
    }

    private func mcpHelperURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/miri-mcp")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "miri-mcp")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/debug/miri-mcp")
        return FileManager.default.isExecutableFile(atPath: development.path) ? development : nil
    }

    private func refreshCodexIntegrationStatus() {
        guard let codex = findExecutable("codex") else { codexIntegrationStatus = "Codex CLI not found"; return }
        Task { [weak self] in
            let installed = await Task.detached { CodexMCPInstaller.isInstalled(codex: codex) }.value
            self?.codexIntegrationStatus = installed ? "Miri MCP is registered with Codex" : "Miri MCP is not registered with Codex"
        }
    }

    func installCodexIntegration() {
        guard let codex = findExecutable("codex") else { lastStatus = "Codex CLI not found"; return }
        guard let helper = mcpHelperURL() else { lastStatus = "Miri MCP helper is missing; reinstall Miri"; return }
        let alert = NSAlert(); alert.messageText = "Install Miri voice integration for Codex?"
        alert.informativeText = "This registers Miri's local stdio MCP helper in ~/.codex/config.toml. It opens no network port. Existing Miri registration is replaced."
        alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        codexIntegrationStatus = "Installing Miri MCP…"
        Task { [weak self] in
            let failure = await Task.detached { () -> String? in
                do { try CodexMCPInstaller.install(codex: codex, helper: helper); return nil }
                catch { return error.localizedDescription }
            }.value
            if let failure {
                self?.codexIntegrationStatus = "Installation failed: \(failure)"
                self?.lastStatus = "Codex integration failed: \(failure)"
            } else {
                self?.codexIntegrationStatus = "Miri MCP is registered with Codex"
                self?.lastStatus = "Codex voice integration installed. Restart Codex to load it."
            }
        }
    }

    private func makeAdapter(for target: TargetDefinition) -> (any AgentAdapter)? {
        let workingDirectory = target.workingDirectory.map { URL(fileURLWithPath: expand($0)) } ?? FileManager.default.homeDirectoryForCurrentUser
        switch target.adapter {
        case "clipboard": return ClipboardAdapter(id: target.id)
        case "cursor", "focused-app": return FocusedAppAdapter(id: target.id)
        case "generic", "generic-command":
            guard let path = target.endpoint else { return nil }
            return GenericCommandAdapter(id: target.id, executable: URL(fileURLWithPath: expand(path)), workingDirectory: workingDirectory)
        case "codex":
            guard let executable = findExecutable("codex") else { return nil }
            return CodexAppServerAdapter(id: target.id, executable: executable, workingDirectory: workingDirectory, threadID: target.session)
        case "claude", "claude-code":
            guard let executable = findExecutable("claude") else { return nil }
            return ClaudeCodeAdapter(id: target.id, executable: executable, workingDirectory: workingDirectory, sessionID: target.session)
        case "hermes":
            guard let endpoint = target.endpoint.flatMap(URL.init(string:)), let session = target.session else { return nil }
            return HermesAdapter(id: target.id, endpoint: endpoint, sessionID: session)
        default: return nil
        }
    }

    private func configureHotkeys(for enabledTargets: [TargetDefinition]) {
        hotkeys?.unregisterAll(); hotkeyNames.removeAll()
        do {
            try hotkeys?.register(KeyboardShortcut.parse(activeHotkey), identifier: 1)
            hotkeyNames[1] = activeHotkey
        } catch {
            lastStatus = "Active hotkey unavailable: \(error.localizedDescription)"
            logger.log(.error, lastStatus)
        }
        let dedicated = enabledTargets.compactMap { target in target.hotkey.map { (target, $0) } }
        for (offset, pair) in dedicated.enumerated() {
            let identifier = UInt32(offset + 100)
            do {
                try hotkeys?.register(KeyboardShortcut.parse(pair.1), identifier: identifier)
                hotkeyNames[identifier] = pair.1
            } catch {
                logger.log(.error, "target hotkey unavailable id=\(pair.0.id): \(error.localizedDescription)")
            }
        }
    }

    private func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    private func findExecutable(_ name: String) -> URL? {
        var override: String?
        if case .string(let value)? = currentConfiguration.sections["agents"]?["\(name)_path"] { override = value }
        return ExecutableResolver.find(name, override: override)
    }

    private func hotKeyEvent(_ event: GlobalHotKeyEvent) {
        switch event {
        case .pressed(let identifier):
            guard !hotkeyIsHeld else { return }
            hotkeyIsHeld = true; hotkeyPressedAt = .now
            let attempt = UUID(); listeningAttemptID = attempt
            Task {
            await beginListening(dedicatedHotkey: hotkeyNames[identifier], attemptID: attempt)
            }
        case .released:
            hotkeyIsHeld = false; listeningAttemptID = nil; endListening()
        case .cancelled: cancel()
        }
    }

    private func audioDeviceChanged(_ change: AudioDeviceChange) {
        switch change {
        case .deviceConnected(let name):
            lastStatus = "Audio device connected: \(name)"; logger.log(lastStatus)
        case .deviceDisconnected(let name):
            logger.log(.warning, "audio device disconnected: \(name)")
            if state == .listening || state == .speaking {
                cancel(); lastStatus = "\(name) disconnected. Select another audio device and try again."
                presentOverlay(.error(message: lastStatus)); dismissOverlay(after: 3)
            } else { lastStatus = "Audio device disconnected: \(name)" }
        case .engineConfigurationChanged:
            logger.log(.warning, "audio engine configuration changed")
            if state == .listening { cancel(); lastStatus = "Audio input changed. Hold the hotkey to record again." }
        }
    }

    func toggleListening() {
        if state == .listening { endListening() } else { hotkeyPressedAt = .now; Task { await beginListening() } }
    }

    private func beginListening(dedicatedHotkey: String? = nil, attemptID: UUID? = nil) async {
        let requiresHeldHotkey = attemptID != nil
        do {
            if requiresHeldHotkey {
                guard hotkeyIsHeld, listeningAttemptID == attemptID else { return }
            }
            switch state {
            case .idle, .speaking: break
            case .failed: state = machine.handle(.cancel)
            default:
                lastStatus = "Finish the current voice request before starting another"
                return
            }
        }
        if state == .speaking {
            synthesizer.stopSpeaking(at: .immediate)
            await synth.stop()
            pcmPlayer?.stop(); speechSessionID = nil; speechInterruptible = true
        }
        if usesParakeet, await !parakeet.isLoaded {
            let message = ParakeetTranscriber.isInstalled
                ? "Speech model is still loading"
                : "Download the on-device speech model in Settings > Speech."
            lastStatus = message; presentOverlay(.error(message: message)); dismissOverlay(after: 2); return
        }
        microphonePermission = await MicrophonePermissions.request()
        guard microphonePermission == .granted else { lastStatus = "Microphone access is required"; presentOverlay(.error(message: lastStatus)); return }
        if requiresHeldHotkey {
            guard hotkeyIsHeld, listeningAttemptID == attemptID else { return }
        }
        do {
            let routed = try router.snapshot(dedicatedHotkey: dedicatedHotkey, activeTargetID: activeTargetID)
            if dedicatedHotkey != nil {
                // A dedicated shortcut is an explicit aim: honour it verbatim.
                recordingSnapshot = routed
                recordingRequestID = nil
            } else {
                let waiting = attention.pending()
                let now = Date()
                switch ContextResolver.resolve(
                    attention: waiting,
                    sessions: Array(sessionPresence.values.filter { !$0.isExpired(at: now) }),
                    pinnedDefault: routed.target,
                    now: now
                ) {
                case .resolved(let resolved, let reason):
                    recordingSnapshot = reason == .pinnedDefault ? routed : resolved
                    // Bind the utterance to the exact request it answers, so a
                    // delayed transcript cannot approve a different one.
                    recordingRequestID = reason == .pendingRequest ? waiting.first?.id : nil
                    // RoutingReason exists so an automatic choice is never
                    // mysterious; log it rather than discarding it.
                    logger.log("routing target=\(recordingSnapshot?.target.id ?? "none") reason=\(reason.rawValue)")
                case .needsSelection:
                    // Several agents are blocked. Guessing here could approve
                    // the wrong command, so ask instead of recording.
                    lastStatus = "Several agents need you. Choose one from the Miri menu, then speak."
                    presentOverlay(.needsInput(label: "Choose an agent")); dismissOverlay(after: 2.5)
                    recordingSnapshot = nil; recordingRequestID = nil
                    state = machine.handle(.cancel)
                    return
                case .noTarget:
                    recordingSnapshot = routed; recordingRequestID = nil
                }
            }
        }
        catch { recordingSnapshot = nil; recordingRequestID = nil }
        let session = UUID().uuidString; recordingSessionID = session
        recordingBuffer.reset()
        do {
            if usesParakeet { try await parakeet.startStream() }
            if requiresHeldHotkey, (!hotkeyIsHeld || listeningAttemptID != attemptID) {
                await parakeet.cancel()
                recordingSessionID = nil; recordingSnapshot = nil; recordingRequestID = nil
                return
            }
            // Samples go straight to the on-device model: no IPC, no
            // subprocess, nothing leaves this process.
            try capture.start { [recordingBuffer, parakeet] chunk in
                recordingBuffer.append(chunk.samples.withUnsafeBytes { Data($0) })
                Task { await parakeet.accept(chunk.samples) }
            } onError: { [weak self] error in Task { @MainActor in self?.fail(error) } }
            state = machine.handle(.pressToTalk); hotkeys?.enableEscapeCancellation(true)
            let target = recordingSnapshot?.target.name ?? "No target"
            lastStatus = "Listening for \(target)"; presentOverlay(.listening(target: target))
            if let hotkeyPressedAt {
                performance.record("overlay_response_ms", milliseconds: Date().timeIntervalSince(hotkeyPressedAt) * 1_000, sessionID: session)
                self.hotkeyPressedAt = nil
            }
        } catch { fail(error) }
    }

    private func endListening() {
        guard state == .listening, let session = recordingSessionID else { return }
        listeningAttemptID = nil
        capture.stop(); audioPipe.finish(); recordingReleasedAt = .now
        state = machine.handle(.releaseToTalk); hotkeys?.enableEscapeCancellation(false)
        presentOverlay(.transcribing(target: recordingSnapshot?.target.name ?? "No target"))
        let audio = recordingBuffer.take()
        if let metrics = AudioSignalMetrics.analyze(float32LE: audio) {
            audioDiagnostics = String(format: "Audio %.1fs · RMS %.3f · peak %.2f", metrics.durationSeconds, metrics.rms, metrics.peak)
            if let warning = metrics.qualityMessage {
                audioSenderTask?.cancel(); audioSenderTask = nil
                recordingSessionID = nil; recordingSnapshot = nil; recordingRequestID = nil; recordingReleasedAt = nil
                Task { [parakeet] in await parakeet.cancel() }
                lastStatus = warning; state = machine.handle(.failure(warning)); presentOverlay(.error(message: warning)); dismissOverlay(after: 2)
                return
            }
        }
        audioSenderTask = nil
        Task {
            do {
                let text = try await parakeet.finish()
                guard recordingSessionID == session else { return }
                await handleFinalTranscript(text, sessionID: session)
            } catch { await MainActor.run { self.fail(error) } }
        }
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.recordingSessionID == session else { return }
                self?.fail(NSError(domain: "MiriSpeechWorker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transcription timed out; the voice session was reset"]))
            }
        }
    }


    /// Shared terminal step for every transcription backend. The Python worker
    /// reaches it through `handleWorkerFrame`; Parakeet calls it directly.
    private func handleFinalTranscript(_ text: String, sessionID: String?) async {
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        if let recordingReleasedAt {
            performance.record("final_transcript_ms", milliseconds: Date().timeIntervalSince(recordingReleasedAt) * 1_000, sessionID: sessionID)
            self.recordingReleasedAt = nil
        }
        state = machine.handle(.transcriptReady)
        guard let snapshot = recordingSnapshot else {
            lastStatus = "No target configured. Transcript: \(text)"; presentOverlay(.error(message: "No target configured")); state = .failed("No target"); return
        }
        // Approval is bound to the request captured when recording began, not
        // merely to its target: an agent can have several requests open, and
        // answering the wrong one could run the wrong command.
        if let requestID = recordingRequestID,
           let pending = attention.item(requestID: requestID), pending.adapterBacked {
            await resolveApprovalTranscript(text, pending: pending)
            recordingSessionID = nil; recordingSnapshot = nil; recordingRequestID = nil
            return
        }
        if let requestID = recordingRequestID, attention.item(requestID: requestID) == nil {
            // The request was withdrawn, expired, or answered elsewhere while
            // the user was speaking. Fail closed rather than re-routing.
            recordingRequestID = nil
            lastStatus = "That request is no longer waiting. Nothing was sent."
            presentOverlay(.error(message: "Request no longer waiting")); dismissOverlay(after: 2)
            recordingSessionID = nil; recordingSnapshot = nil
            state = machine.handle(.delivered)
            return
        }
        let sendingLabel = showTranscriptPreview ? "\(snapshot.target.name) · \(String(text.prefix(80)))" : snapshot.target.name
        presentOverlay(.sending(target: sendingLabel))
        // Spoken form is wrong for dictating into code: "port eight thousand
        // and eighty" must arrive as "port 8080". Applied here rather than in
        // the transcriber so voice approvals above still parse the raw text.
        let written = TranscriptFormatter.written(text)
        if written != text { logger.log("transcript normalized to written form") }
        // Speaking to an agent is the strongest presence signal there is, and
        // it is what ContextResolver's recency rule reads.
        noteAgentActivity(snapshot.target, spokenToByUser: true)
        let outcome = await delivery.deliver(written, to: snapshot)
        switch outcome {
        case .delivered:
            clearQuestionIfNeeded(for: snapshot.target.id)
            lastStatus = "Delivered to \(snapshot.target.name); waiting for response"
            logger.log("transcript delivered target=\(snapshot.target.id)")
            presentOverlay(.delivered(target: snapshot.target.name)); transitionOverlay(to: .waiting(target: snapshot.target.name), after: 0.65); state = machine.handle(.delivered)
        case .copied:
            clearQuestionIfNeeded(for: snapshot.target.id)
            lastStatus = "Copied for \(snapshot.target.name)"
            logger.log("transcript copied target=\(snapshot.target.id)")
            presentOverlay(.delivered(target: snapshot.target.name)); state = machine.handle(.delivered)
        case .queued:
            clearQuestionIfNeeded(for: snapshot.target.id)
            lastStatus = "Queued for \(snapshot.target.name)"
            logger.log("transcript queued target=\(snapshot.target.id)")
            presentOverlay(.queued(target: snapshot.target.name))
        case .confirmationRequired:
            let alert = NSAlert(); alert.messageText = "Replace queued message for \(snapshot.target.name)?"
            alert.informativeText = "Only one voice message can wait per target. Replacing discards the older queued message."
            alert.addButton(withTitle: "Replace Queue"); alert.addButton(withTitle: "Keep Older Message")
            alert.alertStyle = .warning; NSApp.activate(ignoringOtherApps: true)
            let approved = alert.runModal() == .alertFirstButtonReturn
            let resolved = await delivery.deliver(text, to: snapshot, queuePolicy: approved ? .replace : .reject)
            await handleResolvedQueue(resolved, target: snapshot.target)
        case .outboxed(let entry):
            lastStatus = "Delivery failed: \(entry.failure)"
            logger.log(.error, "delivery failed target=\(snapshot.target.id): \(entry.failure)")
            presentOverlay(.error(message: entry.failure)); state = .failed(entry.failure)
            await refreshOutbox()
        }
        recordingSessionID = nil; recordingSnapshot = nil
        if state == .delivering { state = machine.handle(.delivered) }
        if case .copied = outcome { dismissOverlay(after: 1) }
    }

    private func clearQuestionIfNeeded(for targetID: String) {
        attention.removeQuestions(targetID: targetID)
        pendingAgentPrompt = attention.pending().first?.request.title
    }

    private func resolveApprovalTranscript(_ transcript: String, pending: AttentionItem) async {
        guard let adapter = await adapterRegistry.adapter(for: pending.target.id) else {
            fail(AdapterError.unsupportedInteraction); return
        }
        let outcome = await ApprovalOutcome.resolve(transcript: transcript) { response in
            try await adapter.respond(to: pending.request.id, with: response)
        }
        lastStatus = outcome.statusMessage(targetName: pending.target.name)
        // A decision that never left the machine must leave the request
        // answerable: a lost deny must not look like a delivered one.
        if !outcome.requestRemainsPending {
            attention.remove(id: pending.request.id)
            pendingAgentPrompt = attention.pending().first?.request.title
        }
        switch outcome {
        case .notUnderstood:
            state = machine.handle(.delivered)
            presentOverlay(.error(message: "Say approve request or deny request")); dismissOverlay(after: 2)
        case .delivered(let response):
            state = machine.handle(.delivered)
            presentOverlay(.delivered(target: pending.target.name)); dismissOverlay(after: 1)
            logger.log("agent approval resolved target=\(pending.target.id) decision=\(response == .approve ? "approve" : "deny")")
        case .notDelivered(let message):
            logger.log(.error, "agent approval delivery failed target=\(pending.target.id): \(message)")
            fail(AdapterError.interactionDeliveryFailed(message))
            // fail() sets lastStatus to the raw error; restore the message
            // that tells the user their request is still answerable.
            lastStatus = outcome.statusMessage(targetName: pending.target.name)
        }
    }

    private func fail(_ error: Error) {
        capture.stop(); audioPipe.finish(); audioSenderTask?.cancel(); audioSenderTask = nil
        Task { [parakeet] in await parakeet.cancel() }
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        speechTimeoutTask?.cancel(); speechTimeoutTask = nil; hotkeyPressedAt = nil; recordingReleasedAt = nil; speechRequestedAt = nil; lastStatus = error.localizedDescription
        hotkeyIsHeld = false; listeningAttemptID = nil
        recordingSessionID = nil; recordingSnapshot = nil; recordingRequestID = nil; speechSessionID = nil
        Task { [synth] in await synth.stop() }
        logger.log(.error, "interaction failed: \(error.localizedDescription)")
        state = machine.handle(.failure(error.localizedDescription)); presentOverlay(.error(message: error.localizedDescription))
        dismissOverlay(after: 2)
    }

    func speak(_ request: VoiceStatusRequest) async -> ControlResponse {
        do { try await policy.validate(request) }
        catch { lastStatus = error.localizedDescription; return .init(accepted: false, message: error.localizedDescription) }
        // Resolve the target for every kind, not just questions: this is the
        // path `miri-mcp` uses, and without a target ID per-agent mute has
        // nothing to match against.
        let resolved = resolveStatusTarget(request)
        // Return before the interruption logic below, so a muted agent cannot
        // stop another agent's speech on its way to being silenced.
        if let id = resolved?.id, mutedTargetIDs.contains(id) {
            logger.log("agent speech skipped: target muted")
            return .init(accepted: false, message: "\(resolved?.name ?? "That agent") is muted")
        }
        if request.kind == .question, let target = resolved {
            let interaction = AgentInteractionRequest(kind: .question, title: request.text)
            attention.add(.init(request: interaction, target: target, adapterBacked: false))
            pendingAgentPrompt = request.text
            activeTargetID = target.id
            logger.log("agent question bound target=\(target.id)")
        }
        speechRequestedAt = .now
        if synthesizer.isSpeaking {
            guard speechInterruptible && request.priority > speechPriority else { return .init(accepted: false, message: "A status of equal or higher priority is already speaking") }
            synthesizer.stopSpeaking(at: .immediate)
        }
        if speechSessionID != nil {
            guard speechInterruptible && request.priority > speechPriority else { return .init(accepted: false, message: "A status of equal or higher priority is already speaking") }
            await synth.stop(); pcmPlayer?.stop()
        }
        return await startSpeech(
            request.text,
            target: resolved?.name ?? "Agent",
            targetID: resolved?.id,
            interruptible: request.interruptible,
            priority: request.priority
        )
    }

    private func resolveStatusTarget(_ request: VoiceStatusRequest) -> TargetDefinition? {
        if let targetID = request.targetID, let target = targets.first(where: { $0.enabled && $0.id == targetID }) { return target }
        if let source = request.sourceWorkingDirectory {
            let canonical = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path
            let matches = targets.filter {
                guard $0.enabled, let workingDirectory = $0.workingDirectory else { return false }
                return URL(fileURLWithPath: expand(workingDirectory)).standardizedFileURL.resolvingSymlinksInPath().path == canonical
            }
            if let active = matches.first(where: { $0.id == activeTargetID }) { return active }
            if matches.count == 1 { return matches[0] }
        }
        return targets.first(where: { $0.enabled && $0.id == activeTargetID })
            ?? targets.first(where: { $0.enabled && $0.id == currentConfiguration.defaultTarget })
    }

    private func speakAgentResponse(_ text: String, target: String, targetID: String? = nil) async {
        guard state == .idle, speechSessionID == nil, !synthesizer.isSpeaking else {
            logger.log(.warning, "agent response speech skipped because audio interaction is active")
            return
        }
        _ = await startSpeech(text, target: target, targetID: targetID, interruptible: true, priority: 0)
    }

    /// The single choke point for agent speech. The mute check lives here, not
    /// in the callers, because the MCP path bypassed a caller-side check.
    private func startSpeech(
        _ text: String,
        target: String,
        targetID: String? = nil,
        interruptible: Bool,
        priority: Int
    ) async -> ControlResponse {
        if let targetID, mutedTargetIDs.contains(targetID) {
            logger.log("agent speech skipped: target muted")
            return .init(accepted: false, message: "\(target) is muted")
        }
        lastStatus = "Speaking response from \(target)"; state = machine.handle(.speechStarted)
        presentOverlay(.speaking(target: target))
        let session = UUID().uuidString; speechSessionID = session; speechInterruptible = interruptible; speechPriority = priority
        do {
            // Never download mid-conversation: an agent reply must not trigger
            // a ~520 MB fetch. Absent voices fall through to the system voice.
            try await synth.load(allowDownload: false)
            try await synth.speak(
                text,
                onFrame: { [weak self] samples in
                    await MainActor.run {
                        guard let self, self.speechSessionID == session else { return }
                        if let speechRequestedAt = self.speechRequestedAt {
                            self.performance.record("first_audio_ms", milliseconds: Date().timeIntervalSince(speechRequestedAt) * 1_000, sessionID: session)
                            self.speechRequestedAt = nil
                        }
                        do { try self.pcmPlayer?.enqueue(samples) } catch { self.fail(error) }
                    }
                },
                onFinish: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.speechSessionID == session else { return }
                        if let error { self.fail(error); return }
                        self.speechTimeoutTask?.cancel(); self.speechTimeoutTask = nil
                        self.speechSessionID = nil; self.speechInterruptible = true; self.speechPriority = 0
                        if let pcmPlayer = self.pcmPlayer { pcmPlayer.finishWhenDrained { [weak self] in self?.speechFinished() } }
                        else { self.speechFinished() }
                    }
                }
            )
            speechTimeoutTask?.cancel()
            speechTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.speechSessionID == session else { return }
                    self?.fail(NSError(domain: "MiriSpeech", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech playback timed out; the session was reset"]))
                }
            }
            return .init(accepted: true, message: "Status queued")
        } catch {
            // The on-device voice is unavailable; the system voice keeps the
            // agent audible rather than failing the interaction silently.
            logger.log(.warning, "on-device voice unavailable, using system voice: \(error.localizedDescription)")
            speechSessionID = nil; speechInterruptible = interruptible; speechPriority = priority
            if let speechRequestedAt {
                performance.record("first_audio_ms", milliseconds: Date().timeIntervalSince(speechRequestedAt) * 1_000, sessionID: session)
                self.speechRequestedAt = nil
            }
            let utterance = AVSpeechUtterance(string: text); utterance.rate = 0.52; utterance.volume = speechVolume; synthesizer.speak(utterance)
            return .init(accepted: true, message: "Status queued with system voice fallback")
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate); capture.stop()
        audioPipe.finish(); audioSenderTask?.cancel(); audioSenderTask = nil
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        speechTimeoutTask?.cancel(); speechTimeoutTask = nil; recordingBuffer.reset()
        hotkeyIsHeld = false; listeningAttemptID = nil
        hotkeyPressedAt = nil; recordingReleasedAt = nil; speechRequestedAt = nil
        Task { [parakeet] in await parakeet.cancel() }
        Task { [synth] in await synth.stop() }
        pcmPlayer?.stop(); speechSessionID = nil; speechInterruptible = true; speechPriority = 0
        recordingSessionID = nil; recordingSnapshot = nil; recordingRequestID = nil; hotkeys?.enableEscapeCancellation(false)
        state = machine.handle(.cancel); presentOverlay(.cancelled); dismissOverlay(after: 0.25)
    }
    func selectTarget(_ id: String) {
        activeTargetID = id
        let name = targets.first(where: { $0.id == id })?.name ?? id
        let status = targetStatuses[id]?.rawValue ?? "starting"
        lastStatus = "Selected \(name) (\(status))"
    }
    func saveActiveHotkey() {
        do { _ = try KeyboardShortcut.parse(activeHotkey) }
        catch { lastStatus = error.localizedDescription; return }
        activeHotkey = activeHotkey.lowercased()
        currentConfiguration.sections["hotkeys", default: [:]]["active_target"] = .string(activeHotkey)
        Task {
            do { try await configurationStore.write(currentConfiguration); lastStatus = "Hotkey saved: \(activeHotkey)" }
            catch { lastStatus = "Could not save hotkey: \(error.localizedDescription)" }
        }
    }
    func setInputMode(_ mode: MiriInputMode) {
        inputMode = mode; currentConfiguration.inputMode = mode.rawValue
        Task {
            overlay.hide(); lastStatus = "Push to talk enabled"
            do { try await configurationStore.write(currentConfiguration) }
            catch { lastStatus = "Could not save input mode: \(error.localizedDescription)" }
        }
    }

    /// Loads Parakeet only if its models are already on disk. Never downloads:
    /// that requires the explicit consent flow in `installParakeetModels`.
    private func loadParakeetIfInstalled() async {
        parakeetInstalled = ParakeetTranscriber.isInstalled
        voiceInstalled = FluidSpeechSynthesizer.isInstalled
        guard parakeetInstalled else {
            speechHealth = "On-device model is not installed yet"
            return
        }
        do {
            try await parakeet.load(allowDownload: false)
            speechHealth = "On-device speech model ready"
        } catch {
            speechHealth = "On-device model failed to load: \(error.localizedDescription)"
            logger.log(.error, speechHealth)
        }
    }

    /// Downloads both speech models after one explicit consent prompt.
    ///
    /// Transcription and speech are separate FluidAudio downloads. Asking only
    /// about Parakeet left the voice to download silently during the first
    /// agent reply, so consent covers the real total.
    func installParakeetModels() { installSpeechModels() }

    func installSpeechModels() {
        guard !isInstallingParakeet else { return }
        let alert = NSAlert()
        alert.messageText = "Download the on-device speech models?"
        alert.informativeText = "Miri downloads about 1 GB from Hugging Face once: roughly 470 MB for Parakeet transcription and 520 MB for the PocketTTS voice. After that, speech runs entirely on this Mac with no network access."
        alert.addButton(withTitle: "Download"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isInstallingParakeet = true
        speechHealth = "Downloading transcription model…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await parakeet.load(allowDownload: true)
                parakeetInstalled = ParakeetTranscriber.isInstalled
                speechHealth = "Downloading voice…"
                try await synth.load(allowDownload: true)
                voiceInstalled = FluidSpeechSynthesizer.isInstalled
                isInstallingParakeet = false
                speechHealth = "On-device speech models ready"
                lastStatus = "On-device speech models installed"
            } catch {
                isInstallingParakeet = false
                parakeetInstalled = ParakeetTranscriber.isInstalled
                voiceInstalled = FluidSpeechSynthesizer.isInstalled
                speechHealth = "Download failed: \(error.localizedDescription)"
                lastStatus = speechHealth
                logger.log(.error, speechHealth)
            }
        }
    }

    /// Persists the speech-backend choice and restarts the worker so the new
    /// provider takes effect without requiring a relaunch.
    func saveSTTSettings() {
        sttTestStatus = nil
        guard ParakeetTranscriber.isInstalled else {
            sttTestStatus = "Download the on-device model before selecting it."
            return
        }
        currentConfiguration.sections["stt", default: [:]]["provider"] = .string(sttBackend.configurationValue)
        Task {
            do {
                try await configurationStore.write(currentConfiguration)
                await loadParakeetIfInstalled()
                lastStatus = "On-device transcription enabled"
            } catch { lastStatus = "Could not save speech settings: \(error.localizedDescription)" }
        }
    }

    private var vadMinimumSilenceMilliseconds: Int {
        if case .integer(let value)? = currentConfiguration.sections["vad"]?["minimum_silence_ms"] {
            return max(100, min(value, 5_000))
        }
        return 500
    }

    private var speechVolume: Float {
        switch currentConfiguration.sections["audio"]?["speech_volume"] {
        case .number(let value)?: Float(min(1, max(0, value)))
        case .integer(let value)?: Float(min(1, max(0, value)))
        default: 0.85
        }
    }

    private var showTranscriptPreview: Bool {
        if case .boolean(let value)? = currentConfiguration.sections["ui"]?["show_transcript_preview"] { return value }
        return false
    }

    func toggleAgentSpeech() {
        agentSpeechMuted.toggle()
        if agentSpeechMuted, state == .speaking { cancel() }
        lastStatus = agentSpeechMuted ? "Agent speech muted" : "Agent speech enabled"
    }

    func toggleMute(targetID: String) {
        if mutedTargetIDs.contains(targetID) {
            mutedTargetIDs.remove(targetID)
            lastStatus = "Unmuted \(targets.first { $0.id == targetID }?.name ?? targetID)"
        } else {
            mutedTargetIDs.insert(targetID)
            lastStatus = "Muted \(targets.first { $0.id == targetID }?.name ?? targetID)"
        }
    }

    /// Live sessions and everything waiting on the user, ready for the HUD.
    var hudModel: AgentHUDModel {
        let now = Date()
        return AgentHUDModel(
            sessions: Array(sessionPresence.values.filter { !$0.isExpired(at: now) }),
            attention: attention,
            mutedTargetIDs: mutedTargetIDs,
            now: now
        )
    }

    /// Records that an agent did something. Only observed activity creates
    /// presence, so a configured-but-silent target never appears live and the
    /// recency ordering reflects real timestamps.
    private func noteAgentActivity(_ target: TargetDefinition, spokenToByUser: Bool = false) {
        let now = Date()
        let existing = sessionPresence[target.id]
        sessionPresence[target.id] = SessionPresence(
            target: target,
            status: targetStatuses[target.id] ?? .ready,
            lastActiveAt: now,
            lastUserInteractionAt: spokenToByUser ? now : existing?.lastUserInteractionAt,
            expiresAt: now.addingTimeInterval(SessionPresence.liveWindow)
        )
    }
    private func refreshOutbox() async { outboxEntries = await delivery.outboxEntries() }

    private func handleDrainedQueue(_ outcome: DeliveryOutcome, target: TargetDefinition) async {
        switch outcome {
        case .delivered: lastStatus = "Sent queued message to \(target.name)"
        case .copied: lastStatus = "Copied queued message for \(target.name)"
        case .queued: break
        case .confirmationRequired: lastStatus = "Queued message still needs confirmation"
        case .outboxed(let entry): lastStatus = "Queued delivery failed: \(entry.failure)"
        }
    }

    private func handleResolvedQueue(_ outcome: DeliveryOutcome, target: TargetDefinition) async {
        switch outcome {
        case .queued:
            lastStatus = "Queued for \(target.name)"; presentOverlay(.queued(target: target.name))
        case .outboxed(let entry):
            lastStatus = "Kept older queue; new transcript moved to Outbox"
            presentOverlay(.error(message: entry.failure)); await refreshOutbox()
        case .delivered, .copied: await handleDrainedQueue(outcome, target: target)
        case .confirmationRequired: break
        }
    }

    func retryOutbox(_ entry: OutboxEntry) {
        guard let targetID = entry.intendedTargetID, let target = targets.first(where: { $0.id == targetID }) else {
            lastStatus = "Original target no longer exists"; return
        }
        Task {
            let snapshot = RecordingTargetSnapshot(target: target, source: .activeSelection)
            if let outcome = await delivery.retryOutbox(id: entry.id, to: snapshot) {
                await handleDrainedQueue(outcome, target: target)
            }
            await refreshOutbox()
        }
    }

    func copyOutbox(_ entry: OutboxEntry) {
        Task {
            guard let text = await delivery.textForCopy(id: entry.id) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            lastStatus = "Copied failed transcript"
        }
    }

    func discardOutbox(_ entry: OutboxEntry) {
        Task { await delivery.discardOutbox(id: entry.id); await refreshOutbox() }
    }

    func editOutbox(_ entry: OutboxEntry) {
        let alert = NSAlert(); alert.messageText = "Edit failed transcript"
        alert.informativeText = entry.failure; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 150)); scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds); textView.string = entry.text; textView.isEditable = true; textView.font = .systemFont(ofSize: 13)
        scroll.documentView = textView; alert.accessoryView = scroll; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await delivery.editOutbox(id: entry.id, text: textView.string); await refreshOutbox() }
    }
    func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: MiriPaths.configPath)) }

    /// True once a dictation target exists in the configuration.
    var hasCursorTarget: Bool {
        targets.contains { $0.adapter == "cursor" || $0.adapter == "focused-app" }
    }

    /// Adds the "type where my cursor is" target and prompts for the
    /// Accessibility permission it needs. Kept as a one-click action because
    /// hand-editing config.toml is the wrong first experience for dictation.
    func addCursorTarget() {
        guard !hasCursorTarget else {
            lastStatus = "Dictation target already exists"
            return
        }
        let target = TargetDefinition(
            id: "cursor",
            name: "Cursor (type where I'm focused)",
            adapter: "cursor"
        )
        currentConfiguration.targets.append(target)
        Task {
            do {
                try await configurationStore.write(currentConfiguration)
                lastStatus = AccessibilityPermission.isGranted
                    ? "Dictation target added"
                    : "Dictation target added. Grant Accessibility so Miri can type."
                // Prompts only when not already trusted; macOS ignores repeats.
                AccessibilityPermission.requestIfNeeded()
            } catch {
                lastStatus = "Could not add the dictation target: \(error.localizedDescription)"
            }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestMicrophone() { Task { microphonePermission = await MicrophonePermissions.request() } }
    func openMicrophoneSettings() { MicrophonePermissions.openSystemSettings() }
    func openLogs() {
        logger.log("logs opened by user")
        NSWorkspace.shared.open(MiriPaths.logsDirectory)
    }
    func deleteDownloadedModels() {
        let alert = NSAlert(); alert.messageText = "Delete downloaded speech models?"
        alert.informativeText = "Removes the Parakeet transcription model and the PocketTTS voice, about 1 GB in total. Speech stops until you install them again. Configuration remains."
        alert.addButton(withTitle: "Delete Models"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await parakeet.unload()
            await synth.unload()
            do {
                if FileManager.default.fileExists(atPath: MiriPaths.modelsDirectory.path) { try FileManager.default.removeItem(at: MiriPaths.modelsDirectory) }
                // The CoreML bundles live outside MiriPaths, under two
                // different FluidAudio roots. Both must go or this action
                // silently leaves most of a gigabyte behind.
                try ParakeetTranscriber.removeDownloadedModels()
                try FluidSpeechSynthesizer.removeDownloadedModels()
                parakeetInstalled = false; voiceInstalled = false
                speechHealth = "Models deleted"; lastStatus = "Models deleted. Reinstall models, then restart Miri."
                logger.log("downloaded models deleted by user")
            } catch { lastStatus = "Could not delete models: \(error.localizedDescription)"; logger.log(.error, lastStatus) }
        }
    }
    func installModels() { installSpeechModels() }
    func resetAllData() {
        let alert = NSAlert(); alert.messageText = "Reset all Miri data?"
        alert.informativeText = "Deletes configuration, models, caches, logs, and onboarding state. Miri then quits. This cannot be undone."
        alert.addButton(withTitle: "Reset and Quit"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await configurationStore.stopWatching()
            await parakeet.unload(); await synth.unload()
            for url in [MiriPaths.applicationSupport, MiriPaths.cachesDirectory, MiriPaths.logsDirectory, URL(fileURLWithPath: MiriPaths.configPath).deletingLastPathComponent()] {
                try? FileManager.default.removeItem(at: url)
            }
            // FluidAudio keeps its CoreML bundles in its own directory.
            try? ParakeetTranscriber.removeDownloadedModels()
            try? FluidSpeechSynthesizer.removeDownloadedModels()
            UserDefaults.standard.removeObject(forKey: "didCompleteOnboarding")
            NSApplication.shared.terminate(nil)
        }
    }
    func copyLastAgentResponse() {
        guard let lastAgentResponse else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastAgentResponse, forType: .string)
        lastStatus = "Copied the full agent response"
    }
    func showLastAgentResponse() {
        guard let lastAgentResponse else { return }
        let alert = NSAlert()
        alert.messageText = lastAgentName.map { "Last response from \($0)" } ?? "Last agent response"
        alert.informativeText = "The complete response is shown below. Miri keeps it only in memory."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Copy Response")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = lastAgentResponse; textView.isEditable = false; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView; alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { copyLastAgentResponse() }
    }
    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didCompleteOnboarding"), onboardingWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Miri"; window.center(); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MiriOnboardingHost(controller: self) { [weak self, weak window] in
            UserDefaults.standard.set(true, forKey: "didCompleteOnboarding"); window?.close(); self?.onboardingWindow = nil
        })
        onboardingWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func shutdown() {
        logger.log("application shutting down")
        agentCompletionTimeoutTasks.values.forEach { $0.cancel() }
        capture.stop(); hotkeys?.shutdown(); server?.stop()
        Task {
            await adapterRegistry.disconnectAll()
            await configurationStore.stopWatching()
            NSApplication.shared.terminate(nil)
        }
    }
    private func speechFinished() {
        speechTimeoutTask?.cancel(); speechTimeoutTask = nil; speechSessionID = nil
        speechInterruptible = true; speechPriority = 0; state = machine.handle(.speechFinished)
        if let prompt = pendingAgentPrompt { presentOverlay(.needsInput(label: prompt)) }
        else { overlay.hide() }
    }
    private func dismissOverlay(after delay: TimeInterval) {
        overlayDismissTask?.cancel()
        overlayDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.overlay.hide()
        }
    }
    private func transitionOverlay(to state: StatusOverlayState, after delay: TimeInterval) {
        overlayDismissTask?.cancel()
        overlayDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.presentOverlay(state)
        }
    }
    private func presentOverlay(_ state: StatusOverlayState) {
        overlayDismissTask?.cancel(); overlayDismissTask = nil
        overlay.show(state)
    }
}

private struct MiriOnboardingHost: View {
    @ObservedObject var controller: AppController
    @State private var step: FirstRunStep = .welcome
    let finish: () -> Void
    var body: some View {
        MiriOnboardingView(
            step: $step,
            microphonePermission: controller.microphonePermission,
            hotkey: $controller.activeHotkey,
            inputMode: $controller.inputMode,
            targets: controller.targets,
            actions: .init(
                requestMicrophoneAccess: controller.requestMicrophone,
                openMicrophoneSettings: controller.openMicrophoneSettings,
                openConfiguration: controller.openConfig,
                openLogs: controller.openLogs,
                saveActiveHotkey: controller.saveActiveHotkey,
                setInputMode: controller.setInputMode,
                installModels: controller.installModels
            ),
            finish: finish
        )
    }
}

@main struct MiriApplication: App {
    @StateObject private var controller = AppController()
    var body: some Scene {
        MenuBarExtra("Miri", systemImage: "waveform") {
            Text(controller.lastStatus).lineLimit(4).frame(maxWidth: 360)
            Text(String(describing: controller.state).capitalized).font(.caption).foregroundStyle(.secondary)
            if let diagnostics = controller.audioDiagnostics { Text(diagnostics).font(.caption2).foregroundStyle(.secondary) }
            if let response = controller.lastAgentResponse {
                Text("Full agent response available (\(response.count) characters)").font(.caption).foregroundStyle(.secondary)
                Button("Show Full Agent Response…") { controller.showLastAgentResponse() }
                Button("Copy Full Agent Response") { controller.copyLastAgentResponse() }
            }
            if let prompt = controller.pendingAgentPrompt {
                Label(prompt, systemImage: "questionmark.bubble.fill").lineLimit(3)
                Text("Hold \(controller.activeHotkey) to answer the same agent thread.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Menu("Active Target") {
                if controller.targets.isEmpty { Text("No targets configured") }
                ForEach(controller.targets) { target in
                    Button { controller.selectTarget(target.id) } label: {
                        Label("\(target.name) — \(controller.targetStatuses[target.id]?.rawValue ?? "starting")", systemImage: controller.activeTargetID == target.id ? "checkmark" : "circle")
                    }
                }
            }
            if !controller.outboxEntries.isEmpty {
                Menu("Outbox (\(controller.outboxEntries.count))") {
                    ForEach(controller.outboxEntries) { entry in
                        Menu(entry.failure) {
                            Button("Retry") { controller.retryOutbox(entry) }
                            Button("Edit…") { controller.editOutbox(entry) }
                            Button("Copy") { controller.copyOutbox(entry) }
                            Button("Discard", role: .destructive) { controller.discardOutbox(entry) }
                        }
                    }
                }
            }
            Button(controller.state == .listening ? "Finish Listening" : "Listen Now") { controller.toggleListening() }
            if controller.state == .speaking { Button("Stop Speaking") { controller.cancel() }.keyboardShortcut(.escape, modifiers: []) }
            Divider()
            AgentSessionsMenu(controller: controller)
            Divider()
            Menu("Input Mode") {
                ForEach(MiriInputMode.supportedCases) { mode in
                    Button { controller.setInputMode(mode) } label: {
                        Label(mode.displayName, systemImage: controller.inputMode == mode ? "checkmark" : "circle")
                    }
                }
            }
            Button(controller.agentSpeechMuted ? "Enable Agent Speech" : "Mute Agent Speech") { controller.toggleAgentSpeech() }
            Divider()
            SettingsLink { Text("Open Settings…") }
            Button("Open Config File") { controller.openConfig() }
            Button("View Logs") { controller.openLogs() }
            if controller.microphonePermission == .denied { Button("Open Microphone Settings") { controller.openMicrophoneSettings() } }
            Button("Quit Miri") { controller.shutdown() }
        }
        Settings {
            MiriSettingsView(
                microphonePermission: controller.microphonePermission,
                activeHotkey: $controller.activeHotkey,
                inputMode: $controller.inputMode,
                    targets: controller.targets,
                codexThreads: controller.codexThreads,
                isRefreshingCodexThreads: controller.isRefreshingCodexThreads,
                speechHealth: controller.speechHealth,
                codexIntegrationStatus: controller.codexIntegrationStatus,
                activeTargetID: $controller.activeTargetID,
                sttBackend: $controller.sttBackend,
                sttTestStatus: controller.sttTestStatus,
                parakeetInstalled: controller.parakeetInstalled,
                voiceInstalled: controller.voiceInstalled,
                isInstallingParakeet: controller.isInstallingParakeet,
                hasCursorTarget: controller.hasCursorTarget,
                accessibilityGranted: AccessibilityPermission.isGranted,
                actions: .init(
                    requestMicrophoneAccess: controller.requestMicrophone,
                    openMicrophoneSettings: controller.openMicrophoneSettings,
                    openConfiguration: controller.openConfig,
                    openLogs: controller.openLogs,
                    refreshCodexThreads: { Task { await controller.refreshCodexThreads() } },
                    addCodexThread: controller.addCodexThread,
                    installCodexIntegration: controller.installCodexIntegration,
                    saveActiveHotkey: controller.saveActiveHotkey,
                    setInputMode: controller.setInputMode,
                        installModels: controller.installModels,
                    deleteModels: controller.deleteDownloadedModels,
                    resetAllData: controller.resetAllData,
                    saveSTTSettings: controller.saveSTTSettings,
                    installParakeetModels: controller.installParakeetModels,
                    addCursorTarget: controller.addCursorTarget,
                    openAccessibilitySettings: controller.openAccessibilitySettings
                )
            )
        }
    }
}
