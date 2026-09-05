import Foundation

public final class SQLiteStudentRepository: StudentRepository, @unchecked Sendable {
    let database: EncryptedDatabaseService
    let importService: ImportService

    public init(
        databaseURL: URL? = nil,
        keyStore: DatabaseKeyStore = KeychainDatabaseKeyStore(),
        importService: ImportService = ImportService(),
        logger: SafeLogger = .shared
    ) throws {
        self.database = try EncryptedDatabaseService(
            databaseURL: databaseURL,
            keyStore: keyStore,
            logger: logger
        )
        self.importService = importService
    }

    public func listStudents(search: String?, className: String?) throws -> [StudentSummary] {
        try database.listStudents(search: search, className: className)
    }

    public func availableClassNames() throws -> [String] {
        try database.availableClassNames()
    }

    public func getStudentDetails(studentID: String) throws -> StudentDetails {
        try database.getStudentDetails(studentID: studentID)
    }

    public func addStudent(draft: StudentDraft) throws -> StudentSummary {
        try database.addStudent(draft: draft)
    }

    public func archiveStudent(studentID: String) throws {
        try database.archiveStudent(studentID: studentID)
    }

    public func previewImport(_ url: URL, strictMatching: Bool = false) throws -> ImportPreview {
        let document = try importService.load(url: url)
        return try preflight(importService.buildPreview(from: document, strictMatching: strictMatching))
    }

    public func rebuildImportPreview(
        _ preview: ImportPreview,
        mapping: ImportMapping,
        strictMatching: Bool
    ) throws -> ImportPreview {
        try preflight(importService.buildPreview(
            from: preview.document,
            mapping: mapping,
            strictMatching: strictMatching
        ))
    }

    private func preflight(_ preview: ImportPreview) throws -> ImportPreview {
        preview.addingIssues(try database.preflightImport(preview.acceptedRows))
    }

    public func commitImport(_ preview: ImportPreview) throws -> ImportResult {
        guard preview.canCommit else { throw ImportError.cannotCommitPreview }
        return try database.applyImport(
            DatabaseImportRequest(
                sourceFilename: preview.document.sourceFilename,
                sourceHash: preview.document.sourceHash,
                rows: preview.acceptedRows,
                rejectedRowCount: preview.rejectedRowCount
            )
        )
    }

    /// Convenience API for non-UI callers. The UI uses previewImport and
    /// commitImport separately so the user must explicitly confirm the write.
    public func importFile(_ url: URL) throws -> ImportResult {
        try commitImport(previewImport(url, strictMatching: false))
    }

    public func addParentContact(studentID: String, draft: ParentContactDraft) throws -> ParentContact {
        try database.addParentContact(studentID: studentID, draft: draft)
    }

    public func updateParentContact(contactID: String, draft: ParentContactDraft) throws -> ParentContact {
        try database.updateParentContact(contactID: contactID, draft: draft)
    }

    public func archiveParentContact(contactID: String) throws {
        try database.archiveParentContact(contactID: contactID)
    }

    #if DEBUG
    public func seedSyntheticData() throws {
        try database.seedSyntheticData()
    }
    #endif
}
