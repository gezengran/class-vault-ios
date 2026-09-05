import Foundation

public protocol StudentRepository: AnyObject {
    func listStudents(search: String?, className: String?) throws -> [StudentSummary]
    func availableClassNames() throws -> [String]
    func getStudentDetails(studentID: String) throws -> StudentDetails
    func addStudent(draft: StudentDraft) throws -> StudentSummary
    func archiveStudent(studentID: String) throws

    func previewImport(_ url: URL, strictMatching: Bool) throws -> ImportPreview
    func rebuildImportPreview(
        _ preview: ImportPreview,
        mapping: ImportMapping,
        strictMatching: Bool
    ) throws -> ImportPreview
    func commitImport(_ preview: ImportPreview) throws -> ImportResult
    func importFile(_ url: URL) throws -> ImportResult

    func addParentContact(studentID: String, draft: ParentContactDraft) throws -> ParentContact
    func updateParentContact(contactID: String, draft: ParentContactDraft) throws -> ParentContact
    func archiveParentContact(contactID: String) throws
}
