import Foundation
import SQLite3

/// Actor-isolated wrapper around the bundled bible_ios.sqlite.
/// All three versions (ASV, KJV, RVR1960) are available instantly —
/// no network required for chapter or book lookups.
actor LocalBibleLibrary {
    static let shared = LocalBibleLibrary()

    static let bundledVersions: [BibleVersionOption] = [
        BibleVersionOption(slug: "asv",     name: "American Standard Version", languageCode: "en"),
        BibleVersionOption(slug: "kjv",     name: "King James Version",        languageCode: "en"),
        BibleVersionOption(slug: "rvr1960", name: "Reina-Valera 1960",         languageCode: "es"),
    ]

    /// Fast synchronous check — safe to call from any context.
    static func isAvailable(_ slug: String) -> Bool {
        bundledVersions.contains { $0.slug == slug }
    }

    // MARK: - Private state

    private var db: OpaquePointer?

    // Caches — populated lazily, live for the app session.
    private var versionIDCache:   [String: Int32]    = [:]
    private var versionNameCache: [String: String]   = [:]
    private var bookIDCache:      [String: Int32]    = [:]  // canonical_name -> book_id
    private var booksCache:       [String: [BibleBook]] = [:]

    private init() {
        guard let url = Bundle.main.url(forResource: "bible_ios", withExtension: "sqlite") else {
            return
        }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            db = nil
        }
    }

    // MARK: - Public API

    func books(versionSlug: String) -> [BibleBook] {
        if let cached = booksCache[versionSlug] { return cached }
        guard let versionID = resolveVersionID(slug: versionSlug) else { return [] }

        let sql = """
            SELECT bb.id, bb.osis_id, bb.canonical_name, bb.testament,
                   MAX(bv.chapter) AS chapter_count
            FROM bible_verses bv
            JOIN bible_books bb ON bv.book_id = bb.id
            WHERE bv.version_id = ?
            GROUP BY bv.book_id
            ORDER BY bb.id
            """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, versionID)

        var result: [BibleBook] = []
        var index = 1
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 2),
                  let osisPtr = sqlite3_column_text(stmt, 1),
                  let testPtr = sqlite3_column_text(stmt, 3)
            else { continue }
            let bookID       = Int(sqlite3_column_int(stmt, 0))
            let name         = String(cString: namePtr)
            let osisID       = String(cString: osisPtr)
            let testament    = String(cString: testPtr)
            let chapterCount = Int(sqlite3_column_int(stmt, 4))
            result.append(BibleBook(
                bookID:       index,
                bookName:     name,
                bookOrder:    bookID,
                osisID:       osisID,
                testament:    testament,
                chapterCount: chapterCount
            ))
            index += 1
        }
        booksCache[versionSlug] = result
        return result
    }

    func chapter(versionSlug: String, book: String, chapterNumber: Int) -> ScriptureChapter? {
        guard let versionID = resolveVersionID(slug: versionSlug),
              let bookID    = resolveBookID(canonicalName: book)
        else { return nil }

        let sql = """
            SELECT verse, text
            FROM bible_verses
            WHERE version_id = ? AND book_id = ? AND chapter = ?
            ORDER BY verse
            """
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, versionID)
        sqlite3_bind_int(stmt, 2, bookID)
        sqlite3_bind_int(stmt, 3, Int32(chapterNumber))

        var verses: [ScripturePassageVerse] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let verseNum = Int(sqlite3_column_int(stmt, 0))
            let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            verses.append(ScripturePassageVerse(
                verse:     verseNum,
                text:      text,
                reference: "\(book) \(chapterNumber):\(verseNum)"
            ))
        }
        guard !verses.isEmpty else { return nil }

        let versionName = versionNameCache[versionSlug] ?? versionSlug.uppercased()
        let version = ScripturePassageVersion(slug: versionSlug, name: versionName)
        return ScriptureChapter(version: version, book: book, chapter: chapterNumber, verses: verses)
    }

    // MARK: - Private helpers

    private func resolveVersionID(slug: String) -> Int32? {
        if let cached = versionIDCache[slug] { return cached }
        guard let db else { return nil }

        var stmt: OpaquePointer?
        guard prepare("SELECT id, name FROM bible_versions WHERE slug = ? LIMIT 1", &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, slug)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let id   = sqlite3_column_int(stmt, 0)
        let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? slug.uppercased()
        versionIDCache[slug]   = id
        versionNameCache[slug] = name
        return id
    }

    private func resolveBookID(canonicalName: String) -> Int32? {
        if let cached = bookIDCache[canonicalName] { return cached }
        guard let db else { return nil }

        var stmt: OpaquePointer?
        guard prepare("SELECT id FROM bible_books WHERE canonical_name = ? LIMIT 1", &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, canonicalName)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let id = sqlite3_column_int(stmt, 0)
        bookIDCache[canonicalName] = id
        return id
    }

    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Bool {
        guard let db else { return false }
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        guard let stmt else { return }
        let bytes = Array(value.utf8CString)
        // SQLITE_TRANSIENT (-1 cast): SQLite copies the string before returning.
        let transient = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type?.self)
        sqlite3_bind_text(stmt, index, bytes, -1, transient)
    }
}
