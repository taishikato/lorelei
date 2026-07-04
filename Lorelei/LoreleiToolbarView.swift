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

    @State private var isPeekHovered = false

    var body: some View {
        Group {
            if !expansionState.isExpanded && expansionState.showsNotchPeek {
                notchPeek
            } else {
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
            }
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

    /// Lorelei peeking out from behind the notch: a glass head shape whose
    /// top runs under the physical camera housing (invisible), leaving only
    /// the chin with the face visible below the notch edge.
    ///
    /// Clickability affordance: the window is a bit taller than the resting
    /// chin, and on hover the head leans further out (bottom inset animates
    /// to zero) with a pointing-hand cursor - the motion signals that the
    /// face is a control, not a decoration.
    private var notchPeek: some View {
        GlassEffectContainer {
            Button(action: { deferredAction { toggleExpansion() } }) {
                ZStack(alignment: .bottom) {
                    Color.clear

                    faceView
                        .scaleEffect(0.78, anchor: .bottom)
                        .padding(.bottom, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(peekHeadShape)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: peekHeadShape)
            .padding(.bottom, isPeekHovered ? 0 : peekHoverLeanDistance)
            .animation(.snappy(duration: 0.18), value: isPeekHovered)
            .onHover { hovering in
                isPeekHovered = hovering
            }
            .pointerCursor()
            .help(Self.statusLabel(for: companionManager.runStatus))
            .accessibilityLabel(Self.statusLabel(for: companionManager.runStatus))
        }
    }

    /// Extra chin the peek gains while hovered. Must match the difference
    /// between the controller's window chin height and the resting look.
    private let peekHoverLeanDistance: CGFloat = 8

    private var peekHeadShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 14,
            style: .continuous
        )
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

            if case .needsApproval = companionManager.runStatus {
                approvalBlock
            }

            if showsStopButton {
                footer
            }
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

            Button(action: { deferredAction { companionManager.startNewChatSession() } }) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("New chat")
            .accessibilityLabel("New chat")

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
            Group {
                if companionManager.conversationLog.isEmpty {
                    conversationEmptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(companionManager.conversationLog) { entry in
                                conversationRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var conversationEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text("Hold")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    ForEach(BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels, id: \.self) { keyLabel in
                        Text(keyLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.white.opacity(0.14))
                            )
                    }

                    Text("and speak")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Text("Release to send. Hold again while Lorelei is working to steer the task.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
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

            Button("Stop") {
                deferredAction { companionManager.stopCurrentRun() }
            }
            .buttonStyle(.bordered)
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
