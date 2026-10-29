# App behavior

Underpressured compresses, resizes, and converts still images in batches. All processing occurs on the Mac.

## 1. Platform

The app needs Apple Silicon and macOS 27 or later. The direct-distribution app has no sandbox. The updater-free app uses the App Sandbox. On its first launch, macOS moves the direct-distribution app's settings into its container, so the direct-distribution app then starts with initial settings. [Build variants](development.md#build-variants) has the details.

## 2. Main window

### Layout

- The header shows preset badges and an add button. Badges wrap into rows. If the rows are taller than 90 points, the preset area scrolls vertically. Keyboard focus scrolls the focused badge into view.
- Below the presets, a row shows the destination controls and Clear. Output Format is in each preset's popover.
- The empty window shows an import symbol and "Choose files or drop images or folders." A click opens the file picker. The idle footer shows "Choose a preset and where to save, then add files."
- The list groups items by batch. Each row shows the name, relative folder path, state, sizes, savings, and a reason or note if one applies. Growth shows as a positive percentage.

Open, drops on the window or the Dock, File Open, and Open With all use the same intake path.

### Selection and file commands

- Click, Command-click, Shift-click, and the arrow keys change the selection.
- Double-click or Return opens the available files. Space toggles Quick Look. The arrow keys move through the list while Quick Look is open.
- Open, Quick Look, and Show in Finder use the output of an optimized item, and the exported copy or source of a skipped item. Missing files and unfinished, failed, or cancelled items are not available.
- The context menu has the three commands. It targets the clicked row, or the selection if the clicked row is selected.
- The commands act on the eligible files in list order, and are disabled if no file is eligible. Each command checks availability again when it runs.
- Each available row has the three commands as accessibility actions.

### Progress, results, and filters

- During processing, the footer shows progress, savings, and Cancel. At completion, a summary and outcome filters replace the progress.
- The active filter has a checkmark, a tint, the selected accessibility trait, and the value "showing". The checkmark is hidden from accessibility.
- A filter does not move focus to the list. A filter clears the selection of rows that it hides. When the rows show again, the app does not select them again. Quick Look follows the selected files that can still open. It closes when none remain.
- Clear removes result history, selection, filters, and the summary. Clear is available only when processing and intake are idle. You cannot undo Clear. Clear does not change image files.

### Runs and focus

- Progress and background notifications describe the current [Run](GLOSSARY.md#processing). The app sends a background notification only if the user allows notifications.
- The completion banner and its filters cover all result history, which can contain many Runs.
- An admitted batch can move focus to the file list only if no other control has focus. An admission never takes focus from a preset editor or another control.

### Quit and sleep

Closing the window quits the app. If processing is active, the app asks for confirmation:

- Return selects Cancel and Quit.
- Escape and Command-period select Keep Running.

After the user accepts, the app cancels, waits for the queue to become idle, and then replies to the system quit request. While the queue runs, the app prevents idle system sleep.

| Shortcut | Action |
| --- | --- |
| Command-O | Open files or folders |
| Command-1 to Command-9 | Activate a preset |
| Command-comma | Open Settings |
| Command-period | Cancel the queue |

## 3. Presets

A preset stores a name, quality, the lossless flag, a resize rule, the keep-metadata flag, and an output format. The destination is not part of a preset.

### Values

- A name has 1 to 70 Unicode grapheme clusters. The editor removes whitespace at the start and end, and cuts longer text to 70. Two presets can have the same name. An empty or whitespace-only edit restores the previous name. The name field has the accessibility label "Name".
- Quality is 0 to 100. Lossless disables the quality slider. The disabled slider stays visible to accessibility, with its value and a note that Lossless does not use it.
- A resize rule limits the width, the height, or the longer edge. Images keep their aspect ratio and never get larger.
- Construction, edits, and restoration clamp quality to 0–100 and resize limits to at least 1 pixel.

### Starter presets

The values come from `UnderpressuredCore/Presets/PresetRules.swift`. All starters have Lossless off. Balanced JPEG is active at first.

| Starter preset | Quality | Maximum long edge | Output | Keep metadata |
| --- | --- | --- | --- | --- |
| Balanced JPEG | 80 | No limit | JPEG | Off |
| Web | 80 | 2048 pixels | Original | Off |
| Small | 60 | 1080 pixels | Original | Off |
| Screenshots PNG | 70 | No limit | PNG | On |

Starter names follow the app language. Format names, such as JPEG and PNG, do not change. Custom names, and starter presets that the user renamed, keep their text when the language changes. Old presets without a starter identifier keep their stored names.

### Edits

- Edits apply immediately. Edits do not change batches that are already in the queue.
- Add duplicates the active preset and activates the copy. Presets can also be duplicated, removed, and moved.
- The list has 1 to 20 presets with different identities and exactly one active preset. You cannot remove the last preset.
- A preset's identity never changes. A duplicate gets a new identity.
- Removing the active preset activates the next preset, or the previous one if the removed preset was last.

### Move

- Move Earlier and Move Later are in each badge's context menu and in the Presets menu. Each command moves the preset one position. The application menu acts on the active preset. At the start or end of the list, the related command is disabled.
- The accessibility actions show only possible moves. After a move, focus stays on the badge, and the app announces its new position.
- A move keeps IDs and the active preset. It updates the numeric shortcuts and the saved order. A move uses the same undo history as a drag.

### Undo

- Undo and Redo (Command-Z, Command-Shift-Z) apply to create, duplicate, remove, move, and field edits. Activation alone adds no undo step.
- Undo restores a preset with its ID, values, and position.
- One slider drag is one step. One name-editing session is one step. In a focused text field, Command-Z uses native text undo.
- Undo of a removal restores the removed preset's active state. Exception: if the user activated a preset after the removal, including the automatic fallback, that choice stays. Redo uses the same rule. It keeps a later explicit activation if that preset still exists. Otherwise, it uses the active preset that the app recorded.
- Undo runs in reverse order. At the 20-preset limit, undo of an addition frees a slot before undo restores an earlier removal.
- A removal from the editor occurs after the popover closes. Undo does not open the popover again. Focus moves to a neighbor or to the restored badge.
- Undo history lasts for the app session. Undo does not restore cleared results or image files. Rows and selection are not saved.

### Stored preset recovery

The decoder applies these rules when it loads presets. Destination preferences recover on their own. They stay even when presets fall back to the starters.

| Stored input | Recovery |
| --- | --- |
| No settings | Initial defaults |
| Bad preset data, unknown version, or empty list | Use the starter presets |
| Blank or long name, quality out of range, or resize limit of 0 or less | Correct each field with the normal rules. A blank stored name becomes "Preset" |
| Active ID not in the list | Select the first preset |
| Old preset without output format or starter identifier | Use Original output. Keep the stored name. Do not add a starter identifier |
| Two presets with the same ID | Reject the full list and use the starters. Do not make new IDs |
| More than 20 presets | Reject the full list and use the starters. Do not cut the list |

Recovery changes only the loaded values. The next normal save writes them. Loading writes no file and no backup.

## 4. Output format

| Input | Original output | JPEG output | PNG output |
| --- | --- | --- | --- |
| JPEG | JPEG | JPEG | PNG |
| PNG | PNG | JPEG, with transparency flattened onto white | PNG |
| HEIC, WebP, TIFF, AVIF, JPEG XL | Skipped, with a conversion hint | JPEG | PNG |

Decoding also depends on ImageIO. The app does not support GIF, RAW, animated images, or multi-page TIFF.

A conversion uses `.jpg` or `.png`. Original output keeps the source extension and its letter case.

## 5. Destination

### Controls

- The Destination control shows Replace Originals and Export Copies. A change applies only to later intake.
- Export Copies uses the remembered folder if it exists, is a folder, and is writable. If not, the app asks for a folder. The sandboxed app also asks if it cannot open the remembered folder after a relaunch. If the user cancels, the destination does not change.
- The folder menu has Choose Another Folder, Show in Finder, and Forget Folder. Forget Folder selects Replace Originals and clears the remembered folder.
- "Move original to Trash" shows only in Replace Originals mode. Its value stays when the mode changes.
- At small window widths, the folder name is cut in the middle, so Clear stays visible. The folder control shows its full path in its help and its accessibility value.

### Replace Originals

- A same-format result replaces the source atomically at the source path.
- A conversion writes a new file next to the source, then removes the source.
- With "Move original to Trash", the app moves replaced sources to the Trash. If a volume has no Trash, the item fails. Skipped sources do not change.

### Export Copies

- The Export folder copies the dropped folder structure. Loose files go into the Export folder root. The scan does not include the Export folder.
- Items that are already optimal or already optimized export an unchanged copy with a new optimization mark. Other skipped items make no copy.
- If the remembered Export folder is missing, the item fails with "Export folder unavailable". The app keeps the remembered path.

### Folder access in the sandboxed app

A dropped file gives the sandboxed app access to that file, not to its folder. A conversion must create a new file in that folder.

- Before admission, the app finds the folders where it must convert a loose file but cannot create files. For each folder, in intake order, a panel opens at that folder with a Grant Access button.
- The panel does not show for files inside dropped folders, for Export Copies, for same-format results, or in the direct-distribution app.
- If the user cancels the panel, the app still admits the items. Their conversions fail with "No permission".
- If the user cancels the queue while the panel is open, the app discards that intake.

If the sandboxed app cannot write the remembered Export folder (for example, a folder from the direct-distribution app), the same panel opens before the scan. After a grant, the app saves the folder again, so later launches need no panel. If the user cancels, the exports fail with "No permission". A missing Export folder shows no panel.

### Name clashes

- A name clash adds the first free number, for example `photo-2.jpg`. Comparisons follow the case sensitivity of the volume.
- The app reserves planned paths until all admitted work is done. A pending scan alone does not keep reservations.
- The app can replace an existing export that has a valid optimization mark. It never replaces an unrelated file. So a batch admitted after the queue empties can replace an earlier export from the same Run.
- A row's output path refers to the file at that location now, not to a stored copy.

### Safe writes

- The app writes to temporary files on the destination volume, outside the destination folder.
- Before the commit, the app checks the source identity, size, and modification date. If the source changed, the item fails and the app does not replace it.
- Written files keep the source dates, Finder tags, and permissions.

## 6. Processing

- Each intake makes a batch. The batch captures the preset settings, output format, label, identity, and destination. These values never change.
- Batches enter the queue in intake order.
- A folder scan skips hidden items, packages, and symbolic links inside the folder. The app accepts hidden files and folders that the user drops directly. The scan counts non-image files and ignores them.
- If a source already waits or processes, the new item is skipped.
- Item states are waiting, processing, and finished. A finished item has an outcome: optimized, skipped, failed, or cancelled.

### Encode paths

| Output | Lossy | Lossless |
| --- | --- | --- |
| JPEG source, no resize | Progressive jpegli encode at the preset quality | Progressive rewrite that keeps the coefficients |
| JPEG after resize or conversion | Progressive jpegli encode | Visually lossless encode at Butteraugli distance 1.0 |
| PNG | Palette search, with a full-color fallback | oxipng optimization |

- A PNG palette must pass a SSIMULACRA2 floor that depends on quality. `ImageEngine/Native/PNGPalette.swift` has the curve. At quality 98 or more, the app uses lossless PNG.
- Lossless controls only the encode. Resize and conversion still apply. PNG keeps the pixels after the transform. JPEG keeps its coefficients only when there is no pixel transform. A resized or converted JPEG uses a visually lossless encode. The preset editor explains these limits.
- Resize uses vImage Lanczos in linear light. PNG optimization uses oxipng level 2.
- If a native encoder fails, the app uses ImageIO only if the result meets the selected fidelity. A lossless JPEG path fails if its native encoder is not available.

### Color and metadata

- The encoder keeps the color profile. A re-encode converts CMYK to sRGB. Only lossless PNG keeps 16-bit channels. JPEG output flattens transparency onto white.
- Keep metadata keeps EXIF, GPS, IPTC, and XMP. A pixel transform applies the orientation to the pixels. A lossless JPEG rewrite keeps the orientation tag, even when it removes other metadata.
- The encoder removes HDR gain maps and adds an HDR note.

### Size and optimization marks

- If the format and dimensions do not change and the output is not smaller, the item is skipped as already optimal. A conversion or a resize can make a larger file.
- Each written file gets an optimization mark. The mark records its version, the settings, the resolved format, the file size, and the modification date.
- If the settings match and the mark is valid, the app skips the file.
- A change in size, or in the modification date at millisecond precision, makes the mark invalid. The app counts milliseconds from the Unix epoch. A half-millisecond rounds away from zero. The app cannot detect a change inside the same millisecond. Version 1 marks use their stored millisecond value with the same rule.
- If the mark is lost, the app processes the file again.

### Cancellation

- Cancel applies to the full queue. Waiting items cancel immediately. A processing item stops between stages. A codec call that already started finishes first.
- Cancellation removes temporary files. Completed items and committed outputs stay.
- If the app cannot remove the source after a successful conversion, the result gets a note. The committed output stays.

## 7. Logs

The app writes structured Console logs under `app.underpressured.Underpressured`, including item results and codec errors.
