# Agent Log

- The public Xcode shell uses a layered Icon Composer AppIcon. The candidate builder rejects bundles missing its compiled icon files or icon metadata.
- This snapshot starts a new public history. Tests must generate their fixtures; do not import private data or historical release assets.
- The standalone packaging project lives in `Packaging/NyaEH`. Public updates are anonymous and must never access the private channel's saved token.
- Publish from this repository only. Its signed appcast uses anonymous GitHub Release asset URLs and the independent public Sparkle key. Verify the release ZIP before publishing each feed entry; never copy older private assets or Git refs.
- Shared card menu commands resolve the displayed edition in the current catalog. Group navigation targets stable series/version IDs, including groups whose other editions are hidden.
- Work detail keeps one active character shelf per route. Assigning a character from its unclassified list adds a book-scoped tag and refreshes derived evidence in the same database transaction.
