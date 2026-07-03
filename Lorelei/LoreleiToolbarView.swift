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
                    expandedPlaceholder
                } else {
                    collapsedCapsule
                }
            }
            .frame(
                width: expansionState.isExpanded ? 460 : 260,
                height: expansionState.isExpanded ? 220 : 36
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

    private var expandedPlaceholder: some View {
        Button(action: toggleExpansion) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    statusDot
                    Text(Self.statusLabel(for: companionManager.runStatus))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
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
