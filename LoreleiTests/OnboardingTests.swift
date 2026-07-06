//
//  OnboardingTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct OnboardingTests {
    @Test func shouldShowIsTrueOnAFreshDefaultsDomain() async throws {
        let defaults = UserDefaults(suiteName: "OnboardingTests.fresh")!
        defaults.removePersistentDomain(forName: "OnboardingTests.fresh")

        #expect(LoreleiOnboarding.shouldShow(defaults: defaults))
    }

    @Test func shouldShowIsFalseAfterCompletion() async throws {
        let defaults = UserDefaults(suiteName: "OnboardingTests.completed")!
        defaults.removePersistentDomain(forName: "OnboardingTests.completed")
        defaults.set(true, forKey: LoreleiOnboarding.completedDefaultsKey)

        #expect(!LoreleiOnboarding.shouldShow(defaults: defaults))
    }
}
