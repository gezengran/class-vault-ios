import Foundation
import SQLCipher

public enum DatabaseError: LocalizedError, Equatable, Sendable {
    case openFailed(Int32)
    case keyRejected
    case sqlCipherUnavailable
    case databaseFailure(operation: String, code: Int32)
    case migrationFailed
    case recordNotFound
    case invalidPhone
    case invalidStudentName
    case duplicateStudentNumber
    case invalidImportedIdentifier

    public var errorDescription: String? {
        switch self {
        case .openFailed: "加密数据库无法打开。"
        case .keyRejected: "加密数据库密钥无法通过验证。"
        case .sqlCipherUnavailable: "当前数据库连接未启用 SQLCipher。"
        case .databaseFailure: "本地数据库操作失败。"
        case .migrationFailed: "本地数据库结构迁移失败。"
        case .recordNotFound: "找不到请求的本地记录。"
        case .invalidPhone: "电话号码无效或格式可疑。"
        case .invalidStudentName: "学生姓名不能为空。"
        case .duplicateStudentNumber: "该学号已经存在，未新增重复学生。"
        case .invalidImportedIdentifier: "导入的标识符不是允许的不透明标识符。"
        }
    }
}

public final class EncryptedDatabaseService: @unchecked Sendable {
    public let databaseURL: URL

    private let keyStore: DatabaseKeyStore
    private let logger: SafeLogger
    private let fileManager: FileManager
    private let lock = NSLock()
    private var database: OpaquePointer?

    public init(
        databaseURL: URL? = nil,
        keyStore: DatabaseKeyStore = KeychainDatabaseKeyStore(),
        logger: SafeLogger = .shared,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.keyStore = keyStore
        self.logger = logger

        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.databaseURL = applicationSupport
                .appendingPathComponent("TeacherWorkbench", isDirectory: true)
                .appendingPathComponent("teacher_workbench.sqlite")
        }

        try openAndMigrate()
    }

    deinit {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    public func cipherVersion() throws -> String? {
        try synchronized { try scalarTextLocked(sql: "PRAGMA cipher_version;") }
    }

    public func databaseSchemaVersion() throws -> Int {
        try synchronized { Int(try scalarIntegerLocked(sql: "PRAGMA user_version") ?? 0) }
    }

    /// Returns domain records for external export. SQL remains confined to
    /// this service; callers never need to know table names.
    public func studentDetailsForExport(filters: ExportFilters) throws -> [StudentDetails] {
        try synchronized {
            var sql = """
                SELECT student_id, class_name, name, student_number, gender,
                       id_number, primary_school_name, primary_school_class,
                       family_address, status, created_at, updated_at
                FROM student
                WHERE 1 = 1
                """
            var arguments: [SQLiteValue] = []

            if !filters.includeArchived {
                sql += " AND status = 'active'"
            }
            if let className = ValueNormalizer.optionalText(filters.className) {
                sql += " AND NULLIF(class_name, '') = ?"
                arguments.append(.text(className))
            }
            if !filters.studentIDs.isEmpty {
                let sortedIDs = filters.studentIDs.sorted()
                sql += " AND student_id IN (\(sortedIDs.map { _ in "?" }.joined(separator: ",")))"
                arguments.append(contentsOf: sortedIDs.map { .text($0) })
            }
            sql += " ORDER BY name COLLATE NOCASE, student_id"

            return try queryLocked(sql: sql, arguments: arguments).compactMap { row in
                guard let student = decodeStudent(row) else { return nil }
                let contacts = try fetchContactsLocked(
                    studentID: student.id,
                    includeArchived: filters.includeArchived
                )
                return StudentDetails(
                    id: student.id,
                    name: student.name,
                    className: student.className,
                    studentNumber: student.studentNumber,
                    gender: student.gender,
                    idNumber: student.idNumber,
                    primarySchoolName: student.primarySchoolName,
                    primarySchoolClass: student.primarySchoolClass,
                    familyAddress: student.familyAddress,
                    contacts: contacts.map(toPublicContact)
                )
            }
        }
    }

    /// Creates a logically consistent SQLCipher snapshot encrypted with the
    /// supplied key. The portability layer supplies a password-derived key
    /// for backups and the device key when re-keying a restored database.
    public func createEncryptedSnapshot(to destinationURL: URL, encryptionKey: Data) throws {
        guard encryptionKey.count == 32 else { throw DatabaseError.keyRejected }
        try synchronized {
            let directory = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            var isAttached = false
            do {
                try executeLocked(
                    // Bind the raw key as a BLOB. Passing x'...' as a bound
                    // string would make the literal characters part of the
                    // key instead of using the supplied 32 bytes.
                    sql: "ATTACH DATABASE ? AS portability_backup KEY ?",
                    arguments: [.text(destinationURL.path), .blob(encryptionKey)]
                )
                isAttached = true
                _ = try queryLocked(sql: "SELECT sqlcipher_export('portability_backup')")
                try executeLocked(sql: "DETACH DATABASE portability_backup")
                isAttached = false
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: destinationURL.path
                )
            } catch {
                if isAttached { try? executeLocked(sql: "DETACH DATABASE portability_backup") }
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    /// Returns a safety-copy URL after replacing the live database. The
    /// incoming snapshot must already be encrypted with the device key.
    @discardableResult
    public func replaceDatabase(with snapshotURL: URL) throws -> URL {
        try synchronized {
            guard fileManager.fileExists(atPath: snapshotURL.path) else {
                throw DatabaseError.databaseFailure(operation: "restore_missing_snapshot", code: SQLITE_NOTFOUND)
            }

            let safetyCopyURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("teacher_workbench.pre-restore-\(UUID().uuidString).sqlite")
            closeLocked()

            do {
                try fileManager.copyItem(at: databaseURL, to: safetyCopyURL)
                do {
                    try fileManager.removeItem(at: databaseURL)
                    try fileManager.moveItem(at: snapshotURL, to: databaseURL)
                } catch {
                    if !fileManager.fileExists(atPath: databaseURL.path) {
                        try? fileManager.moveItem(at: safetyCopyURL, to: databaseURL)
                    }
                    throw error
                }
                do {
                    try openAndMigrateLocked()
                } catch {
                    try? fileManager.removeItem(at: databaseURL)
                    try? fileManager.moveItem(at: safetyCopyURL, to: databaseURL)
                    try? openAndMigrateLocked()
                    throw error
                }
                return safetyCopyURL
            } catch {
                if database == nil {
                    try? openAndMigrateLocked()
                }
                throw error
            }
        }
    }

    func currentKeyForPortability() throws -> Data {
        try keyStore.loadOrCreateKey()
    }

    func portabilityRecordCounts() throws -> (students: Int, contacts: Int) {
        try synchronized {
            (
                Int(try scalarIntegerLocked(sql: "SELECT COUNT(*) FROM student") ?? 0),
                Int(try scalarIntegerLocked(sql: "SELECT COUNT(*) FROM parent_contact") ?? 0)
            )
        }
    }

    public func listStudents(search: String?, className: String?) throws -> [StudentSummary] {
        try synchronized {
            var sql = """
                SELECT student_id, name,
                       NULLIF(class_name, '') AS display_class,
                       student_number, gender
                FROM student
                WHERE status = 'active'
                """
            var arguments: [SQLiteValue] = []

            if let className = ValueNormalizer.optionalText(className) {
                sql += " AND NULLIF(class_name, '') = ?"
                arguments.append(.text(className))
            }
            if let search = ValueNormalizer.optionalText(search) {
                let pattern = "%\(Self.escapeLike(search))%"
                sql += " AND (name LIKE ? ESCAPE '\\' OR COALESCE(student_number, '') LIKE ? ESCAPE '\\')"
                arguments.append(.text(pattern))
                arguments.append(.text(pattern))
            }
            sql += " ORDER BY name COLLATE NOCASE, student_number COLLATE NOCASE"

            return try queryLocked(sql: sql, arguments: arguments).compactMap { row in
                guard let id = text(row, "student_id"), let name = text(row, "name") else { return nil }
                return StudentSummary(
                    id: id,
                    name: name,
                    className: text(row, "display_class"),
                    studentNumber: text(row, "student_number"),
                    gender: text(row, "gender")
                )
            }
        }
    }

    public func availableClassNames() throws -> [String] {
        try synchronized {
            try queryLocked(
                sql: """
                    SELECT DISTINCT NULLIF(class_name, '') AS display_class
                    FROM student
                    WHERE status = 'active'
                      AND NULLIF(class_name, '') IS NOT NULL
                    ORDER BY display_class COLLATE NOCASE
                    """
            ).compactMap { text($0, "display_class") }
        }
    }

    public func getStudentDetails(studentID: String) throws -> StudentDetails {
        try synchronized {
            guard let row = try fetchStudentLocked(studentID: studentID),
                  let student = decodeStudent(row),
                  student.status == "active" else {
                throw DatabaseError.recordNotFound
            }
            let contacts = try fetchContactsLocked(studentID: studentID)
            guard let id = text(row, "student_id"), let name = text(row, "name") else {
                throw DatabaseError.databaseFailure(operation: "decode_student", code: SQLITE_CORRUPT)
            }
            return StudentDetails(
                id: id,
                name: name,
                className: text(row, "class_name"),
                studentNumber: text(row, "student_number"),
                gender: text(row, "gender"),
                idNumber: text(row, "id_number"),
                primarySchoolName: text(row, "primary_school_name"),
                primarySchoolClass: text(row, "primary_school_class"),
                familyAddress: text(row, "family_address"),
                contacts: contacts.map(toPublicContact)
            )
        }
    }

    public func addStudent(draft: StudentDraft) throws -> StudentSummary {
        try synchronized {
            try transactionLocked {
                guard let name = ValueNormalizer.optionalText(draft.name) else {
                    throw DatabaseError.invalidStudentName
                }

                let studentNumber = ValueNormalizer.optionalText(draft.studentNumber)
                if let studentNumber {
                    let matches = try fetchStudentRecordsLocked(studentNumber: studentNumber)
                    if !matches.isEmpty {
                        throw DatabaseError.duplicateStudentNumber
                    }
                }

                let now = Self.timestamp()
                let record = StoredStudentRecord(
                    id: Self.opaqueIdentifier(prefix: "stu_"),
                    className: ValueNormalizer.optionalText(draft.className),
                    name: name,
                    studentNumber: studentNumber,
                    gender: ValueNormalizer.optionalText(draft.gender),
                    idNumber: ValueNormalizer.optionalText(draft.idNumber),
                    primarySchoolName: ValueNormalizer.optionalText(draft.primarySchoolName),
                    primarySchoolClass: ValueNormalizer.optionalText(draft.primarySchoolClass),
                    familyAddress: ValueNormalizer.optionalText(draft.familyAddress),
                    status: "active",
                    createdAt: now,
                    updatedAt: now
                )
                try insertStudentLocked(record)
                try recordStudentChangeLocked(before: nil, after: record, operation: "insert", importID: nil)
                return StudentSummary(
                    id: record.id,
                    name: record.name,
                    className: record.className,
                    studentNumber: record.studentNumber,
                    gender: record.gender
                )
            }
        }
    }

    /// Archives a student and its active contacts in one transaction. The
    /// records remain in the encrypted database and change history, but are
    /// no longer shown in the active student list.
    public func archiveStudent(studentID: String) throws {
        try synchronized {
            try transactionLocked {
                guard let row = try fetchStudentLocked(studentID: studentID),
                      let existing = decodeStudent(row),
                      existing.status == "active" else {
                    throw DatabaseError.recordNotFound
                }

                let archivedStudent = StoredStudentRecord(
                    id: existing.id,
                    className: existing.className,
                    name: existing.name,
                    studentNumber: existing.studentNumber,
                    gender: existing.gender,
                    idNumber: existing.idNumber,
                    primarySchoolName: existing.primarySchoolName,
                    primarySchoolClass: existing.primarySchoolClass,
                    familyAddress: existing.familyAddress,
                    status: "archived",
                    createdAt: existing.createdAt,
                    updatedAt: Self.timestamp()
                )
                try updateStudentLocked(archivedStudent)
                try recordStudentChangeLocked(
                    before: existing,
                    after: archivedStudent,
                    operation: "archive",
                    importID: nil
                )

                for contact in try fetchContactsLocked(studentID: studentID) {
                    let archivedContact = StoredContactRecord(
                        id: contact.id,
                        studentID: contact.studentID,
                        name: contact.name,
                        relation: contact.relation,
                        phone: contact.phone,
                        contactRole: contact.contactRole,
                        contactOrder: contact.contactOrder,
                        sourceColumn: contact.sourceColumn,
                        isPrimary: contact.isPrimary,
                        status: "archived",
                        createdAt: contact.createdAt,
                        updatedAt: Self.timestamp()
                    )
                    try updateContactLocked(archivedContact)
                    try recordContactChangeLocked(
                        before: contact,
                        after: archivedContact,
                        operation: "archive",
                        importID: nil
                    )
                }
            }
        }
    }

    public func applyImport(_ request: DatabaseImportRequest) throws -> ImportResult {
        try synchronized {
            try transactionLocked {
                let importID = Self.opaqueIdentifier(prefix: "imp_")
                var insertedCount = 0
                var updatedCount = 0
                var rejectedCount = request.rejectedRowCount
                var reviewedRows: [Int] = []

                for row in request.rows {
                    switch try findMatchingStudentLocked(candidate: row.student) {
                    case .review:
                        reviewedRows.append(row.rowNumber)
                        rejectedCount += 1
                        continue
                    case .new(let forcedID):
                        let record = try makeNewStudentRecord(candidate: row.student, forcedID: forcedID)
                        try insertStudentLocked(record)
                        try recordStudentChangeLocked(before: nil, after: record, operation: "insert", importID: importID)
                        insertedCount += 1
                        try importContactsLocked(row.contacts, studentID: record.id, importID: importID)
                    case .existing(let existing):
                        let merged = merge(existing: existing, candidate: row.student)
                        try updateStudentLocked(merged)
                        try recordStudentChangeLocked(before: existing, after: merged, operation: "update", importID: importID)
                        updatedCount += 1
                        try importContactsLocked(row.contacts, studentID: existing.id, importID: importID)
                    }
                }

                try insertImportBatchLocked(
                    importID: importID,
                    sourceFilename: request.sourceFilename,
                    sourceHash: request.sourceHash,
                    insertedCount: insertedCount,
                    updatedCount: updatedCount,
                    rejectedCount: rejectedCount
                )
                logger.record(
                    operation: "import_commit",
                    rowCount: request.rows.count,
                    insertedCount: insertedCount,
                    updatedCount: updatedCount,
                    rejectedCount: rejectedCount,
                    importID: importID,
                    sourceHash: request.sourceHash
                )
                return ImportResult(
                    importID: importID,
                    sourceFilename: request.sourceFilename,
                    sourceHash: request.sourceHash,
                    insertedCount: insertedCount,
                    updatedCount: updatedCount,
                    rejectedCount: rejectedCount,
                    reviewedRowNumbers: reviewedRows.sorted()
                )
            }
        }
    }

    /// Read-only preflight for conflicts that depend on the existing local
    /// database. No data is changed by this method.
    public func preflightImport(_ rows: [NormalizedImportRow]) throws -> [ImportIssue] {
        synchronized {
            var issues: [ImportIssue] = []
            for row in rows {
                do {
                    let match = try findMatchingStudentLocked(candidate: row.student)
                    switch match {
                    case .review:
                        issues.append(ImportIssue(rowNumber: row.rowNumber, code: "database_match_review", message: "现有学生记录使这一行无法唯一匹配，需要人工复核。"))
                    case .existing(let existing):
                        issues.append(contentsOf: try preflightContactIssuesLocked(
                            row.contacts,
                            rowNumber: row.rowNumber,
                            existingStudentID: existing.id
                        ))
                    case .new(_):
                        issues.append(contentsOf: try preflightContactIssuesLocked(
                            row.contacts,
                            rowNumber: row.rowNumber,
                            existingStudentID: nil
                        ))
                    }
                } catch {
                    issues.append(ImportIssue(rowNumber: row.rowNumber, code: "database_match_error", message: "无法使用本地数据库检查这一行。"))
                }
            }
            return issues
        }
    }

    public func addParentContact(studentID: String, draft: ParentContactDraft) throws -> ParentContact {
        try synchronized {
            try transactionLocked {
                guard let studentRow = try fetchStudentLocked(studentID: studentID),
                      let student = decodeStudent(studentRow),
                      student.status == "active" else {
                    throw DatabaseError.recordNotFound
                }
                let normalized = try normalizedDraft(draft)
                let now = Self.timestamp()
                let record = StoredContactRecord(
                    id: Self.opaqueIdentifier(prefix: "par_"),
                    studentID: studentID,
                    name: normalized.name,
                    relation: normalized.relation,
                    phone: normalized.phone,
                    contactRole: normalized.contactRole,
                    contactOrder: nil,
                    sourceColumn: nil,
                    isPrimary: normalized.isPrimary,
                    status: "active",
                    createdAt: now,
                    updatedAt: now
                )
                try insertContactLocked(record)
                try recordContactChangeLocked(before: nil, after: record, operation: "insert", importID: nil)
                return toPublicContact(record)
            }
        }
    }

    public func updateParentContact(contactID: String, draft: ParentContactDraft) throws -> ParentContact {
        try synchronized {
            try transactionLocked {
                guard let existing = try fetchContactLocked(contactID: contactID, includeArchived: false) else {
                    throw DatabaseError.recordNotFound
                }
                let normalized = try normalizedDraft(draft)
                let updated = StoredContactRecord(
                    id: existing.id,
                    studentID: existing.studentID,
                    name: normalized.name,
                    relation: normalized.relation,
                    phone: normalized.phone,
                    contactRole: normalized.contactRole,
                    contactOrder: existing.contactOrder,
                    sourceColumn: existing.sourceColumn,
                    isPrimary: normalized.isPrimary,
                    status: existing.status,
                    createdAt: existing.createdAt,
                    updatedAt: Self.timestamp()
                )
                try updateContactLocked(updated)
                try recordContactChangeLocked(before: existing, after: updated, operation: "update", importID: nil)
                return toPublicContact(updated)
            }
        }
    }

    public func archiveParentContact(contactID: String) throws {
        try synchronized {
            try transactionLocked {
                guard let existing = try fetchContactLocked(contactID: contactID, includeArchived: false) else {
                    throw DatabaseError.recordNotFound
                }
                let archived = StoredContactRecord(
                    id: existing.id,
                    studentID: existing.studentID,
                    name: existing.name,
                    relation: existing.relation,
                    phone: existing.phone,
                    contactRole: existing.contactRole,
                    contactOrder: existing.contactOrder,
                    sourceColumn: existing.sourceColumn,
                    isPrimary: existing.isPrimary,
                    status: "archived",
                    createdAt: existing.createdAt,
                    updatedAt: Self.timestamp()
                )
                try updateContactLocked(archived)
                try recordContactChangeLocked(before: existing, after: archived, operation: "archive", importID: nil)
            }
        }
    }

    public func tableNames() throws -> [String] {
        try synchronized {
            try queryLocked(
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            ).compactMap { text($0, "name") }
        }
    }

    public func changeEventCount() throws -> Int {
        try synchronized { Int(try scalarIntegerLocked(sql: "SELECT COUNT(*) FROM change_event") ?? 0) }
    }

    public func studentCount() throws -> Int {
        try synchronized { Int(try scalarIntegerLocked(sql: "SELECT COUNT(*) FROM student WHERE status = 'active'") ?? 0) }
    }

    public func activeContactCount(studentID: String) throws -> Int {
        try synchronized {
            Int(try scalarIntegerLocked(
                sql: "SELECT COUNT(*) FROM parent_contact WHERE student_id = ? AND status = 'active'",
                arguments: [.text(studentID)]
            ) ?? 0)
        }
    }

    #if DEBUG
    public func seedSyntheticData() throws {
        try synchronized {
            try transactionLocked {
                let student = StoredStudentRecord(
                    id: "stu_ui_demo",
                    className: "八年级1班",
                    name: "Synthetic Student",
                    studentNumber: "SYNTH-001",
                    gender: nil,
                    idNumber: nil,
                    primarySchoolName: nil,
                    primarySchoolClass: nil,
                    familyAddress: nil,
                    status: "active",
                    createdAt: Self.timestamp(),
                    updatedAt: Self.timestamp()
                )
                if try fetchStudentLocked(studentID: student.id) == nil {
                    try insertStudentLocked(student)
                }
                let contact = StoredContactRecord(
                    id: "par_ui_demo",
                    studentID: student.id,
                    name: "Synthetic Parent",
                    relation: "家长",
                    phone: "13800000000",
                    contactRole: ContactRole.parent.rawValue,
                    contactOrder: nil,
                    sourceColumn: nil,
                    isPrimary: true,
                    status: "active",
                    createdAt: Self.timestamp(),
                    updatedAt: Self.timestamp()
                )
                if try fetchContactLocked(contactID: contact.id, includeArchived: true) == nil {
                    try insertContactLocked(contact)
                }
            }
        }
    }
    #endif
}

private extension EncryptedDatabaseService {
    enum SQLiteValue {
        case null
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
    }

    struct StoredStudentRecord: Codable, Equatable {
        let id: String
        let className: String?
        let name: String
        let studentNumber: String?
        let gender: String?
        let idNumber: String?
        let primarySchoolName: String?
        let primarySchoolClass: String?
        let familyAddress: String?
        let status: String
        let createdAt: String
        let updatedAt: String
    }

    struct StoredContactRecord: Codable, Equatable {
        let id: String
        let studentID: String
        let name: String?
        let relation: String?
        let phone: String?
        let contactRole: String
        let contactOrder: Int?
        let sourceColumn: String?
        let isPrimary: Bool
        let status: String
        let createdAt: String
        let updatedAt: String
    }

    enum StudentMatch {
        case new(forcedID: String?)
        case existing(StoredStudentRecord)
        case review
    }

    enum ContactMatch {
        case none
        case existing(StoredContactRecord)
        case review
    }

    struct NormalizedDraft {
        let name: String?
        let relation: String?
        let phone: String?
        let contactRole: String
        let isPrimary: Bool
    }

    enum SQL {
        static let migrationOne: [String] = [
            """
            CREATE TABLE IF NOT EXISTS student (
                student_id TEXT PRIMARY KEY,
                class_name TEXT,
                name TEXT NOT NULL,
                student_number TEXT,
                gender TEXT,
                id_number TEXT,
                primary_school_name TEXT,
                primary_school_class TEXT,
                family_address TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS parent_contact (
                parent_id TEXT PRIMARY KEY,
                student_id TEXT NOT NULL,
                parent_name TEXT,
                relation TEXT,
                phone TEXT,
                contact_role TEXT NOT NULL DEFAULT 'unknown',
                contact_order INTEGER,
                source_column TEXT,
                is_primary INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'active',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                FOREIGN KEY(student_id) REFERENCES student(student_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS import_batch (
                import_id TEXT PRIMARY KEY,
                source_filename TEXT,
                source_hash TEXT NOT NULL,
                imported_at TEXT NOT NULL,
                inserted_count INTEGER NOT NULL,
                updated_count INTEGER NOT NULL,
                rejected_count INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS change_event (
                event_id TEXT PRIMARY KEY,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                before_json TEXT,
                after_json TEXT,
                import_id TEXT,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_student_number ON student(student_number)",
            "CREATE INDEX IF NOT EXISTS idx_student_name_class ON student(name, class_name, primary_school_class)",
            "CREATE INDEX IF NOT EXISTS idx_parent_contact_student ON parent_contact(student_id, status)",
            "CREATE INDEX IF NOT EXISTS idx_parent_contact_phone ON parent_contact(student_id, phone)",
            "CREATE INDEX IF NOT EXISTS idx_parent_contact_source ON parent_contact(student_id, source_column, contact_order)"
        ]
    }

    func openAndMigrate() throws {
        try synchronized { try openAndMigrateLocked() }
    }

    func openAndMigrateLocked() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        var handle: OpaquePointer?
        let openCode = databaseURL.path.withCString { path in
            sqlite3_open_v2(
                path,
                &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard openCode == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.openFailed(openCode)
        }
        database = handle

        do {
            let key = try keyStore.loadOrCreateKey()
            let keyCode = key.withUnsafeBytes { bytes in
                sqlite3_key(handle, bytes.baseAddress, Int32(key.count))
            }
            guard keyCode == SQLITE_OK else { throw DatabaseError.keyRejected }

            try executeLocked(sql: "PRAGMA foreign_keys = ON;")
            try executeLocked(sql: "PRAGMA cipher_memory_security = ON;")
            guard try scalarTextLocked(sql: "PRAGMA cipher_version;") != nil else {
                throw DatabaseError.sqlCipherUnavailable
            }
            _ = try scalarIntegerLocked(sql: "SELECT COUNT(*) FROM sqlite_master")
            try migrateLocked()
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: databaseURL.path
            )
            excludeFromAutomaticBackup(at: directory)
            excludeFromAutomaticBackup(at: databaseURL)
        } catch {
            closeLocked()
            throw error
        }
    }

    func excludeFromAutomaticBackup(at url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var securedURL = url
        try? securedURL.setResourceValues(values)
    }

    func migrateLocked() throws {
        let currentVersion = Int(try scalarIntegerLocked(sql: "PRAGMA user_version") ?? 0)
        guard currentVersion <= 1 else {
            throw DatabaseError.migrationFailed
        }
        guard currentVersion < 1 else { return }

        do {
            try executeLocked(sql: "BEGIN IMMEDIATE")
            for statement in SQL.migrationOne {
                try executeLocked(sql: statement)
            }
            try executeLocked(sql: "PRAGMA user_version = 1")
            try executeLocked(sql: "COMMIT")
        } catch {
            try? executeLocked(sql: "ROLLBACK")
            throw DatabaseError.migrationFailed
        }
    }

    func closeLocked() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func transactionLocked<T>(_ body: () throws -> T) throws -> T {
        try executeLocked(sql: "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try executeLocked(sql: "COMMIT")
            return result
        } catch {
            try? executeLocked(sql: "ROLLBACK")
            throw error
        }
    }

    func executeLocked(sql: String, arguments: [SQLiteValue] = []) throws {
        let statement = try prepareLocked(sql: sql, arguments: arguments)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw DatabaseError.databaseFailure(operation: "execute", code: code)
        }
    }

    func queryLocked(sql: String, arguments: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        let statement = try prepareLocked(sql: sql, arguments: arguments)
        defer { sqlite3_finalize(statement) }

        let columnCount = sqlite3_column_count(statement)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw DatabaseError.databaseFailure(operation: "query", code: code)
            }
            var row: [String: SQLiteValue] = [:]
            for index in 0..<columnCount {
                let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index)"
                row[name] = columnValue(statement: statement, index: index)
            }
            rows.append(row)
        }
        return rows
    }

    func prepareLocked(sql: String, arguments: [SQLiteValue]) throws -> OpaquePointer {
        guard let database else {
            throw DatabaseError.databaseFailure(operation: "prepare_without_database", code: SQLITE_MISUSE)
        }
        var statement: OpaquePointer?
        let prepareCode = sql.withCString { sqlPointer in
            sqlite3_prepare_v2(database, sqlPointer, -1, &statement, nil)
        }
        guard prepareCode == SQLITE_OK, let statement else {
            throw DatabaseError.databaseFailure(operation: "prepare", code: prepareCode)
        }
        do {
            for (offset, argument) in arguments.enumerated() {
                let code = try bind(argument, to: Int32(offset + 1), in: statement)
                guard code == SQLITE_OK else {
                    throw DatabaseError.databaseFailure(operation: "bind", code: code)
                }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    func bind(_ value: SQLiteValue, to index: Int32, in statement: OpaquePointer) throws -> Int32 {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null:
            return sqlite3_bind_null(statement, index)
        case .text(let value):
            return value.withCString { pointer in
                sqlite3_bind_text(statement, index, pointer, -1, transient)
            }
        case .integer(let value):
            return sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            return sqlite3_bind_double(statement, index, value)
        case .blob(let value):
            return value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), transient)
            }
        }
    }

    func columnValue(statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: byteCount), as: UTF8.self))
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_blob(statement, index), byteCount > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: byteCount))
        default:
            return .null
        }
    }

    func scalarTextLocked(sql: String, arguments: [SQLiteValue] = []) throws -> String? {
        guard let row = try queryLocked(sql: sql, arguments: arguments).first else { return nil }
        return row.values.first.flatMap { value in
            if case .text(let text) = value { return text }
            return nil
        }
    }

    func scalarIntegerLocked(sql: String, arguments: [SQLiteValue] = []) throws -> Int64? {
        guard let row = try queryLocked(sql: sql, arguments: arguments).first else { return nil }
        return row.values.first.flatMap { value in
            if case .integer(let integer) = value { return integer }
            if case .text(let text) = value { return Int64(text) }
            return nil
        }
    }

    func text(_ row: [String: SQLiteValue], _ key: String) -> String? {
        guard let value = row[key] else { return nil }
        if case .text(let text) = value { return text }
        return nil
    }

    func integer(_ row: [String: SQLiteValue], _ key: String) -> Int64? {
        guard let value = row[key] else { return nil }
        if case .integer(let integer) = value { return integer }
        if case .text(let text) = value { return Int64(text) }
        return nil
    }

    func bool(_ row: [String: SQLiteValue], _ key: String) -> Bool {
        (integer(row, key) ?? 0) != 0
    }

    func fetchStudentLocked(studentID: String) throws -> [String: SQLiteValue]? {
        try queryLocked(
            sql: "SELECT student_id, class_name, name, student_number, gender, id_number, primary_school_name, primary_school_class, family_address, status, created_at, updated_at FROM student WHERE student_id = ? LIMIT 1",
            arguments: [.text(studentID)]
        ).first
    }

    func fetchStudentRecordsLocked(studentNumber: String) throws -> [StoredStudentRecord] {
        try queryLocked(
            sql: "SELECT student_id, class_name, name, student_number, gender, id_number, primary_school_name, primary_school_class, family_address, status, created_at, updated_at FROM student WHERE student_number = ? AND status = 'active'",
            arguments: [.text(studentNumber)]
        ).compactMap(decodeStudent)
    }

    func fetchStudentRecordsLocked(name: String, classValue: String, useCurrentClass: Bool) throws -> [StoredStudentRecord] {
        let classColumn = useCurrentClass ? "class_name" : "primary_school_class"
        return try queryLocked(
            sql: "SELECT student_id, class_name, name, student_number, gender, id_number, primary_school_name, primary_school_class, family_address, status, created_at, updated_at FROM student WHERE name = ? COLLATE NOCASE AND \(classColumn) = ? COLLATE NOCASE AND status = 'active'",
            arguments: [.text(name), .text(classValue)]
        ).compactMap(decodeStudent)
    }

    func decodeStudent(_ row: [String: SQLiteValue]) -> StoredStudentRecord? {
        guard let id = text(row, "student_id"), let name = text(row, "name"),
              let status = text(row, "status"), let createdAt = text(row, "created_at"),
              let updatedAt = text(row, "updated_at") else { return nil }
        return StoredStudentRecord(
            id: id,
            className: text(row, "class_name"),
            name: name,
            studentNumber: text(row, "student_number"),
            gender: text(row, "gender"),
            idNumber: text(row, "id_number"),
            primarySchoolName: text(row, "primary_school_name"),
            primarySchoolClass: text(row, "primary_school_class"),
            familyAddress: text(row, "family_address"),
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func fetchContactsLocked(studentID: String, includeArchived: Bool = false) throws -> [StoredContactRecord] {
        let statusClause = includeArchived ? "" : " AND status = 'active'"
        return try queryLocked(
            sql: "SELECT parent_id, student_id, parent_name, relation, phone, contact_role, contact_order, source_column, is_primary, status, created_at, updated_at FROM parent_contact WHERE student_id = ?\(statusClause) ORDER BY is_primary DESC, CASE WHEN contact_order IS NULL THEN 999999 ELSE contact_order END, created_at",
            arguments: [.text(studentID)]
        ).compactMap(decodeContact)
    }

    func fetchContactLocked(contactID: String, includeArchived: Bool) throws -> StoredContactRecord? {
        let suffix = includeArchived ? "" : " AND status = 'active'"
        return try queryLocked(
            sql: "SELECT parent_id, student_id, parent_name, relation, phone, contact_role, contact_order, source_column, is_primary, status, created_at, updated_at FROM parent_contact WHERE parent_id = ?\(suffix) LIMIT 1",
            arguments: [.text(contactID)]
        ).compactMap(decodeContact).first
    }

    func matchImportedContactLocked(studentID: String, candidate: ImportedContactCandidate) throws -> ContactMatch {
        if let parentID = ValueNormalizer.optionalText(candidate.parentID),
           let safeParentID = safeImportedParentID(parentID),
           let contact = try fetchContactLocked(contactID: safeParentID, includeArchived: true) {
            guard contact.status == "active", contact.studentID == studentID else { return .review }
            return .existing(contact)
        }

        let phoneMatches = try queryLocked(
            sql: "SELECT parent_id, student_id, parent_name, relation, phone, contact_role, contact_order, source_column, is_primary, status, created_at, updated_at FROM parent_contact WHERE student_id = ? AND phone = ? AND status = 'active'",
            arguments: [.text(studentID), .text(candidate.phone)]
        ).compactMap(decodeContact)
        if phoneMatches.count > 1 { return .review }
        if let contact = phoneMatches.first {
            return .existing(contact)
        }

        if let sourceColumn = candidate.sourceColumn, let order = candidate.contactOrder {
            let sourceMatches = try queryLocked(
                sql: "SELECT parent_id, student_id, parent_name, relation, phone, contact_role, contact_order, source_column, is_primary, status, created_at, updated_at FROM parent_contact WHERE student_id = ? AND source_column = ? AND contact_order = ? AND status = 'active'",
                arguments: [.text(studentID), .text(sourceColumn), .integer(Int64(order))]
            ).compactMap(decodeContact)
            if sourceMatches.count > 1 { return .review }
            if let contact = sourceMatches.first {
                return .existing(contact)
            }
        }
        return .none
    }

    func decodeContact(_ row: [String: SQLiteValue]) -> StoredContactRecord? {
        guard let id = text(row, "parent_id"), let studentID = text(row, "student_id"),
              let role = text(row, "contact_role"), let status = text(row, "status"),
              let createdAt = text(row, "created_at"), let updatedAt = text(row, "updated_at") else { return nil }
        return StoredContactRecord(
            id: id,
            studentID: studentID,
            name: text(row, "parent_name"),
            relation: text(row, "relation"),
            phone: text(row, "phone"),
            contactRole: role,
            contactOrder: integer(row, "contact_order").map(Int.init),
            sourceColumn: text(row, "source_column"),
            isPrimary: bool(row, "is_primary"),
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func findMatchingStudentLocked(candidate: ImportedStudentCandidate) throws -> StudentMatch {
        var canCreateUsingStudentNumber = false
        if let studentNumber = candidate.studentNumber {
            let matches = try fetchStudentRecordsLocked(studentNumber: studentNumber)
            if matches.count > 1 { return .review }
            if let existing = matches.first {
                guard ValueNormalizer.normalizedMatchValue(existing.name) == ValueNormalizer.normalizedMatchValue(candidate.name) else {
                    return .review
                }
                return .existing(existing)
            }
            canCreateUsingStudentNumber = true
        }

        let importedID = ValueNormalizer.optionalText(candidate.studentID)
        let safeImportedID = importedID.flatMap(safeImportedStudentID)
        if let importedID, let importedRow = try fetchStudentLocked(studentID: importedID),
           let existing = decodeStudent(importedRow) {
            return existing.status == "active" ? .existing(existing) : .review
        }

        if canCreateUsingStudentNumber {
            return .new(forcedID: safeImportedID)
        }

        if let safeImportedID {
            return .new(forcedID: safeImportedID)
        }

        if let classValue = candidate.className ?? candidate.primarySchoolClass {
            let useCurrentClass = candidate.className != nil
            let matches = try fetchStudentRecordsLocked(name: candidate.name, classValue: classValue, useCurrentClass: useCurrentClass)
            if matches.count > 1 { return .review }
            if let existing = matches.first { return .existing(existing) }
            return .new(forcedID: safeImportedStudentID(candidate.studentID))
        }

        return .review
    }

    func safeImportedStudentID(_ value: String?) -> String? {
        guard let value = ValueNormalizer.optionalText(value), value.hasPrefix("stu_"), value.count > 4, value.count <= 128 else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar == "_" || scalar == "-" || (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        }) else { return nil }
        return value
    }

    func makeNewStudentRecord(candidate: ImportedStudentCandidate, forcedID: String?) throws -> StoredStudentRecord {
        let id = forcedID ?? Self.opaqueIdentifier(prefix: "stu_")
        if id.isEmpty { throw DatabaseError.invalidImportedIdentifier }
        let now = Self.timestamp()
        return StoredStudentRecord(
            id: id,
            className: candidate.className,
            name: candidate.name,
            studentNumber: candidate.studentNumber,
            gender: candidate.gender,
            idNumber: candidate.idNumber,
            primarySchoolName: candidate.primarySchoolName,
            primarySchoolClass: candidate.primarySchoolClass,
            familyAddress: candidate.familyAddress,
            status: "active",
            createdAt: now,
            updatedAt: now
        )
    }

    func merge(existing: StoredStudentRecord, candidate: ImportedStudentCandidate) -> StoredStudentRecord {
        StoredStudentRecord(
            id: existing.id,
            className: candidate.className ?? existing.className,
            name: candidate.name,
            studentNumber: candidate.studentNumber ?? existing.studentNumber,
            gender: candidate.gender ?? existing.gender,
            idNumber: candidate.idNumber ?? existing.idNumber,
            primarySchoolName: candidate.primarySchoolName ?? existing.primarySchoolName,
            primarySchoolClass: candidate.primarySchoolClass ?? existing.primarySchoolClass,
            familyAddress: candidate.familyAddress ?? existing.familyAddress,
            status: existing.status,
            createdAt: existing.createdAt,
            updatedAt: Self.timestamp()
        )
    }

    func insertStudentLocked(_ record: StoredStudentRecord) throws {
        try executeLocked(
            sql: "INSERT INTO student (student_id, class_name, name, student_number, gender, id_number, primary_school_name, primary_school_class, family_address, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .text(record.id), optional(record.className), .text(record.name), optional(record.studentNumber),
                optional(record.gender), optional(record.idNumber), optional(record.primarySchoolName),
                optional(record.primarySchoolClass), optional(record.familyAddress), .text(record.status),
                .text(record.createdAt), .text(record.updatedAt)
            ]
        )
    }

    func updateStudentLocked(_ record: StoredStudentRecord) throws {
        try executeLocked(
            sql: "UPDATE student SET class_name = ?, name = ?, student_number = ?, gender = ?, id_number = ?, primary_school_name = ?, primary_school_class = ?, family_address = ?, status = ?, updated_at = ? WHERE student_id = ?",
            arguments: [
                optional(record.className), .text(record.name), optional(record.studentNumber), optional(record.gender),
                optional(record.idNumber), optional(record.primarySchoolName), optional(record.primarySchoolClass),
                optional(record.familyAddress), .text(record.status), .text(record.updatedAt), .text(record.id)
            ]
        )
    }

    func insertContactLocked(_ record: StoredContactRecord) throws {
        try executeLocked(
            sql: "INSERT INTO parent_contact (parent_id, student_id, parent_name, relation, phone, contact_role, contact_order, source_column, is_primary, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .text(record.id), .text(record.studentID), optional(record.name), optional(record.relation), optional(record.phone),
                .text(record.contactRole), optional(record.contactOrder), optional(record.sourceColumn),
                .integer(record.isPrimary ? 1 : 0), .text(record.status), .text(record.createdAt), .text(record.updatedAt)
            ]
        )
    }

    func updateContactLocked(_ record: StoredContactRecord) throws {
        try executeLocked(
            sql: "UPDATE parent_contact SET parent_name = ?, relation = ?, phone = ?, contact_role = ?, contact_order = ?, source_column = ?, is_primary = ?, status = ?, updated_at = ? WHERE parent_id = ?",
            arguments: [
                optional(record.name), optional(record.relation), optional(record.phone), .text(record.contactRole),
                optional(record.contactOrder), optional(record.sourceColumn), .integer(record.isPrimary ? 1 : 0),
                .text(record.status), .text(record.updatedAt), .text(record.id)
            ]
        )
    }

    func importContactsLocked(_ candidates: [ImportedContactCandidate], studentID: String, importID: String) throws {
        for candidate in candidates {
            switch try matchImportedContactLocked(studentID: studentID, candidate: candidate) {
            case .review:
                throw DatabaseError.databaseFailure(operation: "ambiguous_contact_match", code: SQLITE_CONSTRAINT)
            case .existing(let existing):
                let updated = StoredContactRecord(
                    id: existing.id,
                    studentID: existing.studentID,
                    name: candidate.name ?? existing.name,
                    relation: candidate.relation ?? existing.relation,
                    phone: candidate.phone,
                    contactRole: ValueNormalizer.optionalText(candidate.contactRole) ?? existing.contactRole,
                    contactOrder: candidate.contactOrder ?? existing.contactOrder,
                    sourceColumn: candidate.sourceColumn ?? existing.sourceColumn,
                    isPrimary: candidate.isPrimary ?? existing.isPrimary,
                    status: existing.status,
                    createdAt: existing.createdAt,
                    updatedAt: Self.timestamp()
                )
                try updateContactLocked(updated)
                try recordContactChangeLocked(before: existing, after: updated, operation: "update", importID: importID)
            case .none:
                let now = Self.timestamp()
                let record = StoredContactRecord(
                    id: ValueNormalizer.optionalText(candidate.parentID).flatMap(safeImportedParentID) ?? Self.opaqueIdentifier(prefix: "par_"),
                    studentID: studentID,
                    name: candidate.name,
                    relation: candidate.relation,
                    phone: candidate.phone,
                    contactRole: ValueNormalizer.optionalText(candidate.contactRole) ?? ContactRole.unknown.rawValue,
                    contactOrder: candidate.contactOrder,
                    sourceColumn: candidate.sourceColumn,
                    isPrimary: candidate.isPrimary ?? false,
                    status: "active",
                    createdAt: now,
                    updatedAt: now
                )
                try insertContactLocked(record)
                try recordContactChangeLocked(before: nil, after: record, operation: "insert", importID: importID)
            }
        }
    }

    func safeImportedParentID(_ value: String) -> String? {
        guard value.hasPrefix("par_"), value.count > 4, value.count <= 128 else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar == "_" || scalar == "-" || (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        }) else { return nil }
        return value
    }

    func preflightContactIssuesLocked(
        _ candidates: [ImportedContactCandidate],
        rowNumber: Int,
        existingStudentID: String?
    ) throws -> [ImportIssue] {
        var issues: [ImportIssue] = []
        for candidate in candidates {
            guard let parentID = ValueNormalizer.optionalText(candidate.parentID),
                  let safeParentID = safeImportedParentID(parentID),
                  let existing = try fetchContactLocked(contactID: safeParentID, includeArchived: true) else {
                if let existingStudentID {
                    switch try matchImportedContactLocked(studentID: existingStudentID, candidate: candidate) {
                    case .review:
                        issues.append(ImportIssue(
                            rowNumber: rowNumber,
                            code: "contact_match_review",
                            message: "现有联系人记录使这一联系人无法唯一匹配，需要人工复核。"
                        ))
                    case .none, .existing:
                        break
                    }
                }
                continue
            }
            guard existing.status == "active", existingStudentID == existing.studentID else {
                issues.append(ImportIssue(
                    rowNumber: rowNumber,
                    code: "contact_id_conflict",
                    message: "导入的联系人 ID 已属于其他联系人或已归档联系人。"
                ))
                continue
            }
        }
        return issues
    }

    func normalizedDraft(_ draft: ParentContactDraft) throws -> NormalizedDraft {
        let phone: String?
        if let rawPhone = ValueNormalizer.optionalText(draft.phone) {
            guard let normalized = try? PhoneNumberNormalizer.normalize(rawPhone) else {
                throw DatabaseError.invalidPhone
            }
            phone = normalized
        } else {
            phone = nil
        }
        return NormalizedDraft(
            name: ValueNormalizer.optionalText(draft.name),
            relation: ValueNormalizer.optionalText(draft.relation),
            phone: phone,
            contactRole: ValueNormalizer.optionalText(draft.contactRole) ?? ContactRole.unknown.rawValue,
            isPrimary: draft.isPrimary
        )
    }

    func optional(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    func optional(_ value: Int?) -> SQLiteValue { value.map { .integer(Int64($0)) } ?? .null }

    func recordStudentChangeLocked(before: StoredStudentRecord?, after: StoredStudentRecord?, operation: String, importID: String?) throws {
        try insertChangeEventLocked(
            entityType: "student",
            entityID: after?.id ?? before?.id ?? "unknown",
            operation: operation,
            beforeJSON: try encode(before),
            afterJSON: try encode(after),
            importID: importID
        )
    }

    func recordContactChangeLocked(before: StoredContactRecord?, after: StoredContactRecord?, operation: String, importID: String?) throws {
        try insertChangeEventLocked(
            entityType: "parent_contact",
            entityID: after?.id ?? before?.id ?? "unknown",
            operation: operation,
            beforeJSON: try encode(before),
            afterJSON: try encode(after),
            importID: importID
        )
    }

    func insertImportBatchLocked(importID: String, sourceFilename: String?, sourceHash: String, insertedCount: Int, updatedCount: Int, rejectedCount: Int) throws {
        try executeLocked(
            sql: "INSERT INTO import_batch (import_id, source_filename, source_hash, imported_at, inserted_count, updated_count, rejected_count) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .text(importID), optional(sourceFilename), .text(sourceHash), .text(Self.timestamp()),
                .integer(Int64(insertedCount)), .integer(Int64(updatedCount)), .integer(Int64(rejectedCount))
            ]
        )
    }

    func insertChangeEventLocked(entityType: String, entityID: String, operation: String, beforeJSON: String?, afterJSON: String?, importID: String?) throws {
        try executeLocked(
            sql: "INSERT INTO change_event (event_id, entity_type, entity_id, operation, before_json, after_json, import_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .text(Self.opaqueIdentifier(prefix: "evt_")), .text(entityType), .text(entityID), .text(operation),
                optional(beforeJSON), optional(afterJSON), optional(importID), .text(Self.timestamp())
            ]
        )
    }

    func encode<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)
    }

    func toPublicContact(_ record: StoredContactRecord) -> ParentContact {
        ParentContact(
            id: record.id,
            name: record.name,
            relation: record.relation,
            phone: record.phone,
            contactRole: record.contactRole,
            contactOrder: record.contactOrder,
            sourceColumn: record.sourceColumn,
            isPrimary: record.isPrimary
        )
    }

    static func opaqueIdentifier(prefix: String) -> String {
        "\(prefix)\(UUID().uuidString.lowercased())"
    }

    static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
