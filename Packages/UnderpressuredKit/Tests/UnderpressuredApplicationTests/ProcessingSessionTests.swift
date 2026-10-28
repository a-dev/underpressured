import Foundation
import Synchronization
import Testing

@testable import UnderpressuredApplication
import UnderpressuredCore

/// A bounded gate keeps a scan in flight until the test releases it.
private final class HeldScan: Sendable {
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)

    func waitUntilStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForRelease() -> Bool {
        release.wait(timeout: .now() + 5) == .success
    }

    func releaseScan() { release.signal() }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProcessingSessionTests {
    private func capture(
        preset: Preset? = nil,
        outputFormat: OutputFormat = .jpeg,
        destination: Destination = .exportFolder(URL(filePath: "/export"))
    ) -> ProcessingSession.Capture {
        ProcessingSession.Capture(
            preset: preset ?? Preset(
                name: "Web", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: outputFormat,
            destination: destination)
    }

    private func queue() -> Queue {
        Queue(parallelism: 1) { item, _, _, _ in
            .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: item.source)
        }
    }

    nonisolated private func items(_ urls: [URL]) -> ScanResult {
        ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
    }

    @Test func capturesSettingsBeforeStartingScanAndAdmitsCapturedBatch() async {
        let order = Mutex<[String]>([])
        let observed = Mutex<[Batch]>([])
        let session = ProcessingSession(queue: queue(), intake: { urls, _, _ in
            order.withLock { $0.append("scan") }
            return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        })
        session.onEvent = { event in
            if case .queue(.batchAdded(let batch)) = event {
                observed.withLock { $0.append(batch) }
            }
        }

        let expected = capture(
            preset: Preset(name: "Captured", quality: 61, lossless: true,
                           resizeRule: .maxLongEdge(1200), keepMetadata: true),
            outputFormat: .png,
            destination: .exportFolder(URL(filePath: "/captured-export")))
        await session.open([URL(filePath: "/photo.jpg")]) {
            order.withLock { $0.append("capture") }
            return expected
        }
        await session.untilIdle()

        #expect(order.withLock { $0 } == ["capture", "scan"])
        let batch = observed.withLock { $0.first }
        #expect(batch?.settings == expected.preset.settings)
        #expect(batch?.outputFormat == expected.outputFormat)
        #expect(batch?.destination == expected.destination)
        #expect(batch?.items.map(\.source) == [URL(filePath: "/photo.jpg")])
    }

    @Test func runStartObserverCannotTreatRegisteredIntakeAsIdle() async throws {
        let heldScan = HeldScan()
        defer { heldScan.releaseScan() }
        let session = ProcessingSession(queue: queue(), intake: { urls, _, _ in
            heldScan.started.continuation.yield(())
            #expect(heldScan.waitForRelease())
            return items(urls)
        })
        var token: UUID?
        var idleCalls = 0
        session.onEvent = { event in
            if case .runStarted = event {
                token = session.reserveIdleOperation { idleCalls += 1 }
            }
        }
        let opening = Task { await session.open([URL(filePath: "/registered.jpg")]) { capture() } }
        await heldScan.waitUntilStarted()
        #expect(idleCalls == 0)
        heldScan.releaseScan()
        await opening.value
        await session.untilIdle()
        #expect(idleCalls == 1)
        session.releaseIdleOperation(try #require(token))
    }

    @Test func cancellationWhileScanIsHeldDiscardsLateResults() async {
        let heldScan = HeldScan()
        let batches = Mutex<[Batch]>([])
        let session = ProcessingSession(queue: queue(), intake: { urls, _, _ in
            heldScan.started.continuation.yield(())
            #expect(heldScan.waitForRelease())
            return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        })
        session.onEvent = { event in
            if case .queue(.batchAdded(let batch)) = event {
                batches.withLock { $0.append(batch) }
            }
        }

        let open = Task {
            await session.open([URL(filePath: "/cancelled.jpg")]) { capture() }
        }
        await heldScan.waitUntilStarted()
        await session.cancel()
        #expect(!session.activity.isRunning)
        heldScan.releaseScan()
        await open.value
        await session.untilIdle()

        #expect(batches.withLock { $0 }.isEmpty)
        #expect(!session.activity.isRunning)
    }

    @Test func reservationLocksAdmissionImmediatelyUntilReleased() async throws {
        let batches = Mutex<[Batch]>([])
        let captureCalls = Mutex(0)
        let session = ProcessingSession(queue: queue(), intake: { urls, _, _ in items(urls) })
        session.onEvent = { event in
            if case .queue(.batchAdded(let batch)) = event {
                batches.withLock { $0.append(batch) }
            }
        }
        var actionCalls = 0
        let token = try #require(session.reserveIdleOperation { actionCalls += 1 })
        #expect(actionCalls == 1)

        let willOpen = AsyncStream<Void>.makeStream()
        let open = Task {
            willOpen.continuation.yield(())
            await session.open([URL(filePath: "/reserved.jpg")]) {
                captureCalls.withLock { $0 += 1 }
                return capture()
            }
        }
        var iterator = willOpen.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(captureCalls.withLock { $0 } == 0)
        #expect(batches.withLock { $0 }.isEmpty)

        session.releaseIdleOperation(token)
        await open.value
        await session.untilIdle()
        #expect(captureCalls.withLock { $0 } == 1)
        #expect(batches.withLock { $0 }.map { $0.items.map(\.source) }
            == [[URL(filePath: "/reserved.jpg")]])
        #expect(actionCalls == 1)
    }

    @Test func staleReservationTokenCannotReleaseCurrentReservation() async throws {
        let batches = Mutex<[Batch]>([])
        let captureCalls = Mutex(0)
        let session = ProcessingSession(queue: queue(), intake: { urls, _, _ in items(urls) })
        session.onEvent = { event in
            if case .queue(.batchAdded(let batch)) = event {
                batches.withLock { $0.append(batch) }
            }
        }
        let firstToken = try #require(session.reserveIdleOperation {})
        session.releaseIdleOperation(firstToken)
        let secondToken = try #require(session.reserveIdleOperation {})
        session.releaseIdleOperation(firstToken)

        let willOpen = AsyncStream<Void>.makeStream()
        let open = Task {
            willOpen.continuation.yield(())
            await session.open([URL(filePath: "/current-reservation.jpg")]) {
                captureCalls.withLock { $0 += 1 }
                return capture()
            }
        }
        var iterator = willOpen.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(captureCalls.withLock { $0 } == 0)
        #expect(batches.withLock { $0 }.isEmpty)

        session.releaseIdleOperation(secondToken)
        await open.value
        await session.untilIdle()
        #expect(captureCalls.withLock { $0 } == 1)
        #expect(batches.withLock { $0 }.map { $0.items.map(\.source) }
            == [[URL(filePath: "/current-reservation.jpg")]])
    }

    @Test func idleActionFollowsPendingScanAndTerminalQueueOutcome() async throws {
        let heldScan = HeldScan()
        let queue = Queue(parallelism: 1) { _, _, _, _ in .failed(.encodeFailed) }
        let session = ProcessingSession(queue: queue, intake: { urls, _, _ in
            heldScan.started.continuation.yield(())
            #expect(heldScan.waitForRelease())
            return items(urls)
        })
        var terminalEventSeen = false
        session.onEvent = { event in
            if case .queue(.itemChanged(_, _, let state)) = event, state.isFinished {
                terminalEventSeen = true
            }
        }
        let open = Task {
            await session.open([URL(filePath: "/failed.jpg")]) { capture() }
        }
        await heldScan.waitUntilStarted()
        var actionSawTerminal = false
        let token = try #require(session.reserveIdleOperation {
            actionSawTerminal = terminalEventSeen
        })
        #expect(!actionSawTerminal)

        heldScan.releaseScan()
        await open.value
        await session.untilIdle()
        #expect(terminalEventSeen)
        #expect(actionSawTerminal)
        #expect(!session.activity.isRunning)
        session.releaseIdleOperation(token)
    }
}
