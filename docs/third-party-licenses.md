# Third-party licenses

The project uses the [MIT license](../LICENSE). [Resources/Acknowledgements.txt](../Resources/Acknowledgements.txt) has the project license and the third-party notices that ship in the app. The About window links to it.

When a dependency pin or the linked dependencies change, update this file and `Acknowledgements.txt`. Then run the [offline verification](#offline-verification).

## Linked components

| Component | Pin location | Bundled notices |
| --- | --- | --- |
| Sparkle 2.10.0 | Xcode `Package.resolved`, revision `eef1a539a373c1f1a320624b1130fc5de7b2e100` | Full Sparkle license, external notices, and vendored Ed25519 license |
| jpegli | `scripts/build-deps.sh`, commit `031a0077f5799a6041004267fc12b956c1f52a20` | jpegli BSD 3-Clause, Highway license with Apache/BSD/CC0 texts, and Little CMS MIT |
| Rust codecs | `rust/up-codecs/Cargo.lock` for `aarch64-apple-darwin` | Exact source licenses listed below and vendored libdeflate MIT |

The pinned Sparkle package declares the binary artifact SHA-256 `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`. The Sparkle framework and helpers come from that artifact. The full Sparkle license keeps the notices for bsdiff, sais-lite, Ed25519, and `SUSignatureVerifier.m`.

## Rust dependencies

The table lists the normal macOS dependencies. It does not list build-only tools, such as cbindgen. For crates with more than one license, the app ships the exact MIT text from the source.

| Crate | Version | Cargo license expression | Bundled source license path |
| --- | --- | --- | --- |
| `adler2` | `2.0.1` | `0BSD OR MIT OR Apache-2.0` | `LICENSE-MIT` |
| `bitflags` | `2.13.2` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `bytemuck` | `1.25.2` | `Zlib OR Apache-2.0 OR MIT` | `LICENSE-MIT` |
| `cfg-if` | `1.0.5` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `crc32fast` | `1.5.3` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `equivalent` | `1.0.3` | `Apache-2.0 OR MIT` | `LICENSE-MIT` |
| `fdeflate` | `0.3.7` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `flate2` | `1.1.10` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `hashbrown` | `0.17.1` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `indexmap` | `2.14.2` | `Apache-2.0 OR MIT` | `LICENSE-MIT` |
| `libdeflate-sys` | `1.26.1` | `Apache-2.0` | `LICENSE` |
| `libdeflater` | `1.26.1` | `Apache-2.0` | `LICENSE` |
| `log` | `0.4.34` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `miniz_oxide` | `0.8.9` | `MIT OR Zlib OR Apache-2.0` | `LICENSE` |
| `miniz_oxide` | `0.9.1` | `MIT OR Zlib OR Apache-2.0` | `LICENSE` |
| `oxipng` | `10.2.1` | `MIT` | `LICENSE` |
| `png` | `0.18.1` | `MIT OR Apache-2.0` | `LICENSE-MIT` |
| `quantizr` | `1.4.3` | `license-file` (`Cargo.toml`) | `LICENSE` |
| `rgb` | `0.8.53` | `MIT` | `LICENSE` |
| `rustc-hash` | `2.1.3` | `Apache-2.0 OR MIT` | `LICENSE-MIT` |
| `simd-adler32` | `0.3.10` | `MIT` | `LICENSE.md` |

Paths are relative to each crate's source folder in the Cargo registry cache. The verifier reads them from offline Cargo metadata.

`libdeflate-sys` also links vendored C code with its own MIT license at `libdeflate/COPYING`. The app ships that text and the Apache-2.0 license of the wrapper.

## Distribution checks

- Keep the upstream license texts, copyright notices, conditions, disclaimers, and external notices that apply.
- Keep the Apache NOTICE text that applies. The project MIT license does not replace dependency notices.
- Before distribution, a person must examine the signed archive, including frameworks, helpers, and acknowledgements. The text-copy check does not replace this review.

## Offline verification

Resolve the dependencies locally, then run:

```sh
scripts/verify-acknowledgements.py \
  --jpegli-source Vendor/.build/jpegli \
  --sparkle-source /path/to/DerivedData/SourcePackages/checkouts/Sparkle \
  --app-bundle /path/to/Underpressured.app \
  --check-sparkle-framework
```

The command uses no network. It checks the source pins, the Cargo dependencies, the exact license copies, and the acknowledgements in the app. It also requires Sparkle.framework and the Sparkle external notices. Keep the resolved Sparkle and jpegli source folders, so you can run the check again.

For the updater-free app, remove the Sparkle options. Use `--skip-sparkle-check` and the `--app-bundle` path of that app.

Without a Sparkle checkout, the direct-distribution check is not complete. Report a skipped check as a partial result.
