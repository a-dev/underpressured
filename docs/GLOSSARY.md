# Image Optimization glossary

Use these terms in code and documentation. [Architecture](architecture.md) defines their owners.

| Term | Meaning |
| --- | --- |
| Preset | Named settings for quality, lossless processing, resize, metadata, and output format. |
| Active Preset | The preset used for the next intake. |
| Quality | Value from 0 to 100 that controls lossy compression. Lossless ignores it. |
| Lossless | Compression without discarded image detail. Resize or conversion to JPEG can still require visually lossless re-encoding. |
| Resize Rule | A positive pixel limit on width, height, or the longer edge. Images never enlarge. |
| Keep metadata | Preserve embedded metadata. The color profile remains regardless of this setting. |
| Output Format | Original, JPEG, or PNG, stored in each preset. |
| Original | Keep the input format when the app can write it. |
| Destination | Replace originals or Export folder, independent of the preset. |
| Replace originals | Write results in place of source files. The Trash option preserves replaced sources in Trash. |
| Export folder | Write copies into a chosen folder while preserving sources and relative paths. |
| Batch | The images from one intake together with the settings, output format, preset name and destination captured for that intake. |
| Queue | Batches waiting or processing in intake order. |
| Run | All intake and batches grouped from the start of activity until pending scans, admissions and unfinished images settle. Run totals describe this group. Retained result history can span multiple runs. |
| ProcessingSession | Application service that owns intake ordering, pending scans, cancellation generations, admission tracking and exclusive idle-operation reservations. It reports Run activity to presentation without waiting for UI throttling. |
| Remembered destination preferences | The selected destination kind, export-folder path and Trash choice saved between app sessions. A missing folder choice cannot produce an intake Destination. A remembered unavailable path stays remembered and processing reports its destination failure. |
| Queue execution interval | An application lifetime from admission until admitted work drains. Queue owns its output reservations and folder checks through QueueExecutionContext. Active workers keep them alive through cancellation. A Run can span several intervals. |
| Item | One image within a batch, with an immutable source URL, captured source identity, dropped root and scanned format. Intake and presentation hold state values. Queue owns the authoritative execution lifecycle. |
| Outcome | Optimized, Skipped, Failed, or Cancelled. |
| Optimized | The app wrote a compressed, resized, or converted image. |
| Skipped | Processing deliberately left the image unchanged. Export may receive an unchanged copy. |
| Failed | An error prevented completion. |
| Cancelled | Cancellation stopped an unfinished item. |
| Savings | Original size minus output size, expressed in bytes and percent. Negative savings mean growth. |
| Optimization mark | Domain facts containing the effective settings, resolved format, size and modification date used to recognize repeat processing. LocalFileSystem owns the versioned JSON/xattr representation. Application commit tokens retain opaque expected bytes. |
| Name clash | An occupied output path that requires a numbered filename. |
| Preset List | The ordered collection of presets and its single active member. It contains between one and twenty presets with distinct identities. |
| Intake | One request to process files or folders, including discovery of the images within them. Use Intake instead of Drop. Intake includes File Open and Open With. |
| Source identity | The identity used to recognize the same input file through its path or underlying file, including hard links. |
| Commit | The point at which a finished output becomes visible at its destination. A committed output remains in place if later cancellation or source cleanup occurs. |
