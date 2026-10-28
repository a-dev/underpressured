import UnderpressuredCore
import Foundation
import Synchronization

/// Processes one Item, checking cancellation before each stage. Returns an Outcome without throwing.
/// One instance serves the Queue. Output reservations belong to the queue execution interval.
public struct Pipeline<Codec: ImageCodec>: Sendable {
    private let files: any FileAccess
    private let codec: Codec

    public init(fileAccess: any FileAccess, codec: Codec) {
        self.files = fileAccess
        self.codec = codec
    }

    /// The closure the Queue runs for each Item.
    public var itemPipeline: ItemPipeline {
        { item, batch, executionContext, gate in
            await run(item, in: batch, executionContext: executionContext, gate: gate)
        }
    }

    public func run(_ item: Item, in batch: BatchContext, executionContext: QueueExecutionContext, gate: StageGate) async -> Outcome {
        let started = ContinuousClock.now
        let outcome: Outcome
        do {
            outcome = try await process(item, in: batch, executionContext: executionContext, gate: gate)
        } catch {
            switch error {
            case .cancelled: outcome = .cancelled
            case .failed(let reason): outcome = .failed(reason)
            case .skipped(let reason): outcome = .skipped(reason, notes: [])
            }
        }
        let elapsed = started.duration(to: ContinuousClock.now).components
        let milliseconds = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        var savings: Savings?
        if case .optimized(let saved, _, _) = outcome { savings = saved }
        PipelineLog.item(
            source: item.source, outcome: outcome, bytesBefore: savings?.originalBytes,
            bytesAfter: savings?.newBytes, milliseconds: milliseconds)
        if case .failed(let reason) = outcome {
            PipelineLog.error(source: item.source, stage: nil, message: reason.diagnosticID)
        }
        return outcome
    }

    /// Why a stage left the pipeline early.
    enum Exit: Error {
        case cancelled
        case failed(FailReason)
        case skipped(SkipReason)
    }

    private func process(_ item: Item, in batch: BatchContext, executionContext: QueueExecutionContext, gate: StageGate) async throws(Exit) -> Outcome {
        // Step 1: read, recognise, mark check.
        try await enter(.checkingMark, gate)
        if case .exportFolder(let export) = batch.destination,
           !executionContext.exportFolderAvailable(batch.id, check: { isFolder(export) }) {
            throw .failed(.exportFolderUnavailable)
        }
        let source = try readSource(item.source)
        let info = try await inspect(source.data)
        let resolved: WritableFormat
        switch batch.outputFormat.resolve(for: info.format) {
        case .write(let format): resolved = format
        case .skip(let reason): throw .skipped(reason)
        }
        if hasMatchingMark(item.source, source.attributes, batch.settings, resolved) {
            return try await copyUnchangedIfExporting(.alreadyOptimized, item, batch, source, resolved, executionContext: executionContext, gate: gate)
        }

        // Step 2: decode, once the pixel budget has room (§7.7).
        try await enter(.decoding, gate)
        do { try await gate.reservePixels(info.pixelWidth * info.pixelHeight) } catch { throw .cancelled }
        let decoded = try await codecCall { () async throws(CodecError) in try await codec.decode(source.data) }

        // Steps 3–5: plan the output, then transform the pixels.
        try await enter(.transforming, gate)
        let plan = try planOutput(item, batch, sourceFormat: info.format, resolved: resolved, executionContext: executionContext)
        let transformPlan = TransformPlan(
            resizeRule: batch.settings.resizeRule, flattenOntoWhite: resolved.flattensTransparencyOntoWhite)
        let transformed = try await codecCall { () async throws(CodecError) in
            try await codec.transform(decoded, transformPlan)
        }

        // Steps 6–7: metadata and encode, into memory.
        try await enter(.encoding, gate)
        let encodePlan = EncodePlan(
            format: resolved, quality: batch.settings.quality, lossless: batch.settings.lossless,
            keepMetadata: batch.settings.keepMetadata)
        let encoded = try await codecCall { () async throws(CodecError) in
            try await codec.encode(transformed, encodePlan)
        }

        // Step 8: not-smaller rule.
        let decision = NotSmallerRule.decide(
            sourceFormat: info.format, sourcePixelWidth: info.pixelWidth, sourcePixelHeight: info.pixelHeight,
            sourceBytes: Int64(source.data.count), outputFormat: encoded.format,
            outputPixelWidth: encoded.pixelWidth, outputPixelHeight: encoded.pixelHeight,
            outputBytes: Int64(encoded.data.count))
        if case .skip(let reason) = decision {
            return try await copyUnchangedIfExporting(reason, item, batch, source, resolved, executionContext: executionContext, gate: gate, plan: plan)
        }

        // Steps 9–10: write, then report Savings.
        let writeNotes = try await write(
            encoded.data, to: plan, item: item, batch: batch, source: source, format: resolved, gate: gate)
        return .optimized(
            Savings(originalBytes: Int64(source.data.count), newBytes: Int64(encoded.data.count)),
            notes: encoded.notes + writeNotes, output: plan.path)
    }

    // MARK: Steps

    private struct Source {
        var data: Data
        /// As read, for change detection right before the move (§7.3 step 9).
        var attributes: FileAttributes
    }

    private func enter(_ stage: Stage, _ gate: StageGate) async throws(Exit) {
        do { try await gate.enter(stage) } catch { throw .cancelled }
    }

    private func isFolder(_ url: URL) -> Bool {
        (try? files.attributes(of: url).kind) == .directory
    }

    private func readSource(_ url: URL) throws(Exit) -> Source {
        do {
            let attributes = try files.attributes(of: url)
            return Source(data: try files.readData(at: url), attributes: attributes)
        } catch {
            throw .failed(error.failReason)
        }
    }

    /// Animated images and multi-page TIFFs are only recognisable once the file is opened (§7.2).
    private func inspect(_ data: Data) async throws(Exit) -> ImageInfo {
        let info = try await codecCall { () async throws(CodecError) in try await codec.inspect(data) }
        if info.frameCount > 1 {
            throw .skipped(.unsupported(info.format == .tiff ? .multiPageTIFF : .animated))
        }
        return info
    }

    private func hasMatchingMark(
        _ url: URL, _ attributes: FileAttributes, _ settings: EffectiveSettings, _ format: WritableFormat
    ) -> Bool {
        guard let mark = try? files.markedOutput(at: url)?.mark
        else { return false }
        return mark.isValid(for: attributes) && mark.matches(settings: settings, outputFormat: format)
    }

    private func planOutput(
        _ item: Item, _ batch: BatchContext, sourceFormat: ImageFormat, resolved: WritableFormat, executionContext: QueueExecutionContext
    ) throws(Exit) -> OutputPlan {
        let name = outputFileName(
            sourceFileName: item.source.lastPathComponent, source: sourceFormat, resolved: resolved)
        do {
            return try executionContext.plan(files: files) { (planner: inout OutputPathPlanner) throws(FileAccessError) in
                try planner.plan(
                    source: item.source, droppedRoot: item.droppedRoot, outputFileName: name,
                    sameFormat: sourceFormat == resolved.imageFormat, destination: batch.destination)
            }
        } catch {
            throw .failed(error.failReason)
        }
    }

    /// Skip the Item. Copy already-optimal or already-optimized sources unchanged to complete an export.
    private func copyUnchangedIfExporting(
        _ reason: SkipReason, _ item: Item, _ batch: BatchContext, _ source: Source, _ format: WritableFormat,
        executionContext: QueueExecutionContext, gate: StageGate, plan: OutputPlan? = nil
    ) async throws(Exit) -> Outcome {
        guard case .exportFolder = batch.destination, reason.copiesToExportFolder else {
            throw .skipped(reason)
        }
        // Skipping means the format didn't change, so the copy keeps the source's name.
        let target: OutputPlan
        if let plan { target = plan } else {
            target = try planOutput(item, batch, sourceFormat: format.imageFormat, resolved: format, executionContext: executionContext)
        }
        let writeNotes = try await write(
            source.data, to: target, item: item, batch: batch, source: source, format: format, gate: gate)
        return .skipped(reason, notes: [.copiedUnchanged] + writeNotes, output: target.path)
    }

    /// Apply dates, tags, and the mark before the temporary file becomes visible.
    private func write(
        _ data: Data, to plan: OutputPlan, item: Item, batch: BatchContext, source: Source,
        format: WritableFormat, gate: StageGate
    ) async throws(Exit) -> [Note] {
        try await enter(.writing, gate)
        var replacesOriginals = false
        var moveToTrash = false
        if case .replaceOriginals(let trash) = batch.destination { (replacesOriginals, moveToTrash) = (true, trash) }
        if moveToTrash, !files.hasTrash(forItemAt: item.source) { throw .failed(.noTrash) }

        let temp = try prepareTemporaryFile(data, for: plan, item: item, batch: batch, format: format)
        do { try await enter(.writing, gate) } catch {
            removeQuietly(temp)
            throw error
        }
        guard sourceUnchanged(item.source, since: source.attributes) else {
            removeQuietly(temp)
            throw .failed(.fileChanged)
        }
        do {
            let notes = try commit(
                temp, plan: plan, source: item.source, replacesOriginals: replacesOriginals,
                moveToTrash: moveToTrash)
            gate.committed()
            return notes
        } catch {
            removeQuietly(temp)
            throw .failed(error.failReason)
        }
    }

    /// The result, complete with the source's dates and tags and the mark, next to its target.
    private func prepareTemporaryFile(
        _ data: Data, for plan: OutputPlan, item: Item, batch: BatchContext, format: WritableFormat
    ) throws(Exit) -> URL {
        var temporary: URL?
        do throws(FileAccessError) {
            for folder in plan.foldersToCreate where !files.fileExists(at: folder) {
                // Parallel Items race to create the same folder; losing the race is fine.
                do throws(FileAccessError) { try files.createDirectory(at: folder) } catch {
                    if !files.fileExists(at: folder) { throw error }
                }
            }
            let temp = try files.writeTemporaryFile(data, near: plan.path)
            temporary = temp
            try files.copyDatesAndTags(from: item.source, to: temp)
            let written = try files.attributes(of: temp)
            let mark = OptimizationMark(
                settings: batch.settings, outputFormat: format, size: written.size,
                modificationDate: written.modificationDate)
            try files.setOptimizationMark(mark, at: temp)
            // Last: a read-only source makes the temporary file read-only too.
            try files.copyPermissions(from: item.source, to: temp)
            return temp
        } catch {
            removeQuietly(temporary)
            throw .failed(error.failReason)
        }
    }

    private func sourceUnchanged(_ url: URL, since before: FileAttributes) -> Bool {
        guard let now = try? files.attributes(of: url) else { return false }
        return now.size == before.size && now.modificationDate == before.modificationDate
            && now.fileIdentity == before.fileIdentity
    }

    /// Moves the finished temporary file into place following the Destination rules (§6).
    private func commit(
        _ temp: URL, plan: OutputPlan, source: URL, replacesOriginals: Bool, moveToTrash: Bool
    ) throws(FileAccessError) -> [Note] {
        switch plan.kind {
        case .replaceSource where moveToTrash:
            // Trash first to keep the source recoverable. The following move cannot overwrite a file.
            try files.trashItem(at: source)
            try files.moveItem(at: temp, to: plan.path)
        case .overwriteMarked(let expected):
            try files.replaceMarkedItem(at: plan.path, withItemAt: temp, expected: expected)
        case .replaceSource:
            try files.replaceItem(at: plan.path, withItemAt: temp)
        case .newFile:
            try files.moveItem(at: temp, to: plan.path)
            // Replace originals with a format change: the source goes only once the new file is in place.
            guard replacesOriginals else { return [] }
            do {
                if moveToTrash { try files.trashItem(at: source) } else { try files.removeItem(at: source) }
            } catch {
                PipelineLog.error(source: source, stage: .writing, message: "Output saved at \(plan.path.path); source cleanup failed: \(error)")
                return [.sourceCleanupFailed]
            }
        }
        return []
    }

    private func removeQuietly(_ url: URL?) {
        if let url { try? files.removeItem(at: url) }
    }

    private func codecCall<T>(_ body: () async throws(CodecError) -> T) async throws(Exit) -> T {
        do {
            return try await body()
        } catch {
            switch error {
            case .unreadable: throw .failed(.cantRead)
            case .encodeFailed: throw .failed(.encodeFailed)
            case .losslessEncoderUnavailable: throw .failed(.losslessEncoderUnavailable)
            }
        }
    }
}
