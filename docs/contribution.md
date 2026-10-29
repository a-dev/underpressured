# Contributing

This guide is for people who build Underpressured, change its code, or improve its translations. The [README](../README.md) describes the app for users.

## Build and test

Follow [Build the app](development.md#build-the-app). Before you send a pull request, run `scripts/test.sh`. CI runs the same script.

## Change the code

Read the [architecture](architecture.md) and the [glossary](GLOSSARY.md) first. Then follow the [change workflow](development.md#change-workflow).

## Commits and pull requests

Write commit messages in the [Conventional Commits](https://www.conventionalcommits.org/) format: `type(scope): summary`.

- Use the type `feat` for a new feature, `fix` for a bug fix, `docs` for documentation, and `chore` for other work.
- The scope is optional. For example, use `sandbox`, `ci`, or `test`.
- Add `!` after the type or scope for a breaking change, for example `feat!:`.

A release commit changes only `Config/Version.xcconfig` and `CHANGELOG.md`. Use the message `chore(release): <VERSION> (build <BUILD>)`, for example `chore(release): 1.1.0 (build 2)`. Make it the last commit before the release tag `<VERSION>-<BUILD>`. See [Release](release.md).

Merge a pull request with a merge commit. Keep the default message from GitHub. If you squash a pull request, give it a title in the Conventional Commits format. GitHub uses that title as the commit message.

Add the `full-ci` label to a release pull request. For a pull request without this label, CI runs only the fast tests.

## Translations

AI tools wrote all seven translations. No native speaker reviewed them yet. The [translation guide](translations.md) tells you how to send a correction.

## Report a problem

[Open an issue](https://github.com/a-dev/underpressured/issues) or email [support@underpressured.app](mailto:support@underpressured.app).
