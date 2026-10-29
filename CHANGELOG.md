# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-10-29

### Added

- A Mac App Store version. It runs in the App Sandbox and has no in-app updates.
- The Help menu has a Privacy Policy item, and Settings > Support has a Privacy Policy link. Both open the privacy policy in your browser.
- When you convert one dropped file to another format, the Mac App Store version asks for access to the file's folder. The sandbox gives access only to the dropped file. The converted file is a new file in the same folder.
- On its first launch, the Mac App Store version moves your presets and settings from the direct download version. Select the Export folder again to let the Mac App Store version write to it.

### Changed

- The quality help text now reads "Higher quality keeps more detail, while lower quality makes smaller files."
- The app saves the Export folder as a security-scoped bookmark, so the Mac App Store version can write to it after a relaunch. The app also still saves the folder path, so version 1.0.0 can read the same setting.

## [1.0.0] - 2026-10-28

First public release. Underpressured compresses, resizes and converts still images in batches on your Mac. It requires Apple Silicon and macOS 27 or later.
