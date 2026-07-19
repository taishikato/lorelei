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
        islandView
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

    /// The island is permanent; everything else slides out from under it -
    /// the side-peeking head while idle, the activity tray while active, and
    /// the conversation panel while expanded. One grammar, one clip, and the
    /// window itself never animates (it is transparent - AppKit frame
    /// animation plus SwiftUI transitions double-animating was the visibly
    /// broken expansion).
    private var islandView: some View {
        GeometryReader { proxy in
            let flank = IslandGeometry.headRestProtrusion + IslandGeometry.headHoverExtra
            let publishedIsland = expansionState.islandSize
            let islandWidth = publishedIsland.width > 0
                ? min(publishedIsland.width, proxy.size.width)
                : max(proxy.size.width - (flank * 2), 1)
            let islandHeight = publishedIsland.height > 0
                ? publishedIsland.height
                : max(proxy.size.height - IslandGeometry.trayHeight, 1)

            VStack(spacing: 0) {
                Button(action: { deferredAction { toggleExpansion() } }) {
                    islandBody(width: islandWidth, height: islandHeight)
                        .overlay(alignment: headSide == .left ? .bottomLeading : .bottomTrailing) {
                            if showsIdleHead {
                                islandHead(height: islandHeight)
                                    .offset(x: headProtrusionOffset, y: 0)
                                    .animation(.snappy(duration: 0.2), value: headSide)
                                    .animation(.snappy(duration: 0.18), value: isHeadHovered)
                            }
                        }
                        .frame(width: islandWidth, height: islandHeight)
                        .frame(maxWidth: .infinity)
                        .contentShape(IslandHitShape(
                            islandWidth: islandWidth,
                            showsHead: showsIdleHead,
                            headSide: headSide
                        ))
                }
                .buttonStyle(.plain)
                .help(Self.statusLabel(for: companionManager.runStatus))
                .accessibilityLabel(Self.statusLabel(for: companionManager.runStatus))
                .pointerCursor()
                .onHover { hovering in
                    isHeadHovered = hovering
                }

                ZStack(alignment: .top) {
                    if expansionState.isExpanded {
                        expandedPanel
                            .frame(
                                width: IslandGeometry.expandedPanelSize.width,
                                height: IslandGeometry.expandedPanelSize.height
                            )
                            // Retract by CONVERGING into the island: scale
                            // toward the top-center anchor (where the island
                            // sits) rather than translating up, which read as
                            // fading away instead of being swallowed.
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .scale(scale: 0.02, anchor: .top)
                                    .combined(with: .opacity)
                            ))
                    } else if activity.showsTray {
                        // The tray is a button too: tapping the activity
                        // readout opens the panel (owner report: the tray
                        // face was dead after the tray moved out of the
                        // island button).
                        Button(action: { deferredAction { toggleExpansion() } }) {
                            islandTray
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: max(proxy.size.height - islandHeight, 0), alignment: .top)
                .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .animation(.snappy(duration: 0.25), value: expansionState.isExpanded)
        .animation(.snappy(duration: 0.22), value: activity)
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

    private var showsIdleHead: Bool {
        !expansionState.isExpanded && activity.showsHead
    }

    private func islandBody(width: CGFloat, height: CGFloat) -> some View {
        // The bottom corner goes SQUARE on the side the head is peeking
        // from: the head continues the island's bottom line past the edge,
        // and a rounded corner there lifts away from that line, exposing a
        // wallpaper wedge under the curve (owner-observed gap).
        let headOut = showsIdleHead
        return UnevenRoundedRectangle(
            bottomLeadingRadius: headOut && headSide == .left
                ? 0 : IslandGeometry.islandBottomRadius,
            bottomTrailingRadius: headOut && headSide == .right
                ? 0 : IslandGeometry.islandBottomRadius,
            style: .continuous
        )
        .fill(DS.Colors.islandSurface)
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    /// Rounded only on the side facing AWAY from the island: the junction
    /// side stays square so the head's bottom edge continues the island's
    /// bottom line with no wedge of wallpaper at the seam (owner feedback).
    private var headShape: UnevenRoundedRectangle {
        switch headSide {
        case .left:
            UnevenRoundedRectangle(
                topLeadingRadius: 10.5,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .right:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 12,
                topTrailingRadius: 10.5,
                style: .continuous
            )
        }
    }

    private func islandHead(height: CGFloat) -> some View {
        ZStack {
            // Seamless with the island: identical fill, no hairline, no
            // gradient - the head must read as the same black object
            // (owner direction), with its bottom edge flush with the island's.
            headShape
                .fill(DS.Colors.islandSurface)

            // Dedicated tiny face: the toolbar faceView has its own layout
            // size and overflowed the head capsule. Fixed geometry only.
            islandHeadFace
                // Keep the face on the protruding side so the island's edge
                // never clips an eye.
                .offset(x: headSide == .left ? -4 : 4)
        }
        .frame(width: IslandGeometry.headSize.width, height: height)
        .clipShape(headShape)
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 2)
    }

    private var islandHeadFace: some View {
        let expression = LoreleiFaceExpression.expression(for: companionManager.runStatus)
        return VStack(spacing: 2.5) {
            HStack(spacing: 7) {
                Circle().fill(.white).frame(width: 4.5, height: 4.5)
                Circle().fill(.white).frame(width: 4.5, height: 4.5)
            }
            .modifier(IslandBlink())

            switch expression {
            case .happy:
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.white.opacity(0.85), lineWidth: 1.4)
                    .frame(width: 9, height: 4)
                    .mask(Rectangle().frame(height: 3).offset(y: 1.5))
            case .sad:
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.white.opacity(0.85), lineWidth: 1.4)
                    .frame(width: 9, height: 4)
                    .mask(Rectangle().frame(height: 3).offset(y: -1.5))
            default:
                Capsule().fill(.white.opacity(0.8))
                    .frame(width: 8, height: 1.6)
            }
        }
    }

    /// Horizontal shift from the island's edge alignment: the head is
    /// edge-anchored (bottomLeading/bottomTrailing), so a positive protrusion
    /// slides it outward past the flank while the rest stays hidden behind
    /// the island body.
    private var headProtrusionOffset: CGFloat {
        let protrusion = IslandGeometry.headRestProtrusion
            + (isHeadHovered ? IslandGeometry.headHoverExtra : 0)
        switch headSide {
        case .left:
            return -protrusion
        case .right:
            return protrusion
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


/// Periodic eye blink for the island head: brief vertical squash every few
/// seconds, with a randomized pause so restarts do not sync.
private struct IslandBlink: ViewModifier {
    @State private var isBlinking = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(y: isBlinking ? 0.12 : 1, anchor: .center)
            .animation(.easeInOut(duration: 0.09), value: isBlinking)
            .task {
                while !Task.isCancelled {
                    let pause = TimeInterval.random(in: 3.2...6.0)
                    try? await Task.sleep(for: .seconds(pause))
                    guard !Task.isCancelled else { return }
                    isBlinking = true
                    try? await Task.sleep(for: .milliseconds(110))
                    isBlinking = false
                }
            }
    }
}


/// Hit-test region for the island button (the island band only - the drop
/// zone below is outside the button entirely): the island bar plus the
/// peeking head while visible. The empty flank corners of the fixed-width
/// window must NOT be clickable.
private struct IslandHitShape: Shape {
    let islandWidth: CGFloat
    let showsHead: Bool
    let headSide: IslandSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let flank = max((rect.width - islandWidth) / 2, 0)
        path.addRect(CGRect(x: flank, y: 0, width: islandWidth, height: rect.height))

        if showsHead {
            let protrusion = IslandGeometry.headRestProtrusion + IslandGeometry.headHoverExtra
            switch headSide {
            case .left:
                path.addRect(CGRect(
                    x: max(flank - protrusion, 0),
                    y: 0,
                    width: IslandGeometry.headSize.width,
                    height: rect.height
                ))
            case .right:
                path.addRect(CGRect(
                    x: rect.width - flank + protrusion - IslandGeometry.headSize.width,
                    y: 0,
                    width: IslandGeometry.headSize.width,
                    height: rect.height
                ))
            }
        }
        return path
    }
}
