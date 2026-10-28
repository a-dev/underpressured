# Third-party licenses

[Resources/Acknowledgements.txt](../Resources/Acknowledgements.txt) contains the bundled project license and third-party notices.
The About window links to this content. The project uses the [MIT license](../LICENSE).

Update this inventory and the bundled texts when dependency pins or the linked dependency graph change.
The verifier checks exact copies against local source files without network access.

## Linked components

| Component | Pin location | Bundled notices |
| --- | --- | --- |
| Sparkle 2.10.0 | Xcode `Package.resolved`, revision `eef1a539a373c1f1a320624b1130fc5de7b2e100` | Full Sparkle license, external notices, and vendored Ed25519 license |
| jpegli | `scripts/build-deps.sh`, commit `031a0077f5799a6041004267fc12b956c1f52a20` | jpegli BSD 3-Clause, Highway license with Apache/BSD/CC0 texts, and Little CMS MIT |
| Rust codecs | `rust/up-codecs/Cargo.lock` for `aarch64-apple-darwin` | Exact source licenses listed below and vendored libdeflate MIT |

Sparkle's pinned package declares binary artifact SHA-256 `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`.
Its framework and helpers come from that artifact.
The full Sparkle license retains notices for bsdiff, sais-lite, Ed25519, and `SUSignatureVerifier.m`.

## Rust dependencies

This table lists normal macOS dependencies. It excludes build-only tools such as cbindgen.
For dual-licensed crates, the bundle uses the exact MIT text from the source.

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

Paths are relative to each crate's source directory in Cargo's registry cache.
The verifier reads those paths from offline Cargo metadata.
`libdeflate-sys` also links vendored C code with its own MIT license at `libdeflate/COPYING`.
The bundle includes that text and the wrapper's Apache-2.0 license.

## Distribution checks

Keep upstream license texts, copyright notices, conditions, disclaimers, and applicable external notices in the acknowledgements.
Keep applicable Apache NOTICE material. The project MIT license does not replace dependency notices.
Review the exact signed archive, including frameworks, helpers, and acknowledgements, before distribution.
The text-copy check does not replace that review.

## Offline verification

Resolve dependencies locally. Run:

```sh
scripts/verify-acknowledgements.py \
  --jpegli-source Vendor/.build/jpegli \
  --sparkle-source /path/to/DerivedData/SourcePackages/checkouts/Sparkle \
  --app-bundle /path/to/Underpressured.app \
  --check-sparkle-framework
```

The command checks source pins, the Cargo dependency set, exact license copies, and the app's acknowledgements resource.
It also requires Sparkle.framework and Sparkle's external notices.
Keep the resolved Sparkle and jpegli source directories available for repeat checks.

For the updater-free app, omit Sparkle options. Use `--skip-sparkle-check` and that app's `--app-bundle` path.
A missing Sparkle checkout prevents a complete direct-distribution check. Report skipped checks as partial results.
