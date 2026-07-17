//
//  AXAccessibilityWakerTests.swift
//  LoreleiTests
//

import ApplicationServices
import Testing
@testable import Lorelei

struct AXAccessibilityWakerTests {
    @Test func dormantTreeStatusesAreWakeable() {
        #expect(AXAccessibilityWaker.isWakeable(.noValue))
        #expect(AXAccessibilityWaker.isWakeable(.cannotComplete))
    }

    @Test func hardFailuresAreNotWakeable() {
        #expect(!AXAccessibilityWaker.isWakeable(.success))
        #expect(!AXAccessibilityWaker.isWakeable(.apiDisabled))
        #expect(!AXAccessibilityWaker.isWakeable(.notImplemented))
        #expect(!AXAccessibilityWaker.isWakeable(.invalidUIElement))
        #expect(!AXAccessibilityWaker.isWakeable(.failure))
    }
}
