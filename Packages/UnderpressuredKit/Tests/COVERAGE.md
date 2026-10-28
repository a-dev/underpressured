# Test coverage map

See [Build and test](../../../docs/development.md#run-tests) for commands and suite responsibilities.

| Behavior | Test files |
| --- | --- |
| Presets and captured settings | `UnderpressuredCoreTests/PresetTests.swift`, `PresetListTests.swift`, `UnderpressuredApplicationTests/BatchSnapshotTests.swift` |
| Preset undo at every initialized position and active-last fallback: exact values, IDs, order, later explicit activation, and persistence after undo/redo | `AppModelTests/PresetUndoTests.swift` |
| Preset names: explicit 70-character contract, literal 69/70/71 grapheme boundaries, capped duplicate suffixes, and unchanged saved names of lengths 21–70 | `UnderpressuredCoreTests/PresetTests.swift`, `PresetListTests.swift`, `MacPlatformTests/SettingsStoreTests.swift` |
| Intake and format resolution | `UnderpressuredApplicationTests/ScannerTests.swift`, `UnderpressuredCoreTests/OutputFormatTests.swift` |
| Paths, marks, and size decisions | `UnderpressuredApplicationTests/OutputPathPlannerTests.swift`, `UnderpressuredCoreTests/OptimizationMarkTests.swift`, `NotSmallerRuleTests.swift`, `LocalFileSystemTests/StoredOptimizationMarkTests.swift` |
| Converted-output commit failure: both cleanup preferences preserve original bytes, never attempt source cleanup, remove temporary output; successful conversion/cleanup-error behavior retained | `UnderpressuredApplicationTests/PipelineTests.swift` |
| Linear scheduler transition budget, once-only completion, terminal retirement and planner release | `UnderpressuredApplicationTests/ExecutionRetentionTests.swift` |
| Actual volume case property; controlled collision policies for both case modes | `LocalFileSystemTests/LocalFileAccessTests.swift`, `UnderpressuredApplicationTests/RunReservationTests.swift`, `OutputPathPlannerTests.swift` |
| Pipeline writes and output URLs | `UnderpressuredApplicationTests/PipelineTests.swift` |
| Scheduling, cancellation, and memory admission | `UnderpressuredApplicationTests/QueueTests.swift`, `PixelBudgetTests.swift`, `MacPlatformTests/ParallelismTests.swift` |
| Selection and openable files | `AppModelTests/SelectionTests.swift`, `ItemRowTests.swift` |
| Progress delivery: shared manual clock, coalesced burst at the deadline before idle, immediate idle final state, and 10,000-item final counts | `AppModelTests/ThrottleTests.swift`, `ManualProgressTime.swift` |
| Presentation and system services | `AppModelTests/`, `MacPlatformTests/` |
| Codecs, pixels, and metadata | `ImageEngineTests/` |
| Visually lossless JPEG: literal jpegli distance 1.0 at slider endpoints; real resized JPEG / converted PNG decoded fidelity, degraded and wrong-content controls; metadata preserves coefficients and score | `ImageEngineTests/JPEGEncodeTests.swift`, `Fixtures/JPEGFidelityFixture.swift` |
| Transparent PNG: independent dark/light compositing and low-level scores in both worst-background directions, real search rejection, decoded transparent/partial/opaque values | `ImageEngineTests/PNGPaletteTests.swift` |
| Resized alpha: genuine transparent/partial/opaque interiors and colored fringe appearance on light/dark backgrounds | `ImageEngineTests/ResizeTests.swift` |
| Recoverable originals in real Trash, exact owned cleanup on success and assertion failure | `LocalFileSystemTests/LocalFileAccessWriteTests.swift`, `IntegrationTests/EndToEndTests.swift`, `QueueTestSupport/OwnedTrashItems.swift` |
| Native selected filters: required AX buttons, selected/unselected values, hidden decorative glyph, model toggle action, and reviewed checkmark pixels | `AppTests/OutputActionsTests.swift`, `AppTests/Fixtures/checkmark-macos27.png` |
| Native minimum-width destination and Clear: required nodes, content containment, nonoverlap, full-path help/value, and populated-history Clear action in LTR and RTL | `AppTests/UnderpressuredTests.swift` |
| Localized minimum-width layouts with 70-character presets, long export paths, RTL order, and fitting sizes | `AppTests/LocalizationLayoutTests.swift`, fresh-process `scripts/check-localized-ui.sh` |
| Cancellation stress: 1,000 seeded rounds per destination, identity/terminal counts, source bytes and dates, output decode/format/dimensions, mark/savings, unreported images and temporary cleanup | `IntegrationTests/CancelStressTests.swift` |
| Deterministic cancellation before commit preserves sources; after commit preserves success and openable output | `LocalFileSystemTests/CancelIntegrationTests.swift`, `UnderpressuredApplicationTests/PipelineTests.swift` |
| Files and cancellation cleanup | `LocalFileSystemTests/`, `IntegrationTests/` |

Test files define individual assertions. Native captures and AX dumps are retained diagnostics. Only the narrow reviewed checkmark crop has a pixel comparison. Human review of the captures and VoiceOver remains pending in [native gestures and VoiceOver checklist](../../../docs/development.md#native-gestures-and-voiceover).

Some test names retain numbered requirement identifiers. The identifiers do not define current documentation structure.

Cancellation stress pins fixture dates to whole seconds and replays delay choices through `UP_CANCEL_SEED` and `UP_CANCEL_ROUNDS`; OS scheduling remains nondeterministic. Subsecond mark precision is not covered by these fixtures.

## Architecture and execution contracts

[Architecture](../../../docs/architecture.md) defines current ownership.

| Contract | Tests or checks |
| --- | --- |
| Preset construction, mutations, restoration, and position bounds | `UnderpressuredCoreTests/PresetTests.swift`, `PresetListTests.swift`, `MacPlatformTests/SettingsStoreTests.swift` |
| Captured settings and atomic identity rejection | `UnderpressuredApplicationTests/BatchSnapshotTests.swift`, `QueueAdmissionTests.swift` |
| Run lifetime across pending intake | `AppModelTests/CombinedRunIntakeTests.swift`, `IntakeOrderTests.swift`, `IntakeCancellationTests.swift`, `MultiRunBannerTests.swift` |
| Intake cancellation and exclusive idle handoff | `UnderpressuredApplicationTests/ProcessingSessionTests.swift`, `AppModelTests/IdleOperationTests.swift`, `QuitTests.swift`, `AppTests/UpdateInstallationTests.swift` |
| Reservation lifetime and bounded execution | `UnderpressuredApplicationTests/RunReservationTests.swift`, `ExecutionRetentionTests.swift`, `PixelBudgetTests.swift` |
| Committed output survives cancellation and source-cleanup failure | `UnderpressuredApplicationTests/WriteFailureCancellationTests.swift`, `PipelineTests.swift`, `LocalFileSystemTests/LocalFileAccessWriteTests.swift` |
| Stored settings and mark compatibility | `MacPlatformTests/PresetStorageTests.swift`, `SettingsStoreTests.swift`, `LocalFileSystemTests/StoredOptimizationMarkTests.swift` |
| Target dependencies, imports, and source ownership | `scripts/check-architecture.py`, `scripts/test_check_architecture.py` |

## Limits

Test source defines assertions and fixture scope. A passing test does not prove all images or native interactions.
Screenshots and accessibility dumps are diagnostic artifacts. Human review remains pending in the linked checklist.
Cancellation stress uses whole-second fixture dates. OS scheduling remains nondeterministic.
Memory retention requires further profiling. External CI acceptance remains pending in [CI configuration](../../../docs/development.md#configure-ci).
