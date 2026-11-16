// 本文件持久化标签视觉配置，数据库只保存相对资产路径和裁剪参数。

import Foundation
import GRDB

struct SQLiteTagVisualProfileRepository: TagVisualProfileRepository {
    let dbQueue: any DatabaseWriter

    func profiles(tagIDs: [Tag.DatabaseID]) throws -> [Tag.DatabaseID: TagVisualProfile] {
        guard !tagIDs.isEmpty else {
            return [:]
        }

        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: tagIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT tag_id, foreground_asset_path, foreground_scale,
                           foreground_offset_x, foreground_offset_y,
                           background_asset_path, background_scale,
                           background_offset_x, background_offset_y,
                           background_color_hex, background_color_source,
                           created_at, updated_at
                    FROM tag_visual_profiles
                    WHERE tag_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(tagIDs)
            )

            return Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    let profile = Self.profile(row: row)
                    return (profile.tagID, profile)
                }
            )
        }
    }

    func profile(tagID: Tag.DatabaseID) throws -> TagVisualProfile? {
        try profiles(tagIDs: [tagID])[tagID]
    }

    func upsert(_ profile: TagVisualProfile) throws -> TagVisualProfile {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    INSERT INTO tag_visual_profiles (
                        tag_id, foreground_asset_path, foreground_scale,
                        foreground_offset_x, foreground_offset_y,
                        background_asset_path, background_scale,
                        background_offset_x, background_offset_y,
                        background_color_hex, background_color_source,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(tag_id) DO UPDATE SET
                        foreground_asset_path = excluded.foreground_asset_path,
                        foreground_scale = excluded.foreground_scale,
                        foreground_offset_x = excluded.foreground_offset_x,
                        foreground_offset_y = excluded.foreground_offset_y,
                        background_asset_path = excluded.background_asset_path,
                        background_scale = excluded.background_scale,
                        background_offset_x = excluded.background_offset_x,
                        background_offset_y = excluded.background_offset_y,
                        background_color_hex = excluded.background_color_hex,
                        background_color_source = excluded.background_color_source,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    profile.tagID,
                    profile.foregroundAssetPath,
                    normalizedScale(profile.foregroundScale),
                    normalizedOffset(profile.foregroundOffsetX),
                    normalizedOffset(profile.foregroundOffsetY),
                    profile.backgroundAssetPath,
                    normalizedScale(profile.backgroundScale),
                    normalizedOffset(profile.backgroundOffsetX),
                    normalizedOffset(profile.backgroundOffsetY),
                    profile.backgroundColorHex,
                    profile.backgroundColorSource.rawValue,
                    profile.createdAt,
                    now
                ]
            )

            return try fetchProfile(db: db, tagID: profile.tagID) ?? TagVisualProfile.empty(tagID: profile.tagID)
        }
    }

    func clearForegroundAsset(tagID: Tag.DatabaseID) throws -> TagVisualProfile? {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    UPDATE tag_visual_profiles
                    SET foreground_asset_path = NULL,
                        foreground_scale = 1,
                        foreground_offset_x = 0,
                        foreground_offset_y = 0,
                        updated_at = ?
                    WHERE tag_id = ?
                    """,
                arguments: [now, tagID]
            )

            return try fetchProfile(db: db, tagID: tagID)
        }
    }

    func clearBackgroundAsset(tagID: Tag.DatabaseID) throws -> TagVisualProfile? {
        try dbQueue.write { db in
            let now = Timestamp.nowMilliseconds()
            try db.execute(
                sql: """
                    UPDATE tag_visual_profiles
                    SET background_asset_path = NULL,
                        background_scale = 1,
                        background_offset_x = 0,
                        background_offset_y = 0,
                        updated_at = ?
                    WHERE tag_id = ?
                    """,
                arguments: [now, tagID]
            )

            return try fetchProfile(db: db, tagID: tagID)
        }
    }

    private static func profile(row: Row) -> TagVisualProfile {
        TagVisualProfile(
            tagID: row["tag_id"],
            foregroundAssetPath: row["foreground_asset_path"],
            foregroundScale: row["foreground_scale"],
            foregroundOffsetX: row["foreground_offset_x"],
            foregroundOffsetY: row["foreground_offset_y"],
            backgroundAssetPath: row["background_asset_path"],
            backgroundScale: row["background_scale"],
            backgroundOffsetX: row["background_offset_x"],
            backgroundOffsetY: row["background_offset_y"],
            backgroundColorHex: row["background_color_hex"],
            backgroundColorSource: TagVisualBackgroundColorSource(rawValue: row["background_color_source"]) ?? .generated,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func fetchProfile(db: Database, tagID: Tag.DatabaseID) throws -> TagVisualProfile? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT tag_id, foreground_asset_path, foreground_scale,
                       foreground_offset_x, foreground_offset_y,
                       background_asset_path, background_scale,
                       background_offset_x, background_offset_y,
                       background_color_hex, background_color_source,
                       created_at, updated_at
                FROM tag_visual_profiles
                WHERE tag_id = ?
                """,
            arguments: [tagID]
        )
        return row.map(Self.profile(row:))
    }

    private func normalizedScale(_ scale: Double) -> Double {
        min(max(scale, 0.4), 4)
    }

    private func normalizedOffset(_ offset: Double) -> Double {
        min(max(offset, -1.5), 1.5)
    }
}
