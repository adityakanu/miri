import MiriCore
import SwiftUI

struct MiriSettingsActions {
    var requestMicrophoneAccess: () -> Void = {}
    var openMicrophoneSettings: () -> Void = {}
    var openConfiguration: () -> Void = {}
    var openLogs: () -> Void = {}
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
    var setHotkey: (String, String) -> Void = { _, _ in }
}

struct MiriSettingsView: View {
    let microphonePermission: MicrophonePermission
    @Binding var activeHotkey: String
    @Binding var inputMode: MiriInputMode
    let targets: [TargetDefinition]
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

    /// Sidebar destinations.
    ///
    /// Sessions is a parent with one child per agent rather than a single long
    /// pane: choosing a target should never mean scrolling past the other
    /// agents to reach yours.
    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case general, speech
        case codex, claude, hermes, dictation
        case privacy

        var id: String { rawValue }

        /// Children of the Sessions group, in the order they are listed.
        static let sessionPanes: [Pane] = [.codex, .claude, .hermes, .dictation]

        /// Top-level rows, in order. Session children are nested under the
        /// Sessions group heading rather than appearing here.
        static let topLevel: [Pane] = [.general, .speech, .privacy]

        var title: String {
            switch self {
            case .general: "General"
            case .speech: "Speech"
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .hermes: "Hermes"
            case .dictation: "Dictation"
            case .privacy: "Privacy"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .speech: "waveform"
            case .codex: "chevron.left.forwardslash.chevron.right"
            case .claude: "sparkles"
            case .hermes: "point.3.connected.trianglepath.dotted"
            case .dictation: "cursorarrow.and.square.on.square.dashed"
            case .privacy: "hand.raised"
            }
        }

        /// The agent this pane lists sessions for, when it is an agent pane.
        var agent: AgentSessionSummary.Agent? {
            switch self {
            case .codex: .codex
            case .claude: .claude
            case .hermes: .hermes
            default: nil
            }
        }
    }

    @AppStorage("settings.selectedPane") private var selectedPaneRaw = Pane.general.rawValue
    /// Draft hotkey text per target, so typing doesn't fight the configuration
    /// round-trip until Save/Return commits it — mirrors how activeHotkey
    /// already works as a separate @Binding from the persisted value.
    @State private var hotkeyDrafts: [String: String] = [:]

    private var selection: Pane {
        get { Pane(rawValue: selectedPaneRaw) ?? .general }
        nonmutating set { selectedPaneRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationSplitView {
            // Explicit buttons drive the detail column. NavigationLink and
            // List(selection:) both proved unreliable in the Settings scene:
            // the row highlighted but the pane never changed.
            List {
                ForEach(Pane.topLevel.prefix(2), id: \.self) { sidebarRow($0) }

                Section("Sessions") {
                    ForEach(Pane.sessionPanes, id: \.self) { sidebarRow($0) }
                }

                ForEach(Pane.topLevel.dropFirst(2), id: \.self) { sidebarRow($0) }
            }
            .navigationSplitViewColumnWidth(MiriTheme.Metrics.sidebarWidth)
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch selection {
                case .general: general
                case .speech: speech
                case .codex, .claude, .hermes: agentPane
                case .dictation: dictationPane
                case .privacy: privacy
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Miri Settings")
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 660)
        .accessibilityLabel("Miri settings")
    }

    /// One sidebar row. The badge shows how many sessions an agent currently
    /// offers, so the counts are readable without visiting each pane.
    @ViewBuilder private func sidebarRow(_ pane: Pane) -> some View {
        Button {
            selection = pane
        } label: {
            HStack(spacing: 6) {
                Label(pane.title, systemImage: pane.symbol)
                Spacer()
                if let agent = pane.agent {
                    let count = discoveredSessions.filter { $0.agent == agent }.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(count) sessions")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selection == pane ? Color.accentColor.opacity(0.22) : .clear)
        )
        .accessibilityAddTraits(selection == pane ? .isSelected : [])
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

    /// One agent's sessions: which of its targets is active, and which of its
    /// discovered conversations can be added.
    ///
    /// Selection lives on the rows themselves. An earlier version paired a
    /// working menu picker with a list of rows whose radio circles were purely
    /// decorative, so the page appeared to offer two selectors and only one
    /// responded. There is now one control, and it is the list.
    @ViewBuilder private var agentPane: some View {
        if let agent = selection.agent {
            let agentTargets = targets.filter { $0.adapter == agent.rawValue }
            let sessions = discoveredSessions.filter { $0.agent == agent }

            MiriPane(
                title: agent.displayName,
                subtitle: agent.isExperimental
                    ? "Experimental: this adapter does not yet have the live validation Codex has."
                    : "Sessions Miri can speak to, and where the next utterance goes."
            ) {
                MiriSection(
                    title: "Targets",
                    subtitle: "Select the one that receives the next thing you say."
                ) {
                    if agentTargets.isEmpty {
                        MiriCard {
                            Text("No \(agent.displayName) targets yet. Add one from the sessions below.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // "Use configured default" is a real choice, so it is a
                        // row like any other rather than a separate control.
                        SelectableTargetRow(
                            title: "Use configured default",
                            subtitle: "Miri picks using the routing rules.",
                            isActive: activeTargetID == nil,
                            select: { activeTargetID = nil },
                            remove: nil
                        )
                        ForEach(agentTargets) { target in
                            SelectableTargetRow(
                                title: target.name,
                                subtitle: [
                                    target.enabled ? nil : "Disabled",
                                    target.session.map { "Session \($0.prefix(8))" },
                                ]
                                .compactMap { $0 }
                                .joined(separator: " · "),
                                isActive: target.id == activeTargetID,
                                select: { activeTargetID = target.id },
                                remove: { actions.removeTarget(target.id) },
                                hotkey: Binding(
                                    get: { hotkeyDrafts[target.id] ?? target.hotkey ?? "" },
                                    set: { hotkeyDrafts[target.id] = $0 }
                                ),
                                saveHotkey: { actions.setHotkey(target.id, hotkeyDrafts[target.id] ?? "") }
                            )
                        }
                    }
                }

                MiriSection(
                    title: "Available sessions",
                    subtitle: "Conversations Miri found for \(agent.displayName)."
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

                    if sessions.isEmpty {
                        MiriCard {
                            Text(sessionDiscoveryNotes[agent] ?? "No \(agent.displayName) sessions found on this Mac.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(sessions.prefix(12)) { session in
                            DiscoveredSessionRow(
                                session: session,
                                isAdded: targets.contains { $0.session == session.id },
                                add: { actions.addSession(session) }
                            )
                        }
                    }
                }

                if agent == .codex {
                    MiriSection(title: "Voice integration") {
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
                }
            }
            .onAppear {
                if discoveredSessions.isEmpty { actions.refreshSessions() }
            }
        }
    }

    /// Dictation is not an agent conversation, so it gets its own pane rather
    /// than a section wedged among the agents.
    private var dictationPane: some View {
        MiriPane(
            title: "Dictation",
            subtitle: "Types what you say into whichever app has keyboard focus. Your clipboard is never used."
        ) {
            MiriSection(title: "Target") {
                MiriCard {
                    VStack(alignment: .leading, spacing: 10) {
                        if let cursorTarget = targets.first(where: { $0.adapter == "cursor" }) {
                            Label("Dictation target is configured.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            // A dedicated hotkey lets dictation and a coding
                            // agent live on separate presses, so Miri is
                            // usable for everyday typing without stealing the
                            // shortcut you use to talk to an agent.
                            LabeledContent("Shortcut") {
                                TextField(
                                    "e.g. option+d",
                                    text: Binding(
                                        get: { hotkeyDrafts[cursorTarget.id] ?? cursorTarget.hotkey ?? "" },
                                        set: { hotkeyDrafts[cursorTarget.id] = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 160)
                                .lineLimit(1)
                                .onSubmit { actions.setHotkey(cursorTarget.id, hotkeyDrafts[cursorTarget.id] ?? "") }
                                .accessibilityHint("Bypasses automatic routing to dictate directly, separate from the agent shortcut")
                            }
                            Text("Leave blank to use the default shortcut for dictation too.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Add Dictation Target") { actions.addCursorTarget() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            MiriSection(
                title: "Permission",
                subtitle: "macOS requires Accessibility permission before any app can type into another."
            ) {
                MiriCard {
                    VStack(alignment: .leading, spacing: 10) {
                        if accessibilityGranted {
                            Label("Accessibility permission granted.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
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

/// A target row that *is* the selection control.
///
/// The whole row is the button, so the visible radio marker and the clickable
/// area are the same thing — the earlier decorative-circle row looked
/// selectable but ignored clicks.
private struct SelectableTargetRow: View {
    let title: String
    let subtitle: String
    let isActive: Bool
    let select: () -> Void
    /// Nil for rows that are not removable, such as the default choice.
    let remove: (() -> Void)?
    /// Nil for rows with no hotkey to edit, such as the default choice.
    var hotkey: Binding<String>?
    var saveHotkey: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).fontWeight(isActive ? .semibold : .regular).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
            .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")

            // A dedicated hotkey bypasses recency and pending-request routing
            // to reach this exact target, so it needs its own field per
            // target rather than sharing the single default shortcut —
            // that is what lets, for example, the dictation target and a
            // coding agent each have their own press.
            if let hotkey {
                TextField("Hotkey", text: hotkey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 110)
                    .lineLimit(1)
                    .onSubmit { saveHotkey?() }
                    .accessibilityLabel("Dedicated shortcut for \(title)")
                    .accessibilityHint("Bypasses automatic routing to speak directly to this target")
            }

            if let remove {
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MiriTheme.Metrics.cardCornerRadius)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MiriTheme.Metrics.cardCornerRadius)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08))
        )
    }
}

/// A discovered conversation that can be adopted as a target.
private struct DiscoveredSessionRow: View {
    let session: AgentSessionSummary
    let isAdded: Bool
    let add: () -> Void

    var body: some View {
        MiriCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).lineLimit(1)
                    Text(
                        [session.projectName, String(session.id.prefix(8))]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isAdded {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Already added")
                } else {
                    Button("Add") { add() }
                }
            }
        }
        .accessibilityElement(children: .contain)
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
