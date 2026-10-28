# Project instructions

## Architecture

Underpressured uses domain-driven design within one Image Optimization bounded context. Read [the glossary](docs/GLOSSARY.md) and [the architecture contract](docs/architecture.md) before changing domain behavior.

- Domain types and operations own product invariants. Validate construction and every public mutation path, including restoration from storage.
- Application services own intake, admission, scheduling, cancellation and effect sequencing. Platform adapters implement their ports. Presentation owns observable UI state, localized text, focus and undo registration.
- Dependencies point inward. Do not introduce platform services, task scheduling or persistence formats into the domain. Foundation value types are permitted.
- Keep one owner for each mutable execution resource. Preserve atomic admission, source exclusion, path reservations, pixel budgets and file-commit semantics.
- A product Run includes pending intake. A queue execution interval ends when admitted work drains. Do not conflate their identities or lifetimes.
- Preserve persisted keys and compatible payloads during refactoring. Apply the documented recovery policy at storage boundaries.
- Update the glossary, specification and architecture with changes to language, behavior or ownership. Document consequential boundary changes in the architecture guide.
- Use the focused checks in [development](docs/development.md) and the existing integration gate. Mark planned coverage as pending until it has been implemented and run.

Keep focused changes within scope. Do not describe unexecuted checks as verified. See [native interaction checks](docs/development.md#native-gestures-and-voiceover) and [release build checks](docs/release.md#release-build-checks) for pending manual acceptance. Avoid generic repositories, event buses and extra bounded contexts without a concrete need.
