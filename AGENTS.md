# MDViewer project guidance

## Scope and precedence

- Implement MarkdownIt natively for iPhone and iPad, with iOS/iPadOS 26 as the baseline. The workspace remains MDViewer.
- Read [README](README.md), [the design specification](design/README.md) and [the architecture](docs/native-architecture.md) before changing the reader. Follow the shared component invariants; implementation parameters remain reviewable. The latest user instruction takes precedence.
- Discuss and obtain confirmation before introducing an unrequested product capability or workflow. Continue authorized fixes, alignment, component reuse and motion refinement without repeated permission requests.

## Sources of truth

| Source | Responsibility |
| --- | --- |
| [README](README.md) | Concise product introduction, language links and approved product screenshots |
| [Design specification](design/README.md) | Visual hierarchy, responsive layout, component behavior, rendering scope and motion |
| [Native architecture](docs/native-architecture.md) | Module relationships, state ownership, file access, context versions, tools and transport |
| [Privacy](docs/privacy.md) | Data, credentials and network flows |
| [Design tokens](design/tokens.json) | Shared values and motion parameters |
| [Components](design/components.json) | Component ownership, reuse contracts and design-section references |
| [Icons](design/icons.json) | Icon mapping |
| [Brand resources](design/brand/README.md) | One SVG master and palette for all generated logo and App icon assets |
| `MarkdownIt/Localizable.xcstrings` / `InfoPlist.xcstrings` | Shared native/Web UI translations and system permission copy |

Maintain requirements in these sources rather than duplicating the product specification here. Expanded and collapsed outline states share one toggle and row component. Motion must support Reduce Motion and rapid reversal.

## Implementation boundaries

- Design for general Markdown readers and arbitrary subjects, with restrained Apple-style UI and Feishu Docs reading quality. Do not add prototype labels, unsolicited welcome copy, extra product modes, a top toolbar or unrequested actions.
- Preserve original local files, arbitrary relative resources within granted folders, editable source, preview and outline from one buffer. Keep collapsed outline width at zero and follow the component's smooth chapter tracking and manual-scroll rules.
- Native preview and source expose one AI action in the system selection menu, without a second overlay. Global AI uses the current document, never an abandoned selection; sent references and retry snapshots remain immutable.
- Preview is read-only. Source can assist reading and edit only on an explicit request. Keep tools within the current file, validate revision and unique nonoverlapping replacements, apply atomically, save, and share undo/redo with manual input. Do not add an Apply stage or fixed tool-round limit; journal completed tools and detect repetition without document progress.
- Keep credentials, transport, file access and physical keyboard handling native. Software Return inserts a newline; physical Enter sends and Shift+Enter inserts a newline. Respect IME confirmation, repeats and drafts during generation.
- Use one rendering, selection and motion implementation. Web content must not receive API keys. Provider failures must not introduce automatic protocol/model fallback or retries.
- Follow the system's App language selection, with English fallback. Keep native and Web UI copy in the String Catalogs and regenerate Web resources after translation changes. Preserve document text, filenames, references and model responses verbatim; test helpers must not infer control state from a translated label.

## Editing and verification

- Edit formal rendering sources in `MarkdownIt/WebSource/`, fixed dependencies in `vendor/`, and the long fixture in `MarkdownItTests/Fixtures/ReadingGuide/`.
- Run `python3 scripts/build_native_web.py`, then `--check`. Commit generated `Resources/Web`, `Resources/Sample` and `Reader/ReaderDesign.swift` with their sources; never hand-edit only the outputs or depend on prototype/demo artifacts.
- Maintain the checked-in Xcode project and shared scheme directly. Check target membership and build phases when adding files. Release excludes the Debug fixture and includes `PrivacyInfo.xcprivacy`.
- Follow [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md). Verify affected behavior on both simulator families; report actual checks and remaining limits. Browser checks, simulated transport, simulator builds and CI configuration do not prove native device behavior, real provider success or a hosted CI pass.
- Use `scripts/verify_ios.py` for both full and targeted simulator verification (`--test-case` for diagnosis). Keep the shared build and signature checks; do not substitute hand-written simulator build commands or disable code signing. Targeted passes do not replace the full regression.
- Reproduce bugs and gather evidence before choosing a fix. Distinguish a hypothesis from a confirmed cause; do not add guessed delays. Outline feedback must not combine WebKit's default gray tap highlight with the current-row style.
- Never skip tests or exclude required cases to bypass a failure without the user's explicit permission. An unavailable test environment is an unresolved verification blocker, not a passing result.
- Test credentials use independent Keychain services and are deleted afterward. Never temporarily replace the normal App key. Offline dependency files, licenses and fonts must match `vendor/assets.json`.

## Repository hygiene

Public documentation must help users operate the app or contributors maintain it. Keep README to the agreed introduction and screenshot; CONTRIBUTING owns development and testing, SECURITY owns vulnerability reporting, and docs contains architecture and privacy. Keep actual product limitations with the relevant user guidance. CI/PR records hold run results and Issues track concrete defects. Do not retain acceptance progress, old provider results, chat histories or investigation reports, including by moving them into another document or archive.

Scripts require a repeatable maintenance purpose documented in CONTRIBUTING.md. Stable regressions belong in test targets. Remove temporary probes, raw requests/responses, build caches, screenshots and exploratory assets after investigation. Preserve approved brand masters, dependency licenses and shared component invariants.
