# Contributing

This guide is for people who want to build Underpressured, change its code, or improve its translations. The [README](../README.md) describes the app for users.

## Build from source

You need an Apple Silicon Mac with macOS 27 or later, Xcode 27, CMake, Ninja, and Rust with Cargo. Run these commands from the repository root:

```sh
scripts/build-deps.sh
open Underpressured.xcodeproj
```

Then run the `Underpressured` scheme in Xcode. The first dependency build fetches pinned sources, and later builds reuse them when the inputs have not changed.

## Run the tests

`scripts/test.sh` runs the full suite, the same one CI runs:

```sh
scripts/test.sh
```

[Build and test](development.md) covers focused test commands, performance checks, CI, and the manual interaction checks.

## Before you change the code

Read the [architecture guide](architecture.md) and the [glossary](GLOSSARY.md) first. When a change alters app behavior, a product term, or which module owns something, update [App behavior](SPEC.md), the glossary, and the architecture guide in the same change. The [change workflow](development.md#change-workflow) lists the steps.

## Translations

AI tools drafted the Spanish, Brazilian Portuguese, German, French, Arabic, Japanese, and Simplified Chinese translations, and no native speaker has reviewed them yet. The [translation guide](translations.md) explains where the strings live, which terms to keep, and how to send a correction. You can also [offer a translation review](https://github.com/a-dev/underpressured/issues/new?title=Translation%20contribution) as a GitHub issue.

## Report a problem

[Open an issue](https://github.com/a-dev/underpressured/issues) on GitHub or email [support@underpressured.app](mailto:support@underpressured.app).

## Reference

- [Documentation index](README.md)
- [App behavior](SPEC.md)
- [Architecture and source map](architecture.md)
- [Glossary](GLOSSARY.md)
- [Build and test](development.md)
- [Release](release.md), including signing, notarization, and the [release build checks](release.md#release-build-checks)
- [Translations](translations.md)
- [Third-party licenses](third-party-licenses.md)
- [Codec benchmarks](../bench/README.md)
