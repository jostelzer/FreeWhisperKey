import XCTest
@testable import TranscribeMenuApp

final class StartupCaptureCoordinatorTests: XCTestCase {
    func testResolveOnRecorderStartBeginsRecordingWhenNoEarlyRelease() {
        var coordinator = StartupCaptureCoordinator()

        XCTAssertEqual(coordinator.resolveOnRecorderStart(), .beginRecording)
        XCTAssertFalse(coordinator.releasedBeforeRecorderStart)
    }

    func testResolveOnRecorderStartCancelsWhenReleasedBeforeStart() {
        var coordinator = StartupCaptureCoordinator()
        coordinator.markReleaseBeforeRecorderStart()

        XCTAssertEqual(coordinator.resolveOnRecorderStart(), .cancelCapture)
        XCTAssertFalse(coordinator.releasedBeforeRecorderStart)
    }

    func testCoordinatorResetsAfterCancelDecision() {
        var coordinator = StartupCaptureCoordinator()
        coordinator.markReleaseBeforeRecorderStart()

        XCTAssertEqual(coordinator.resolveOnRecorderStart(), .cancelCapture)
        XCTAssertEqual(coordinator.resolveOnRecorderStart(), .beginRecording)
    }
}
