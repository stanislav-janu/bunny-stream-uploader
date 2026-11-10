import XCTest
@testable import BunnyUploaderCore

final class SleepCheckTests: XCTestCase {
    private let output = """
    Assertion status system-wide:
       PreventUserIdleSystemSleep     1
    Listed by owning process:
       pid 4242(BunnyUploader): [0x0001] 00:00:05 PreventUserIdleSystemSleep named: "Uploading videos to Bunny"
       pid 99(coreaudiod): [0x0002] 00:10:00 PreventUserIdleSystemSleep named: "audio"
       pid 4243(Other): [0x0003] 00:00:01 PreventUserIdleDisplaySleep named: "video"
    """

    func testFindsTheProcessAssertion() {
        XCTAssertTrue(SleepCheck.assertionHeld(in: output, pid: 4242))
    }

    func testIgnoresOtherProcessesAndOtherAssertionTypes() {
        XCTAssertFalse(SleepCheck.assertionHeld(in: output, pid: 424))
        XCTAssertFalse(SleepCheck.assertionHeld(in: output, pid: 4243))
        XCTAssertFalse(SleepCheck.assertionHeld(in: "", pid: 4242))
    }
}
