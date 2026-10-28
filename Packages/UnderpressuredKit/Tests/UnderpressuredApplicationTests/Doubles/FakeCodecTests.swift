import UnderpressuredApplication
import Foundation
import QueueTestSupport

import Synchronization
import Testing
@testable import UnderpressuredCore

@Suite("FakeCodec")
struct FakeCodecTests {
    @Test func inspect_defaultsToJPEG100x100AndRecordsTheCall() async throws {
        let codec = FakeCodec()
        let data = Data("a".utf8)

        let info = try await codec.inspect(data)

        #expect(info == ImageInfo(format: .jpeg, pixelWidth: 100, pixelHeight: 100))
        #expect(codec.calls == [.inspect(data)])
    }

    @Test func inspect_scriptedResultAppliesOnlyToItsInput() async throws {
        let codec = FakeCodec()
        let png = Data("png".utf8)
        let other = Data("other".utf8)
        let scripted = ImageInfo(format: .png, pixelWidth: 640, pixelHeight: 480, frameCount: 3)
        codec.setInspect(.success(scripted), for: png)

        let forPNG = try await codec.inspect(png)
        let forOther = try await codec.inspect(other)

        #expect(forPNG == scripted)
        #expect(forOther.format == .jpeg)
    }

    @Test func decode_scriptedFailureThrowsOnlyForItsInput() async throws {
        let codec = FakeCodec()
        let bad = Data("bad".utf8)
        let good = Data("good".utf8)
        codec.setDecode(.failure(.unreadable), for: bad)

        await #expect(throws: CodecError.unreadable) {
            try await codec.decode(bad)
        }
        let image = try await codec.decode(good)
        #expect(image.sourceData == good)
    }

    @Test func decode_returnsImageWithTheScriptedSize() async throws {
        let codec = FakeCodec()
        let data = Data("big".utf8)
        codec.setInspect(.success(ImageInfo(format: .jpeg, pixelWidth: 2048, pixelHeight: 1365)), for: data)

        let image = try await codec.decode(data)

        #expect(image == FakeCodec.Image(width: 2048, height: 1365, sourceData: data))
    }

    @Test func transform_scriptedFailureThrowsAndPlanIsRecorded() async throws {
        let codec = FakeCodec()
        let data = Data("t".utf8)
        let image = FakeCodec.Image(width: 10, height: 10, sourceData: data)
        let plan = TransformPlan(resizeRule: .maxLongEdge(2048), flattenOntoWhite: true)
        codec.setTransform(.failure(.unreadable), for: data)

        await #expect(throws: CodecError.unreadable) {
            try await codec.transform(image, plan)
        }
        #expect(codec.calls == [.transform(data, plan)])
    }

    @Test func encode_returnsScriptedBytesFormatSizeAndNotes() async throws {
        let codec = FakeCodec()
        let data = Data("e".utf8)
        let image = FakeCodec.Image(width: 1600, height: 900, sourceData: data)
        let plan = EncodePlan(format: .png, quality: 80, lossless: false, keepMetadata: false)
        codec.setEncode(bytes: 1234, format: .png, width: 800, height: 450, notes: [.keptFullColor], for: data)

        let output = try await codec.encode(image, plan)

        #expect(
            output == EncodedImage(
                data: Data(count: 1234), format: .png, pixelWidth: 800, pixelHeight: 450,
                notes: [.keptFullColor]))
    }

    @Test func encode_scriptedFailureThrowsEncodeFailed() async throws {
        let codec = FakeCodec()
        let data = Data("f".utf8)
        let image = FakeCodec.Image(width: 1, height: 1, sourceData: data)
        let plan = EncodePlan(format: .jpeg, quality: 85, lossless: false, keepMetadata: true)
        codec.setEncode(.failure(.encodeFailed("disk")), for: data)

        await #expect(throws: CodecError.encodeFailed("disk")) {
            try await codec.encode(image, plan)
        }
    }

    @Test func hold_keepsCallInFlightUntilReleased() async throws {
        let codec = FakeCodec()
        let data = Data("held".utf8)
        let finished = Mutex(false)
        codec.hold(.decode)

        let task = Task {
            let image = try await codec.decode(data)
            finished.withLock { $0 = true }
            return image
        }
        await codec.waitUntilStarted(.decode)

        #expect(codec.count(.decode) == 1)
        #expect(finished.withLock { $0 } == false)

        codec.release(.decode)
        let image = try await task.value
        #expect(image.sourceData == data)
        #expect(finished.withLock { $0 } == true)
    }

    @Test func hold_affectsOnlyTheHeldOperation() async throws {
        let codec = FakeCodec()
        codec.hold(.decode)

        // Would suspend forever if inspect were held too.
        let info = try await codec.inspect(Data("x".utf8))

        #expect(info.format == .jpeg)
    }

    @Test func release_resumesEveryParkedCallAndLaterCallsDoNotWait() async throws {
        let codec = FakeCodec()
        let data = Data("two".utf8)
        codec.hold(.decode)
        let first = Task { try await codec.decode(data) }
        let second = Task { try await codec.decode(data) }
        await codec.waitUntilStarted(.decode, count: 2)

        codec.release(.decode)

        let firstImage = try await first.value
        let secondImage = try await second.value
        #expect(firstImage.sourceData == data)
        #expect(secondImage.sourceData == data)

        // Would hang if the release had not cleared the hold.
        _ = try await codec.decode(data)
        #expect(codec.count(.decode) == 3)
    }

    @Test func waitUntilStarted_returnsAtOnceForCallsThatAlreadyHappened() async throws {
        let codec = FakeCodec()
        let data = Data("done".utf8)
        let image = FakeCodec.Image(width: 1, height: 1, sourceData: data)
        _ = try await codec.encode(image, EncodePlan(format: .jpeg, quality: 80, lossless: false, keepMetadata: false))

        // Would hang if it waited for a new call.
        await codec.waitUntilStarted(.encode)

        #expect(codec.count(.encode) == 1)
    }

    @Test func calls_recordInputsAndPlansInOrder() async throws {
        let codec = FakeCodec()
        let data = Data("seq".utf8)
        let transformPlan = TransformPlan(resizeRule: .none, flattenOntoWhite: false)
        let encodePlan = EncodePlan(format: .jpeg, quality: 70, lossless: false, keepMetadata: false)

        _ = try await codec.inspect(data)
        let decoded = try await codec.decode(data)
        let transformed = try await codec.transform(decoded, transformPlan)
        _ = try await codec.encode(transformed, encodePlan)

        #expect(
            codec.calls == [
                .inspect(data),
                .decode(data),
                .transform(data, transformPlan),
                .encode(data, encodePlan),
            ])
        #expect(codec.calls.map(\.operation) == [.inspect, .decode, .transform, .encode])
    }
}
