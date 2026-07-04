//
//  LoreleiToolbarView.swift
//  Lorelei
//
//  SwiftUI content for the floating glass toolbar.
//

import SwiftUI

struct LoreleiToolbarView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var expansionState: LoreleiToolbarExpansionState
    let toggleExpansion: @MainActor @Sendable () -> Void

    var body: some View {
        GlassEffectContainer {
            Group {
                if expansionState.isExpanded {
                    expandedPanel
                } else {
                    collapsedCapsule
                }
            }
            .frame(
                width: expansionState.isExpanded ? 460 : 140,
                height: expansionState.isExpanded ? 430 : 40
            )
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: expansionState.isExpanded ? 18 : 18))
        }
        .animation(.snappy(duration: 0.22), value: expansionState.isExpanded)
    }

    static func statusLabel(for runStatus: LoreleiRunStatus) -> String {
        switch runStatus {
        case .idle:
            "Ready"
        case .listening:
            "Listening…"
        case .transcribing:
            "Transcribing…"
        case .working(let activity):
            activity
        case .needsApproval:
            "Needs approval"
        case .finished(let success):
            success ? "Done" : "Failed"
        }
    }

    private var collapsedCapsule: some View {
        Button(action: { deferredAction { toggleExpansion() } }) {
            faceView
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Self.statusLabel(for: companionManager.runStatus))
        .accessibilityLabel(Self.statusLabel(for: companionManager.runStatus))
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            expandedHeader
            conversationArea
            activityLine

            if case .needsApproval = companionManager.runStatus {
                approvalBlock
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var expandedHeader: some View {
        HStack(spacing: 9) {
            faceView
                .scaleEffect(0.72)
                .frame(width: 36, height: 20)
            Text(Self.statusLabel(for: companionManager.runStatus))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer()

            Button(action: { deferredAction { toggleExpansion() } }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
    }

    private var faceView: some View {
        LoreleiFaceView(
            expression: LoreleiFaceExpression.expression(for: companionManager.runStatus),
            audioLevel: companionManager.currentAudioPowerLevel
        )
    }

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(companionManager.conversationLog) { entry in
                        conversationRow(entry)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 0.7)
            )
            .onChange(of: companionManager.conversationLog) { _, log in
                guard let lastID = log.last?.id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func conversationRow(_ entry: ConversationEntry) -> some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 34)
                Text("You: \(entry.text)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(entry.text)
                .font(.system(size: 12, weight: .light, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activityLine: some View {
        HStack(spacing: 8) {
            if case .working = companionManager.runStatus {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            }

            Text(activityText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 16)
    }

    private var approvalBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(companionManager.pendingApprovalTitle ?? "Needs approval")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Button("Accept") {
                    deferredAction { companionManager.acceptPendingApproval() }
                }
                .buttonStyle(.borderedProminent)

                Button("Decline") {
                    deferredAction { companionManager.cancelPendingApproval() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.24), lineWidth: 0.7)
        )
    }

    private var footer: some View {
        HStack {
            Spacer()

            if showsStopButton {
                Button("Stop") {
                    deferredAction { companionManager.stopCurrentRun() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var streamDisplayText: String {
        if case .finished = companionManager.runStatus,
           let latestResultSummary = companionManager.latestResultSummary,
           !latestResultSummary.isEmpty {
            return latestResultSummary
        }

        if !companionManager.streamText.isEmpty {
            return companionManager.streamText
        }

        return companionManager.latestResultSummary ?? ""
    }

    private var activityText: String {
        if let currentActivity = companionManager.currentActivity {
            return currentActivity
        }

        switch companionManager.runStatus {
        case .working(let activity):
            return activity
        case .needsApproval:
            return "Waiting for approval"
        case .finished(let success):
            return success ? "Done" : "Failed"
        default:
            return Self.statusLabel(for: companionManager.runStatus)
        }
    }

    private var showsStopButton: Bool {
        switch companionManager.runStatus {
        case .working, .needsApproval:
            true
        default:
            false
        }
    }

}

/// Runs a state-mutating button action on the next main-actor tick.
///
/// Toolbar buttons (expand/collapse, Stop, Accept/Decline) synchronously
/// mutate state that removes their own subtree from the view hierarchy.
/// Doing that inside the gesture dispatch crashes SwiftUI's button gesture
/// callbacks (EXC_BAD_ACCESS in MainActor.assumeIsolated) when stream
/// updates are re-rendering the panel at the same time - deferring one tick
/// lets the gesture finish before the hierarchy changes.
@MainActor
func deferredAction(_ action: @escaping @MainActor @Sendable () -> Void) {
    Task { @MainActor in
        action()
    }
}
