import UnderpressuredApplication
import MacPlatform
import AppKit
import AppModel
import ImageEngine
import LocalFileSystem
import UnderpressuredCore

/// Builds the real AppModel: LocalFileAccess + NativeCodec behind the Queue.
@MainActor
enum AppWiring {
    static func makeModel() -> AppModel {
        let files = LocalFileAccess()
        let pipeline = Pipeline(fileAccess: files, codec: NativeCodec())
        // One Item per performance core; the pixel budget caps decoded pixels in flight (§7.7).
        let queue = Queue(parallelism: PerformanceCores.count(), pipeline: pipeline.itemPipeline)
        return AppModel(
            queue: queue,
            intake: { urls, exportFolder, isActive in
                Scanner(files: files).scan(urls, exportFolder: exportFolder, isActive: isActive)
            },
            settingsStore: UserDefaultsSettingsStore(),
            notifier: UserNotifier(),
            sleepPreventer: PowerAssertionSleepPreventer(),
            isFrontmost: { NSApp.isActive })
    }
}
