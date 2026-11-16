// 本文件集中定义 NyaEH 主库迁移、表结构和索引，迁移必须保持既有本地书库数据可升级。

import GRDB

extension DatabaseMigrator {
    static var nyaeh: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // 早期迁移以幂等建表为主，后续版本只追加列/表/索引。不要重排或重命名已发布迁移，
        // 否则用户本地 NyaEH.sqlite 的迁移历史会和代码不一致。
        migrator.registerMigration("v1_initial_library") { db in
            try db.createNyaEHBookTables()
        }

        migrator.registerMigration("v2_book_library_schema") { db in
            try db.createNyaEHBookTables()
        }

        migrator.registerMigration("v3_tag_indexing") { db in
            try db.addTagIndexing()
        }

        migrator.registerMigration("v4_tag_translation_cache") { db in
            try db.addTagTranslationCacheFields()
        }

        migrator.registerMigration("v5_library_grouping") { db in
            try db.addLibraryGrouping()
        }

        migrator.registerMigration("v6_version_label_suggestions") { db in
            try db.addVersionLabelSuggestions()
        }

        migrator.registerMigration("v7_followed_tags") { db in
            try db.createFollowedTagTable()
        }

        migrator.registerMigration("v8_version_recommendations") { db in
            try db.createVersionRecommendationTables()
        }

        migrator.registerMigration("v9_book_version_labels") { db in
            try db.addBookVersionLabels()
        }

        migrator.registerMigration("v10_collection_recommendations") { db in
            try db.createCollectionRecommendationTables()
        }

        migrator.registerMigration("v11_work_character_index") { db in
            try db.createWorkCharacterIndexTables()
        }

        migrator.registerMigration("v12_tag_visual_profiles") { db in
            try db.createTagVisualProfileTables()
        }

        migrator.registerMigration("v13_tag_visual_background_assets") { db in
            try db.addTagVisualBackgroundAssetFields()
        }

        migrator.registerMigration("v14_database_performance_maintenance") { db in
            try db.addDatabasePerformanceMaintenanceIndexes()
        }

        migrator.registerMigration("v15_last_read_at") { db in
            try db.addLastReadAt()
        }

        migrator.registerMigration("v16_reading_state_and_user_hidden") { db in
            try db.addReadingStateAndUserHidden()
        }

        migrator.registerMigration("v17_interaction_performance_indexes") { db in
            try db.addInteractionPerformanceIndexes()
        }

        migrator.registerMigration("v18_search_entity_indexes") { db in
            try db.addSearchEntityIndexes()
        }

        migrator.registerMigration("v19_import_pipeline") { db in
            try db.createImportPipelineTables()
        }

        migrator.registerMigration("v20_deletion_consistency") { db in
            try db.execute(sql: """
                CREATE TABLE library_deletion_operations (
                    book_id INTEGER PRIMARY KEY, source_path TEXT NOT NULL,
                    source_identity TEXT, cover_path TEXT, stage TEXT NOT NULL,
                    last_error TEXT, updated_at INTEGER NOT NULL
                );
                ALTER TABLE import_pipeline_batches ADD COLUMN deleted_count INTEGER NOT NULL DEFAULT 0;
                """)
            try LibraryConsistency.repair(db, backfillDeletedCounts: true)
        }

        migrator.registerMigration("v21_work_character_claims") { db in
            try db.execute(sql: """
                CREATE TABLE work_character_decisions (
                    parody_tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    character_tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    decision TEXT NOT NULL CHECK (decision IN ('confirmed', 'excluded')),
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY (parody_tag_id, character_tag_id)
                );
                CREATE TABLE book_work_character_suppressions (
                    book_id INTEGER NOT NULL REFERENCES library_books(id) ON DELETE CASCADE,
                    parody_tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    character_tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (book_id, parody_tag_id, character_tag_id)
                );
                CREATE INDEX idx_work_character_decisions_character
                    ON work_character_decisions(character_tag_id, parody_tag_id);
                """)
        }

        migrator.registerMigration("v22_version_series_membership") { db in
            try SeriesMembership.repair(db)
        }

        return migrator
    }
}

private extension Database {
    func createNyaEHBookTables() throws {
        // library_books 是本地书库显示与管理状态的主表；gallery_metadata 保存外部 API 原始摘要。
        // 原始 archive 路径只记录在 filepath，文件本身仍留在用户选择的书库目录。
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS gallery_metadata (
                hash TEXT PRIMARY KEY,
                gallery_id INTEGER,
                gallery_token TEXT,
                title TEXT,
                title_jpn TEXT,
                status TEXT NOT NULL,
                rating REAL,
                tags TEXT NOT NULL DEFAULT '[]',
                pages INTEGER,
                posted INTEGER,
                filesize INTEGER,
                category TEXT,
                url TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS library_books (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                cover_path TEXT,
                hash TEXT NOT NULL,
                filepath TEXT NOT NULL UNIQUE,
                type TEXT NOT NULL,
                file_count INTEGER,
                bundle_size INTEGER,
                mtime INTEGER,
                cover_hash TEXT,
                status TEXT NOT NULL,
                date INTEGER NOT NULL,
                rating REAL,
                tags TEXT NOT NULL DEFAULT '[]',
                title_jpn TEXT,
                pages INTEGER,
                posted INTEGER,
                filesize INTEGER,
                category TEXT,
                url TEXT,
                collection_id INTEGER,
                collection_order INTEGER,
                version_group_id INTEGER,
                is_primary_version INTEGER NOT NULL DEFAULT 1,
                version_label TEXT,
                language_code TEXT NOT NULL DEFAULT 'unknown',
                is_translated INTEGER NOT NULL DEFAULT 0,
                is_full_color INTEGER NOT NULL DEFAULT 0,
                censorship TEXT NOT NULL DEFAULT 'unknown',
                has_extraneous_ads INTEGER NOT NULL DEFAULT 0,
                mark INTEGER NOT NULL DEFAULT 0,
                hidden_book INTEGER NOT NULL DEFAULT 0,
                is_user_hidden INTEGER NOT NULL DEFAULT 0,
                read_count INTEGER NOT NULL DEFAULT 0,
                last_read_at INTEGER,
                exist INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS import_jobs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_path TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """)

        try createGroupingTables()
        try createBookVersionLabelTable()
        try createBaseIndexes()
        try createGroupingIndexes()
    }

    func createImportPipelineTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS import_pipeline_batches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                status TEXT NOT NULL,
                stage TEXT NOT NULL,
                pause_reason TEXT,
                total_count INTEGER NOT NULL DEFAULT 0,
                ready_count INTEGER NOT NULL DEFAULT 0,
                deferred_count INTEGER NOT NULL DEFAULT 0,
                review_count INTEGER NOT NULL DEFAULT 0,
                failed_count INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                started_at INTEGER,
                completed_at INTEGER,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS import_pipeline_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id INTEGER,
                book_id INTEGER NOT NULL UNIQUE,
                source_hash TEXT NOT NULL,
                source_mtime INTEGER,
                stage TEXT NOT NULL,
                metadata_source TEXT,
                preferred_gallery_url TEXT,
                attempt_count INTEGER NOT NULL DEFAULT 0,
                last_error_kind TEXT,
                last_error_message TEXT,
                retry_after INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                completed_at INTEGER,
                FOREIGN KEY (batch_id) REFERENCES import_pipeline_batches(id) ON DELETE SET NULL,
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_import_pipeline_batches_status
                ON import_pipeline_batches(status, id DESC);
            CREATE INDEX IF NOT EXISTS idx_import_pipeline_items_batch_stage
                ON import_pipeline_items(batch_id, stage, id);
            CREATE INDEX IF NOT EXISTS idx_import_pipeline_items_stage
                ON import_pipeline_items(stage, updated_at DESC);
            """)
    }

    func createBaseIndexes() throws {
        // 这些索引对应首页/书库排序、same-hash 查找、最近阅读和状态筛选的热路径；
        // 新增复合索引前先确认写入成本，因为扫描和批量导入会频繁更新 library_books。
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_hash ON library_books(hash);
            CREATE INDEX IF NOT EXISTS idx_library_books_title ON library_books(title);
            CREATE INDEX IF NOT EXISTS idx_library_books_status ON library_books(status);
            CREATE INDEX IF NOT EXISTS idx_library_books_mark ON library_books(mark);
            CREATE INDEX IF NOT EXISTS idx_library_books_hidden_book ON library_books(hidden_book);
            CREATE INDEX IF NOT EXISTS idx_library_books_user_hidden ON library_books(is_user_hidden);
            CREATE INDEX IF NOT EXISTS idx_library_books_date_title
                ON library_books(date DESC, title COLLATE NOCASE ASC);
            CREATE INDEX IF NOT EXISTS idx_library_books_hash_date
                ON library_books(hash, date DESC);
            CREATE INDEX IF NOT EXISTS idx_library_books_last_read_at
                ON library_books(last_read_at DESC, title COLLATE NOCASE ASC);
            CREATE INDEX IF NOT EXISTS idx_gallery_metadata_status ON gallery_metadata(status);
            CREATE INDEX IF NOT EXISTS idx_gallery_metadata_gallery ON gallery_metadata(gallery_id, gallery_token);
            CREATE INDEX IF NOT EXISTS idx_import_jobs_status ON import_jobs(status);
            """)
    }

    func addLastReadAt() throws {
        try addColumnIfNeeded("last_read_at", sql: "ALTER TABLE library_books ADD COLUMN last_read_at INTEGER")
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_last_read_at
                ON library_books(last_read_at DESC, title COLLATE NOCASE ASC);
            """)
    }

    func addReadingStateAndUserHidden() throws {
        try addColumnIfNeeded(
            "is_user_hidden",
            sql: "ALTER TABLE library_books ADD COLUMN is_user_hidden INTEGER NOT NULL DEFAULT 0"
        )
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS book_reading_state (
                book_id INTEGER PRIMARY KEY REFERENCES library_books(id) ON DELETE CASCADE,
                current_page_index INTEGER NOT NULL DEFAULT 0 CHECK(current_page_index >= 0),
                total_pages INTEGER NOT NULL DEFAULT 0 CHECK(total_pages >= 0),
                updated_at INTEGER NOT NULL,
                completed_at INTEGER
            );

            CREATE INDEX IF NOT EXISTS idx_library_books_user_hidden
                ON library_books(is_user_hidden);
            CREATE INDEX IF NOT EXISTS idx_book_reading_state_updated
                ON book_reading_state(updated_at DESC, book_id ASC);
            CREATE INDEX IF NOT EXISTS idx_book_reading_state_completed
                ON book_reading_state(completed_at, updated_at DESC);
            """)
    }

    func addDatabasePerformanceMaintenanceIndexes() throws {
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_date_title
                ON library_books(date DESC, title COLLATE NOCASE ASC);
            CREATE INDEX IF NOT EXISTS idx_library_books_hash_date
                ON library_books(hash, date DESC);
            """)
    }

    func addInteractionPerformanceIndexes() throws {
        // Search 的默认排序使用 COALESCE(posted, date)，必须使用表达式索引才能避免
        // 在可见书籍集合上创建临时排序 B-Tree。其余索引覆盖最常用的范围与排序组合。
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_visible_posted
                ON library_books(
                    hidden_book,
                    is_user_hidden,
                    COALESCE(posted, date) DESC,
                    title COLLATE NOCASE ASC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_visible_added
                ON library_books(
                    hidden_book,
                    is_user_hidden,
                    created_at DESC,
                    title COLLATE NOCASE ASC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_visible_title
                ON library_books(
                    hidden_book,
                    is_user_hidden,
                    title COLLATE NOCASE ASC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_visible_status_posted
                ON library_books(
                    hidden_book,
                    is_user_hidden,
                    status,
                    COALESCE(posted, date) DESC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_visible_mark_posted
                ON library_books(
                    hidden_book,
                    is_user_hidden,
                    mark,
                    COALESCE(posted, date) DESC,
                    id ASC
                );
            """)
    }

    func addSearchEntityIndexes() throws {
        // Search 会先匹配系列/版本组中的成员，再按 collection > version group > book
        // 折叠为展示实体；这些索引以用户隐藏状态为首列，不再把结构隐藏混入可见性。
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_search_entity
                ON library_books(
                    is_user_hidden,
                    (CASE
                        WHEN collection_id IS NOT NULL THEN 0
                        WHEN version_group_id IS NOT NULL THEN 1
                        ELSE 2
                    END),
                    COALESCE(collection_id, version_group_id, id)
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_search_posted
                ON library_books(
                    is_user_hidden,
                    COALESCE(posted, date) DESC,
                    title COLLATE NOCASE ASC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_search_added
                ON library_books(
                    is_user_hidden,
                    created_at DESC,
                    title COLLATE NOCASE ASC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_search_title
                ON library_books(
                    is_user_hidden,
                    title COLLATE NOCASE ASC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_search_status_posted
                ON library_books(
                    is_user_hidden,
                    status,
                    COALESCE(posted, date) DESC,
                    id ASC
                );
            CREATE INDEX IF NOT EXISTS idx_library_books_search_mark_posted
                ON library_books(
                    is_user_hidden,
                    mark,
                    COALESCE(posted, date) DESC,
                    id ASC
                );
            """)
    }

    func createTagTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                namespace TEXT NOT NULL,
                name TEXT NOT NULL,
                raw_value TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS book_tags (
                book_id INTEGER NOT NULL,
                tag_id INTEGER NOT NULL,
                PRIMARY KEY (book_id, tag_id),
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE,
                FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS tag_translations (
                tag_id INTEGER NOT NULL,
                language_code TEXT NOT NULL,
                translated_name TEXT NOT NULL,
                intro TEXT,
                links TEXT NOT NULL DEFAULT '[]',
                source TEXT NOT NULL DEFAULT 'ehtagtranslation',
                source_revision TEXT,
                updated_at INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (tag_id, language_code),
                FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );
            """)
    }

    func createFollowedTagTable() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS followed_tags (
                tag_id INTEGER PRIMARY KEY,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_followed_tags_updated_at
                ON followed_tags(updated_at DESC);
            """)
    }

    func createVersionRecommendationTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS version_recommendation_batches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                completed_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS version_recommendations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id INTEGER,
                kind TEXT NOT NULL,
                target_version_group_id INTEGER,
                score INTEGER NOT NULL,
                reasons TEXT NOT NULL DEFAULT '[]',
                fingerprint TEXT NOT NULL UNIQUE,
                status TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (batch_id) REFERENCES version_recommendation_batches(id) ON DELETE SET NULL,
                FOREIGN KEY (target_version_group_id) REFERENCES book_version_groups(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS version_recommendation_members (
                recommendation_id INTEGER NOT NULL,
                book_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (recommendation_id, book_id),
                FOREIGN KEY (recommendation_id) REFERENCES version_recommendations(id) ON DELETE CASCADE,
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_version_recommendations_status_kind
                ON version_recommendations(status, kind, target_version_group_id, score DESC);

            CREATE INDEX IF NOT EXISTS idx_version_recommendation_members_book
                ON version_recommendation_members(book_id);
            """)
    }

    func createCollectionRecommendationTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS collection_recommendation_batches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                completed_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS collection_recommendations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_id INTEGER,
                kind TEXT NOT NULL,
                target_collection_id INTEGER,
                score INTEGER NOT NULL,
                reasons TEXT NOT NULL DEFAULT '[]',
                fingerprint TEXT NOT NULL UNIQUE,
                status TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (batch_id) REFERENCES collection_recommendation_batches(id) ON DELETE SET NULL,
                FOREIGN KEY (target_collection_id) REFERENCES book_collections(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS collection_recommendation_members (
                recommendation_id INTEGER NOT NULL,
                book_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY (recommendation_id, book_id),
                FOREIGN KEY (recommendation_id) REFERENCES collection_recommendations(id) ON DELETE CASCADE,
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_collection_recommendations_status_kind
                ON collection_recommendations(status, kind, target_collection_id, score DESC);

            CREATE INDEX IF NOT EXISTS idx_collection_recommendation_members_book
                ON collection_recommendation_members(book_id);
            """)
    }

    func createWorkCharacterIndexTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS book_work_character_links (
                book_id INTEGER NOT NULL,
                parody_tag_id INTEGER NOT NULL,
                character_tag_id INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (book_id, parody_tag_id, character_tag_id),
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE,
                FOREIGN KEY (parody_tag_id) REFERENCES tags(id) ON DELETE CASCADE,
                FOREIGN KEY (character_tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS work_character_index_state (
                id INTEGER PRIMARY KEY,
                last_indexed_book_updated_at INTEGER NOT NULL,
                last_full_rebuild_at INTEGER,
                updated_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_book_work_character_links_parody
                ON book_work_character_links(parody_tag_id, character_tag_id);

            CREATE INDEX IF NOT EXISTS idx_book_work_character_links_character
                ON book_work_character_links(character_tag_id, parody_tag_id);

            CREATE INDEX IF NOT EXISTS idx_book_work_character_links_book
                ON book_work_character_links(book_id);

            CREATE INDEX IF NOT EXISTS idx_library_books_updated_at
                ON library_books(updated_at);
            """)
    }

    func createTagVisualProfileTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS tag_visual_profiles (
                tag_id INTEGER PRIMARY KEY,
                foreground_asset_path TEXT,
                foreground_scale REAL NOT NULL DEFAULT 1,
                foreground_offset_x REAL NOT NULL DEFAULT 0,
                foreground_offset_y REAL NOT NULL DEFAULT 0,
                background_color_hex TEXT,
                background_color_source TEXT NOT NULL DEFAULT 'generated',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_tag_visual_profiles_updated_at
                ON tag_visual_profiles(updated_at DESC);
            """)
    }

    func addTagVisualBackgroundAssetFields() throws {
        try execute(sql: """
            ALTER TABLE tag_visual_profiles
                ADD COLUMN background_asset_path TEXT;

            ALTER TABLE tag_visual_profiles
                ADD COLUMN background_scale REAL NOT NULL DEFAULT 1;

            ALTER TABLE tag_visual_profiles
                ADD COLUMN background_offset_x REAL NOT NULL DEFAULT 0;

            ALTER TABLE tag_visual_profiles
                ADD COLUMN background_offset_y REAL NOT NULL DEFAULT 0;
            """)
    }

    func createGroupingTables() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS book_collections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS book_version_groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """)

        try createVersionLabelSuggestionTable()
        try createBookVersionLabelTable()
    }

    func createGroupingIndexes() throws {
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_collection ON library_books(collection_id, collection_order);
            CREATE INDEX IF NOT EXISTS idx_library_books_version_group ON library_books(version_group_id);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_library_books_primary_version
                ON library_books(version_group_id)
                WHERE version_group_id IS NOT NULL AND is_primary_version = 1;
            """)
    }

    func createTagIndexes() throws {
        try execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_library_books_language_code ON library_books(language_code);
            CREATE INDEX IF NOT EXISTS idx_library_books_is_translated ON library_books(is_translated);
            CREATE INDEX IF NOT EXISTS idx_library_books_is_full_color ON library_books(is_full_color);
            CREATE INDEX IF NOT EXISTS idx_library_books_censorship ON library_books(censorship);
            CREATE INDEX IF NOT EXISTS idx_library_books_has_extraneous_ads ON library_books(has_extraneous_ads);
            CREATE INDEX IF NOT EXISTS idx_tags_namespace_name ON tags(namespace, name);
            CREATE INDEX IF NOT EXISTS idx_book_tags_tag_id ON book_tags(tag_id);
            CREATE INDEX IF NOT EXISTS idx_tag_translations_source ON tag_translations(source);
            """)
    }

    func addTagIndexing() throws {
        try addColumnIfNeeded("language_code", sql: "ALTER TABLE library_books ADD COLUMN language_code TEXT NOT NULL DEFAULT 'unknown'")
        try addColumnIfNeeded("is_translated", sql: "ALTER TABLE library_books ADD COLUMN is_translated INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded("is_full_color", sql: "ALTER TABLE library_books ADD COLUMN is_full_color INTEGER NOT NULL DEFAULT 0")
        try addColumnIfNeeded("censorship", sql: "ALTER TABLE library_books ADD COLUMN censorship TEXT NOT NULL DEFAULT 'unknown'")
        try addColumnIfNeeded("has_extraneous_ads", sql: "ALTER TABLE library_books ADD COLUMN has_extraneous_ads INTEGER NOT NULL DEFAULT 0")
        try createTagTables()
        try createTagIndexes()
    }

    func addTagTranslationCacheFields() throws {
        try addColumnIfNeeded(
            "tag_translations",
            columnName: "intro",
            sql: "ALTER TABLE tag_translations ADD COLUMN intro TEXT"
        )
        try addColumnIfNeeded(
            "tag_translations",
            columnName: "links",
            sql: "ALTER TABLE tag_translations ADD COLUMN links TEXT NOT NULL DEFAULT '[]'"
        )
        try addColumnIfNeeded(
            "tag_translations",
            columnName: "source",
            sql: "ALTER TABLE tag_translations ADD COLUMN source TEXT NOT NULL DEFAULT 'ehtagtranslation'"
        )
        try addColumnIfNeeded(
            "tag_translations",
            columnName: "source_revision",
            sql: "ALTER TABLE tag_translations ADD COLUMN source_revision TEXT"
        )
        try addColumnIfNeeded(
            "tag_translations",
            columnName: "updated_at",
            sql: "ALTER TABLE tag_translations ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0"
        )
        try createTagIndexes()
    }

    func addLibraryGrouping() throws {
        try addColumnIfNeeded("collection_id", sql: "ALTER TABLE library_books ADD COLUMN collection_id INTEGER")
        try addColumnIfNeeded("collection_order", sql: "ALTER TABLE library_books ADD COLUMN collection_order INTEGER")
        try addColumnIfNeeded("version_group_id", sql: "ALTER TABLE library_books ADD COLUMN version_group_id INTEGER")
        try addColumnIfNeeded("is_primary_version", sql: "ALTER TABLE library_books ADD COLUMN is_primary_version INTEGER NOT NULL DEFAULT 1")
        try addColumnIfNeeded("version_label", sql: "ALTER TABLE library_books ADD COLUMN version_label TEXT")
        try createGroupingTables()
        try createGroupingIndexes()
    }

    func addVersionLabelSuggestions() throws {
        try createVersionLabelSuggestionTable()
        try backfillVersionLabelSuggestions()
    }

    func addBookVersionLabels() throws {
        try createBookVersionLabelTable()
        try backfillBookVersionLabels()
    }

    func createBookVersionLabelTable() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS book_version_labels (
                book_id INTEGER NOT NULL,
                label TEXT NOT NULL,
                position INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (book_id, label COLLATE NOCASE),
                FOREIGN KEY (book_id) REFERENCES library_books(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_book_version_labels_book_position
                ON book_version_labels(book_id, position);
            """)
    }

    func backfillBookVersionLabels() throws {
        let now = Timestamp.nowMilliseconds()
        try execute(
            sql: """
                INSERT OR IGNORE INTO book_version_labels (
                    book_id, label, position, created_at, updated_at
                )
                SELECT
                    id,
                    TRIM(version_label),
                    0,
                    COALESCE(created_at, ?),
                    COALESCE(updated_at, ?)
                FROM library_books
                WHERE version_label IS NOT NULL AND TRIM(version_label) <> ''
                """,
            arguments: [now, now]
        )
    }

    func createVersionLabelSuggestionTable() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS version_label_suggestions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                label TEXT NOT NULL UNIQUE COLLATE NOCASE,
                usage_count INTEGER NOT NULL DEFAULT 0,
                last_used_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_version_label_suggestions_usage
                ON version_label_suggestions(usage_count DESC, last_used_at DESC, label);
            """)
    }

    func backfillVersionLabelSuggestions() throws {
        let now = Timestamp.nowMilliseconds()
        try execute(
            sql: """
                INSERT OR IGNORE INTO version_label_suggestions (
                    label, usage_count, last_used_at, created_at, updated_at
                )
                SELECT
                    MIN(label) AS label,
                    COUNT(*) AS usage_count,
                    COALESCE(MAX(updated_at), ?) AS last_used_at,
                    COALESCE(MIN(created_at), ?) AS created_at,
                    ? AS updated_at
                FROM (
                    SELECT TRIM(version_label) AS label, created_at, updated_at
                    FROM library_books
                    WHERE version_label IS NOT NULL AND TRIM(version_label) <> ''
                )
                GROUP BY LOWER(label)
                """,
            arguments: [now, now, now]
        )
    }

    func addColumnIfNeeded(_ columnName: String, sql: String) throws {
        try addColumnIfNeeded("library_books", columnName: columnName, sql: sql)
    }

    func addColumnIfNeeded(_ tableName: String, columnName: String, sql: String) throws {
        let targetColumns = try columns(in: tableName)
        guard !targetColumns.contains(where: { $0.name == columnName }) else {
            return
        }

        try execute(sql: sql)
    }
}
