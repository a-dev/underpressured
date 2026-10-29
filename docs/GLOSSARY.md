# Glossary

Use these terms in code and in documentation. [Architecture](architecture.md) tells which module owns each one.

## Settings

| Term | Meaning |
| --- | --- |
| Preset | A named set of settings: quality, lossless, resize rule, keep metadata, and output format. |
| Preset List | The ordered presets, 1 to 20, each with a different identity. Exactly one is active. |
| Active Preset | The preset that the next intake uses. |
| Quality | A value from 0 to 100 for lossy compression. Lossless ignores it. |
| Lossless | Compression that keeps all image detail. A resize or a conversion to JPEG can still need a visually lossless encode. |
| Resize Rule | A positive pixel limit on the width, the height, or the longer edge. The app never makes an image larger. |
| Keep metadata | Keep the embedded metadata. The app always keeps the color profile. |
| Output Format | Original, JPEG, or PNG. Each preset has one. |
| Original | Keep the input format if the app can write it. |
| Destination | Replace originals or Export folder. The destination is not part of a preset. |
| Replace originals | Write each result in place of its source file. With the Trash option, the app moves the replaced source to the Trash. |
| Export folder | Write copies into a folder that the user selects. The sources do not change. Relative folder paths stay the same. |
| Remembered destination preferences | The destination kind, the Export folder path, and the Trash option, saved between app sessions. |

## Processing

| Term | Meaning |
| --- | --- |
| Intake | One request to process files or folders, including the scan for images. Open, File Open, Dock drops, and Open With are all intake. Use "intake", not "drop". |
| Batch | The images from one intake, with the settings, output format, preset name, and destination that the intake captured. |
| Item | One image in a batch. It has a fixed source URL, source identity, dropped root, and scanned format. |
| Source identity | How the app recognizes the same input file, by path or by the file itself, including hard links. |
| Queue | The batches that wait or process, in intake order. |
| Run | All intake and batches from the start of activity until no scan, admission, or unfinished item remains. Run totals describe one Run. Result history can contain many Runs. |
| Queue execution interval | The time from an admission until all admitted work is done. One Run can contain many intervals. |
| Name clash | An output path that is already in use, so the app adds a number to the filename. |
| Commit | The moment a finished output appears at its destination. A committed output stays, even if a cancellation or a source cleanup occurs later. |
| Optimization mark | Stored facts about a written file: settings, format, size, and modification date. The app uses the mark to find repeat work. |

## Results

| Term | Meaning |
| --- | --- |
| Outcome | Optimized, Skipped, Failed, or Cancelled. |
| Optimized | The app wrote a compressed, resized, or converted image. |
| Skipped | The app did not change the image on purpose. Export can still write an unchanged copy. |
| Failed | An error stopped the item. |
| Cancelled | A cancellation stopped an unfinished item. |
| Savings | Original size minus output size, in bytes and in percent. Negative savings mean the file got larger. |
