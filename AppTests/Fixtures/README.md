# Selected-filter indicator baseline

`checkmark-macos27.png` is the 24×24 pixel crop of the real selected filter's checkmark, rendered by the existing `NSHostingView` window fixture. The fixture uses Aqua appearance, an opaque white background, `en_US` locale, LTR layout, and 2× backing scale. The crop starts 10 points inside the required button's AX frame and spans 12×12 points around its vertical center. AX screen frames are converted through the window into the hosting view's coordinates, including its flipped orientation.

Reviewed by the implementing agent on 28 October 2026: the crop contains the whole dark checkmark on the native light button surface, with no title or button edge. The full hosting-view screenshot was also inspected. This is automated-fixture review, not human visual or VoiceOver approval. Human review remains pending.

Validated runner: Apple M2, macOS 27.0.1 (26A434), Xcode 27.1 (27A9275). The pixel test requires the exact OS patch and 2× backing scale. A runner or appearance change requires explicit inspection and calibration; there is no update/autoaccept mode. All three selected filters compare to this same glyph crop, allowing mean absolute RGB error below 0.025 on a 0–1 scale. The pixel assertion requires the glyph to remain visible.

Native `cacheDisplay` retains transparent pixels unless the fixture supplies a background. An initial transparent capture appeared black in the image viewer; it was rejected, never used as a baseline. A later ScreenCaptureKit attempt failed macOS recording authorization and was removed. The final fixture captures only its own hosted view and needs no screen-recording permission.

Every run retains actual crops, content screenshots, full-window screenshots, and AX dumps under its printed `UI ARTIFACTS` directory. Review these when the test fails; do not replace the baseline solely to make a new runner pass.
