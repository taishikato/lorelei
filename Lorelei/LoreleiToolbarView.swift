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
    let toggleExpansion: () -> Void

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
                width: expansionState.isExpanded ? 460 : 260,
                height: expansionState.isExpanded ? 430 : 36
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
        Button(action: toggleExpansion) {
            HStack(spacing: 9) {
                statusDot
                Text(Self.statusLabel(for: companionManager.runStatus))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                if case .working = companionManager.runStatus {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.statusLabel(for: companionManager.runStatus))
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            expandedHeader
            streamArea
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
            statusDot
            Text(Self.statusLabel(for: companionManager.runStatus))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer()

            Button(action: toggleExpansion) {
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

    private var streamArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(streamDisplayText)
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("stream-bottom")
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
            .onChange(of: companionManager.streamText) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("stream-bottom", anchor: .bottom)
                }
            }
            .onChange(of: companionManager.latestResultSummary) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("stream-bottom", anchor: .bottom)
                }
            }
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
                    companionManager.acceptPendingApproval()
                }
                .buttonStyle(.borderedProminent)

                Button("Decline") {
                    companionManager.cancelPendingApproval()
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
                    companionManager.stopCurrentRun()
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

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .scaleEffect(companionManager.runStatus == .listening ? 1.22 : 1)
            .animation(
                companionManager.runStatus == .listening
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: companionManager.runStatus
            )
    }

    private var statusColor: Color {
        switch companionManager.runStatus {
        case .idle:
            .gray
        case .listening:
            .green
        case .transcribing, .working:
            .blue
        case .needsApproval:
            .orange
        case .finished(let success):
            success ? .gray : .red
        }
    }
}
