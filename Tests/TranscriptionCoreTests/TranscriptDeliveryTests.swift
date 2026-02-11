import XCTest
@testable import TranscriptionCore

final class TranscriptDeliveryTests: XCTestCase {
    private let autoPasteConfig = TranscriptDeliveryConfiguration(
        autoPasteEnabled: true,
        prependSpaceBeforePaste: false,
        insertNewlineOnBreak: false
    )

    func testProcessTranscriptSkipsBlankAudioSentinel() {
        let delivery = TranscriptDelivery()

        let result = delivery.processTranscript("[BLANK_AUDIO]", configuration: autoPasteConfig)

        XCTAssertNil(result)
    }

    func testProcessTranscriptSkipsEmptyText() {
        let delivery = TranscriptDelivery()

        let result = delivery.processTranscript("", configuration: autoPasteConfig)

        XCTAssertNil(result)
    }

    func testProcessTranscriptSkipsWhitespaceOnlyText() {
        let delivery = TranscriptDelivery()

        let result = delivery.processTranscript(" \n\t ", configuration: autoPasteConfig)

        XCTAssertNil(result)
    }

    func testProcessTranscriptStillReturnsPasteForNormalTranscript() {
        let delivery = TranscriptDelivery()

        let result = delivery.processTranscript("hello world", configuration: autoPasteConfig)

        switch result?.action {
        case .paste(let text):
            XCTAssertEqual(text, "hello world")
        default:
            XCTFail("Expected a paste action for non-empty transcript.")
        }
    }
}
