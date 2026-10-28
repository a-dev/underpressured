import UnderpressuredApplication
import Foundation

/// Buffers incoming URLs until the window attaches the model.
@MainActor
public final class OpenRouter {
    private var pending: [[URL]] = []
    private var model: AppModel?

    public init() {}

    /// Opens `urls` now if a model is attached, otherwise keeps them for `attach(_:)`.
    public func open(_ urls: [URL]) async {
        guard let model else {
            pending.append(urls)
            return
        }
        await model.open(urls)
    }

    /// Attaches the model and opens everything received so far, in arrival order.
    public func attach(_ model: AppModel) async {
        self.model = model
        let waiting = pending
        pending = []
        for urls in waiting { await model.open(urls) }
    }
}
