# Underpressured

Underpressured is a macOS app for compressing, resizing, and converting images in batches. Drop files or folders, choose a preset, and replace the originals or export copies.

Image processing happens on your Mac. The app has no analytics. Optional update checks and downloads contact the configured release hosts: automatic checks are offered only after you consent, and **Check for Updates…** starts a manual check. Update checks read the feed on GitHub Pages (`a-dev.github.io`) and download from GitHub Releases. Updates are never installed silently. You choose whether to install; if processing is active, installation and restart wait until the queue is idle, including after cancellation. See [Release](docs/release.md#first-update-enabled-release) for how to install the first update-enabled release.

The app requires Apple Silicon and macOS 27 or later. To build from source, use Xcode 27, CMake, Ninja, and Rust.

```sh
scripts/build-deps.sh
open Underpressured.xcodeproj
```

Run the `Underpressured` scheme in Xcode. Run `scripts/test.sh` for the full test suite.

## Languages

The app uses the macOS preferred language for the app. English is the source and fallback language. The available translations are Spanish, Brazilian Portuguese, German, French, Arabic, Japanese, and Simplified Chinese. Translation drafts are AI-generated and have not yet received native-speaker review. Help review or improve them using the [translation contribution guide](docs/translations.md).

To choose a language, open **Apple menu → System Settings → General → Language & Region → Applications**, then add Underpressured or select its entry. Quit and reopen the app if the change does not appear immediately. Underpressured displays the language resolved by macOS in Settings → General; it does not provide a separate in-app language override.

## Support

Email [support@underpressured.app](mailto:support@underpressured.app), [report an issue](https://github.com/a-dev/underpressured/issues), or [offer a translation review](https://github.com/a-dev/underpressured/issues/new?title=Translation%20contribution).

## Documentation

- [Documentation index](docs/README.md)
- [Translation contribution and review guide](docs/translations.md)
- [App behavior](docs/SPEC.md)
- [Architecture and source map](docs/architecture.md)
- [Build and test](docs/development.md)
- [Glossary](docs/GLOSSARY.md)

Underpressured uses the [MIT license](LICENSE). Bundled third-party texts are documented in the [license inventory](docs/third-party-licenses.md); the release build check is in [Release build checks](docs/release.md#release-build-checks).
