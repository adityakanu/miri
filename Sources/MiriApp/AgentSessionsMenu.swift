import MiriCore
import SwiftUI

/// Live agent sessions in the menu bar: who is waiting, who is working, and
/// where the next utterance goes.
///
/// Reuses the existing menu rather than adding a second window — the same rows
/// the HUD panel shows, without new window plumbing.
struct AgentSessionsMenu: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let model = controller.hudModel
        Section(model.summary) {
            if model.isEmpty {
                Text("No agent sessions")
            } else {
                ForEach(model.rows.prefix(AgentHUDModel.maximumVisibleRows)) { row in
                    Menu {
                        Button("Speak to \(row.name)") { controller.selectTarget(row.id) }
                        Button(row.isMuted ? "Unmute" : "Mute") { controller.toggleMute(targetID: row.id) }
                    } label: {
                        Label(rowTitle(row), systemImage: symbol(for: row))
                    }
                    .accessibilityLabel(row.accessibilityLabel)
                }
                if model.hiddenRowCount > 0 {
                    Text("\(model.hiddenRowCount) more in Settings")
                }
            }
        }
    }

    private func rowTitle(_ row: AgentHUDRow) -> String {
        var title = row.project.map { "\(row.name) · \($0)" } ?? row.name
        title += " — \(row.state.label)"
        if row.isMuted { title += " (muted)" }
        return title
    }

    private func symbol(for row: AgentHUDRow) -> String {
        switch row.state {
        case .needsApproval: "exclamationmark.triangle.fill"
        case .needsAnswer: "questionmark.bubble.fill"
        case .failed: "xmark.octagon.fill"
        case .working: "ellipsis.circle"
        case .ready: "circle"
        case .disconnected: "circle.dashed"
        }
    }
}

/// Agent sessions running on this Mac right now.
///
/// These come from the process table rather than from transcript timestamps,
/// so the list is what is genuinely open — the sessions you are most likely to
/// want to speak to. They sit at the top level of the menu because selecting
/// the terminal you are working in should not require opening Settings or
/// scrolling a submenu.
struct LiveSessionsMenu: View {
    @ObservedObject var controller: AppController

    var body: some View {
        let rows = controller.liveSessionRows
        if !rows.isEmpty {
            Section("Running now") {
                ForEach(rows) { row in
                    Button {
                        controller.selectLiveSession(row)
                    } label: {
                        Label(
                            title(for: row),
                            systemImage: isActive(row) ? "checkmark.circle.fill" : "terminal"
                        )
                    }
                    .accessibilityLabel(row.accessibilityLabel)
                }
            }
        }
    }

    private func title(for row: LiveSessionRow) -> String {
        "\(row.title) — \(row.subtitle)"
    }

    private func isActive(_ row: LiveSessionRow) -> Bool {
        row.existingTarget.map { $0.id == controller.activeTargetID } ?? false
    }
}
