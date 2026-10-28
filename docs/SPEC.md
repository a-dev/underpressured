# App behavior

## 1. Purpose

Underpressured compresses, resizes, and converts still images in batches. All processing runs locally.

## 2. Platform

The app targets Apple Silicon and macOS 27 or later. The app is not sandboxed. See [Release](release.md) for signing and distribution.

## 3. Main window

The header contains preset badges and an add button. Badges wrap into rows. When the rows exceed 90 points, the preset area scrolls vertically. Keyboard focus scrolls the focused badge into view. Short lists keep their natural height. The content row below the presets contains destination controls and Clear. Output Format belongs to each preset's popover.

The empty window shows an import symbol and "Choose files or drop images or folders." Clicking it opens the file picker. The idle footer says "Choose a preset and where to save, then add files." The empty window accepts files and folders. File Open, Dock drops, and Open With use the same intake path.

The list groups items by batch. Rows show the name, relative folder path, state, sizes, savings, and any reason or note. Growth has a positive percentage.

Click, Command-click, Shift-click, and arrow keys control selection. Double-click or Return opens available files. Space toggles Quick Look. Arrow keys move through the list while Quick Look is open.

Open, Quick Look, and Show in Finder use the written output for optimized items. Skipped items use their exported copy or source. Missing files and unfinished, failed, or cancelled items are unavailable.

The selection context menu offers all three commands. Context-clicking an unselected row targets that row. Context-clicking a selected row targets the selected set. Mixed selections act on eligible files in list order, and all commands are disabled when none are eligible. Actions recheck availability when invoked. Show in Finder reveals the eligible files together. Each available row also has named Open, Quick Look, and Show in Finder accessibility actions.

Clear removes result history, selection, filters, and the completion summary when processing and intake are idle. You cannot undo Clear. Clear does not change image files. During processing, the footer shows progress, savings, and Cancel. Completion replaces progress with a summary and outcome filters. The active filter has a persistent checkmark as well as its tint, selected accessibility trait, and "showing" value. The checkmark is hidden from accessibility.

A run starts when valid, nonempty intake starts while the app is idle. It includes all intake received until pending scans, admissions and unfinished items settle. A temporary gap in queued processing does not end the run while a scan is pending. Active progress and background completion notifications describe that run. The completion banner summarizes retained result history, which can span multiple runs, and offers filters for outcomes in that history. A background completion posts a notification when permission allows it.

A nonempty batch admission can focus the file list when its window has no occupied control, or keep focus in an already focused list. Admissions preserve active preset editors and other focused controls. Filtering does not request list focus. Filtering clears selected rows that become hidden. Showing those rows again does not restore their selection. Quick Look follows the remaining selected openable files and closes when none remain.

Closing the window quits the app. Quitting during processing asks for confirmation. Return selects Cancel and Quit. Escape and Command-period select Keep Running. Accepted quit waits for cancellation and queue idle before replying to the system termination request. The app prevents idle system sleep while the queue runs.

| Shortcut | Action |
| --- | --- |
| Command-O | Open files or folders |
| Command-1 through Command-9 | Activate a preset |
| Command-comma | Open Settings |
| Command-period | Cancel the queue |

## 4. Presets

Each preset stores a name, quality, lossless flag, resize rule, metadata flag, and output format. Destination is separate.

All built-in preset names follow the app language, including Balanced JPEG, Web, Small, and Screenshots PNG. Format names such as JPEG and PNG remain unchanged. Custom names, including renamed built-in presets, stay exactly as entered when the language changes. Legacy presets without a built-in identifier retain their stored names.

A name has 1 to 70 composed characters, measured as Unicode grapheme clusters. The editor trims surrounding whitespace. It truncates longer edits to 70 characters. Two presets can have the same name. An empty or whitespace-only edit restores the previous name. Quality is 0 to 100. Lossless disables it. The disabled slider stays visible to accessibility, with its value and a note that Lossless does not use it. The name field has the accessibility label Name.

Resize rules limit width, height, or the longer edge. Images retain their aspect ratio and never enlarge.

The starter values match `UnderpressuredCore/Presets/PresetRules.swift`.

| Starter preset | Quality | Maximum long edge | Output | Keep metadata |
| --- | --- | --- | --- | --- |
| Balanced JPEG | 80 | No limit | JPEG | Off |
| Web | 80 | 2048 pixels | Original | Off |
| Small | 60 | 1080 pixels | Original | Off |
| Screenshots PNG | 70 | No limit | PNG | On |

All starters disable Lossless. Balanced JPEG is initially active.

Edits apply immediately. Add duplicates and activates the active preset. Presets support duplication, removal, and reordering. A preset list contains 1–20 presets with distinct identities and exactly one active member. The last preset cannot be removed. Construction, edits and restoration clamp quality to 0–100 and resize limits to at least one pixel. Preset identity is immutable. Duplication creates a new identity.

Move Earlier and Move Later in each badge's context menu and the Presets menu move one position. The application menu targets the active preset. Boundary commands are disabled. Named accessibility actions offer only possible moves, retain the moved badge's focus, and request an announcement of its resulting position. Movement preserves IDs and activation, updates numeric shortcut positions and saved order, and uses the same undo history as dragging.

Preset creation, duplication, removal, movement, and field edits support Undo and Redo through the Edit menu, Command-Z, and Command-Shift-Z. Restoring a preset preserves its ID, values, and position. A slider drag is one operation. Name edits form one operation per editing session. Command-Z in a focused text field retains native text undo. Empty names revert to the name at editor opening and do not create a history entry when nothing changed.

Activation alone does not create an undo entry. Removing the active preset activates its next neighbor, or its previous neighbor at the end. Undo restores the removed preset's active state unless the user explicitly activated a preset afterward, including selecting the automatic fallback. Redo follows the same rule: it preserves a later explicit activation if that preset survives, otherwise it uses the recorded destination state's active preset. Structural undo runs in reverse order, so undoing an addition frees its slot before an earlier removal is restored at the 20-preset limit.

Removal from the editor waits until its popover closes. Undo restores the preset without reopening that popover. Removal and restoration request focus on a surviving neighbor or the restored badge.

Settings persist after Undo and Redo. Undo history exists only for the current app session. Rows and selection do not persist. Editing a preset does not change batches already queued. Preset undo does not restore cleared results or image files.

### Stored preset recovery

The decoder enforces the following recovery contract. Destination preferences recover independently and are preserved when presets fall back to starters.

| Stored input | Recovery |
| --- | --- |
| Missing settings | Initial defaults |
| Malformed preset payload, unknown version or empty list | Use starter presets |
| Blank/long name, out-of-range quality or nonpositive resize limit | Normalize each field using the existing rules. Blank stored names use "Preset" |
| Active ID absent from list | Select the first preset |
| Legacy preset without output format or starter identifier | Use Original output. Retain its stored name without assigning a starter identifier |
| Duplicate preset IDs | Reject the entire preset list and use starters. Do not invent replacement IDs |
| More than 20 presets | Reject the entire preset list and use starters. Do not silently truncate |

Duplicate names remain valid. A list with two different presets sharing an ID is invalid even if the active ID matches. A 21-entry list is invalid even if its active entry would survive truncation. Recovery takes effect in memory at load. The normal save path persists it. Loading does not create a separate write or backup.

## 5. Output format

| Input | Original output | JPEG output | PNG output |
| --- | --- | --- | --- |
| JPEG | JPEG | JPEG | PNG |
| PNG | PNG | JPEG with transparency flattened onto white | PNG |
| HEIC, WebP, TIFF, AVIF, JPEG XL | Skipped with a conversion hint | JPEG | PNG |

Decode support also depends on ImageIO. GIF, RAW, animated images, and multi-page TIFFs are unsupported.

Conversion uses `.jpg` or `.png`. Original output preserves the source extension and its case.

## 6. Destination

The Destination control shows both Replace Originals and Export Copies. Export Copies reuses the remembered folder when it exists, is a directory, and is writable. Otherwise, it requests a folder. Cancelling leaves the previous destination unchanged. The folder menu offers Choose Another Folder, Show in Finder, and Forget Folder. Forget Folder selects replacement and clears the remembered folder.

Move original to Trash appears beside replacement controls only in replacement mode. Its preference survives mode changes. Destination changes affect later intake only.

Replace originals writes a same-format result atomically at the source path. Conversion writes a sibling file before removing the source.

Move originals to Trash sends replaced sources to the Trash. A volume without Trash produces a failure. Skipped sources remain untouched.

At constrained widths, the export-folder name truncates in the middle so Clear remains visible. The folder control exposes its full path through help and its accessibility value.

Export folder preserves sources and mirrors dropped folder paths. Loose files go into the export root. Scanning excludes the export folder.

Already-optimal and already-optimized items export unchanged copies with fresh optimization marks. Other skipped items produce no copy.

Name clashes add the first available suffix, such as `photo-2.jpg`. Planned paths stay reserved until all admitted queue work drains. Pending scans alone do not retain those reservations. Comparisons follow the volume's case sensitivity.

An existing export with a valid optimization mark can be refreshed. Unrelated files cannot be overwritten.

For example, two same-name images admitted during overlapping processing receive distinct reserved paths, even if the first finishes before the second writes. If processing drains while a later intake is still scanning, that later batch uses fresh reservations and may refresh the earlier valid marked export. Both batches can still belong to one run for completion totals. Historical row output paths refer to the current file at that location, not an archived version of its bytes.

Writes use temporary files on the destination volume. Before committing, the pipeline checks the source's identity, size, and modification date.

Written files retain source dates, Finder tags, and permissions. A changed source produces a failure instead of a replacement.

## 7. Processing

Each intake creates a batch with immutable captured preset settings, output format, label, identity and destination. Batches enter the queue in intake order. Queue owns execution state. Published item rows are independent values. Admission rejects a candidate batch with duplicate item IDs or batch/item IDs colliding with active execution before emitting events or reserving sources. IDs can be reused once their execution records retire.

Folder scanning skips hidden descendants, packages, and symbolic links. Explicitly dropped hidden files and folders are accepted. Non-image files are counted and ignored.

A source already waiting or processing becomes skipped. Item states are waiting, processing, and finished. Finished outcomes are optimized, skipped, failed, or cancelled.

### Encode paths

| Output | Lossy | Lossless |
| --- | --- | --- |
| JPEG source without resize | Progressive jpegli encode at the preset quality | Coefficient-preserving progressive rewrite |
| JPEG after resize or conversion | Progressive jpegli encode | Visually lossless encode at Butteraugli distance 1.0 |
| PNG | Palette search, with full-color fallback | oxipng optimization |

PNG palette acceptance uses a quality-dependent SSIMULACRA2 floor. `ImageEngine/Native/PNGPalette.swift` defines the curve. Quality 98 or higher uses lossless PNG.

Lossless controls encoding. Resize and conversion still work. PNG keeps the pixels after the transform. JPEG keeps its coefficients only when there is no pixel transform. A resized or converted JPEG uses visually lossless encoding. The preset editor explains these limits.

Resize uses vImage Lanczos in linear light. PNG optimization uses oxipng level 2. Native encode failures use an ImageIO fallback only when it meets the selected fidelity contract. Lossless JPEG paths fail if their native encoder is unavailable.

### Color and metadata

The encoder keeps the color profile. Re-encoding converts CMYK to sRGB. Only lossless PNG retains 16-bit channels. JPEG output flattens transparency onto white.

Keep metadata retains EXIF, GPS, IPTC, and XMP. Pixel transforms normalize orientation. Lossless JPEG rewriting preserves the orientation tag even when other metadata is removed.

The encoder removes HDR gain maps and adds an HDR note.

### Size and optimization marks

When format and dimensions remain unchanged, an output that is not smaller becomes skipped as already optimal. Conversion and resize may produce larger files.

Every written file receives an optimization mark. The mark records its version, effective settings, resolved format, file size, and modification date.

Matching settings and a valid mark skip repeated processing. A size change or a change to the modification date's nearest millisecond invalidates the mark. Milliseconds are measured from the Unix epoch and half-millisecond ties round away from zero. Dates in the same millisecond bucket remain indistinguishable, even if the file changed. Existing version 1 marks use the stored millisecond value under this same rule. Losing the mark causes processing to run again.

### Cancellation

Cancel applies to the entire queue. Waiting items cancel immediately. Processing stops between stages. A codec call already in progress finishes before cancellation takes effect.

Cancellation removes temporary files. Completed items remain completed. Cancellation preserves completed outputs.

A commit is the point at which an output becomes visible at its destination. Cancellation after commit must retain the successful output. Failure to clean up a source after a successful converted output is a note on that result, not cancellation or rollback of the committed output.

## 8. Diagnostics and verification

The app writes structured Console logs under `app.underpressured.Underpressured`, including item results and codec errors.

[Build and test](development.md) lists the automated checks. [Native interaction checks](development.md#native-gestures-and-voiceover) and [release build checks](release.md#release-build-checks) cover manual verification.

Ownership and source locations are in [Architecture](architecture.md).
