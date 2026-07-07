//
//  ForegroundToolTests.swift
//  LoreleiTests
//

import Testing
import AppKit
import Combine
import CoreAudio
import Foundation
import CoreGraphics
import ServiceManagement
@testable import Lorelei

@MainActor
struct ForegroundToolTests {

    @Test func foregroundDynamicToolSpecRegistersLoreleiForegroundApp() throws {
        let spec = CodexAppServerDesktopForegroundTool.spec

        #expect(spec.name == "foreground_app")
        #expect(spec.namespace == "lorelei")
        #expect(spec.description.contains("current macOS Space"))

        guard case .object(let schema) = spec.inputSchema else {
            Issue.record("Expected object input schema.")
            return
        }
        guard case .object(let properties) = schema["properties"] else {
            Issue.record("Expected schema properties.")
            return
        }

        #expect(schema["type"] == .string("object"))
        #expect(properties["appName"] != nil)
        #expect(properties["bundleIdentifier"] != nil)
        #expect(properties["url"] != nil)
        #expect(properties["maxSpaceSwitches"] != nil)
    }

    @Test func foregroundDynamicToolOpensURLActivatesAndReturnsWhenWindowAlreadyOnscreen() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [true])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([
            "appName": .string("Google Chrome"),
            "bundleIdentifier": .string("com.google.Chrome"),
            "url": .string("https://chatgpt.com")
        ])))

        #expect(result.success)
        #expect(textContent(result)?.contains("Google Chrome") == true)
        #expect(textContent(result)?.contains("onscreen") == true)
        #expect(recorder.events == [
            "open:https://chatgpt.com:Google Chrome:com.google.Chrome",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome"
        ])
    }

    @Test func foregroundDynamicToolCyclesSpacesUntilTargetWindowIsOnscreen() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [false, false, true])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([
            "appName": .string("Google Chrome"),
            "bundleIdentifier": .string("com.google.Chrome"),
            "maxSpaceSwitches": .number(3)
        ])))

        #expect(result.success)
        #expect(recorder.spaceDirections == [.right, .right])
        #expect(recorder.events == [
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome",
            "switch:right",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome",
            "switch:right",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome"
        ])
    }

    @Test func foregroundActivationPlanYieldsThenActivatesThenOpensBundleFallbackForRunningApps() throws {
        #expect(LiveDesktopForegrounding.activationPlan(isAppAlreadyRunning: true) == [
            .yieldActivationToRunningApplication,
            .activateRunningApplication,
            .openApplicationActivatingBundleURL,
            .reResolveRunningApplicationAfterLaunch,
            .waitUntilFinishedLaunching,
            .setAccessibilityFrontmost,
            .retryActivationUntilFrontmostApplication
        ])
    }

    @Test func foregroundActivationPlanOpensApplicationForNotRunningApps() throws {
        #expect(LiveDesktopForegrounding.activationPlan(isAppAlreadyRunning: false) == [
            .openApplicationActivatingBundleURL,
            .reResolveRunningApplicationAfterLaunch,
            .waitUntilFinishedLaunching,
            .setAccessibilityFrontmost,
            .retryActivationUntilFrontmostApplication
        ])
    }

    @Test func foregroundActivationPlanWaitsForFinishedLaunchingOnColdLaunch() throws {
        #expect(LiveDesktopForegrounding.shouldWaitForFinishedLaunching(isAppAlreadyRunning: false))
        #expect(!LiveDesktopForegrounding.shouldWaitForFinishedLaunching(isAppAlreadyRunning: true))
    }

    @Test func foregroundDynamicToolReportsMissingTarget() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([:])))

        #expect(!result.success)
        #expect(textContent(result)?.contains("appName or bundleIdentifier") == true)
        #expect(recorder.events.isEmpty)
    }

    private func foregroundToolRequest(
        arguments: CodexAppServerJSONValue
    ) -> CodexAppServerDynamicToolCallRequest {
        CodexAppServerDynamicToolCallRequest(
            requestID: 47,
            callID: "call-1",
            namespace: "lorelei",
            tool: "foreground_app",
            arguments: arguments
        )
    }
}
