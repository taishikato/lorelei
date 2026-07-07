//
//  UpdateChecker.swift
//  Lorelei
//
//  Manual "Check for Updates" against GitHub Releases. No auto-download or
//  install - this only compares versions and, if newer, hands the user off
//  to the release page in their browser.
//

import Combine
import Foundation

struct UpdateCheckResult: Equatable {
    let latestVersion: String
    let releaseURL: URL
    let isNewer: Bool
}

protocol LatestReleaseFetching {
    func fetchLatestRelease() async throws -> (tagName: String, htmlURL: URL)
}

struct GitHubLatestReleaseFetcher: LatestReleaseFetching {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/taishikato/lorelei/releases/latest"
    )!

    private struct LatestReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    func fetchLatestRelease() async throws -> (tagName: String, htmlURL: URL) {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(LatestReleaseResponse.self, from: data)
        return (response.tagName, response.htmlURL)
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case updateAvailable(UpdateCheckResult)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let fetcher: LatestReleaseFetching
    private let currentVersion: String

    init(
        fetcher: LatestReleaseFetching = GitHubLatestReleaseFetcher(),
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    ) {
        self.fetcher = fetcher
        self.currentVersion = currentVersion
    }

    func check() async {
        state = .checking

        do {
            let (tagName, htmlURL) = try await fetcher.fetchLatestRelease()
            let isNewer = Self.isVersion(tagName, newerThan: currentVersion)

            if isNewer {
                state = .updateAvailable(
                    UpdateCheckResult(latestVersion: tagName, releaseURL: htmlURL, isNewer: true)
                )
            } else {
                state = .upToDate(tagName)
            }

            LoreleiAnalytics.capture(.updateCheckPerformed(updateAvailable: isNewer))
        } catch {
            state = .failed("Couldn't check for updates")
        }
    }

    /// Compares two `vX.Y[.Z]`-style version strings (a leading `v`/`V` is
    /// stripped) by numeric component, left to right. Missing or non-numeric
    /// components count as 0 - malformed tags should never crash, just
    /// compare as not-newer.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateComponents = versionComponents(candidate)
        let currentComponents = versionComponents(current)
        let count = max(candidateComponents.count, currentComponents.count)

        for index in 0..<count {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0

            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }

        return false
    }

    private static func versionComponents(_ version: String) -> [Int] {
        var trimmed = version
        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }

        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }
}
