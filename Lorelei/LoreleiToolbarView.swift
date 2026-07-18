//
//  LoreleiToolbarView.swift
//  Lorelei
//
//  SwiftUI content for the floating island toolbar.
//

import SwiftUI

struct LoreleiToolbarView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var expansionState: LoreleiToolbarExpansionState
    let toggleExpansion: @MainActor @Sendable () -> Void
    let openSettings: @MainActor @Sendable () -> Void

    @State private var isHeadHovered = false
    @State private var headSide: IslandSide = .left
    @State private var sideScheduler = IslandSideScheduler()

    private var activity: IslandActivity {
        IslandActivity.activity(for: companionManager.runStatus)
    }

    var body: some View {
        Group {
            if expansionState.isExpanded {
                expandedPanel
                    .frame(width: 460, height: 430)
            } else {
                islandView
            }
        }
        .animation(.snappy(duration: 0.22), value: expansionState.isExpanded)
        .animation(.snappy(duration: 0.22), value: activity)
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

    /// Collapsed island: true-black notch bar, side-peeking head while idle /
    /// finished, and an activity tray that drops while active.
    private var islandView: some View {
        Button(action: { deferredAction { toggleExpansion() } }) {
            GeometryReader { proxy in
                let flank = IslandGeometry.headRestProtrusion + IslandGeometry.headHoverExtra
                let islandWidth = max(proxy.size.width - (flank * 2), 1)
                let islandHeight = max(proxy.size.height - IslandGeometry.trayHeight, 1)

                ZStack(alignment: .top) {
                    Color.clear

                    VStack(spacing: 0) {
                        ZStack {
                            islandBody(width: islandWidth, height: islandHeight)

                            if activity.showsHead {
                                islandHead
                                    .offset(x: headOffset(islandWidth: islandWidth), y: islandHeight * 0.18)
                                    .animation(.snappy(duration: 0.2), value: headSide)
                                    .animation(.snappy(duration: 0.18), value: isHeadHovered)
                            }
                        }
                        .frame(width: islandWidth, height: islandHeight)
                        .frame(maxWidth: .infinity)

                        ZStack(alignment: .top) {
                            if activity.showsTray {
                                islandTray
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .frame(width: IslandGeometry.trayWidth, height: IslandGeometry.trayHeight, alignment: .top)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.statusLabel(for: companionManager.runStatus))
        .accessibilityLabel(Self.statusLabel(for: companionManager.runStatus))
        .pointerCursor()
        .onHover { hovering in
            isHeadHovered = hovering
        }
        .onChange(of: companionManager.runStatus) { oldStatus, newStatus in
            let wasIdle = IslandActivity.activity(for: oldStatus) == .idlePeek
            let isIdle = IslandActivity.activity(for: newStatus) == .idlePeek
            guard isIdle, !wasIdle else { return }
            var scheduler = sideScheduler
            headSide = scheduler.sideAfterReturnToIdle(current: headSide)
            sideScheduler = scheduler
        }
        .task(id: activity == .idlePeek) {
            guard activity == .idlePeek else { return }
            while !Task.isCancelled {
                var scheduler = sideScheduler
                let delay = scheduler.nextSwitchDelay()
                sideScheduler = scheduler
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard IslandActivity.activity(for: companionManager.runStatus) == .idlePeek else {
                    continue
                }
                withAnimation(.snappy(duration: 0.22)) {
                    headSide = headSide == .left ? .right : .left
                }
            }
        }
    }

    private func islandBody(width: CGFloat, height: CGFloat) -> some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: IslandGeometry.islandBottomRadius,
            bottomTrailingRadius: IslandGeometry.islandBottomRadius,
            style: .continuous
        )
        .fill(DS.Colors.islandSurface)
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    private var islandHead: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DS.Colors.islandRaised, DS.Colors.islandSurface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Capsule(style: .continuous)
                .stroke(DS.Colors.islandHairline, lineWidth: 0.8)
                .padding(.top, 0.5)

            faceView
                .scaleEffect(0.55)
        }
        .frame(width: IslandGeometry.headSize.width, height: IslandGeometry.headSize.height)
        .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 2)
    }

    private func headOffset(islandWidth: CGFloat) -> CGFloat {
        let protrusion = IslandGeometry.headRestProtrusion
            + (isHeadHovered ? IslandGeometry.headHoverExtra : 0)
        let halfIsland = islandWidth / 2
        let halfHead = IslandGeometry.headSize.width / 2
        switch headSide {
        case .left:
            return -(halfIsland + protrusion - halfHead)
        case .right:
            return halfIsland + protrusion - halfHead
        }
    }

    private var islandTray: some View {
        ZStack {
            UnevenRoundedRectangle(
                bottomLeadingRadius: IslandGeometry.trayCornerRadius,
                bottomTrailingRadius: IslandGeometry.trayCornerRadius,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [DS.Colors.islandRaised, DS.Colors.islandSurface],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            UnevenRoundedRectangle(
                bottomLeadingRadius: IslandGeometry.trayCornerRadius,
                bottomTrailingRadius: IslandGeometry.trayCornerRadius,
                style: .continuous
            )
            .stroke(DS.Colors.islandHairline, lineWidth: 0.8)

            trayContent
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: IslandGeometry.trayWidth, height: IslandGeometry.trayHeight)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 3)
    }

    @ViewBuilder
    private var trayContent: some View {
        switch activity {
        case .listening:
            IslandListeningBarsView(audioPowerLevel: companionManager.currentAudioPowerLevel)
        case .transcribing:
            IslandListeningBarsView(audioPowerLevel: 0.08, calmShimmer: true)
        case .working:
            IslandScanningEyesView()
        case .needsApproval:
            IslandScanningEyesView()
                .opacity(0.55)
                .modifier(IslandApprovalPulseModifier())
        case .idlePeek, .finished:
            EmptyView()
        }
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
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: IslandGeometry.trayCornerRadius,
                bottomTrailingRadius: IslandGeometry.trayCornerRadius,
                style: .continuous
            )
            .fill(DS.Colors.islandSurface)
            .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
        )
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
                .foregroundStyle(DS.Colors.textPrimary)

            Spacer()

            Button(action: { deferredAction { companionManager.startNewChatSession() } }) {
                Text("New Chat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(DS.Colors.islandRaised)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Start a fresh conversation")
            .accessibilityLabel("New chat")

            Button(action: { deferredAction { openSettings() } }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Settings")
            .accessibilityLabel("Settings")

            Button(action: { deferredAction { toggleExpansion() } }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Collapse")
            .accessibilityLabel("Collapse")
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
                    .fill(DS.Colors.islandRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.Colors.islandHairline, lineWidth: 0.7)
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
        VStack(spacing: 16) {
            if companionManager.allPermissionsGranted {
                emptyStateGuidance
            } else {
                emptyStateGuidance
                    .opacity(0.35)

                permissionNotice
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var emptyStateGuidance: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)

            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text("Hold")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)

                    ForEach(BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels, id: \.self) { keyLabel in
                        Text(keyLabel)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(DS.Colors.islandRaised)
                            )
                    }

                    Text("and speak")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                }

                Text("Release to send. Hold again while Lorelei is working to steer the task.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var permissionNotice: some View {
        VStack(spacing: 10) {
            // firstTextBaseline keeps the icon on the first line when the
            // permission list wraps; a centered HStack floats it mid-block.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Lorelei needs permissions before it can listen: \(companionManager.missingPermissionNames.joined(separator: ", "))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Button(action: { deferredAction { openSettings() } }) {
                Text("Open Settings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(DS.Colors.islandRaised)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
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
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }
        case .assistant:
            Text(entry.text)
                .font(.system(size: 12, weight: .light, design: .monospaced))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var approvalBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(companionManager.pendingApprovalTitle ?? "Needs approval")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
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

    private var showsStopButton: Bool {
        companionManager.canStopCurrentRun
    }

}

private struct IslandListeningBarsView: View {
    let audioPowerLevel: CGFloat
    var calmShimmer: Bool = false

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.white.opacity(calmShimmer ? 0.7 : 0.92))
                        .frame(
                            width: 3,
                            height: barHeight(for: barIndex, timelineDate: timelineContext.date)
                        )
                }
            }
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * (calmShimmer ? 2.1 : 3.6))
            + CGFloat(barIndex) * 0.35
        if calmShimmer {
            let shimmer = (sin(animationPhase) + 1) / 2
            return 4 + shimmer * 6 * listeningBarProfile[barIndex]
        }

        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 12 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

private struct IslandScanningEyesView: View {
    @State private var lookOffset: CGFloat = -3

    var body: some View {
        HStack(spacing: 14) {
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 7, height: 7)
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 7, height: 7)
        }
        .offset(x: lookOffset)
        .task {
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.55)) {
                    lookOffset = 3
                }
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    lookOffset = -3
                }
                try? await Task.sleep(for: .milliseconds(650))
            }
        }
    }
}

private struct IslandApprovalPulseModifier: ViewModifier {
    @State private var pulsed = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsed ? 0.45 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
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
