# NyaEH Agent Guide

## Architecture

NyaEH is the SwiftPM-first macOS SwiftUI package core for the user-facing NyaEH app. Keep the project text-based and easy to review. Keep the existing packaging project thin.

The package exposes the app scene for two hosts:

- `NyaEHCore`: the library product and main module used by tests and external app shells. The SwiftPM package name is `NyaEH`.
- `NyaEHDevRunner`: the SwiftPM executable used by `script/build_and_run.sh` for local development runs.
- `NyaEHScene`: the public SwiftUI `Scene` entry point shared by `NyaEHDevRunner` and the external Xcode shell.
- `Packaging/NyaEH`: the Xcode macOS app shell. It imports this package through the local package reference `../..` and owns the app name, AppIcon, `com.gazelee.NyaEH` Bundle ID, sandbox settings, signing, hardened runtime, Info.plist generation, and distributable `.app` builds.

The shared package and external Xcode shell both target macOS 26 or newer.

Keep business logic, SwiftUI app UI, stores, services, database code, models, and tests in this package. Do not copy NyaEH source files into the Xcode target; the shell should stay thin and call `NyaEHScene()`.

Use these source boundaries:

- `App/`: reusable scene setup and window/settings composition.
- `Views/`: SwiftUI screens and focused components. Keep `ContentView` as high-level navigation/composition.
- `Stores/`: observable UI state, view-facing actions, async task orchestration, and derived display collections.
- `Models/`: domain values such as library books, gallery metadata, tags, statuses, preferences, grouping, and batch jobs.
- `Services/`: use-case oriented app services for scanning, metadata fetching, cover caching, tag translation, credentials, bookmarks, and file status.
- `Database/`: SQLite connections, migrations, repositories, and repository protocols.
- `Support/`: small helpers, formatting, path utilities, localization, theme/language values, and extensions.

Prefer existing patterns over new framework layers. Add abstractions only when they reduce real duplication or isolate a domain boundary that already exists in the codebase.

`NyaEHAppModel` is the scene-level dependency container. Views should receive the narrow domain handle they use (`SearchStore`, `HomeStore`, `ReadingStore`, `OrganizationStore`, `TagDiscoveryStore`, `TaskCenterStore`, or `MaintenanceStore`) rather than the entire app model. `CatalogStore` owns the shared book identity cache and targeted entity mutations; cross-domain invalidation flows through `LibraryChangeBus`.

## Skills and Toolchain

- Use Swift Concurrency (`swift-concurrency:swift-concurrency`) for Task, actor, Sendable, isolation diagnostics, cancellation, and task lifetime work.
- Use SwiftUI Expert (`swiftui-expert:swiftui-expert-skill`) for SwiftUI state, composition, list identity, navigation, performance, and SDK API migration.
- Use the relevant Build macOS Apps skills for SwiftPM/build/run workflows, windows, AppKit interop, signing, and sandbox issues. Combine skills when a change crosses these boundaries, reading only the references relevant to the task.
- Refer to skills by name; do not add machine-specific, versioned plugin cache paths to repository guidance. Apply skill advice against actual code, compiler diagnostics, and project constraints. Installing a skill is not a reason to introduce dependencies, change architecture, or perform a blanket refactor.
- After a toolchain upgrade, record `swift --version`, `xcodebuild -version`, and the selected SDK. Separately inspect `Package.swift` and the external Xcode shell's effective settings for Swift language mode, strict concurrency, default actor isolation, and upcoming/approachable concurrency features. Do not assume shell settings apply to package targets.
- Distinguish compiler version, Swift language mode, SDK version, and deployment target. The currently installed toolchain does not establish the project's minimum required toolchain; retain macOS 26 support unless the user explicitly changes that product requirement.
- Check API availability and provide compatible fallback behavior before adopting newer APIs. Base syntax migrations on the selected compiler and actual diagnostics; do not prescribe blanket adoption of `@concurrent` or newer state initialization syntax.
- Establish an upgrade baseline with both the SwiftPM verification commands and external Xcode shell build under Verification. Record successes, failures, and untested behavior explicitly; a successful version command is not a successful build or runtime check.

## Concurrency Review

- Keep UI-owned mutable state on `MainActor`. Give heavy synchronous IO, archive extraction, image decoding, and vector computation an explicit execution boundary off the main actor; adding `async` alone does not establish one. Do not isolate whole services to `MainActor` merely to silence diagnostics.
- Prefer structured concurrency. For each retained unstructured or detached task, identify its owner, cancellation propagation, completion cleanup, and result-validity checks. Awaiting a task's value does not by itself propagate cancellation to that task.
- Review stopping underlying work separately from discarding stale results. Carry cancellation through service and worker boundaries, and use request identity or generation checks where work can be superseded. After cancellation and immediate restart, an old task must not publish results or clear the new task's handle/progress state.
- When adding or modifying `@unchecked Sendable`, `@preconcurrency`, or `nonisolated(unsafe)`, document the concrete safety invariant and the conditions for replacing the escape hatch with checked isolation. Inspect mutable dependencies and cross-actor values rather than treating an annotation as proof of safety.
- Preserve bounded concurrency, request coalescing, cache budgets, security-scoped access lifetimes, and deterministic/transactional database commit rules. Cancellation changes must respect shared consumers and must not introduce partial commits where an operation promises atomicity.

## Data Rules

- The SQLite database is the source of truth for local library state.
- `library_books` stores source file paths, display fields, metadata summaries, grouping state, user flags, and file existence/status.
- `library_books.last_read_at` stores the most recent reader-open time; do not infer recent viewing from `updated_at` because metadata, grouping, status, and other writes can update that field.
- `library_books.is_user_hidden` is the explicit user hide flag. Keep it separate from structural `hidden_book`, which hides collection/version members from top-level grouping displays.
- `book_reading_state` stores per-book current page, total pages, and completion time. Preserve it across rescans and use it for continue/unread/completed Search scopes.
- `gallery_metadata` stores external E-Hentai/ExHentai metadata keyed by SHA1 hash.
- `import_pipeline_batches` and `import_pipeline_items` persist smart-import batch boundaries and per-book stages. Never infer batch membership from `updated_at`; a batch must keep its original book-ID snapshot across restarts and concurrent scans.
- Tag data is materialized from each book's metadata into `tags`, `book_tags`, and `tag_translations` for filtering, summaries, and display.
- `book_work_character_links` remains rebuildable evidence from single-work books. `work_character_decisions` stores durable global manual confirmations/exclusions, while `book_work_character_suppressions` stores per-book automatic-claim dismissals. Detail pages resolve these together; automatic claims are book-scoped and never become evidence for further inference. A work detail must still show books carrying its tag when no character can be assigned.
- Collections and version groups are database-backed organization features. Keep their behavior in services/repositories, not ad hoc view mutations.
- A version group occupies one logical series slot. Its members share the same collection and order, or both fields are null. Organization transactions own these fields and structural visibility. Scan and metadata commits must preserve committed grouping. v22 and maintenance repair unambiguous legacy groups; report conflicting series and resolve them through an explicit series assignment.
- Organization actions are queued in user order through the background `OrganizationMutationWorker`; `CatalogStore` may apply deterministic temporary UI changes, but committed repository snapshots reconcile them. Keep targeted book/group cache patches and revision-checked background projections instead of calling full `refresh()` for each organization write. Debounced series order must flush before membership changes, and source deletion must drain the organization queue.
- The partial unique index permits only one primary book per version group. Switch primaries by demoting the old primary before promoting the replacement within the same transaction; a single multirow `UPDATE` may violate the index as rows are checked.
- Reusable version label history is stored in `version_label_suggestions`; keep `library_books.version_label` as the current per-book value.
- Long-lived app data must be rooted through `AppDataDirectory`.
- Versioned `.nyaehbackup` packages contain `NyaEH.sqlite`, optional `TagAssets`, and `manifest.json`. Source archives, rebuildable caches, and credentials are intentionally excluded.
- Production app data lives in `~/Library/Application Support/NyaEH/`.
- Keep legacy storage identifiers in `LegacyNaming`. The first launch snapshots the old SQLite database, including WAL state, into the new filename without replacing an existing database or removing the source. Backup restore accepts the previous filename. Do not change existing migration IDs.
- Development runs launched through `script/build_and_run.sh` set `NYAEH_APP_SUPPORT_DIR` and write app data under `.nyaeh-dev/Application Support/NyaEH/`.
- Development runs also set `NYAEH_USER_DEFAULTS_SUITE=NyaEH.Development` so preferences stay separate from production.
- `NyaEHDevRunner` explicitly passes `NyaEHDevelopmentConfiguration`, which enables the development-only Debug sidebar page. `script/build_and_run.sh` sets `NYAEH_DEVELOPMENT_COMIC_PATH` to `.nyaeh-dev/comic/comictest.zip`; the external NyaEH Xcode shell must continue using the default `NyaEHScene()` so debug tools remain absent from production.
- Production E-Hentai/ExHentai cookies use `CredentialStore` backed by `~/Library/Application Support/NyaEH/Credentials/credentials.json`, not UserDefaults or Keychain. The directory is mode `0700` and the atomically written file is mode `0600`. The app does not read or migrate old Keychain entries; users re-enter cookies after upgrading.
- Development runs set `NYAEH_CREDENTIAL_STORE=developmentPlaintext`, so credentials are stored as plaintext JSON under `.nyaeh-dev/Application Support/NyaEH/Credentials/`; QA uses its own isolated app-data root. Backups exclude credentials.
- Sparkle checks the signed feed in `XKLZ/NyaEH-Public` anonymously. The public app must not access, send, or delete the old private channel's update token.
- Original book files stay in their source locations. Normal management operations update database records only.
- Source removal is an explicit confirmed move to macOS Trash, never a fallback permanent deletion. `library_deletion_operations` journals source identity and the file/DB/cache phases; startup may only resume `sourceHandled` and `cleanupPending` operations without touching source paths. Uncertain file moves require an explicit retry.
- Book deletion, pending recommendation invalidation, version-primary/singleton repair, affected empty collection removal, shared metadata cleanup, and import counters commit in one main-database transaction through `LibraryConsistency`. Pending create recommendations require two logical members; add recommendations may have one. Keep membership/fingerprint checks shared with acceptance and repository reads/writes.
- Import `deleted_count` is incremented from the removed item's persisted batch membership; `total_count` remains the original snapshot. Only migration backfills historical missing-member counts. Version-review completion must still precede collection analysis; manually paused batches stay paused.
- v20 performs a backed-up, one-time repair of all historical empty groups/collections and invalid derived relationships. Ordinary startup must not delete newly created empty groups. Maintenance reuses the same repair rules. Keep backup manifest schema version and pending-migration backup checks in sync with appended migrations.
- Missing or broken files should be represented as status, not treated as fatal errors.

## Current Systems

- Library scanning supports local `.zip` and `.cbz` archives. It records file size, modification time, image count, representative SHA1 hash, and missing/broken status.
- Production `NyaEH.sqlite` connections use a WAL-backed GRDB `DatabasePool`; repositories accept `DatabaseReader`/`DatabaseWriter` protocols so tests may continue using an in-memory `DatabaseQueue`.
- Cover caching extracts and stores generated cover thumbnails under app data. Rescans may skip archive reads only when file metadata and cover cache are still valid. UI cover loading must go through `CoverImageLoader`, which coalesces requests, downsamples to the 128/256/512 pixel buckets, and runs at most four decodes concurrently before caching by decoded cost. Offscreen views should cancel their load task so queued requests without waiters can be discarded and completed orphan decodes do not publish UI updates.
- Gallery metadata fetch searches E-Hentai/ExHentai by representative SHA1 and stores API metadata separately before copying display summaries onto `library_books`.
- Reader page loading records reading through `CatalogStore.recordRead`, which performs targeted `read_count`/`last_read_at` updates. `ReaderArchiveSession` owns one archive enumeration per reader window; do not reopen or re-enumerate an archive for each page.
- The independent reader is a lightweight media window: keep its bottom Liquid Glass controls transient and centered, preserve native continuous scrolling, and route paged wheel/key input through the window-scoped bridge. Its optional left thumbnail rail is a persistent display preference, must reuse the window's `ReaderArchiveSession`, downsample lazily instead of retaining full pages, and keep a separate bounded thumbnail cache. Window frame and global layout/fit/zoom/thumbnail restoration use `AppPreferences` / the configured UserDefaults suite; legacy `NSWindow` autosave is migration-only. Keep these UI preferences separate from reading progress, do not persist fullscreen/control visibility, and keep page-number editing as the only keyboard-focusable reader control.
- Search is the only user-facing full-library browser. Keep `.library` / `LibraryShelfView` as deprecated internal compatibility entry points only; do not add them to sidebar, menus, or user documentation.
- Search paging and ordinary scope/tag/facet filtering belong in SQLite. Search visibility is controlled by `is_user_hidden`, never structural `hidden_book`. Grouped search deduplicates collection, version group, or standalone-book entities before counting and paging. The individual-books mode matches, counts, and pages by book ID, including matching secondary versions. Regex may use the bounded Swift fallback after SQL-compatible scope/title narrowing.
- Search input edits and tag-suggestion selection update the draft only. A selected suggestion replaces the active token without submitting; Return without a selected suggestion or the explicit Search button submits the query.
- Search also supports one-shot cover-image queries against `CoverVectors.sqlite`. Query images are read under temporary security-scoped access, converted with the same Vision revision/`.scaleFit` preprocessing as indexed covers, and never persisted. Cover-image results use squared-L2 thresholds (`20` high confidence, `120` maximum) and exclude user-hidden/missing books. Grouped results sort by minimum entity distance. Individual results page the bounded match list in distance order. Treat sqlite-vec's raw `distance` as L2 and square it at the repository boundary so the app-wide cover-distance contract remains squared L2.
- Reader image memory is windowed around the current page and cost-limited to 5% of physical memory clamped to 128–384 MiB; do not retain every decoded page or compressed page data after decode. Reader thumbnails are independently downsampled to at most 320 pixels and cost-limited to 32 MiB so the thumbnail rail never expands the full-page cache.
- Metadata batch jobs run through the task-center domain/Catalog orchestration, honor user-configured limits/delays/retries, and should pause on access/authentication failures instead of hammering remote services.
- Smart import uses per-book metadata work followed by one version-analysis wave and one collection-analysis wave per batch. Recommendation analysis reads the full eligible library, while focus book IDs constrain newly written candidates to changes involving the current batch. Version decisions must settle before collection analysis begins.
- Smart import metadata checks a manually supplied gallery URL, then a valid single-line HTTPS E-Hentai/ExHentai URL in optional archive `webinfo.txt`, then the local SHA1 cache and remote SHA1 search. Missing or invalid `webinfo.txt` falls through; a valid URL whose API fetch fails follows the normal retry/pause/defer rules without hash-search fallback. Read source archives under the saved library bookmark; this does not affect manual detail or batch metadata fetches.
- Collection/series recommendations may use Apple `NLContextualEmbedding` only after the user explicitly downloads the CJK assets, builds a compatible preprocessing-v3 `SemanticTitleVectors.sqlite`, and enables the setting. The precision-first profile uses normalized-vector squared L2 `0.2767` and mutual Top-3; `0.30` remains diagnostic-only. The cache stores mean-pooled, L2-normalized title-stem vectors by model/profile generation, is rebuildable, and is excluded from backups. Preprocessing v3 indexes clean unnumbered titles as well as structured ordinal titles. Series construction still begins from explicit ordinal seeds; one clean unnumbered title may be inferred as volume 1 only through strict lexical evidence, an explicit volume 2 or two numbered supporters, no existing volume 1, and no catalog/special-edition ambiguity. Semantic evidence cannot bypass this lexical gate. Existing collection primaries may support one best add-to-collection target but never participate in duplicate create candidates; conflicting ordinals and exact multi-target ties produce no user-visible recommendation. Missing assets/indexes always fall back to lexical rules and never block smart import.
- Series ordinal handling must flow through `SeriesOrdinalResolver`. Recommendation inference keeps the strict implicit-first evidence gate; confirmed collections use the relaxed sort policy: stable clean-unnumbered members, compatible explicit ordinals, then stable unresolved/rejected members. Recommendation acceptance and the manual auto-sort action write only `library_books.collection_order`. Acceptance sorts once and stales conflicting pending recommendations; scans, refreshes, and app launch must not silently reorder existing collections. A version group's secondary members inherit the primary member's collection order so later primary switches do not change the logical series position. Do not add a persistent ordinal field or rewrite titles to preserve parsed evidence.
- The Import page is a maintenance inbox over original `LibraryBook` records. It must not use Search/group display folding, must show structural secondary versions independently, and must not mutate the shared Search filter.
- Full scans inspect archives with at most three workers, commit results in deterministic path order, throttle progress to 10 Hz, and detect missing paths through a temporary `seen_paths` table plus `NOT EXISTS`.
- EhTagTranslation cache downloads the latest release `db.text.json` from `EhTagTranslation/Database`, stores a manifest/cache under app data, and materializes translations only for locally known tags.
- The NyaEH Xcode shell must keep outgoing network client entitlement enabled. Metadata fetch, tag translation downloads, and connectivity tests all use `URLSession` and fail under App Sandbox without `com.apple.security.network.client`.
- Preferences belong in `AppPreferences`; persist non-secret preferences in UserDefaults and secrets in `CredentialStore`.
- The General language picker writes the host app's own `AppleLanguages` preference, shared by NyaEH and Sparkle after restart. Migrate legacy preferences only within the host's persistent domain, without replacing current values or importing old UserDefaults credentials. Keep the current interface language stable until relaunch.
- Localization should flow through `AppLocalizer` and `L10nKey`. Avoid hard-coded user-facing strings in views when a localized key already fits.
- Security-scoped library folders should be saved and resolved through `LibraryBookmarkService`.
- In the sandboxed NyaEH app, every feature that reads original archive paths from `library_books.filepath` must resolve the saved library folder bookmark and hold security-scoped access while reading. This applies to scanner reads, reader/archive preview, and any future source-file inspection.

## macOS UI Rules

- Distinguish view-owned state, injected observable state, and bindings. Do not seed one-time `State` from inputs that must continue tracking a parent; document intentional one-time seeds and their view identity assumptions.
- Keep frequently changing dependencies close to the smallest subtree that reads them. The domain handles currently forward to a shared `CatalogStore`; do not assume they provide independent state or observation isolation. Prefer narrow domain dependencies without mandating an unrelated architecture rewrite.
- Preserve stable list and navigation identity. Review task ownership and stale-result handling when views disappear, the selected book changes, or a reader window closes.
- Ordinary card menus resolve actions by the displayed book ID. Reading state belongs to that edition and favorites use the existing version-group synchronization. Search card selection uses Command-click on the cover or title; secondary clicks open the menu. Compact rows and management member lists own their selection gestures.
- Series and version management keep separate candidate-pane visibility preferences in `AppPreferences`. A compact-window candidate sheet is temporary and must not overwrite either saved preference.
- Version management's direct reader action routes through `BookDetailView` so bookmark access, reading progress and reader window preferences use the existing launch path. Clear a pending launch when navigation leaves its book.
- Retain necessary AppKit bridges, existing command routing, and reader behavior. Generic skill guidance alone is not grounds to rewrite FocusedValues-based menus or expand Liquid Glass usage; validate ownership, capture lifetimes, availability, and the actual desktop behavior involved.
- Ground performance changes in measurements such as Instruments traces or the existing benchmarks. File length is a review clue, not proof of an update-cost problem or a requirement to split a view.
- Prefer SwiftUI-native macOS scenes, split views, sidebars, toolbars, commands, settings panes, keyboard affordances, and system controls.
- Main-window trailing action groups and their spacers use `MainWindowToolbarLayout.actionPlacement` (explicit `.automatic`) inside the `NavigationSplitView` detail column, with one leading flexible spacer in that column. `.secondaryAction` marks these items as centered on macOS; attaching spacers to the outer split view puts them in the sidebar section. Category pages own their trailing toolbar and spacer while the parent omits its actions. Alignment must not depend on a visible title or the development/QA `.principal` identity item; production omits that identity item entirely.
- Use system-adaptive colors and materials.
- Keep large screens decomposed into focused subviews. View files may contain private helper views when they are tightly scoped to the parent screen.
- Put user actions on the appropriate domain Store, `CatalogStore`, or services when they change app state, touch the database, perform IO, or coordinate async work.
- Do not make the UI delete, move, or rewrite source archive files unless the feature is explicitly designed as a destructive file operation with confirmation.
- Xcode shell changes belong in `Packaging/NyaEH` only when they concern packaging, signing, sandbox, app icon, bundle metadata, or the shell's call into `NyaEHScene()`.
- Keep the layered Icon Composer `AppIcon.icon` in the app target, with `AppIcon` selected as the primary icon in Debug and Release. The public candidate builder checks the compiled icon and bundle metadata before packaging.

## Documentation Hygiene

- Before non-trivial work, read this file. If the change may be affected by prior architectural decisions, also scan the latest entries in `AGENTSLOG.md`.
- After every code change or feature addition, check whether `AGENTS.md` or `README.md` needs to be updated. Update them when architecture, setup, user-facing behavior, data rules, verification, or packaging expectations change.
- Append to `AGENTSLOG.md` only for changes that may affect future implementation decisions: target/product structure, app entry points, database schema or data-root rules, verification commands, Xcode shell/signing/sandbox workflow, or cross-module behavior contracts.
- Do not use `AGENTSLOG.md` as a detailed changelog. Skip ordinary UI tweaks, formatting-only changes, and localized bug fixes unless they change a rule future agents must know.

## Testing Guidance

- Database changes need migration/repository tests using temporary databases.
- Scanner/archive changes need coverage for supported extensions, representative hash selection, cover cache reuse, missing files, broken archives, and fallback readers.
- Metadata fetching changes need HTTP-client-backed tests for URL/cookie construction, HTML parsing, API mapping, and access/error pages.
- Batch metadata changes need tests for limits, retry behavior, skipped books, progress state, and pause conditions.
- Tag translation changes need parser/cache/materialization/resolver tests.
- Preference or credential changes need tests for defaults, normalization, suite isolation, and legacy migration where applicable.
- Store/UI behavior should be tested at the store/service level when possible; keep view-only changes small and manually verify through the app.
- For task lifecycle changes, cover cancellation reaching underlying work, immediate restart after cancellation, stale-result suppression, and one consumer cancelling a shared request while another remains active. Exercise the Store-to-service boundary when a service-only test cannot prove user-action behavior.
- For UI changes, manually verify navigation, keyboard focus, window closure, and state restoration as relevant to the affected behavior. Select the app environment by persistent-state risk and required evidence using the rules below.

## Choosing a Test Environment

- Use the persistent development app for rapid visual iteration on colors, layout, navigation hierarchy, and animation, including inspection of realistic page density in the existing development library. Do not use its retained library for destructive deletion, import, or migration checks.
- Use an ephemeral QA session for flows that change library records, grouping, reading progress, preferences, or source files, and for restart persistence, failure recovery, or cleanup checks. Use the sandbox QA host when the behavior depends on bookmarks, folder grants, file permissions, Trash, signing, or App Sandbox.
- Test database and algorithm changes first with temporary databases, fixed fixtures, or the relevant opt-in performance script. The default QA gallery has only two synthetic books; its UI cannot establish recommendation quality or large-library performance. Add QA UI verification when the user-facing flow matters.
- These paths can be combined: iterate on appearance in the persistent development app, then use ephemeral QA for stateful behavior. `./script/verify.sh` remains the automatic acceptance baseline before handing off substantial changes. `./script/build_and_run.sh --verify` checks only an ephemeral build and startup; neither startup check nor automated tests establish manual UI acceptance.
- If the right path is unclear, briefly tell the user before testing what each environment can prove, what retained data it may touch, and what it would leave unverified. Choose the path that matches the higher state risk and proceed; ask only when the choice depends on a user preference or would require touching real user data.

## Test Isolation and Lifecycle

- Use `script/verify.sh` for acceptance runs; `script/build_and_run.sh` remains the persistent development entry. `--verify` delegates to an ephemeral startup check. Preserve existing `.nyaeh-dev` data.
- Test hosts validate their Info.plist profile and matching environment before database, defaults, credentials, or server initialization. Missing configuration must fail closed, never use production paths or Keychain. Keep the formal Xcode shell calling `NyaEHScene()`.
- QA hosts must be restarted through `script/verify.sh restart <session-id>` so their isolation environment is restored. The development host's in-app language restart delegates to `script/build_and_run.sh`, which rebuilds into a temporary bundle, stops only the recorded instance, replaces the app, and relaunches with its isolation environment. It preserves `.nyaeh-dev` data; QA still reports the script-only limitation.
- `TestRuntime` owns test identity and path validation. QA source operations are restricted to the session's generated fixture inventory. Do not use real source archives for destructive tests or copy production databases by default.
- Never use global name-based process termination such as `pkill -x NyaEH`. Stop only the recorded application path, Bundle ID, PID and launch-time identity. Use exact app paths/IDs for UI tools, not display-name guesses.
- Only one live QA session per workspace. Finish it before switching to sandbox verification. QA app names, window titles and banners must clearly distinguish them from production and persistent development.
- Build/test first, startup check second; add sandbox/UI checks when relevant. A validated ready record proves startup, not UI acceptance. Locked/unavailable UI remains pending and must be reported explicitly.
- Session manifests in ignored `.nyaeh-verification/` track resources before/after creation. Success cleans owned resources; failure/interruption/pending UI retains them for 7 days. Entry commands clean expired stopped sessions; compact reports retain 30 days. Do not add a background cleanup daemon.
- Cleanup verifies canonical paths, ownership and resource identity. Changed/unverified/in-use resources must be retained and reported. Never empty Trash; only delete specifically journaled synthetic files whose current identity and hash match. Preserve retry journals on cleanup failures.
- Every verification handoff reports build, tests, startup, UI and cleanup separately, including remaining resources. Shared build caches and persistent development data are excluded from session cleanup.

## Verification

Run these before handing off substantial changes:

```bash
./script/verify.sh
# Internally runs swift build, swift test, script tests, and isolated startup verification
```

For synthetic 5k/10k/30k Search performance verification, run `./script/performance_verify.sh`. Keep absolute timing assertions out of the ordinary test run; the script enables them explicitly with `NYAEH_RUN_PERFORMANCE_TESTS=1`.

When a change touches the external Xcode shell, package products, app entry points, signing, or sandbox behavior, also run:

```bash
xcodebuild -project Packaging/NyaEH/NyaEH.xcodeproj -scheme NyaEH -configuration Debug build
```

For release packaging checks, use the same project and scheme with `-configuration Release`; default app version values live in the Xcode project and can be overridden at build time with `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.

Build a local public candidate with `./script/build_public_candidate.sh` after setting `NYAEH_SPARKLE_PUBLIC_KEY`. This command must never publish or upload. Keep tests synthetic; do not add test databases, source archives, personal credentials or private release assets to history.

For documentation-only changes, reading the edited files and checking `git diff --stat` is enough unless code behavior was also touched.
