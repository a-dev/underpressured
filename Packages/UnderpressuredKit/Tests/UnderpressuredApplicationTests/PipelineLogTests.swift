import Foundation
import Testing

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

struct PipelineLogTests {
    @Test func message_spec8_optimized() {
        let text = PipelineLog.message(
            outcome: .optimized(Savings(originalBytes: 1000, newBytes: 400), notes: [], output: URL(filePath: "/out")),
            bytesBefore: 1000, bytesAfter: 400, milliseconds: 12)
        #expect(text == "outcome=optimized reason=\"-\" bytes=1000->400 ms=12")
    }

    @Test func message_spec8_skipped() {
        let text = PipelineLog.message(
            outcome: .skipped(.alreadyOptimal, notes: []), bytesBefore: nil, bytesAfter: nil, milliseconds: 3)
        #expect(text == "outcome=skipped reason=\"already_optimal\" bytes=-->- ms=3")
    }

    @Test func message_spec8_failed() {
        let text = PipelineLog.message(
            outcome: .failed(.diskFull), bytesBefore: nil, bytesAfter: nil, milliseconds: 7)
        #expect(text == "outcome=failed reason=\"disk_full\" bytes=-->- ms=7")
    }

    @Test func message_spec8_cancelled() {
        let text = PipelineLog.message(outcome: .cancelled, bytesBefore: nil, bytesAfter: nil, milliseconds: 0)
        #expect(text == "outcome=cancelled reason=\"-\" bytes=-->- ms=0")
    }
}
