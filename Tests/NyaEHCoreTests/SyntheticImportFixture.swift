import Foundation
import GRDB

enum SyntheticImportFixture {
    static let bookA = String(repeating: "a", count: 40)
    static let bookB = String(repeating: "b", count: 40)
    static let bookC = String(repeating: "c", count: 40)
    static let duplicate = String(repeating: "d", count: 40)
    static let collectionTitle = "Fixture Series"
    static let url = "https://example.test/g/900000001/fixture-token/"

    static func make(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let common = """
            title TEXT, status TEXT, rating REAL, tags TEXT, title_jpn TEXT, filecount INTEGER,
            posted INTEGER, filesize INTEGER, category TEXT, url TEXT, mark INTEGER,
            createdAt TEXT, updatedAt TEXT
            """
        let manga = try DatabaseQueue(path: directory.appendingPathComponent("database.sqlite").path)
        try manga.write { db in
            try db.execute(sql: "CREATE TABLE Mangas (id TEXT PRIMARY KEY, hash TEXT, hiddenBook INTEGER, readCount INTEGER, \(common))")
            let hashes = [bookA, bookB, bookC, duplicate, duplicate, String(repeating: "e", count: 40)]
            for (index, hash) in hashes.enumerated() {
                try db.execute(
                    sql: "INSERT INTO Mangas (id, hash, title, status) VALUES (?, ?, ?, 'tagged')",
                    arguments: ["record-\(index)", hash, "Fixture book \(index)"]
                )
            }
        }

        let metadata = try DatabaseQueue(path: directory.appendingPathComponent("metadata.sqlite").path)
        try metadata.write { db in
            try db.execute(sql: "CREATE TABLE Metadata (hash TEXT PRIMARY KEY, \(common))")
            let tags = #"{"artist":["Fixture Artist"],"group":["Fixture Group"],"other":["Fixture Tag"]}"#
            for hash in [bookA, bookB, bookC] {
                try db.execute(
                    sql: """
                        INSERT INTO Metadata (hash, title, status, rating, tags, filecount, category, url)
                        VALUES (?, 'External Fixture', 'tagged', 4.16, ?, 28, 'Doujinshi', ?)
                        """,
                    arguments: [hash, tags, url]
                )
            }
        }

        struct Collection: Encodable {
            let id: String
            let title: String
            let list: [String]
        }
        let series = Collection(id: "fixture-series", title: collectionTitle, list: [bookB, bookC].map { "book:\($0)" })
        try JSONEncoder().encode([series]).write(to: directory.appendingPathComponent("collectionList.json"))
    }
}
