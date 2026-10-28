import UnderpressuredApplication
import Foundation
import Synchronization
import UnderpressuredCore

/// A scripted `ImageCodec` for tests.
///
/// Scripts are keyed by input bytes. `for: nil` (the default argument) sets the result for every input
/// that has no script of its own. Unscripted defaults: inspect gives JPEG 100 x 100 with one frame;
/// decode and transform succeed; encode returns half the input's bytes in the requested format at the
/// image's size with no notes.
///
/// Delays are gates, not sleeps. `hold(_:)` makes calls of one stage suspend until `release(_:)`.
/// `waitUntilStarted(_:count:)` returns once a call has begun, including one parked at a gate.
/// Every call is recorded in `calls`, in order.
public final class FakeCodec: ImageCodec, @unchecked Sendable {
    /// Decoded pixels in the fake: the scripted size and the source bytes.
    public struct Image: Sendable, Hashable {
        public var width: Int
        public var height: Int
        public var sourceData: Data

        public init(width: Int, height: Int, sourceData: Data) {
            self.width = width
            self.height = height
            self.sourceData = sourceData
        }
    }

    public enum Operation: Sendable, Hashable, CaseIterable {
        case inspect, decode, transform, encode
    }

    /// One recorded call. `input` is the source bytes (for transform and encode, the Image's sourceData).
    public enum Call: Sendable, Hashable {
        case inspect(Data)
        case decode(Data)
        case transform(Data, TransformPlan)
        case encode(Data, EncodePlan)

        public var operation: Operation {
            switch self {
            case .inspect: .inspect
            case .decode: .decode
            case .transform: .transform
            case .encode: .encode
            }
        }

        public var input: Data {
            switch self {
            case .inspect(let data), .decode(let data), .transform(let data, _), .encode(let data, _):
                data
            }
        }
    }

    private struct StartWaiter {
        let operation: Operation
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        static let defaultInfo = ImageInfo(format: .jpeg, pixelWidth: 100, pixelHeight: 100, frameCount: 1)

        var inspectResults: [Data?: Result<ImageInfo, CodecError>] = [:]
        var decodeResults: [Data?: Result<Void, CodecError>] = [:]
        var transformResults: [Data?: Result<Void, CodecError>] = [:]
        var encodeResults: [Data?: Result<EncodedImage, CodecError>] = [:]
        var held: Set<Operation> = []
        var parked: [Operation: [CheckedContinuation<Void, Never>]] = [:]
        var startCounts: [Operation: Int] = [:]
        var startWaiters: [StartWaiter] = []
        var calls: [Call] = []

        func scripted<T>(_ table: [Data?: T], for data: Data) -> T? {
            table[data] ?? table[Data?.none]
        }

        func inspectResult(for data: Data) -> Result<ImageInfo, CodecError> {
            scripted(inspectResults, for: data) ?? .success(Self.defaultInfo)
        }

        func decodeResult(for data: Data) -> Result<Image, CodecError> {
            switch scripted(decodeResults, for: data) ?? .success(()) {
            case .failure(let error):
                return .failure(error)
            case .success:
                let info: ImageInfo
                if case .success(let scriptedInfo) = inspectResult(for: data) {
                    info = scriptedInfo
                } else {
                    info = Self.defaultInfo
                }
                return .success(
                    Image(width: info.pixelWidth, height: info.pixelHeight, sourceData: data))
            }
        }

        func transformResult(for data: Data) -> Result<Void, CodecError> {
            scripted(transformResults, for: data) ?? .success(())
        }

        func encodeResult(for image: Image, plan: EncodePlan) -> Result<EncodedImage, CodecError> {
            if let found = scripted(encodeResults, for: image.sourceData) {
                return found
            }
            return .success(
                EncodedImage(
                    data: Data(count: image.sourceData.count / 2), format: plan.format,
                    pixelWidth: image.width, pixelHeight: image.height))
        }

        /// Records a call and returns the continuations of start-waiters that are now satisfied.
        mutating func record(_ call: Call) -> [CheckedContinuation<Void, Never>] {
            calls.append(call)
            startCounts[call.operation, default: 0] += 1
            let counts = startCounts
            let ready = startWaiters.filter { (counts[$0.operation] ?? 0) >= $0.count }
            startWaiters.removeAll { (counts[$0.operation] ?? 0) >= $0.count }
            return ready.map(\.continuation)
        }
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: Scripting

    /// The inspect result for `data`, or the default when `data` is nil.
    public func setInspect(_ result: Result<ImageInfo, CodecError>, for data: Data? = nil) {
        state.withLock { $0.inspectResults[data] = result }
    }

    /// Whether decode of `data` (or of every other input, when nil) succeeds or throws.
    public func setDecode(_ result: Result<Void, CodecError>, for data: Data? = nil) {
        state.withLock { $0.decodeResults[data] = result }
    }

    /// Whether transform of an Image with `data` as its source succeeds or throws.
    public func setTransform(_ result: Result<Void, CodecError>, for data: Data? = nil) {
        state.withLock { $0.transformResults[data] = result }
    }

    /// The encode result for an Image with `data` as its source, or the default when nil.
    public func setEncode(_ result: Result<EncodedImage, CodecError>, for data: Data? = nil) {
        state.withLock { $0.encodeResults[data] = result }
    }

    /// A successful encode returning `bytes` zero bytes in `format` at `width` x `height`.
    public func setEncode(
        bytes: Int, format: WritableFormat, width: Int, height: Int, notes: [Note] = [],
        for data: Data? = nil
    ) {
        setEncode(
            .success(
                EncodedImage(
                    data: Data(count: bytes), format: format, pixelWidth: width,
                    pixelHeight: height, notes: notes)),
            for: data)
    }

    // MARK: Gates

    /// Makes every call of `operation` suspend until `release(operation)`.
    public func hold(_ operation: Operation) {
        state.withLock { _ = $0.held.insert(operation) }
    }

    /// Stops holding `operation` and resumes every call parked on it. Later calls don't wait.
    public func release(_ operation: Operation) {
        let resumed = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.held.remove(operation)
            return s.parked.removeValue(forKey: operation) ?? []
        }
        for continuation in resumed {
            continuation.resume()
        }
    }

    /// Returns once at least `count` calls of `operation` have begun, counting calls since the codec was made.
    public func waitUntilStarted(_ operation: Operation, count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyStarted = state.withLock { s -> Bool in
                if (s.startCounts[operation] ?? 0) >= count { return true }
                s.startWaiters.append(
                    StartWaiter(operation: operation, count: count, continuation: continuation))
                return false
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    // MARK: Recording

    /// Every call made so far, in order.
    public var calls: [Call] {
        state.withLock { $0.calls }
    }

    /// How many calls of `operation` have been made.
    public func count(_ operation: Operation) -> Int {
        state.withLock { s in s.calls.filter { $0.operation == operation }.count }
    }

    // MARK: ImageCodec

    public func inspect(_ data: Data) async throws(CodecError) -> ImageInfo {
        await begin(.inspect(data))
        return try Self.unwrap(state.withLock { $0.inspectResult(for: data) })
    }

    public func decode(_ data: Data) async throws(CodecError) -> Image {
        await begin(.decode(data))
        return try Self.unwrap(state.withLock { $0.decodeResult(for: data) })
    }

    public func transform(_ image: Image, _ plan: TransformPlan) async throws(CodecError) -> Image {
        await begin(.transform(image.sourceData, plan))
        try Self.unwrap(state.withLock { $0.transformResult(for: image.sourceData) })
        return image
    }

    public func encode(_ image: Image, _ plan: EncodePlan) async throws(CodecError) -> EncodedImage {
        await begin(.encode(image.sourceData, plan))
        return try Self.unwrap(state.withLock { $0.encodeResult(for: image, plan: plan) })
    }

    // MARK: Helpers

    /// Records the call, wakes start-waiters, then suspends while the operation is held.
    private func begin(_ call: Call) async {
        let woken = state.withLock { $0.record(call) }
        for continuation in woken {
            continuation.resume()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = state.withLock { s -> Bool in
                guard s.held.contains(call.operation) else { return true }
                s.parked[call.operation, default: []].append(continuation)
                return false
            }
            if open {
                continuation.resume()
            }
        }
    }

    private static func unwrap<T>(_ result: Result<T, CodecError>) throws(CodecError) -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}
