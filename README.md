# Underpressured

Underpressured is a free, open-source Mac app that compresses, converts, and resizes images in batches. Drop in a single image or a whole folder, pick a preset, and choose whether to replace the originals or save copies somewhere else. When the batch finishes, the app shows how much smaller each file got.

Website: [underpressured.app](https://underpressured.app/)

[Download the latest release](https://github.com/a-dev/underpressured/releases/latest) from GitHub. A Mac App Store version is coming soon. The app needs a Mac with Apple Silicon and macOS 27 or later.

## How it works

You work in three steps: pick a preset, pick a destination, then add images.

### 1. Pick a preset

A preset stores everything about how to process an image:

- the output format: JPEG, PNG, or the same format as the source
- the compression: a quality from 0 to 100, or lossless
- an optional size limit by width, height, or the longer side
- whether to keep metadata such as EXIF, GPS, IPTC, and XMP

The app starts with four presets: Balanced JPEG, Web, Small, and Screenshots PNG. You can edit them, duplicate one into a new preset such as "Website images", reorder them, and keep up to 20. Command-1 through Command-9 switch presets, and Undo works on every preset change.

Resizing keeps the aspect ratio and never makes an image larger. Changing a preset doesn't affect images that are already in the queue.

### 2. Pick where the results go

You have two choices:

- Replace the originals. The compressed file takes the source's place. You can also have the app move each original to the Trash instead of overwriting it.
- Export copies. The originals stay untouched and the compressed files go to a folder you choose. Dropped folders keep their subfolder structure. If a file with the same name already exists, the app adds a suffix such as `photo-2.jpg` instead of overwriting it.

The app writes each result to a temporary file first. Before it saves the result, it checks that the source hasn't changed since processing started. Saved files keep the source's dates, Finder tags, and permissions.

### 3. Add images

Drop files or folders onto the window, use File > Open (Command-O), drop them on the Dock icon, or use Open With in Finder. The app scans folders, skips hidden files, packages, and symbolic links, and ignores files that aren't images.

It reads JPEG, PNG, HEIC, WebP, TIFF, AVIF, and JPEG XL and writes JPEG or PNG. With "Original" as the output format, JPEG and PNG stay in their format. Other formats need JPEG or PNG output, and the app skips them with a hint to convert. It doesn't support GIF, RAW, animated images, or multi-page TIFFs.

### 4. Check the results

Each row lists the new size and the percentage change. When a batch finishes, a summary shows the total savings, and you can filter the list by outcome: optimized, skipped, failed, or cancelled. Select rows to preview them with Quick Look (Space), open them (Return), or show them in Finder.

If a compressed file would be larger than the original and the format and dimensions stay the same, the app keeps the original and marks the image as already optimal. Each file it writes gets an optimization mark, so adding the same image again with the same settings skips it.

Cancel (Command-period) stops the whole queue. Finished images stay finished, and the app removes any half-written temporary files. If you quit while images are processing, the app asks first, and it keeps the Mac awake while the queue runs.

## Codecs

- [jpegli](https://github.com/google/jpegli) writes progressive JPEGs at the preset quality. In lossless mode the app rewrites a JPEG without re-encoding its pixel data. A resized or converted JPEG gets a visually lossless encode instead.
- quantizr searches for a smaller color palette for lossy PNG and keeps it only when the result stays above a quality floor. Otherwise the PNG stays full color.
- [oxipng](https://github.com/shssoichiro/oxipng) optimizes lossless PNG at level 2 without changing any pixels.
- vImage resizes with a Lanczos filter in linear light.

JPEG output flattens transparency onto white. The app keeps the color profile, converts CMYK to sRGB when it re-encodes, and removes HDR gain maps with a note on the row. The [benchmarks page](https://underpressured.app/benchmarks/) shows the test setup, results, and limits.

## Privacy and updates

All image processing happens on your Mac, and the app collects no analytics.

The app checks for updates only after you agree to automatic checks, or when you choose Check for Updates… yourself. Update checks read a feed on GitHub Pages (`a-dev.github.io`) and download from GitHub Releases. The app never installs an update without asking you. If images are processing, it waits until the queue is idle, including after a cancellation, before it installs and restarts.
## Languages

The app is available in English, Spanish, Brazilian Portuguese, German, French, Arabic, Japanese, and Simplified Chinese. It follows the macOS language setting and falls back to English. AI tools drafted the translations, and native speakers haven't reviewed them yet.

To change the language, open Apple menu > System Settings > General > Language & Region > Applications, then add Underpressured or select its entry. Quit and reopen the app if the change doesn't show up. Settings > General in the app shows the language that macOS picked. The app has no language setting of its own.

## Support

Email [support@underpressured.app](mailto:support@underpressured.app), [report an issue](https://github.com/a-dev/underpressured/issues), or visit the [support page](https://underpressured.app/support/).

## License

Underpressured uses the [MIT license](LICENSE). The [license inventory](docs/third-party-licenses.md) lists the bundled third-party licenses.

## Contributing

To build the app from source, run the tests, change the code, or review translations, read the [contribution guide](docs/contribution.md).
