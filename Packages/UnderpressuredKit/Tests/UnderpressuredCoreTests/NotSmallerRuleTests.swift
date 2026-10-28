import Testing
@testable import UnderpressuredCore

@Suite struct NotSmallerRuleTests {
    // Same format, same pixel size: the only rule that can skip.

    @Test func notSmaller_spec7_3_step8_equalBytesIsSkippedAsAlreadyOptimal() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .jpeg, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .jpeg, outputPixelWidth: 800, outputPixelHeight: 600, outputBytes: 1_000
        )
        #expect(decision == .skip(.alreadyOptimal))
    }

    @Test func notSmaller_spec7_3_step8_largerOutputIsSkippedAsAlreadyOptimal() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .png, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .png, outputPixelWidth: 800, outputPixelHeight: 600, outputBytes: 1_001
        )
        #expect(decision == .skip(.alreadyOptimal))
    }

    @Test func notSmaller_spec7_3_step8_smallerOutputIsWritten() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .jpeg, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .jpeg, outputPixelWidth: 800, outputPixelHeight: 600, outputBytes: 999
        )
        #expect(decision == .write)
    }

    // A conversion or a resize is written regardless of size.

    @Test func notSmaller_spec7_3_step8_conversionIsWrittenEvenWhenLarger() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .heic, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .jpeg, outputPixelWidth: 800, outputPixelHeight: 600, outputBytes: 5_000
        )
        #expect(decision == .write)
    }

    @Test func notSmaller_spec7_3_step8_conversionIsWrittenWhenEqual() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .png, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .jpeg, outputPixelWidth: 800, outputPixelHeight: 600, outputBytes: 1_000
        )
        #expect(decision == .write)
    }

    @Test func notSmaller_spec7_3_step8_resizeIsWrittenEvenWhenLarger() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .jpeg, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .jpeg, outputPixelWidth: 400, outputPixelHeight: 300, outputBytes: 5_000
        )
        #expect(decision == .write)
    }

    @Test func notSmaller_spec7_3_step8_heightOnlyChangeCountsAsResize() {
        let decision = NotSmallerRule.decide(
            sourceFormat: .png, sourcePixelWidth: 800, sourcePixelHeight: 600, sourceBytes: 1_000,
            outputFormat: .png, outputPixelWidth: 800, outputPixelHeight: 599, outputBytes: 1_000
        )
        #expect(decision == .write)
    }
}
