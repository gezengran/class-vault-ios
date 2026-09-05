import Foundation
import SwiftUI

@MainActor
final class StudentListViewModel: ObservableObject {
    let repository: StudentRepository

    @Published var students: [StudentSummary] = []
    @Published var searchText = ""
    @Published var selectedClass = ""
    @Published var classNames: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    init(repository: StudentRepository) {
        self.repository = repository
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            classNames = try repository.availableClassNames()
            if !selectedClass.isEmpty && !classNames.contains(selectedClass) {
                selectedClass = ""
            }
            students = try repository.listStudents(
                search: searchText,
                className: selectedClass.isEmpty ? nil : selectedClass
            )
        } catch {
            errorMessage = "学生数据无法加载。"
        }
    }

    func previewImport(url: URL, strictMatching: Bool) throws -> ImportPreview {
        try repository.previewImport(url, strictMatching: strictMatching)
    }

    func commitImport(_ preview: ImportPreview) throws -> ImportResult {
        let result = try repository.commitImport(preview)
        load()
        return result
    }

    func addStudent(_ draft: StudentDraft) throws -> StudentSummary {
        let student = try repository.addStudent(draft: draft)
        load()
        return student
    }

    func archiveStudent(_ studentID: String) throws {
        try repository.archiveStudent(studentID: studentID)
        load()
    }

    func rebuildImportPreview(_ preview: ImportPreview, mapping: ImportMapping, strictMatching: Bool) throws -> ImportPreview {
        try repository.rebuildImportPreview(preview, mapping: mapping, strictMatching: strictMatching)
    }
}

@MainActor
final class StudentDetailViewModel: ObservableObject {
    let repository: StudentRepository
    let studentID: String

    @Published var details: StudentDetails?
    @Published var errorMessage: String?

    init(repository: StudentRepository, studentID: String) {
        self.repository = repository
        self.studentID = studentID
    }

    func load() {
        do {
            details = try repository.getStudentDetails(studentID: studentID)
        } catch {
            errorMessage = "学生详情无法加载。"
        }
    }

    func addContact(_ draft: ParentContactDraft) throws {
        _ = try repository.addParentContact(studentID: studentID, draft: draft)
        load()
    }

    func updateContact(_ contactID: String, draft: ParentContactDraft) throws {
        _ = try repository.updateParentContact(contactID: contactID, draft: draft)
        load()
    }

    func archiveContact(_ contactID: String) throws {
        try repository.archiveParentContact(contactID: contactID)
        load()
    }
}
