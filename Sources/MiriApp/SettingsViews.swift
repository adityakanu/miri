import MiriCore
import SwiftUI

struct MiriSettingsActions {
    var requestMicrophoneAccess: () -> Void = {}
    var openMicrophoneSettings: () -> Void = {}
    var openConfiguration: () -> Void = {}
    var openLogs: () -> Void = {}
    var refreshCodexThreads: () -> Void = {}
    var addCodexThread: (CodexThreadSummary) -> Void = { _ in }
    var installCodexIntegration: () -> Void = {}
    var saveActiveHotkey: () -> Void = {}
    var setInputMode: (MiriInputMode) -> Void = { _ in }
    var setModelProfile: (ModelLifecycleProfile) -> Void = { _ in }
    var installModels: () -> Void = {}
    var deleteModels: () -> Void = {}
    var resetAllData: () -> Void = {}
    var applySTTPreset: (STTPreset) -> Void = { _ in }
    var saveSTTSettings: () -> Void = {}
    var testSTTConnection: () -> Void = {}
    var removeStoredKey: () -> Void = {}
    var installParakeetModels: () -> Void = {}
}

struct MiriSettingsView: View {
    let microphonePermission: MicrophonePermission
    @Binding var activeHotkey: String
    @Binding var inputMode: MiriInputMode
    @Binding var modelProfile: ModelLifecycleProfile
    let targets: [TargetDefinition]
    let codexThreads: [CodexThreadSummary]
    let isRefreshingCodexThreads: Bool
    let speechHealth: String
    let codexIntegrationStatus: String
    @Binding var activeTargetID: String?
    @Binding var sttBackend: STTBackend
    @Binding var cloudSettings: STTCloudSettings
    @Binding var cloudAPIKey: String
    let cloudKeyIsStored: Bool
    let sttTestStatus: String?
    let isTestingSTT: Bool
    let parakeetInstalled: Bool
    let isInstallingParakeet: Bool
    var configurationError: String?
    var actions = MiriSettingsActions()

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            speech
                .tabItem { Label("Speech", systemImage: "waveform") }
            targetsPane
                .tabItem { Label("Targets", systemImage: "arrow.triangle.branch") }
            privacy
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 470, idealHeight: 560)
        .accessibilityLabel("Miri settings")
    }

    private var speech: some View {
        Form {
            Section("Transcription") {
                Picker("Speech recognition", selection: $sttBackend) {
                    ForEach(STTBackend.supportedCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(sttBackend.detail).font(.caption).foregroundStyle(.secondary)
            }

            if sttBackend == .parakeet {
                Section("On-device model") {
                    HStack {
                        Label(
                            parakeetInstalled ? "Parakeet TDT is installed" : "Parakeet TDT is not installed",
                            systemImage: parakeetInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                        .foregroundStyle(parakeetInstalled ? .green : .primary)
                        Spacer()
                        if !parakeetInstalled {
                            Button(isInstallingParakeet ? "Downloading…" : "Download Model…") {
                                actions.installParakeetModels()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstallingParakeet)
                        }
                    }
                    Text("About 470 MB, downloaded once from Hugging Face. After that Miri transcribes with no network access at all.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if sttBackend == .cloud {
                Section("Provider") {
                    HStack(spacing: 8) {
                        ForEach(STTPreset.all) { preset in
                            Button(preset.name) { actions.applySTTPreset(preset) }
                                .buttonStyle(.bordered)
                                .accessibilityHint(preset.note)
                        }
                    }
                    Text(STTPreset.matching(baseURL: cloudSettings.trimmedBaseURL, model: cloudSettings.trimmedModel).note)
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("API base URL") {
                        TextField("https://api.groq.com/openai/v1", text: $cloudSettings.baseURL)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Model") {
                        TextField("whisper-large-v3-turbo", text: $cloudSettings.model)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API key") {
                        HStack {
                            SecureField(cloudKeyIsStored ? "Stored in Keychain" : "Paste your key", text: $cloudAPIKey)
                                .textFieldStyle(.roundedBorder)
                            if cloudKeyIsStored {
                                Button("Remove", role: .destructive) { actions.removeStoredKey() }
                            }
                        }
                    }
                    Text(cloudKeyIsStored
                         ? "A key is saved in your macOS Keychain. Leave the field blank to keep it."
                         : "The key is saved to your macOS Keychain, never to config.toml. Local servers usually need no key.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Recognition tuning") {
                    LabeledContent("Language") {
                        TextField("en", text: $cloudSettings.language)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    LabeledContent("Vocabulary hint") {
                        TextField("Codex, SwiftUI, AVFoundation", text: $cloudSettings.prompt)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Listing names and jargon you say often makes the model spell them correctly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Save Speech Settings") { actions.saveSTTSettings() }
                        .buttonStyle(.borderedProminent)
                        .disabled((sttBackend == .cloud && !cloudSettings.isValid)
                                  || (sttBackend == .parakeet && !parakeetInstalled))
                    if sttBackend == .cloud {
                        Button(isTestingSTT ? "Testing…" : "Test Connection") { actions.testSTTConnection() }
                            .disabled(isTestingSTT || !cloudSettings.isValid)
                    }
                }
                if let sttTestStatus {
                    Label(sttTestStatus, systemImage: sttTestStatus.hasPrefix("Connected") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(sttTestStatus.hasPrefix("Connected") ? .green : .orange)
                        .font(.caption).textSelection(.enabled)
                }
                Label(speechHealth, systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if sttBackend == .cloud {
                    Label("Utterance audio leaves this Mac and is subject to that provider's terms.", systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var general: some View {
        Form {
            Section("Microphone") {
                MicrophonePermissionRow(permission: microphonePermission, actions: actions)
            }
            Section("Interaction") {
                LabeledContent("Push-to-talk shortcut") {
                    HStack {
                        // A placeholder identical to the current value was
                        // painted behind the editor by AppKit when this row was
                        // compressed, making option+space appear twice. Keep
                        // the placeholder semantic and force a single line.
                        TextField("Shortcut", text: $activeHotkey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .frame(width: 160)
                            .fixedSize(horizontal: true, vertical: false)
                            .onSubmit { actions.saveActiveHotkey() }
                        Button("Save") { actions.saveActiveHotkey() }
                    }
                }
                .accessibilityElement(children: .combine)
                Picker("Input mode", selection: $inputMode) {
                    ForEach(MiriInputMode.supportedCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: inputMode) { _, value in actions.setInputMode(value) }
                Text(inputMode.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech models") {
                Label(speechHealth, systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Install or Repair Models…") { actions.installModels() }
            }
            Section("Files") {
                HStack {
                    Button("Open Configuration") { actions.openConfiguration() }
                        .accessibilityHint("Opens Miri's TOML configuration file")
                    Button("Open Logs") { actions.openLogs() }
                        .accessibilityHint("Opens Miri's local logs folder")
                }
                if let configurationError {
                    Label(configurationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityLabel("Configuration error: \(configurationError)")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var targetsPane: some View {
        Form {
            Section("Codex threads") {
                HStack {
                    Text("Choose exact conversation used by voice commands.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { actions.refreshCodexThreads() } label: {
                        Label(isRefreshingCodexThreads ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshingCodexThreads)
                }
                if codexThreads.isEmpty {
                    Text("No Codex threads loaded. Start Codex, then refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(codexThreads.prefix(20)) { thread in
                        HStack(spacing: 12) {
                            Image(systemName: thread.status == "active" ? "bolt.circle.fill" : "bubble.left.and.bubble.right")
                                .foregroundStyle(thread.status == "active" ? .orange : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(thread.displayName).fontWeight(.medium).lineLimit(1)
                                Text("\(URL(fileURLWithPath: thread.workingDirectory).lastPathComponent) · \(thread.id.prefix(8))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if targets.contains(where: { $0.session == thread.id }) {
                                Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Button("Add Target") { actions.addCodexThread(thread) }
                            }
                        }
                    }
                }
            }
            Section("Codex voice integration") {
                Label(codexIntegrationStatus, systemImage: "waveform.and.mic")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Install or Repair Miri MCP…") { actions.installCodexIntegration() }
                Text("Lets Codex announce progress, blockers, questions, and completion through Miri. Approval requests from Miri-managed threads are handled directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Active target") {
                if targets.isEmpty {
                    ContentUnavailableView(
                        "No Targets Configured",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Add a target to config.toml, then Miri will reload it automatically.")
                    )
                } else {
                    Picker("Target used for the next recording", selection: $activeTargetID) {
                        Text("Use configured default").tag(String?.none)
                        ForEach(targets.filter(\.enabled)) { target in
                            Text(target.name).tag(Optional(target.id))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    ForEach(targets) { target in TargetSummaryRow(target: target, selected: target.id == activeTargetID) }
                }
            }
            Section {
                Button("Edit Targets in Configuration") { actions.openConfiguration() }
                    .keyboardShortcut("e", modifiers: [.command])
                    .accessibilityHint("Opens the configuration file where targets are managed")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var privacy: some View {
        Form {
            Section(sttBackend.isOnDevice ? "Local by design" : "Current setup") {
                if sttBackend == .cloud {
                    Label("Cloud transcription is on: each utterance is uploaded to \(cloudSettings.trimmedBaseURL).", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Switch to on-device in the Speech tab for fully offline transcription.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Microphone audio and speech inference stay on this Mac.", systemImage: "laptopcomputer.and.arrow.down")
                    if sttBackend == .parakeet {
                        Label("Parakeet runs in Miri itself on the Apple Neural Engine.", systemImage: "cpu")
                    }
                }
                Label("Miri collects no analytics and opens no local HTTP port.", systemImage: "network.slash")
                Label("Transcripts are not saved. Failed deliveries remain only in memory and are erased when Miri quits.", systemImage: "externaldrive.badge.xmark")
                Label("Models are downloaded only after you approve the download.", systemImage: "arrow.down.circle")
                if cloudKeyIsStored {
                    Label("Your API key is stored in the macOS Keychain, not in config.toml.", systemImage: "key.fill")
                }
            }
            Section("Review") {
                Button("Open Configuration") { actions.openConfiguration() }
                Button("Open Logs") { actions.openLogs() }
                Button("Delete Downloaded Models…", role: .destructive) { actions.deleteModels() }
                Button("Reset All Miri Data…", role: .destructive) { actions.resetAllData() }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

struct MiriOnboardingView: View {
    @Binding var step: FirstRunStep
    let microphonePermission: MicrophonePermission
    @Binding var hotkey: String
    @Binding var inputMode: MiriInputMode
    @Binding var modelProfile: ModelLifecycleProfile
    let targets: [TargetDefinition]
    var actions = MiriSettingsActions()
    var finish: () -> Void

    private var readiness: FirstRunReadiness {
        FirstRunReadiness(microphonePermission: microphonePermission, targets: targets)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(FirstRunStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 5)
                        .accessibilityHidden(true)
                }
            }
            .padding([.horizontal, .top], 24)

            Group { page }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(36)

            Divider()
            HStack {
                Button("Back") { if let previous = step.previous { step = previous } }
                    .disabled(step.isFirst)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Spacer()
                Text("Step \(step.rawValue + 1) of \(FirstRunStep.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                Spacer()
                if step.isLast {
                    Button("Finish Setup") { finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!readiness.canFinish)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint(readiness.remainingRequirements.joined(separator: ", "))
                } else {
                    Button("Continue") { if let next = step.next { step = next } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Continues to the next setup step")
                }
            }
            .padding(20)
        }
        .frame(width: 650, height: 500)
        .accessibilityLabel("Miri first-run setup")
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            OnboardingPage(icon: "waveform", title: "Welcome to Miri", detail: "Private, local voice control for your coding agents.") {
                Text("We’ll set up your microphone, interaction shortcut, speech models, and first agent target.")
            }
        case .microphone:
            OnboardingPage(icon: "mic", title: "Microphone access", detail: "Miri converts microphone audio to text locally and sends only the finished transcript to your selected target.") {
                MicrophonePermissionRow(permission: microphonePermission, actions: actions)
            }
        case .interaction:
            OnboardingPage(icon: "keyboard", title: "Choose how to speak", detail: "Push to Talk is the recommended default and never listens until you hold the shortcut.") {
                Picker("Input mode", selection: $inputMode) {
                    ForEach(MiriInputMode.supportedCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.radioGroup)
                    .onChange(of: inputMode) { _, value in actions.setInputMode(value) }
                LabeledContent("Shortcut") {
                    HStack {
                        TextField("Shortcut", text: $hotkey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .frame(width: 160)
                            .fixedSize(horizontal: true, vertical: false)
                        Button("Save") { actions.saveActiveHotkey() }
                    }
                }
                Text(inputMode.detail).font(.caption).foregroundStyle(.secondary)
            }
        case .targets:
            OnboardingPage(icon: "arrow.triangle.branch", title: "Agent targets", detail: "A target tells Miri where to deliver your transcript.") {
                if targets.isEmpty {
                    Label("No targets configured yet", systemImage: "exclamationmark.circle")
                    Button("Open Configuration") { actions.openConfiguration() }.keyboardShortcut("e", modifiers: [.command])
                } else {
                    ForEach(targets) { TargetSummaryRow(target: $0, selected: false) }
                }
            }
        case .privacy:
            OnboardingPage(icon: "hand.raised", title: "Your voice stays yours", detail: "Miri processes speech locally, collects no analytics, and keeps no transcript history.") {
                Label("No persistent transcript history", systemImage: "checkmark.circle")
                Label("No local HTTP service", systemImage: "checkmark.circle")
                Label("Memory-only failed-delivery outbox", systemImage: "checkmark.circle")
                if !readiness.canFinish {
                    VStack(alignment: .leading) {
                        Text("Before finishing:").font(.headline)
                        ForEach(readiness.remainingRequirements, id: \.self) { Text("• \($0)") }
                    }.foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct OnboardingPage<Content: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.largeTitle).fontWeight(.semibold)
            Text(detail).font(.title3).foregroundStyle(.secondary)
            Divider()
            content
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MicrophonePermissionRow: View {
    let permission: MicrophonePermission
    let actions: MiriSettingsActions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(statusText, systemImage: icon)
                .foregroundStyle(permission == .granted ? .green : .primary)
                .accessibilityLabel("Microphone permission: \(statusText)")
            Spacer()
            switch permission {
            case .undetermined:
                Button("Allow Microphone") { actions.requestMicrophoneAccess() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Shows the macOS microphone permission prompt")
            case .denied, .restricted:
                Button("Open System Settings") { actions.openMicrophoneSettings() }
                    .accessibilityHint("Opens Privacy and Security microphone settings")
            case .granted:
                Text("Ready").foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch permission {
        case .undetermined: "Permission not requested"
        case .denied: "Permission denied"
        case .restricted: "Permission restricted"
        case .granted: "Permission granted"
        }
    }

    private var icon: String {
        switch permission {
        case .granted: "checkmark.circle.fill"
        case .undetermined: "questionmark.circle"
        case .denied, .restricted: "exclamationmark.triangle.fill"
        }
    }
}

private struct TargetSummaryRow: View {
    let target: TargetDefinition
    let selected: Bool

    var body: some View {
        HStack {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(target.name)
                Text([target.adapter, target.hotkey].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !target.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(target.name), \(target.adapter) adapter\(target.enabled ? "" : ", disabled")")
    }
}
