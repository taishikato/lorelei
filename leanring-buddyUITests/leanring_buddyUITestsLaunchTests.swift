//
//  leanring_buddyUITestsLaunchTests.swift
//  leanring-buddyUITests
//
//  Created by thorfinn on 3/2/26.
//

import XCTest

final class leanring_buddyUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        throw XCTSkip("Lorelei's launch flow is verified by local app launch smoke until a TCC-aware UI harness exists.")
    }
}
