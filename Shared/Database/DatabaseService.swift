// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

enum DatabaseError: LocalizedError {
    case appGroupNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appGroupNotFound(let identifier):
            return
                "App Group container not found for identifier: \(identifier). Check entitlements."
        }
    }
}

/// Owns a GRDB database in WAL mode (DatabasePool for disk, DatabaseQueue for in-memory).
@MainActor @Observable
final class DatabaseService {
    let writer: DatabaseWriter
    let dbPath: String

    private nonisolated static let openingQueue = DispatchQueue(
        label: "com.echo.database-opening", qos: .userInitiated)

    private nonisolated struct Connection: Sendable {
        let writer: DatabasePool
        let path: String

        init(databaseURL: URL) throws {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let path = databaseURL.path
            self.path = path
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA foreign_keys=ON")
            }
            writer = try DatabasePool(path: path, configuration: config)
            try DatabaseService.makeMigrator().migrate(writer)
            ContainerPathRepair.runIfNeeded(writer: writer)
            Logger(category: "DatabaseService").info(
                "Database opened at \(path, privacy: .private)")
        }
    }

    private init(connection: Connection) {
        writer = connection.writer
        dbPath = connection.path
    }

    convenience init(
        appGroupIdentifier: String = AppGroupDefaults.suiteName,
        appGroupFallbackDirectory: URL? = DatabaseServiceAppGroupFallback.defaultDirectory,
        allowAppGroupFallback: Bool = DatabaseServiceAppGroupFallback.isAllowed
    ) throws {
        let url = try Self.databaseURL(
            appGroupIdentifier: appGroupIdentifier,
            appGroupFallbackDirectory: appGroupFallbackDirectory,
            allowAppGroupFallback: allowAppGroupFallback)
        try self.init(databaseURL: url)
    }

    convenience init(databaseURL: URL) throws {
        try self.init(connection: Connection(databaseURL: databaseURL))
    }

    /// Opens and repairs the database without blocking the UI or a cooperative
    /// executor thread. Callers must wait for this before exposing library views.
    static func openForLaunch(databaseURL: URL? = nil) async throws -> DatabaseService {
        try Task.checkCancellation()
        let url = try databaseURL ?? Self.databaseURL()
        let connection = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Connection, Error>) in
            openingQueue.async {
                continuation.resume(with: Result { try Connection(databaseURL: url) })
            }
        }
        // Let an in-flight SQLite transaction finish safely, but do not install
        // its result into a view whose launch task has been cancelled.
        try Task.checkCancellation()
        return DatabaseService(connection: connection)
    }

    private static func databaseURL(
        appGroupIdentifier: String = AppGroupDefaults.suiteName,
        appGroupFallbackDirectory: URL? = DatabaseServiceAppGroupFallback.defaultDirectory,
        allowAppGroupFallback: Bool = DatabaseServiceAppGroupFallback.isAllowed
    ) throws -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return container.appendingPathComponent("echo.sqlite")
        }
        if DatabaseServiceAppGroupFallback.isAllowed, allowAppGroupFallback,
            let appGroupFallbackDirectory
        {
            Logger(category: "DatabaseService").warning(
                "Using debug simulator database fallback because App Group container is unavailable."
            )
            return appGroupFallbackDirectory.appendingPathComponent("echo.sqlite")
        }
        throw DatabaseError.appGroupNotFound(appGroupIdentifier)
    }

    init(inMemory: Void) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        self.writer = try DatabaseQueue(path: ":memory:", configuration: config)
        self.dbPath = ":memory:"
        try runMigrations(writer: writer)
    }

    // MARK: - Accessors

    func read<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    // `T: Sendable` because GRDB's async `read`/`write` return the value across the
    // database access pool's executor boundary; Swift 6 requires the result to be
    // Sendable for that hop. (The synchronous variants above stay on the caller.)
    func readAsync<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws
        -> T
    {
        try await writer.read(block)
    }

    func write<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    func writeAsync<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws
        -> T
    {
        try await writer.write(block)
    }

    // MARK: - Migrations

    private nonisolated func runMigrations(writer: DatabaseWriter) throws {
        try Self.makeMigrator().migrate(writer)
    }

    /// The app's migrator. Exposed so tests can run the real registration list
    /// against a hand-built database shape (e.g. one stranded mid-upgrade)
    /// without going through an initializer, which always migrates on open.
    nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration(
            "v24_feed_note_position_voice_memo",
            merging: Schema_V24.mergedMigrationIdentifiers
        ) { db, appliedIdentifiers in
            try Schema_V24.migrate(db, appliedIdentifiers: appliedIdentifiers)
        }
        migrator.registerMigration("v25_study_plans") { db in
            try Schema_V25.migrate(db)
        }
        migrator.registerMigration("v26_timeline_segment_key") { db in
            try Schema_V26.migrate(db)
        }
        migrator.registerMigration("v27_library") { db in
            try Schema_V27.migrate(db)
        }
        migrator.registerMigration("v28_pdf_block_page") { db in
            try Schema_V28.migrate(db)
        }
        migrator.registerMigration("v29_audiobook_text_origin") { db in
            try Schema_V29.migrate(db)
        }
        migrator.registerMigration("v30_narration_quality_issue") { db in
            try Schema_V30.migrate(db)
        }
        migrator.registerMigration("v31_abs_server_multi") { db in
            try Schema_V31.migrate(db)
        }
        migrator.registerMigration("v32_narration_text") { db in
            try Schema_V32.migrate(db)
        }
        migrator.registerMigration("v33_study_plan_card_pacing") { db in
            try Schema_V33.migrate(db)
        }
        migrator.registerMigration("v34_study_auto_export") { db in
            try Schema_V34.migrate(db)
        }
        migrator.registerMigration("v35_library_edition_grouping") { db in
            try Schema_V35.migrate(db)
        }
        migrator.registerMigration("v36_code_language") { db in
            try Schema_V36.migrate(db)
        }
        migrator.registerMigration("v37_article_workshop") { db in
            try Schema_V37.migrate(db)
        }
        migrator.registerMigration("v37_repair_anthology_build_attempt_receipts") { db in
            try Schema_V37.repairBuildAttemptReceipts(db)
        }
        migrator.registerMigration("v38_generated_chapter_key") { db in
            try Schema_V38.migrate(db)
        }
        migrator.registerMigration("v39_article_sync") { db in
            try Schema_V39.migrate(db)
        }
        migrator.registerMigration("v40_narration_quality_issue_origin") { db in
            try Schema_V40.migrate(db)
        }
        migrator.registerMigration("v41_repair_squashed_baseline_gap") { db in
            try Schema_V41.migrate(db)
        }
        // Block re-keying checks this foreign key for each block. The existing
        // book-first compound index otherwise forces a full anchor scan per row.
        migrator.registerMigration("v42_alignment_anchor_foreign_key_index") { db in
            try db.create(
                index: "idx_alignment_anchor_epub_block", on: "alignment_anchor",
                columns: ["epub_block_id"], ifNotExists: true)
        }
        migrator.registerMigration("v43_epub_pronunciation_annotations") { db in
            try db.alter(table: "epub_block") { table in
                table.add(column: "pronunciation_annotations", .text)
            }
        }
        return migrator
    }
}

private enum DatabaseServiceAppGroupFallback {
    #if DEBUG && targetEnvironment(simulator)
        static var isAllowed: Bool { true }
        static var defaultDirectory: URL? {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
            .appending(path: "Echo", directoryHint: .isDirectory)
            .appending(path: "DebugAppGroupFallback", directoryHint: .isDirectory)
        }
    #else
        static var isAllowed: Bool { false }
        static var defaultDirectory: URL? { nil }
    #endif
}
