//
//  LoreleiRunStatus.swift
//  Lorelei
//
//  Turn progress state shared by the App Server executor and companion UI.
//

import Foundation

enum LoreleiRunStatus: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case working(String)
    case needsApproval(String)
    case finished(success: Bool)
}

enum CodexAppServerTurnProgress: Equatable, Sendable {
    case agentMessageDelta(String)
    case toolCallStarted(name: String)
    case toolCallCompleted(name: String, success: Bool)
}

typealias CodexAppServerTurnProgressHandler = @Sendable (CodexAppServerTurnProgress) -> Void
