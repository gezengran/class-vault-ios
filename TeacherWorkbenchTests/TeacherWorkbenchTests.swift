import Foundation
import XCTest
@testable import TeacherWorkbench

final class TeacherWorkbenchTests: XCTestCase {
    func testDatabaseCreationMigrationAndCipherHeader() throws {
        try withDatabase { database, _ in
            XCTAssertEqual(
                Set(try database.tableNames()),
                Set(["student", "parent_contact", "import_batch", "change_event"])
            )
            XCTAssertNotNil(try database.cipherVersion())

            let bytes = try Data(contentsOf: database.databaseURL)
            XCTAssertNotEqual(Data(bytes.prefix(16)), Data("SQLite format 3\0".utf8))
        }
    }

    func testDatabaseCannotOpenWithWrongKey() throws {
        let url = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originalKey = testKey()
        var wrongKey = testKey()
        while wrongKey == originalKey {
            wrongKey = testKey()
        }

        do {
            _ = try EncryptedDatabaseService(
                databaseURL: url,
                keyStore: FixedDatabaseKeyStore(key: originalKey)
            )
        }

        XCTAssertThrowsError(
            try EncryptedDatabaseService(
                databaseURL: url,
                keyStore: FixedDatabaseKeyStore(key: wrongKey)
            )
        )
    }

    func testImportedOpaqueStudentIDCanCreateAStudentWithoutAStudentNumber() throws {
        let csv = """
        student_id,name
        stu_imported_001,Student With Imported ID
        """

        try withRepository { repository, _ in
            let url = try writeSyntheticCSV(csv)
            defer { try? FileManager.default.removeItem(at: url) }

            let preview = try repository.previewImport(url, strictMatching: false)
            XCTAssertTrue(preview.canCommit)
            _ = try repository.commitImport(preview)

            let student = try XCTUnwrap(repository.listStudents(search: "Student With Imported ID", className: nil).first)
            XCTAssertEqual(student.name, "Student With Imported ID")
        }
    }

    func testInitialImportCreatesPhoneOnlyContacts() throws {
        let csv = """
        学号,姓名,性别,身份证,小学班级,联系方式一,联系方式二,家庭地址
        SYN-001,Synthetic Student,男,-,小学一班,138 0000 0000,,-
        """

        try withRepository { repository, _ in
            let url = try writeSyntheticCSV(csv)
            defer { try? FileManager.default.removeItem(at: url) }

            let preview = try repository.previewImport(url, strictMatching: false)
            XCTAssertTrue(preview.canCommit)
            XCTAssertEqual(preview.acceptedRows.count, 1)
            XCTAssertEqual(preview.acceptedRows[0].student.primarySchoolClass, "小学一班")
            XCTAssertEqual(preview.acceptedRows[0].contacts.count, 1)
            XCTAssertNil(preview.acceptedRows[0].contacts[0].name)
            XCTAssertNil(preview.acceptedRows[0].contacts[0].relation)

            let result = try repository.commitImport(preview)
            XCTAssertEqual(result.insertedCount, 1)
            XCTAssertEqual(try repository.listStudents(search: "Synthetic", className: nil).count, 1)

            let student = try XCTUnwrap(repository.listStudents(search: nil, className: nil).first)
            let details = try repository.getStudentDetails(studentID: student.id)
            let contact = try XCTUnwrap(details.contacts.first)
            XCTAssertEqual(contact.phone, "13800000000")
            XCTAssertNil(contact.name)
            XCTAssertNil(contact.relation)
            XCTAssertEqual(contact.sourceColumn, "联系方式一")
        }
    }

    func testManualContactEditAndBlankReimportPreservesFields() throws {
        let initialCSV = """
        学号,姓名,小学班级,联系方式一,联系方式二
        SYN-001,Synthetic Student,小学一班,13800000000,13900000000
        """
        let laterCSV = """
        学号,姓名,小学班级,联系方式一,联系方式二
        SYN-001,Synthetic Student,小学一班,13800000000,
        """

        try withRepository { repository, _ in
            let firstURL = try writeSyntheticCSV(initialCSV)
            defer { try? FileManager.default.removeItem(at: firstURL) }
            let firstResult = try repository.commitImport(repository.previewImport(firstURL, strictMatching: false))
            XCTAssertEqual(firstResult.insertedCount, 1)

            let student = try XCTUnwrap(repository.listStudents(search: "SYN-001", className: nil).first)
            var details = try repository.getStudentDetails(studentID: student.id)
            let importedContact = try XCTUnwrap(details.contacts.first(where: { $0.sourceColumn == "联系方式一" }))
            _ = try repository.updateParentContact(
                contactID: importedContact.id,
                draft: ParentContactDraft(
                    name: "Synthetic Parent",
                    relation: "父亲",
                    phone: importedContact.phone,
                    contactRole: ContactRole.parent.rawValue,
                    isPrimary: true
                )
            )

            let manualContact = try repository.addParentContact(
                studentID: student.id,
                draft: ParentContactDraft(
                    name: "Second Synthetic Contact",
                    relation: "监护人",
                    phone: "13700000000",
                    contactRole: ContactRole.guardian.rawValue,
                    isPrimary: false
                )
            )

            let laterURL = try writeSyntheticCSV(laterCSV)
            defer { try? FileManager.default.removeItem(at: laterURL) }
            let laterResult = try repository.commitImport(repository.previewImport(laterURL, strictMatching: false))
            XCTAssertEqual(laterResult.insertedCount, 0)
            XCTAssertEqual(laterResult.updatedCount, 1)

            details = try repository.getStudentDetails(studentID: student.id)
            let edited = try XCTUnwrap(details.contacts.first(where: { $0.id == importedContact.id }))
            XCTAssertEqual(edited.name, "Synthetic Parent")
            XCTAssertEqual(edited.relation, "父亲")
            XCTAssertEqual(details.contacts.count, 3, "A blank imported cell must not delete an existing contact.")

            try repository.archiveParentContact(contactID: manualContact.id)
            details = try repository.getStudentDetails(studentID: student.id)
            XCTAssertFalse(details.contacts.contains(where: { $0.id == manualContact.id }))
            XCTAssertGreaterThanOrEqual(try repository.database.changeEventCount(), 5)
        }
    }

    func testSearchByNameAndStudentNumber() throws {
        let csv = """
        学号,姓名,班级,小学班级,性别,联系方式一
        SYN-001,Synthetic Student,初一（8）班,小学一班,男,13800000000
        SYN-002,Another Synthetic Student,初一（8）班,小学二班,女,13900000000
        """

        try withRepository { repository, _ in
            let url = try writeSyntheticCSV(csv)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try repository.commitImport(repository.previewImport(url, strictMatching: false))

            XCTAssertEqual(try repository.listStudents(search: "Another", className: nil).count, 1)
            XCTAssertEqual(try repository.listStudents(search: "SYN-002", className: nil).count, 1)
            XCTAssertEqual(try repository.listStudents(search: nil, className: "初一（8）班").count, 2)
            XCTAssertEqual(try repository.listStudents(search: nil, className: "小学一班").count, 0)
            XCTAssertEqual(try repository.listStudents(search: "SYN-001", className: nil).first?.gender, "男")
        }
    }

    func testTableTitleBecomesCurrentClassAndPrimarySchoolClassRemainsSecondary() {
        let document = ParsedImportDocument(
            sourceFilename: "2026级初一（8）班学生信息表.xlsx",
            sourceHash: "title-class-hash",
            headers: ["学号", "姓名", "小学班级"],
            rows: [["SYN-001", "Synthetic Student", "小学一班"]],
            tableTitle: "2026级初一（8）班学生信息表"
        )

        XCTAssertEqual(document.currentClassName, "初一（8）班")

        let preview = ImportService().buildPreview(from: document, strictMatching: false)
        XCTAssertTrue(preview.canCommit)
        XCTAssertEqual(preview.acceptedRows.first?.student.className, "初一（8）班")
        XCTAssertEqual(preview.acceptedRows.first?.student.primarySchoolClass, "小学一班")
    }

    func testCSVTitleRowIsDetectedBeforeTheHeader() throws {
        let csv = """
        2026级初一（8）班学生信息表,,
        学号,姓名,小学班级
        SYN-001,Synthetic Student,小学一班
        """

        let table = try CSVParser.parse(data: Data(csv.utf8))
        XCTAssertEqual(table.headerRowNumber, 2)
        XCTAssertEqual(table.tableTitle, "2026级初一（8）班学生信息表")

        let document = ParsedImportDocument(
            sourceFilename: "students.csv",
            sourceHash: "csv-title-hash",
            headers: table.headers,
            rows: table.rows,
            headerRowNumber: table.headerRowNumber,
            tableTitle: table.tableTitle
        )
        XCTAssertEqual(document.currentClassName, "初一（8）班")
    }

    func testManualStudentAddAndArchive() throws {
        try withRepository { repository, _ in
            let student = try repository.addStudent(
                draft: StudentDraft(
                    name: "Manual Synthetic Student",
                    className: "初一（8）班",
                    studentNumber: "MANUAL-001",
                    gender: "女"
                )
            )

            XCTAssertEqual(student.className, "初一（8）班")
            XCTAssertEqual(student.gender, "女")
            XCTAssertEqual(try repository.listStudents(search: nil, className: "初一（8）班").count, 1)

            try repository.archiveStudent(studentID: student.id)

            XCTAssertTrue(try repository.listStudents(search: "Manual Synthetic Student", className: nil).isEmpty)
            XCTAssertThrowsError(try repository.getStudentDetails(studentID: student.id))
            XCTAssertGreaterThanOrEqual(try repository.database.changeEventCount(), 2)
        }
    }

    func testGenderAppearanceMapsCommonValues() {
        XCTAssertEqual(StudentGenderAppearance(gender: "男"), .male)
        XCTAssertEqual(StudentGenderAppearance(gender: "female"), .female)
        XCTAssertEqual(StudentGenderAppearance(gender: nil), .other)
    }

    func testDuplicateAndInvalidPhoneRowsAreReportedBeforeCommit() throws {
        let document = ParsedImportDocument(
            sourceFilename: "synthetic.csv",
            sourceHash: "synthetic-hash",
            headers: ["学号", "姓名", "小学班级", "联系方式一"],
            rows: [
                ["SYN-001", "Synthetic Student", "小学一班", "13800000000"],
                ["SYN-001", "Conflicting Synthetic Student", "小学一班", "not-a-phone" ]
            ]
        )
        let preview = ImportService().buildPreview(from: document, strictMatching: false)

        XCTAssertFalse(preview.canCommit)
        XCTAssertEqual(preview.rejectedRowCount, 2)
        XCTAssertTrue(preview.issues.contains(where: { $0.code == "conflicting_duplicate" }))
        XCTAssertTrue(preview.issues.contains(where: { $0.code == "invalid_phone" }))
    }

    func testNameAndClassDuplicatesWithoutAStableIdentifierRequireReview() {
        let document = ParsedImportDocument(
            sourceFilename: "synthetic.csv",
            sourceHash: "ambiguous-hash",
            headers: ["姓名", "小学班级"],
            rows: [
                ["Synthetic Same Name", "小学一班"],
                ["Synthetic Same Name", "小学一班"]
            ]
        )

        let preview = ImportService().buildPreview(from: document, strictMatching: false)

        XCTAssertFalse(preview.canCommit)
        XCTAssertEqual(preview.acceptedRows.count, 0)
        XCTAssertEqual(preview.issues.filter { $0.code == "ambiguous_duplicate" }.count, 2)
    }

    func testExistingParentIDCollisionIsReportedBeforeCommit() throws {
        let firstCSV = """
        学号,姓名,parent_id,家长电话
        SYN-001,First Synthetic Student,par_imported_001,13800000000
        """
        let conflictingCSV = """
        学号,姓名,parent_id,家长电话
        SYN-002,Second Synthetic Student,par_imported_001,13900000000
        """

        try withRepository { repository, _ in
            let firstURL = try writeSyntheticCSV(firstCSV)
            defer { try? FileManager.default.removeItem(at: firstURL) }
            _ = try repository.commitImport(repository.previewImport(firstURL, strictMatching: false))

            let conflictingURL = try writeSyntheticCSV(conflictingCSV)
            defer { try? FileManager.default.removeItem(at: conflictingURL) }
            let preview = try repository.previewImport(conflictingURL, strictMatching: false)

            XCTAssertFalse(preview.canCommit)
            XCTAssertTrue(preview.issues.contains(where: { $0.code == "contact_id_conflict" }))
            XCTAssertEqual(try repository.database.studentCount(), 1)
        }
    }

    func testAliasMappingIncludesCurrentTargetLayout() {
        let mapping = ImportAliasDictionary().proposedMapping(for: [
            "学号", "姓名", "性别", "身份证", "毕业学校名称", "小学班级", "联系方式一", "联系方式二", "家庭地址"
        ])

        XCTAssertEqual(mapping.field(for: "学号"), .studentNumber)
        XCTAssertEqual(mapping.field(for: "姓名"), .name)
        XCTAssertEqual(mapping.field(for: "毕业学校名称"), .primarySchoolName)
        XCTAssertEqual(mapping.field(for: "小学班级"), .primarySchoolClass)
        XCTAssertEqual(mapping.field(for: "联系方式一"), .phone)
        XCTAssertEqual(mapping.field(for: "联系方式二"), .phone)
        XCTAssertEqual(mapping.field(for: "家庭地址"), .familyAddress)
    }

    func testXLSXParserHandlesStandardOfficeOpenXMLWithTitleRowAndSharedStrings() throws {
        let base64 = """
        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
        AAcABwBZAgAApAUAAAAA
        """
        let data = try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))

        let table = try XLSXParser.parse(data: data)

        XCTAssertEqual(table.headers, ["学号", "姓名", "性别", "联系方式一"])
        XCTAssertEqual(table.headerRowNumber, 3)
        XCTAssertEqual(table.tableTitle, "2026级初一（8）班学生信息表")
        XCTAssertEqual(table.rows, [["SYN-001", "张三", "男", "13800000000"]])
    }

    func testImportIssueRowNumberPreservesAnOffsetXLSXHeaderRow() {
        let document = ParsedImportDocument(
            sourceFilename: "synthetic.xlsx",
            sourceHash: "synthetic-xlsx-hash",
            headers: ["学号", "姓名"],
            rows: [["SYN-001", ""]],
            headerRowNumber: 4
        )

        let preview = ImportService().buildPreview(from: document, strictMatching: false)

        XCTAssertTrue(preview.issues.contains(where: { issue in
            issue.code == "missing_name" && issue.rowNumber == 5
        }))
    }

    func testPhoneNormalizationAndTelURL() throws {
        XCTAssertEqual(try PhoneNumberNormalizer.normalize("+86 138-0000-0000"), "+8613800000000")
        XCTAssertEqual(try PhoneNumberNormalizer.normalize("138 0000 0000"), "13800000000")
        XCTAssertNil(PhoneNumberNormalizer.validNormalized("123"))
        XCTAssertEqual(PhoneCallService.url(for: "138 0000 0000")?.absoluteString, "tel:13800000000")
    }

    func testCancelingPreviewChangesNothing() throws {
        let csv = """
        学号,姓名,联系方式一
        SYN-001,Synthetic Student,13800000000
        """

        try withRepository { repository, _ in
            let url = try writeSyntheticCSV(csv)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try repository.previewImport(url, strictMatching: false)
            XCTAssertEqual(try repository.database.studentCount(), 0)
        }
    }

    func testSafeLogOutputContainsNoStudentValues() {
        var messages: [String] = []
        let logger = SafeLogger(sink: { messages.append($0) })
        logger.record(operation: "import_commit", rowCount: 2, importID: "imp_test", sourceHash: "hash_test")
        let output = messages.joined(separator: "\n")
        XCTAssertFalse(output.contains("Synthetic Student"))
        XCTAssertFalse(output.contains("13800000000"))
        XCTAssertTrue(output.contains("operation=import_commit"))
    }

    private func withDatabase(_ body: (EncryptedDatabaseService, URL) throws -> Void) throws {
        let url = temporaryDatabaseURL()
        do {
            let database = try EncryptedDatabaseService(
                databaseURL: url,
                keyStore: FixedDatabaseKeyStore(key: testKey())
            )
            try body(database, url)
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func withRepository(_ body: (SQLiteStudentRepository, URL) throws -> Void) throws {
        let url = temporaryDatabaseURL()
        do {
            let repository = try SQLiteStudentRepository(
                databaseURL: url,
                keyStore: FixedDatabaseKeyStore(key: testKey())
            )
            try body(repository, url)
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TeacherWorkbenchTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("teacher_workbench.sqlite")
    }

    private func writeSyntheticCSV(_ csv: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeacherWorkbenchImport-\(UUID().uuidString).csv")
        try csv.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    private func testKey() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }
}
