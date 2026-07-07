//
//  UpdateCheckerTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

@MainActor
struct UpdateCheckerTests {
    @Test func versionComparison() async throws {
        #expect(UpdateChecker.isVersion("v1.1", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion("v1.0", newerThan: "1.0"))
        #expect(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))
        #expect(!UpdateChecker.isVersion("0.9", newerThan: "1.0"))
        #expect(UpdateChecker.isVersion("v2", newerThan: "1.9.9"))
        // Malformed tags must never crash - they simply compare as not-newer.
        #expect(!UpdateChecker.isVersion("vNext", newerThan: "1.0"))
    }

    @Test func checkReportsUpdateAvailable() async throws {
        let fetcher = FakeLatestReleaseFetcher(
            tagName: "v9.9",
            htmlURL: URL(string: "https://github.com/taishikato/lorelei/releases/tag/v9.9")!
        )
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.1")

        await checker.check()

        guard case let .updateAvailable(result) = checker.state else {
            Issue.record("Expected .updateAvailable, got \(checker.state)")
            return
        }

        #expect(result.latestVersion == "v9.9")
        #expect(result.releaseURL == fetcher.htmlURL)
        #expect(result.isNewer)
    }

    @Test func checkReportsUpToDate() async throws {
        let fetcher = FakeLatestReleaseFetcher(
            tagName: "v1.1",
            htmlURL: URL(string: "https://github.com/taishikato/lorelei/releases/tag/v1.1")!
        )
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.1")

        await checker.check()

        guard case let .upToDate(version) = checker.state else {
            Issue.record("Expected .upToDate, got \(checker.state)")
            return
        }

        #expect(version == "v1.1")
    }

    @Test func checkReportsFailureOnThrow() async throws {
        let fetcher = FakeLatestReleaseFetcher(error: URLError(.notConnectedToInternet))
        let checker = UpdateChecker(fetcher: fetcher, currentVersion: "1.1")

        await checker.check()

        guard case let .failed(message) = checker.state else {
            Issue.record("Expected .failed, got \(checker.state)")
            return
        }

        #expect(!message.isEmpty)
    }
}

private struct FakeLatestReleaseFetcher: LatestReleaseFetching {
    let tagName: String
    let htmlURL: URL
    let error: Error?

    init(tagName: String = "v0.0", htmlURL: URL = URL(string: "https://example.com")!, error: Error? = nil) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.error = error
    }

    func fetchLatestRelease() async throws -> (tagName: String, htmlURL: URL) {
        if let error {
            throw error
        }
        return (tagName, htmlURL)
    }
}
