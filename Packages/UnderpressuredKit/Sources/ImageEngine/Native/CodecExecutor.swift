import UnderpressuredApplication
import Dispatch
import UnderpressuredCore

/// Runs synchronous codecs on a dedicated queue to keep Swift cooperative threads available.
enum CodecExecutor {
    private static let queue = DispatchQueue(
        label: "app.underpressured.codec", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(
        _ work: @escaping @Sendable () throws(CodecError) -> T
    ) async throws(CodecError) -> T {
        let result: Result<T, CodecError> = await withCheckedContinuation { continuation in
            queue.async {
                do throws(CodecError) {
                    continuation.resume(returning: .success(try work()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }
}
