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
    @Published var modelProfile: ModelLifecycleProfile = .responsive
    @Published var audioDiagnostics: String?
    @Published var targetStatuses: [String: TargetStatus] = [:]
    @Published var lastAgentResponse: String?
    @Published var lastAgentName: String?
    @Published var codexThreads: [CodexThreadSummary] = []
    @Published var isRefreshingCodexThreads = false
    @Published var activeHotkey = "option+space"
    @Published var agentSpeechMuted = false
    @Published var outboxEntries: [OutboxEntry] = []
    @Published var speechHealth = "Speech worker starting"
    private var machine = InteractionMachine()
    private let policy = StatusPolicy()
    private let configurationStore = ConfigurationStore()
    private let worker = WorkerClient()
    private let capture = MicrophoneCapture()
    private let recordingBuffer = RecordingBuffer()
    private let audioPipe = AudioChunkPipe()
    private let pcmPlayer = try? SpeechPCMPlayer()
    private let overlay = StatusOverlayController()
    private let adapterRegistry = AdapterRegistry()
    private let logger = MiriLogger()
    private let performance = PerformanceRecorder()
    private let launchStartedAt = Date()
    private lazy var delivery = DeliveryCoordinator(adapters: adapterRegistry)
    private let synthesizer = AVSpeechSynthesizer()
    private lazy var speechDelegate = SpeechDelegate { [weak self] in Task { @MainActor in self?.speechFinished() } }
    private var server: ControlSocketServer?
    private var hotkeys: GlobalHotKeyController?
    private var hotkeyNames: [UInt32: String] = [:]
    private var router = TargetRouter(registry: .init(targets: []))
    private var currentConfiguration = MiriConfiguration()
    private var recordingSnapshot: RecordingTargetSnapshot?
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
    private var wakeSessionID: String?
    private var wakeUtterance = false
    private var wakeTimeoutTask: Task<Void, Never>?
    private var workerEventTask: Task<Void, Never>?
    private var lastWorkerEnvironment: [String: String]?
    private var hotkeyPressedAt: Date?
    private var recordingReleasedAt: Date?
    private var speechRequestedAt: Date?
    private var hotkeyIsHeld = false
    private var listeningAttemptID: UUID?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var speechTimeoutTask: Task<Void, Never>?

    override init() {
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
        await startWorker()
    }

    private func startWorker() async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/miri-worker")
        let development = root.appending(path: "Worker/.venv/bin/miri-worker")
        let executable = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : development
        let workerDirectory = executable == bundled ? Bundle.main.resourceURL : root.appending(path: "Worker")
        if FileManager.default.isExecutableFile(atPath: executable.path) {
            do {
                let environment = workerEnvironment()
                try await worker.start(executable: executable, workingDirectory: workerDirectory, environment: environment)
                lastWorkerEnvironment = environment
                workerEventTask?.cancel()
                workerEventTask = Task { [weak self] in guard let self else { return }; for await frame in worker.events() { await self.handleWorkerFrame(frame) } }
                _ = try await worker.sendJSON(.hello, body: ["peer": "Miri.app"])
                _ = try await worker.sendJSON(.health, body: EmptyBody())
                _ = try await worker.sendJSON(.modelStatus, body: EmptyBody())
                logger.log("speech worker started")
                performance.record("cold_start_ms", milliseconds: Date().timeIntervalSince(launchStartedAt) * 1_000)
                if inputMode == .wakeWord { await startWakeMonitoring() }
            } catch { lastStatus = "Worker unavailable: \(error.localizedDescription)"; logger.log(.error, lastStatus) }
        } else { lastStatus = "Worker missing. Run make bootstrap."; logger.log(.error, lastStatus) }
    }

    private func restartWorker() async {
        await stopWakeMonitoring(); capture.stop(); audioPipe.finish()
        workerEventTask?.cancel(); workerEventTask = nil
        await worker.stop(); speechHealth = "Restarting speech worker…"
        await startWorker()
    }

    private func apply(_ configuration: MiriConfiguration) {
        let previousDefault = currentConfiguration.defaultTarget
        currentConfiguration = configuration
        targets = configuration.targets
        let enabledTargetIDs = Set(configuration.targets.filter(\.enabled).map(\.id))
        if activeTargetID == nil || !enabledTargetIDs.contains(activeTargetID!) || activeTargetID == previousDefault {
            activeTargetID = configuration.defaultTarget
        }
        inputMode = MiriInputMode(rawValue: configuration.inputMode) ?? .pushToTalk
        if case .string(let value)? = configuration.sections["hotkeys"]?["active_target"] { activeHotkey = value }
        else { activeHotkey = "option+space" }
        configureHotkeys(for: configuration.targets.filter(\.enabled))
        if case .string(let profile)? = configuration.sections["audio"]?["profile"] { modelProfile = ModelLifecycleProfile(rawValue: profile) ?? .responsive }
        if case .string(let display)? = configuration.sections["ui"]?["display"], let id = UInt32(display) { overlay.setPinnedDisplay(id) }
        else { overlay.setPinnedDisplay(nil) }
        switch configuration.sections["audio"]?["speech_volume"] {
        case .number(let value)?: pcmPlayer?.volume = Float(value)
        case .integer(let value)?: pcmPlayer?.volume = Float(value)
        default: break
        }
        router = TargetRouter(registry: .init(targets: configuration.targets), defaultTargetID: configuration.defaultTarget)
        reconfigureAdapters(configuration.targets.filter(\.enabled))
        if let lastWorkerEnvironment, lastWorkerEnvironment != workerEnvironment() {
            Task { await restartWorker() }
        }
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
        switch event {
        case .status(let status):
            targetStatuses[target.id] = status
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
        case .completed:
            completeAgentTurn(target)
        case .failed(let message):
            agentCompletionTimeoutTasks.removeValue(forKey: target.id)?.cancel()
            responseBuffers.removeValue(forKey: target.id); finalResponses.removeValue(forKey: target.id)
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
        lastStatus = "\(target.name) completed successfully"
        logger.log("agent turn completed target=\(target.id) response_characters=\(response.count)")
        if shouldSpeakAgentResponses, let spoken = AgentSpeechFormatter.spokenText(from: response, maxCharacters: agentSpeechLimit) {
            Task { await self.speakAgentResponse(spoken, target: target.name) }
        } else {
            presentOverlay(.delivered(target: target.name)); dismissOverlay(after: 1.2)
        }
        Task {
            if let outcome = await delivery.drainQueue(for: target.id) { await handleDrainedQueue(outcome, target: target) }
            await refreshOutbox()
        }
    }

    private func workerEnvironment() -> [String: String] {
        func string(_ section: String, _ key: String) -> String? { if case .string(let value)? = currentConfiguration.sections[section]?[key] { return value }; return nil }
        func bool(_ section: String, _ key: String) -> Bool? { if case .boolean(let value)? = currentConfiguration.sections[section]?[key] { return value }; return nil }
        func number(_ section: String, _ key: String) -> Double? {
            switch currentConfiguration.sections[section]?[key] { case .number(let value)?: return value; case .integer(let value)?: return Double(value); default: return nil }
        }
        var environment: [String: String] = [:]
        environment["MIRI_PROFILE"] = modelProfile.rawValue
        if let value = string("stt", "provider") { environment["MIRI_STT_PROVIDER"] = value }
        if let value = string("tts", "provider") { environment["MIRI_TTS_PROVIDER"] = value }
        if let value = string("vad", "provider") { environment["MIRI_VAD_PROVIDER"] = value }
        if let value = string("wakeword", "provider") { environment["MIRI_WAKE_WORD_PROVIDER"] = value }
        if let value = string("stt", "model_path") { environment["MIRI_PROVIDER_MOONSHINE_MODEL_PATH"] = expand(value) }
        if case .integer(let value)? = currentConfiguration.sections["stt"]?["model_arch"] { environment["MIRI_PROVIDER_MOONSHINE_MODEL_ARCH"] = String(value) }
        if let value = string("tts", "config_path") { environment["MIRI_PROVIDER_POCKET_TTS_CONFIG_PATH"] = expand(value) }
        if let value = string("tts", "language") { environment["MIRI_PROVIDER_POCKET_TTS_LANGUAGE"] = value }
        if let value = string("tts", "voice_path") ?? string("tts", "voice") { environment["MIRI_PROVIDER_POCKET_TTS_VOICE"] = expand(value) }
        if bool("tts", "allow_model_downloads") == true { environment["MIRI_PROVIDER_ALLOW_MODEL_DOWNLOADS"] = "true" }
        if let value = string("wakeword", "model_path") { environment["MIRI_PROVIDER_OPENWAKEWORD_MODEL_PATHS"] = expand(value) }
        if let value = number("vad", "threshold") { environment["MIRI_PROVIDER_SILERO_THRESHOLD"] = String(value) }
        if let value = number("wakeword", "threshold") { environment["MIRI_PROVIDER_OPENWAKEWORD_THRESHOLD"] = String(value) }
        if let value = string("models", "manifest_path") { environment["MIRI_MODEL_MANIFEST"] = expand(value) }
        else if let bundledManifest = Bundle.main.resourceURL?.appending(path: "model-manifest.json"), FileManager.default.fileExists(atPath: bundledManifest.path) {
            environment["MIRI_MODEL_MANIFEST"] = bundledManifest.path
        } else {
            let developmentManifest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Worker/models/model-manifest.json")
            if FileManager.default.fileExists(atPath: developmentManifest.path) {
                environment["MIRI_MODEL_MANIFEST"] = developmentManifest.path
            }
        }
        if let value = string("models", "directory") { environment["MIRI_MODELS_DIRECTORY"] = expand(value) }
        else { environment["MIRI_MODELS_DIRECTORY"] = MiriPaths.modelsDirectory.path }
        // Pocket TTS uses Hugging Face's cache internally. Keep that cache within
        // Miri's removable Application Support model directory rather than ~/.cache.
        environment["HF_HOME"] = MiriPaths.modelsDirectory.appending(path: "huggingface").path
        return environment
    }

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

    private func makeAdapter(for target: TargetDefinition) -> (any AgentAdapter)? {
        let workingDirectory = target.workingDirectory.map { URL(fileURLWithPath: expand($0)) } ?? FileManager.default.homeDirectoryForCurrentUser
        switch target.adapter {
        case "clipboard": return ClipboardAdapter(id: target.id)
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appending(path: ".local/bin/\(name)"), URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"), URL(fileURLWithPath: "/usr/local/bin/\(name)")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func hotKeyEvent(_ event: GlobalHotKeyEvent) {
        switch event {
        case .pressed(let identifier):
            guard !hotkeyIsHeld else { return }
            hotkeyIsHeld = true; hotkeyPressedAt = .now
            let attempt = UUID(); listeningAttemptID = attempt
            Task {
            await stopWakeMonitoring()
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

    private func beginListening(dedicatedHotkey: String? = nil, triggeredByWakeWord: Bool = false, attemptID: UUID? = nil) async {
        let requiresHeldHotkey = !triggeredByWakeWord && attemptID != nil
        if !triggeredByWakeWord {
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
            if let session = speechSessionID { _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session) }
            pcmPlayer?.stop(); speechSessionID = nil; speechInterruptible = true
        }
        let workerState = await worker.state
        guard workerState == .running else {
            let diagnostic = await worker.diagnostic
            let message: String
            switch workerState {
            case .starting: message = "Speech models are still warming up"
            case .failed(let reason): message = diagnostic ?? reason
            default: message = "Speech worker is not running. Run make models-dev, then restart Miri."
            }
            lastStatus = message; presentOverlay(.error(message: message)); dismissOverlay(after: 2); return
        }
        microphonePermission = await MicrophonePermissions.request()
        guard microphonePermission == .granted else { lastStatus = "Microphone access is required"; presentOverlay(.error(message: lastStatus)); return }
        if requiresHeldHotkey {
            guard hotkeyIsHeld, listeningAttemptID == attemptID else { return }
        }
        do { recordingSnapshot = try router.snapshot(dedicatedHotkey: dedicatedHotkey, activeTargetID: activeTargetID) }
        catch { recordingSnapshot = nil }
        let session = UUID().uuidString; recordingSessionID = session; wakeUtterance = triggeredByWakeWord
        recordingBuffer.reset()
        do {
            _ = try await worker.sendJSON(
                .audioStart,
                body: AudioStartBody(vadEndpointing: triggeredByWakeWord, minimumSilenceMilliseconds: vadMinimumSilenceMilliseconds),
                sessionID: session
            )
            if requiresHeldHotkey, (!hotkeyIsHeld || listeningAttemptID != attemptID) {
                _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session)
                recordingSessionID = nil; recordingSnapshot = nil
                return
            }
            let stream = audioPipe.open()
            audioSenderTask = Task { [worker] in
                do {
                    for await data in stream {
                        _ = try await worker.send(messageType: .audioChunk, sessionID: session, payload: data, kind: .pcmFloat32)
                    }
                } catch { await MainActor.run { self.fail(error) } }
            }
            try capture.start { [recordingBuffer, audioPipe] chunk in
                let data = chunk.samples.withUnsafeBytes { Data($0) }
                recordingBuffer.append(data)
                audioPipe.yield(data)
            } onError: { [weak self] error in Task { @MainActor in self?.fail(error) } }
            state = machine.handle(.pressToTalk); hotkeys?.enableEscapeCancellation(true)
            let target = recordingSnapshot?.target.name ?? "No target"
            lastStatus = "Listening for \(target)"; presentOverlay(.listening(target: target))
            if let hotkeyPressedAt {
                performance.record("overlay_response_ms", milliseconds: Date().timeIntervalSince(hotkeyPressedAt) * 1_000, sessionID: session)
                self.hotkeyPressedAt = nil
            }
            if triggeredByWakeWord {
                wakeTimeoutTask?.cancel()
                wakeTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.wakeUtteranceTimeoutSeconds ?? 20))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.endListening() }
                }
            }
        } catch { fail(error) }
    }

    private func endListening() {
        guard state == .listening, let session = recordingSessionID else { return }
        listeningAttemptID = nil
        capture.stop(); audioPipe.finish(); wakeTimeoutTask?.cancel(); wakeTimeoutTask = nil; recordingReleasedAt = .now
        state = machine.handle(.releaseToTalk); hotkeys?.enableEscapeCancellation(false)
        presentOverlay(.transcribing(target: recordingSnapshot?.target.name ?? "No target"))
        let audio = recordingBuffer.take()
        if let metrics = AudioSignalMetrics.analyze(float32LE: audio) {
            audioDiagnostics = String(format: "Audio %.1fs · RMS %.3f · peak %.2f", metrics.durationSeconds, metrics.rms, metrics.peak)
            if let warning = metrics.qualityMessage {
                audioSenderTask?.cancel(); audioSenderTask = nil
                recordingSessionID = nil; recordingSnapshot = nil; recordingReleasedAt = nil
                Task { _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session) }
                lastStatus = warning; state = machine.handle(.failure(warning)); presentOverlay(.error(message: warning)); dismissOverlay(after: 2)
                return
            }
        }
        let sender = audioSenderTask; audioSenderTask = nil
        Task {
            do {
                await sender?.value
                _ = try await worker.sendJSON(.audioStop, body: EmptyBody(), sessionID: session)
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

    private func handleWorkerFrame(_ frame: IPCFrame) async {
        if frame.header.messageType == MessageType.error.rawValue,
           let value = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] {
            let message = value["detail"] as? String ?? value["message"] as? String ?? "Speech worker error"
            if frame.header.sessionID == wakeSessionID { wakeSessionID = nil }
            fail(NSError(domain: "MiriSpeechWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            return
        }
        if frame.header.messageType == MessageType.wakeDetected.rawValue,
           frame.header.sessionID == wakeSessionID {
            await activateWakeUtterance()
            return
        }
        if frame.header.messageType == MessageType.audioEndpoint.rawValue,
           frame.header.sessionID == recordingSessionID,
           wakeUtterance, state == .listening {
            endListening()
            return
        }
        if frame.header.messageType == "response",
           let value = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
           value["operation"] as? String == MessageType.health.rawValue {
            let stt = value["stt"] as? [String: Any]; let tts = value["tts"] as? [String: Any]
            let sttReady = stt?["ready"] as? Bool == true; let ttsReady = tts?["ready"] as? Bool == true
            speechHealth = "STT \(sttReady ? "ready" : "not ready") · TTS \(ttsReady ? "ready" : "not ready")"
            return
        }
        if frame.header.messageType == "response",
           let value = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
           let operation = value["operation"] as? String,
           operation == MessageType.modelInstall.rawValue || operation == MessageType.modelStatus.rawValue {
            if operation == MessageType.modelInstall.rawValue {
                let installed = value["installed"] as? [String] ?? []
                speechHealth = installed.isEmpty ? "No managed models required" : "Installed \(installed.count) model artifact(s)"
                _ = try? await worker.sendJSON(.health, body: EmptyBody())
            } else if value["configured"] as? Bool == false {
                speechHealth = "Managed model manifest not configured; using local provider paths"
            }
            return
        }
        if frame.header.messageType == MessageType.modelProgress.rawValue,
           let progress = try? JSONDecoder().decode(ModelProgressBody.self, from: frame.payload) {
            let total = progress.totalBytes.map { " / \($0)" } ?? ""
            speechHealth = "Downloading \(progress.model): \(progress.downloadedBytes)\(total) bytes"
            return
        }
        if frame.header.messageType == MessageType.speechChunk.rawValue {
            if let speechRequestedAt {
                performance.record("first_audio_ms", milliseconds: Date().timeIntervalSince(speechRequestedAt) * 1_000, sessionID: frame.header.sessionID)
                self.speechRequestedAt = nil
            }
            do { try pcmPlayer?.enqueuePCMBytes(frame.payload) } catch { fail(error) }
            return
        }
        if frame.header.messageType == MessageType.speechStop.rawValue {
            guard frame.header.sessionID == speechSessionID else { return }
            speechTimeoutTask?.cancel(); speechTimeoutTask = nil
            speechSessionID = nil; speechInterruptible = true; speechPriority = 0
            if let pcmPlayer { pcmPlayer.finishWhenDrained { [weak self] in self?.speechFinished() } }
            else { speechFinished() }
            return
        }
        guard frame.header.messageType == MessageType.transcriptFinal.rawValue,
              frame.header.sessionID == recordingSessionID,
              let value = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
              let text = value["text"] as? String else { return }
        recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        if let recordingReleasedAt {
            performance.record("final_transcript_ms", milliseconds: Date().timeIntervalSince(recordingReleasedAt) * 1_000, sessionID: frame.header.sessionID)
            self.recordingReleasedAt = nil
        }
        state = machine.handle(.transcriptReady)
        guard let snapshot = recordingSnapshot else {
            lastStatus = "No target configured. Transcript: \(text)"; presentOverlay(.error(message: "No target configured")); state = .failed("No target"); return
        }
        let sendingLabel = showTranscriptPreview ? "\(snapshot.target.name) · \(String(text.prefix(80)))" : snapshot.target.name
        presentOverlay(.sending(target: sendingLabel))
        let outcome = await delivery.deliver(text, to: snapshot)
        switch outcome {
        case .delivered:
            lastStatus = "Delivered to \(snapshot.target.name); waiting for response"
            logger.log("transcript delivered target=\(snapshot.target.id)")
            presentOverlay(.delivered(target: snapshot.target.name)); transitionOverlay(to: .waiting(target: snapshot.target.name), after: 0.65); state = machine.handle(.delivered)
        case .copied:
            lastStatus = "Copied for \(snapshot.target.name)"
            logger.log("transcript copied target=\(snapshot.target.id)")
            presentOverlay(.delivered(target: snapshot.target.name)); state = machine.handle(.delivered)
        case .queued:
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
        if inputMode == .wakeWord { await startWakeMonitoring(after: 1.1) }
    }

    private func fail(_ error: Error) {
        capture.stop(); audioPipe.finish(); audioSenderTask?.cancel(); audioSenderTask = nil
        wakeTimeoutTask?.cancel(); wakeTimeoutTask = nil; recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        speechTimeoutTask?.cancel(); speechTimeoutTask = nil; hotkeyPressedAt = nil; recordingReleasedAt = nil; speechRequestedAt = nil; lastStatus = error.localizedDescription
        hotkeyIsHeld = false; listeningAttemptID = nil
        let recording = recordingSessionID; let speech = speechSessionID; let wake = wakeSessionID
        recordingSessionID = nil; recordingSnapshot = nil; speechSessionID = nil; wakeSessionID = nil
        if let recording { Task { _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: recording) } }
        if let speech { Task { _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: speech) } }
        if let wake { Task { _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: wake) } }
        logger.log(.error, "interaction failed: \(error.localizedDescription)")
        state = machine.handle(.failure(error.localizedDescription)); presentOverlay(.error(message: error.localizedDescription))
        dismissOverlay(after: 2)
    }

    func speak(_ request: VoiceStatusRequest) async -> ControlResponse {
        do { try await policy.validate(request) }
        catch { lastStatus = error.localizedDescription; return .init(accepted: false, message: error.localizedDescription) }
        speechRequestedAt = .now
        if synthesizer.isSpeaking {
            guard speechInterruptible && request.priority > speechPriority else { return .init(accepted: false, message: "A status of equal or higher priority is already speaking") }
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let session = speechSessionID {
            guard speechInterruptible && request.priority > speechPriority else { return .init(accepted: false, message: "A status of equal or higher priority is already speaking") }
            _ = try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session); pcmPlayer?.stop()
        }
        return await startSpeech(request.text, target: "Agent", interruptible: request.interruptible, priority: request.priority)
    }

    private func speakAgentResponse(_ text: String, target: String) async {
        guard state == .idle, speechSessionID == nil, !synthesizer.isSpeaking else {
            logger.log(.warning, "agent response speech skipped because audio interaction is active")
            return
        }
        _ = await startSpeech(text, target: target, interruptible: true, priority: 0)
    }

    private func startSpeech(_ text: String, target: String, interruptible: Bool, priority: Int) async -> ControlResponse {
        lastStatus = "Speaking response from \(target)"; state = machine.handle(.speechStarted)
        presentOverlay(.speaking(target: target))
        let session = UUID().uuidString; speechSessionID = session; speechInterruptible = interruptible; speechPriority = priority
        do {
            _ = try await worker.sendJSON(.speechStart, body: SpeechStartBody(text: text), sessionID: session)
            speechTimeoutTask?.cancel()
            speechTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.speechSessionID == session else { return }
                    self?.fail(NSError(domain: "MiriSpeechWorker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech playback timed out; the session was reset"]))
                }
            }
            return .init(accepted: true, message: "Status queued")
        } catch {
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
        wakeTimeoutTask?.cancel(); wakeTimeoutTask = nil; recordingTimeoutTask?.cancel(); recordingTimeoutTask = nil
        speechTimeoutTask?.cancel(); speechTimeoutTask = nil; recordingBuffer.reset()
        hotkeyIsHeld = false; listeningAttemptID = nil
        hotkeyPressedAt = nil; recordingReleasedAt = nil; speechRequestedAt = nil
        if let session = wakeSessionID { Task { try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session) } }
        wakeSessionID = nil
        if let session = recordingSessionID { Task { try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session) } }
        if let session = speechSessionID { Task { try? await worker.sendJSON(.cancel, body: EmptyBody(), sessionID: session) } }
        pcmPlayer?.stop(); speechSessionID = nil; speechInterruptible = true; speechPriority = 0
        recordingSessionID = nil; recordingSnapshot = nil; hotkeys?.enableEscapeCancellation(false)
        state = machine.handle(.cancel); presentOverlay(.cancelled); dismissOverlay(after: 0.25)
        if inputMode == .wakeWord { Task { await startWakeMonitoring(after: 0.5) } }
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
        currentConfiguration.sections["wakeword", default: [:]]["enabled"] = .boolean(mode == .wakeWord)
        Task {
            if mode == .wakeWord { await startWakeMonitoring() }
            else { await stopWakeMonitoring(); overlay.hide(); lastStatus = "Push to talk enabled" }
            do { try await configurationStore.write(currentConfiguration) }
            catch { lastStatus = "Could not save input mode: \(error.localizedDescription)" }
        }
    }
    func setModelProfile(_ profile: ModelLifecycleProfile) {
        modelProfile = profile
        currentConfiguration.sections["audio", default: [:]]["profile"] = .string(profile.rawValue)
        Task {
            do {
                try await configurationStore.write(currentConfiguration)
                lastStatus = "\(profile.displayName) speech profile enabled"
            } catch { lastStatus = "Could not save model profile: \(error.localizedDescription)" }
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

    private var wakeUtteranceTimeoutSeconds: Int {
        if case .integer(let value)? = currentConfiguration.sections["wakeword"]?["utterance_timeout_seconds"] {
            return max(2, min(value, 60))
        }
        return 20
    }

    private var wakeWordIsConfigured: Bool {
        guard case .string(let provider)? = currentConfiguration.sections["wakeword"]?["provider"],
              provider == "openwakeword",
              case .string(let path)? = currentConfiguration.sections["wakeword"]?["model_path"] else { return false }
        return FileManager.default.fileExists(atPath: expand(path))
    }

    private func startWakeMonitoring(after delay: TimeInterval = 0) async {
        guard inputMode == .wakeWord, wakeSessionID == nil, state == .idle else { return }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        guard inputMode == .wakeWord, wakeSessionID == nil, state == .idle else { return }
        guard wakeWordIsConfigured else {
            lastStatus = "Wake word needs a local openWakeWord model path in Settings/config"
            presentOverlay(.error(message: "Wake-word model missing")); dismissOverlay(after: 3)
            return
        }
        microphonePermission = await MicrophonePermissions.request()
        guard microphonePermission == .granted else { lastStatus = "Microphone access is required for wake word"; return }
        guard await worker.state == .running else { lastStatus = "Speech worker is not running"; return }
        let session = UUID().uuidString
        do {
            _ = try await worker.sendJSON(.wakeStart, body: WakeStartBody(), sessionID: session)
            wakeSessionID = session
            let stream = audioPipe.open()
            audioSenderTask = Task { [worker] in
                do {
                    for await data in stream {
                        _ = try await worker.send(messageType: .wakeChunk, sessionID: session, payload: data, kind: .pcmFloat32)
                    }
                } catch { await MainActor.run { self.fail(error) } }
            }
            try capture.start { [audioPipe] chunk in
                audioPipe.yield(chunk.samples.withUnsafeBytes { Data($0) })
            } onError: { [weak self] error in Task { @MainActor in self?.fail(error) } }
            let target = targets.first(where: { $0.id == activeTargetID })?.name ?? "active target"
            lastStatus = "Wake word listening · \(target)"
            presentOverlay(.listening(target: "Wake word · \(target)"))
        } catch {
            wakeSessionID = nil; fail(error)
        }
    }

    private func stopWakeMonitoring() async {
        guard let session = wakeSessionID else { return }
        wakeSessionID = nil; capture.stop(); audioPipe.finish()
        let sender = audioSenderTask; audioSenderTask = nil
        await sender?.value
        _ = try? await worker.sendJSON(.wakeStop, body: EmptyBody(), sessionID: session)
    }

    private func activateWakeUtterance() async {
        guard wakeSessionID != nil else { return }
        await stopWakeMonitoring()
        await beginListening(triggeredByWakeWord: true)
    }
    func toggleAgentSpeech() {
        agentSpeechMuted.toggle()
        if agentSpeechMuted, state == .speaking { cancel() }
        lastStatus = agentSpeechMuted ? "Agent speech muted" : "Agent speech enabled"
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
    func requestMicrophone() { Task { microphonePermission = await MicrophonePermissions.request() } }
    func openMicrophoneSettings() { MicrophonePermissions.openSystemSettings() }
    func openLogs() {
        logger.log("logs opened by user")
        NSWorkspace.shared.open(MiriPaths.logsDirectory)
    }
    func deleteDownloadedModels() {
        let alert = NSAlert(); alert.messageText = "Delete downloaded speech models?"
        alert.informativeText = "Speech features stop until models are installed again. Configuration remains."
        alert.addButton(withTitle: "Delete Models"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await worker.stop()
            do {
                if FileManager.default.fileExists(atPath: MiriPaths.modelsDirectory.path) { try FileManager.default.removeItem(at: MiriPaths.modelsDirectory) }
                speechHealth = "Models deleted"; lastStatus = "Models deleted. Reinstall models, then restart Miri."
                logger.log("downloaded models deleted by user")
            } catch { lastStatus = "Could not delete models: \(error.localizedDescription)"; logger.log(.error, lastStatus) }
        }
    }
    func installModels() {
        let alert = NSAlert(); alert.messageText = "Download local speech models?"
        alert.informativeText = "Miri will download only checksum-pinned artifacts from the configured manifest. Audio and transcripts remain local. Downloads can be resumed."
        alert.addButton(withTitle: "Download Models"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        speechHealth = "Preparing model download…"
        Task {
            do {
                _ = try await worker.sendJSON(.modelInstall, body: ["consent": true])
                currentConfiguration.sections["stt"] = [
                    "provider": .string("moonshine"), "model": .string("small-streaming"),
                    "model_path": .string(MiriPaths.modelsDirectory.appending(path: "moonshine/small-streaming-en").path),
                    "model_arch": .integer(4)
                ]
                currentConfiguration.sections["tts", default: [:]]["provider"] = .string("pocket-tts")
                currentConfiguration.sections["tts", default: [:]]["language"] = .string("english")
                currentConfiguration.sections["tts", default: [:]]["voice"] = .string("alba")
                currentConfiguration.sections["tts", default: [:]]["allow_model_downloads"] = .boolean(true)
                currentConfiguration.sections["vad", default: [:]]["provider"] = .string("silero")
                try await configurationStore.write(currentConfiguration)
                await restartWorker()
                speechHealth = "Local speech models installed"
                lastStatus = "Speech models are ready"
            } catch {
                speechHealth = "Model install failed: \(error.localizedDescription)"
                lastStatus = speechHealth
            }
        }
    }
    func resetAllData() {
        let alert = NSAlert(); alert.messageText = "Reset all Miri data?"
        alert.informativeText = "Deletes configuration, models, caches, logs, and onboarding state. Miri then quits. This cannot be undone."
        alert.addButton(withTitle: "Reset and Quit"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical; NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await worker.stop(); await configurationStore.stopWatching()
            for url in [MiriPaths.applicationSupport, MiriPaths.cachesDirectory, MiriPaths.logsDirectory, URL(fileURLWithPath: MiriPaths.configPath).deletingLastPathComponent()] {
                try? FileManager.default.removeItem(at: url)
            }
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
        capture.stop(); hotkeys?.shutdown(); server?.stop(); Task { await worker.stop(); await configurationStore.stopWatching() }; NSApplication.shared.terminate(nil)
    }
    private func speechFinished() {
        speechTimeoutTask?.cancel(); speechTimeoutTask = nil; speechSessionID = nil
        speechInterruptible = true; speechPriority = 0; state = machine.handle(.speechFinished); overlay.hide()
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
            modelProfile: $controller.modelProfile,
            targets: controller.targets,
            actions: .init(
                requestMicrophoneAccess: controller.requestMicrophone,
                openMicrophoneSettings: controller.openMicrophoneSettings,
                openConfiguration: controller.openConfig,
                openLogs: controller.openLogs,
                saveActiveHotkey: controller.saveActiveHotkey,
                setInputMode: controller.setInputMode,
                setModelProfile: controller.setModelProfile,
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
            Menu("Input Mode") {
                ForEach(MiriInputMode.allCases) { mode in
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
                modelProfile: $controller.modelProfile,
                targets: controller.targets,
                codexThreads: controller.codexThreads,
                isRefreshingCodexThreads: controller.isRefreshingCodexThreads,
                speechHealth: controller.speechHealth,
                activeTargetID: $controller.activeTargetID,
                actions: .init(
                    requestMicrophoneAccess: controller.requestMicrophone,
                    openMicrophoneSettings: controller.openMicrophoneSettings,
                    openConfiguration: controller.openConfig,
                    openLogs: controller.openLogs,
                    refreshCodexThreads: { Task { await controller.refreshCodexThreads() } },
                    addCodexThread: controller.addCodexThread,
                    saveActiveHotkey: controller.saveActiveHotkey,
                    setInputMode: controller.setInputMode,
                    setModelProfile: controller.setModelProfile,
                    installModels: controller.installModels,
                    deleteModels: controller.deleteDownloadedModels,
                    resetAllData: controller.resetAllData
                )
            )
        }
    }
}
