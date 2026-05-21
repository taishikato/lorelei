//
//  leanring_buddyUITests.swift
//  leanring-buddyUITests
//
//  Created by thorfinn on 3/2/26.
//

import XCTest

final class leanring_buddyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testManualTCCFlowIsNotAutomatedYet() throws {
        throw XCTSkip("Lorelei is a menu bar voice app with local TCC prompts; use the manual launch smoke for MVP verification.")
    }
}
