# Translations

English is the source language. The app also has Spanish, Brazilian Portuguese, German, French, Arabic, Japanese, and Simplified Chinese. AI tools wrote these seven translations. No native speaker reviewed them yet. A catalog entry with the state `translated` only means that the text exists.

To help, open a [GitHub issue](https://github.com/a-dev/underpressured/issues/new?title=Translation%20contribution), send a pull request, or email [support@underpressured.app](mailto:support@underpressured.app). Tell us your language or region, and if you are a native speaker or fluent.

## Where the strings are

| Catalog | Strings |
| --- | --- |
| [`App/Localizable.xcstrings`](../App/Localizable.xcstrings) | App menus, Settings, and support text |
| [`AppModel/Resources/Localizable.xcstrings`](../Packages/UnderpressuredKit/Sources/AppModel/Resources/Localizable.xcstrings) | Results, presets, and accessibility speech |

The key is the English text. Each entry has a translator comment. Read the comment first. Do not change the sentinel entries `localization.app-bundle-check` and `localization.bundle-check`.

Do not translate `Underpressured`, JPEG, PNG, shortcuts, or technical identifiers. Use the macOS names for system sections in your language.

## Terms

Use the same word for a term in all strings.

| English | Meaning |
| --- | --- |
| Preset | A saved set of image settings. The built-in presets are Balanced JPEG, Web, Small, and Screenshots PNG. Translate all built-in names. Preserve custom names and the JPEG and PNG format names. Use the usual image-editing word. |
| Replace Originals | Write the result in place of the source. The source can go to Trash. Keep it different from Export Copies. |
| Export Copies / Export folder | Save copies in a folder. The original does not change. |
| Lossless | Keeps the image data, with the limits in the help text. Do not promise more. |
| Visually lossless | JPEG re-encode with no visible loss. It is not mathematically lossless. |
| Quality | Encoding quality. Higher keeps more detail and usually makes larger files. Lossless does not use it. |
| Resize Rule | A maximum width, height, or long edge. `px` is pixels. |
| Optimized / Skipped / Failed / Cancelled | Different result states. Skipped is not an error. |
| Already optimal / Already optimized with these settings | Two different skip reasons. |
| Keep metadata | Keeps EXIF, GPS, IPTC, and XMP. The encoder always keeps the color profile. Keep the privacy meaning. |
| Active Preset | The preset for new work. |
| Check for Updates… | Manual update check. The ellipsis means that the command starts a process. |

If a comment does not answer your question, ask in an issue. Do not guess.

## Placeholders and plurals

- Keep each placeholder and its type: `%@` is a string or value, `%lld` is an integer. To change word order, use positional forms such as `%2$@`.
- Do not add units or punctuation that the value already has. The comment says if a value is a count, percentage, size, filename, path, or dimension.
- Keep a sentence in one key. Do not join fragments.
- Keep all plural categories. Arabic uses zero, one, two, few, many, and other.
- Do not change filenames and paths. In Arabic, mixed-direction text must stay readable.
- Accessibility strings are spoken. Translate them as natural speech. Do not shorten them.
- Keep menu verbs and ellipses.

## Report a correction

Include the language, English key, current translation, proposed translation, and reason in the issue.
Add a screenshot when layout affects meaning. Use test files only.
To make current screenshots, use the [checks](#checks).

## Checks

- `python3 scripts/check-localization.py` checks the catalogs.
- `scripts/check-localized-ui.sh` makes screenshots of the UI in each language.

## Translation review

For each language, complete these checks on a real Mac:

- [ ] Review both catalogs in context, including menus, Settings, errors, results, and VoiceOver speech. Follow the translator comments and [terms](#terms).
- [ ] Check placeholders, units, plural forms, and filenames and paths. For Arabic, check right-to-left layout and mixed-direction text.
- [ ] Switch the app language in System Settings and relaunch. Check dialogs, notifications, About, help, and layout for wrapping or truncation.
- [ ] Run the [checks](#checks). After corrections, recheck layout and VoiceOver. Record the commit, macOS version, results, and any checks you could not complete.

## Review status

A language is "reviewed" only when a native or fluent reviewer completes the [translation review](#translation-review), and all findings are resolved. Record the reviewer's name (with their agreement), fluency, date, scope, and issue or PR links. Mark each finding as corrected, declined with a reason, or open.

All seven languages need a review. No reviewer is recorded yet.

| Language | What to check |
| --- | --- |
| Spanish (`es`) | Check regional neutrality, "preajuste," and wording for non-image files. |
| Brazilian Portuguese (`pt-BR`) | Check Brazilian usage for "predefinição" and verbs for export, optimization, and Trash. |
| German (`de`) | Check "Voreinstellung," "Skalierungsregel," and macOS section names. |
| French (`fr`) | Check agreement, "préréglage," and macOS section names. |
| Arabic (`ar`) | Check agreement, all plural forms (including parenthetical counts), mixed filename speech, and visually lossless wording. |
| Japanese (`ja`) | Check natural image-processing terms and the distinction between source file and original format. |
| Simplified Chinese (`zh-Hans`) | Check image-processing terms, menu verbs, and accessibility speech. |
