# Local builds require Apple Silicon, macOS 27+, Xcode 27, CMake, and Rust/Cargo.
# Run `make` to list commands. Colons are escaped only in target declarations;
# invoke them normally, for example: make build:sparkless
.DEFAULT_GOAL := help

# Keep generated files in the git-ignored build/ directory.
# Override with: make build:sparkless BUILD_DIR=/absolute/path/to/output
BUILD_DIR ?= $(CURDIR)/build/sparkless
APP_PATH = $(BUILD_DIR)/Build/Products/Release/UnderpressuredUpdaterFree.app
ZIP_PATH = $(BUILD_DIR)/UnderpressuredUpdaterFree.zip

.PHONY: help deps build\:sparkless zip\:sparkless

help:
	@printf '%s\n' \
	  'make deps             Build or reuse cached native dependencies.' \
	  'make build:sparkless  Build a Release app without Sparkle updates.' \
	  'make zip:sparkless    Build and ZIP the app for transfer to another Mac.'

# The script checks its cache before rebuilding. Its first run needs network access.
deps:
	./scripts/build-deps.sh

# This existing scheme excludes Sparkle and needs no feed URL or update key.
# Ad hoc signing allows local testing without a Developer ID certificate.
# The result is not notarized; the receiving Mac may require Open Anyway in
# System Settings > Privacy & Security. It also needs Apple Silicon and macOS 27+.
build\:sparkless: deps
	xcodebuild build \
	  -project Underpressured.xcodeproj \
	  -scheme UnderpressuredUpdaterFree \
	  -configuration Release \
	  -derivedDataPath "$(BUILD_DIR)" \
	  CODE_SIGN_IDENTITY="-" \
	  CODE_SIGN_STYLE=Manual
	@printf '\nApp: %s\n' "$(APP_PATH)"

# Preserve the app bundle and its metadata when packaging it for transfer.
# Unzip on the other Mac and copy the .app to Applications; Xcode is not needed.
zip\:sparkless: build\:sparkless
	ditto -c -k --sequesterRsrc --keepParent "$(APP_PATH)" "$(ZIP_PATH)"
	@printf '\nZIP: %s\n' "$(ZIP_PATH)"
