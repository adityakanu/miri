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
    var installModels: () -> Void = {}
    var deleteModels: () -> Void = {}
    var resetAllData: () -> Void = {}
    var saveSTTSettings: () -> Void = {}
    var installParakeetModels: () -> Void = {}
    var addCursorTarget: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var refreshSessions: () -> Void = {}
    var addSession: (AgentSessionSummary) -> Void = { _ in }
    var removeTarget: (String) -> Void = { _ in }
}

struct MiriSettingsView: View {
    let microphonePermission: MicrophonePermission
    @Binding var activeHotkey: String
    @Binding var inputMode: MiriInputMode
    let targets: [TargetDefinition]
    let codexThreads: [CodexThreadSummary]
    let isRefreshingCodexThreads: Bool
    let speechHealth: String
    let codexIntegrationStatus: String
    @Binding var activeTargetID: String?
    @Binding var sttBackend: STTBackend
    let sttTestStatus: String?
    let parakeetInstalled: Bool
    let voiceInstalled: Bool
    let isInstallingParakeet: Bool
    let hasCursorTarget: Bool
    let accessibilityGranted: Bool
    let discoveredSessions: [AgentSessionSummary]
    let isRefreshingSessions: Bool
    let sessionDiscoveryNotes: [AgentSessionSummary.Agent: String]
    var configurationError: String?
    var actions = MiriSettingsActions()

    /// Sidebar destinations. `Sessions` replaces the old "Targets" tab: the
    /// pane is about live agent conversations, not a config file section.
    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case general, speech, sessions, privacy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .speech: "Speech"
            case .sessions: "Sessions"
            case .privacy: "Privacy"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .speech: "waveform"
            case .sessions: "bubble.left.and.bubble.right"
            case .privacy: "hand.raised"
            }
        }
    }

    @State private var selection: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                NavigationLink(value: pane) {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
            .navigationSplitViewColumnWidth(MiriTheme.Metrics.sidebarWidth)
            .listStyle(.sidebar)
        } detail: {
            switch selection {
            case .general: general
            case .speech: speech
            case .sessions: targetsPane
            case .privacy: privacy
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
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

            Section("On-device models") {
                Label(
                    parakeetInstalled ? "Parakeet transcription is installed" : "Parakeet transcription is not installed",
                    systemImage: parakeetInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                )
                .foregroundStyle(parakeetInstalled ? .green : .primary)
                Label(
                    voiceInstalled ? "PocketTTS voice is installed" : "PocketTTS voice is not installed",
                    systemImage: voiceInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                )
                .foregroundStyle(voiceInstalled ? .green : .primary)
                if !parakeetInstalled || !voiceInstalled {
                    Button(isInstallingParakeet ? "Downloading…" : "Download Models…") {
                        actions.installParakeetModels()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstallingParakeet)
                }
                Text("About 1 GB in total, downloaded once from Hugging Face: roughly 470 MB for transcription and 520 MB for the voice. After that Miri speaks and listens with no network access at all.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Save Speech Settings") { actions.saveSTTSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!parakeetInstalled)
                if let sttTestStatus {
                    Label(sttTestStatus, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption).textSelection(.enabled)
                }
                Label(speechHealth, systemImage: "waveform.badge.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var general: some View {
        MiriPane(title: "General", subtitle: "Microphone access, the push-to-talk shortcut, and local files.") {
            MiriSection(title: "Microphone") {
                MiriCard {
                    MicrophonePermissionRow(permission: microphonePermission, actions: actions)
                }
            }

            MiriSection(
                title: "Push to talk",
                subtitle: "Hold this shortcut to speak. Miri listens only while it is held."
            ) {
                HStack(spacing: 8) {
                    // A placeholder identical to the current value was painted
                    // behind the editor by AppKit when this row was compressed,
                    // making option+space appear twice. Keep the placeholder
                    // semantic and force a single line.
                    TextField("Shortcut", text: $activeHotkey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 180)
                        .fixedSize(horizontal: true, vertical: false)
                        .onSubmit { actions.saveActiveHotkey() }
                    Button("Save") { actions.saveActiveHotkey() }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Push-to-talk shortcut")
            }

            MiriSection(title: "Speech models") {
                MiriCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(speechHealth, systemImage: "waveform.badge.magnifyingglass")
                            .font(.callout)
                            .textSelection(.enabled)
                        Button("Install or Repair Models…") { actions.installModels() }
                    }
                }
            }

            MiriSection(title: "Files") {
                HStack(spacing: 8) {
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
    }

    private var targetsPane: some View {
        MiriPane(
            title: "Sessions",
            subtitle: "Live agent conversations Miri can speak to, and where the next utterance goes."
        ) {
            MiriSection(
                title: "Active target",
                subtitle: "Receives the next thing you say, unless an agent is waiting on you."
            ) {
                if targets.filter(\.enabled).isEmpty {
                    MiriCard {
                        Text("No targets yet. Add a session below, or the dictation target to type into any app.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Target used for the next recording", selection: $activeTargetID) {
                        Text("Use configured default").tag(String?.none)
                        ForEach(targets.filter(\.enabled)) { target in
                            Text(target.name).tag(Optional(target.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 380, alignment: .leading)

                    VStack(spacing: 8) {
                        ForEach(targets) { target in
                            ConfiguredTargetRow(
                                target: target,
                                isActive: target.id == activeTargetID,
                                remove: { actions.removeTarget(target.id) }
                            )
                        }
                    }
                }
            }

            MiriSection(
                title: "Dictation",
                subtitle: "Types where your cursor already is. Your clipboard is never used."
            ) {
                MiriCard {
                    VStack(alignment: .leading, spacing: 10) {
                        if hasCursorTarget {
                            Label("Dictation target is configured.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Add Dictation Target") { actions.addCursorTarget() }
                                .buttonStyle(.borderedProminent)
                        }
                        if !accessibilityGranted {
                            Label(
                                "Accessibility permission is required before Miri can type.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                            Button("Open Accessibility Settings") { actions.openAccessibilitySettings() }
                        }
                    }
                }
            }

            MiriSection(
                title: "Discovered sessions",
                subtitle: "Conversations found across Codex, Claude Code, and Hermes."
            ) {
                HStack {
                    Button { actions.refreshSessions() } label: {
                        Label(
                            isRefreshingSessions ? "Refreshing…" : "Refresh",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isRefreshingSessions)
                    Spacer()
                }

                ForEach(AgentSessionSummary.Agent.allCases, id: \.self) { agent in
                    AgentSessionGroup(
                        agent: agent,
                        sessions: discoveredSessions.filter { $0.agent == agent },
                        note: sessionDiscoveryNotes[agent],
                        isAdded: { session in targets.contains { $0.session == session.id } },
                        add: { actions.addSession($0) }
                    )
                }
            }

            MiriSection(title: "Codex voice integration") {
                MiriCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(codexIntegrationStatus, systemImage: "waveform.and.mic")
                            .font(.callout)
                        Button("Install or Repair Miri MCP…") { actions.installCodexIntegration() }
                        Text("Lets Codex announce progress, blockers, questions, and completion through Miri.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Button("Edit Targets in Configuration") { actions.openConfiguration() }
                .keyboardShortcut("e", modifiers: [.command])
                .accessibilityHint("Opens the configuration file where targets are managed")
        }
    }

    private var privacy: some View {
        Form {
            Section("Local by design") {
                Label("Microphone audio and speech inference stay on this Mac.", systemImage: "laptopcomputer.and.arrow.down")
                Label("Parakeet runs in Miri itself on the Apple Neural Engine.", systemImage: "cpu")
                Label("Miri collects no analytics and opens no local HTTP port.", systemImage: "network.slash")
                Label("Transcripts are not saved. Failed deliveries remain only in memory and are erased when Miri quits.", systemImage: "externaldrive.badge.xmark")
                Label("Models are downloaded only after you approve the download.", systemImage: "arrow.down.circle")
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

/// One configured target: what it is, whether it receives the next utterance,
/// and a way to remove it without editing config.toml.
private struct ConfiguredTargetRow: View {
    let target: TargetDefinition
    let isActive: Bool
    let remove: () -> Void

    var body: some View {
        MiriCard {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).fontWeight(.medium).lineLimit(1)
                    Text([target.adapter, target.hotkey].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !target.enabled {
                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) { remove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(target.name)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(target.name), \(target.adapter) adapter\(target.enabled ? "" : ", disabled")\(isActive ? ", active target" : "")"
        )
    }
}

/// Discovered sessions for one agent, with its own empty/failure note so a
/// missing agent never looks like a missing feature.
private struct AgentSessionGroup: View {
    let agent: AgentSessionSummary.Agent
    let sessions: [AgentSessionSummary]
    let note: String?
    let isAdded: (AgentSessionSummary) -> Bool
    let add: (AgentSessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(agent.displayName).font(.headline)
                if agent.isExperimental {
                    Text("Experimental")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .accessibilityLabel("Experimental adapter")
                }
                Spacer()
                if !sessions.isEmpty {
                    Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let note, sessions.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(sessions.prefix(8)) { session in
                    MiriCard {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).lineLimit(1)
                                Text(subtitle(for: session))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isAdded(session) {
                                Label("Added", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Already added")
                            } else {
                                Button("Add") { add(session) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for session: AgentSessionSummary) -> String {
        [session.projectName, String(session.id.prefix(8))]
            .compactMap { $0 }
            .joined(separator: " · ")
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
