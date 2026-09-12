import CryptoKit
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

public enum ClassVaultFileTypes {
    public static let backup = UTType(exportedAs: "com.sinclair.classvault-backup", conformingTo: .data)
}

/// Composes the two intentionally separate portability paths. The backup
/// path is for recovery; the export path is for readable data exchange.
public final class DataPortabilityService: @unchecked Sendable {
    public let backup: any DataBackupService
    public let export: any DataExportService

    public init(
        database: EncryptedDatabaseService,
        exportSource: DataExportSource,
        fileManager: FileManager = .default
    ) {
        backup = BackupService(database: database, fileManager: fileManager)
        export = ExportService(source: exportSource, fileManager: fileManager)
    }
}

public final class BackupService: DataBackupService, @unchecked Sendable {
    public static let backupFormat = "classvault-backup"
    public static let currentFormatVersion = 1
    public static let passwordIterations = 120_000
    public static let coreDatabaseEntry = "data/core.sqlite"

    private static let knownComponentIdentifiers = Set(["core-database"])

    private let database: EncryptedDatabaseService
    private let fileManager: FileManager

    public init(database: EncryptedDatabaseService, fileManager: FileManager = .default) {
        self.database = database
        self.fileManager = fileManager
    }

    public func createBackup(destination: URL, password: String) throws -> BackupResult {
        try validatePassword(password)

        let workingDirectory = try makeWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let salt = makeSalt()
        let encryptionKey = try PasswordKeyDerivation.derive(
            password: password,
            salt: salt,
            iterations: Self.passwordIterations
        )
        let coreURL = workingDirectory.appendingPathComponent("core.sqlite")
        try database.createEncryptedSnapshot(to: coreURL, encryptionKey: encryptionKey)

        let metadata = BackupMetadata(
            backupFormat: Self.backupFormat,
            formatVersion: Self.currentFormatVersion,
            createdAt: Self.timestamp(),
            appVersion: Self.appVersion,
            databaseSchemaVersion: try database.databaseSchemaVersion(),
            content: BackupContent(
                modules: [.students, .contacts],
                history: true,
                attachments: false
            ),
            encryption: BackupEncryptionMetadata(
                algorithm: "SQLCipher",
                keyDerivation: "PBKDF2-SHA256",
                iterations: Self.passwordIterations,
                salt: salt.base64EncodedString()
            ),
            components: [
                BackupComponentDescriptor(
                    componentIdentifier: "core-database",
                    componentVersion: 1,
                    entryPath: Self.coreDatabaseEntry
                )
            ]
        )

        let manifest = try JSONEncoder.portabilityEncoder.encode(metadata)
        try prepareDestination(destination)
        let archive = try Archive(url: destination, accessMode: .create)
        try addEntry(manifest, path: "manifest.json", to: archive)
        try addEntry(Data(contentsOf: coreURL), path: Self.coreDatabaseEntry, to: archive)
        try protectUserFile(at: destination)

        let byteCount = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue
            ?? 0
        return BackupResult(outputURL: destination, metadata: metadata, byteCount: byteCount)
    }

    public func inspectBackup(at url: URL) throws -> BackupMetadata {
        let archive = try openArchive(at: url)
        let manifestData = try readEntry(named: "manifest.json", from: archive)
        let metadata: BackupMetadata
        do {
            metadata = try JSONDecoder().decode(BackupMetadata.self, from: manifestData)
        } catch {
            throw BackupError.invalidPackage
        }
        try validateMetadata(metadata, archive: archive)
        return metadata
    }

    public func validateBackup(at url: URL, password: String) throws -> BackupValidationResult {
        try validatePassword(password)
        let metadata = try inspectBackup(at: url)
        let workingDirectory = try makeWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let salt = try decodeSalt(from: metadata)
        let encryptionKey = try PasswordKeyDerivation.derive(
            password: password,
            salt: salt,
            iterations: metadata.encryption.iterations
        )
        let coreURL = workingDirectory.appendingPathComponent("core.sqlite")
        try extractEntry(named: Self.coreDatabaseEntry, from: url, to: coreURL)

        do {
            let sourceDatabase = try EncryptedDatabaseService(
                databaseURL: coreURL,
                keyStore: FixedDatabaseKeyStore(key: encryptionKey),
                fileManager: fileManager
            )
            let counts = try sourceDatabase.portabilityRecordCounts()
            guard counts.students >= 0, counts.contacts >= 0 else {
                throw BackupError.validationFailed
            }
            let unknownComponents = metadata.components
                .map(\.componentIdentifier)
                .filter { !Self.knownComponentIdentifiers.contains($0) }
                .sorted()
            return BackupValidationResult(
                isValid: true,
                metadata: metadata,
                studentCount: counts.students,
                contactCount: counts.contacts,
                unknownComponents: unknownComponents
            )
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.wrongPassword
        }
    }

    public func restoreBackup(
        from url: URL,
        password: String,
        mode: RestoreMode
    ) throws -> RestoreResult {
        guard mode == .replaceCurrentData else { throw BackupError.restoreFailed }
        let validation = try validateBackup(at: url, password: password)
        let workingDirectory = try makeWorkingDirectory()
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let salt = try decodeSalt(from: validation.metadata)
        let encryptionKey = try PasswordKeyDerivation.derive(
            password: password,
            salt: salt,
            iterations: validation.metadata.encryption.iterations
        )
        let sourceURL = workingDirectory.appendingPathComponent("source.sqlite")
        let deviceKeyedURL = workingDirectory.appendingPathComponent("restored.sqlite")
        try extractEntry(named: Self.coreDatabaseEntry, from: url, to: sourceURL)

        do {
            let sourceDatabase = try EncryptedDatabaseService(
                databaseURL: sourceURL,
                keyStore: FixedDatabaseKeyStore(key: encryptionKey),
                fileManager: fileManager
            )
            let deviceKey = try database.currentKeyForPortability()
            try sourceDatabase.createEncryptedSnapshot(to: deviceKeyedURL, encryptionKey: deviceKey)
        } catch {
            throw BackupError.restoreFailed
        }

        do {
            let safetyCopyURL = try database.replaceDatabase(with: deviceKeyedURL)
            return RestoreResult(
                metadata: validation.metadata,
                safetyCopyURL: safetyCopyURL,
                studentCount: validation.studentCount,
                contactCount: validation.contactCount,
                unknownComponents: validation.unknownComponents
            )
        } catch {
            throw BackupError.restoreFailed
        }
    }

    private func validatePassword(_ password: String) throws {
        guard password.count >= 8 else { throw BackupError.passwordTooShort }
    }

    private func validateMetadata(_ metadata: BackupMetadata, archive: Archive) throws {
        guard metadata.backupFormat == Self.backupFormat else { throw BackupError.invalidPackage }
        guard metadata.formatVersion <= Self.currentFormatVersion else {
            throw BackupError.unsupportedFormatVersion(metadata.formatVersion)
        }
        guard metadata.formatVersion > 0,
              metadata.encryption.algorithm == "SQLCipher",
              metadata.encryption.keyDerivation == "PBKDF2-SHA256",
              metadata.encryption.iterations >= 10_000,
              Data(base64Encoded: metadata.encryption.salt) != nil,
              metadata.encryption.salt.isEmpty == false else {
            throw BackupError.invalidPackage
        }
        guard metadata.components.contains(where: {
            $0.componentIdentifier == "core-database" && $0.entryPath == Self.coreDatabaseEntry
        }), archive[Self.coreDatabaseEntry] != nil else {
            throw BackupError.invalidPackage
        }
    }

    private func decodeSalt(from metadata: BackupMetadata) throws -> Data {
        guard let salt = Data(base64Encoded: metadata.encryption.salt), salt.count >= 16 else {
            throw BackupError.invalidPackage
        }
        return salt
    }

    private func makeWorkingDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ClassVaultBackup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func prepareDestination(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    private func protectUserFile(at url: URL) throws {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func openArchive(at url: URL) throws -> Archive {
        guard fileManager.fileExists(atPath: url.path) else { throw BackupError.invalidPackage }
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw BackupError.invalidPackage
        }
    }

    private func readEntry(named path: String, from archive: Archive) throws -> Data {
        guard let entry = archive[path] else { throw BackupError.invalidPackage }
        var data = Data()
        do {
            _ = try archive.extract(entry, consumer: { chunk in data.append(chunk) })
        } catch {
            throw BackupError.invalidPackage
        }
        return data
    }

    private func extractEntry(named path: String, from url: URL, to destination: URL) throws {
        let archive = try openArchive(at: url)
        let data = try readEntry(named: path, from: archive)
        guard data.isEmpty == false else { throw BackupError.invalidPackage }
        try data.write(to: destination, options: [.atomic])
    }

    private func addEntry(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            guard start < data.count else { return Data() }
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    private func makeSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public final class ExportService: DataExportService, @unchecked Sendable {
    private let source: DataExportSource
    private let fileManager: FileManager

    public init(source: DataExportSource, fileManager: FileManager = .default) {
        self.source = source
        self.fileManager = fileManager
    }

    public func exportStudents(
        request: StudentExportRequest,
        destination: URL
    ) throws -> ExportResult {
        try exportDataset(
            request: DatasetExportRequest(
                modules: [.students],
                format: request.format,
                filters: request.filters
            ),
            destination: destination
        )
    }

    public func exportGrades(
        request: GradeExportRequest,
        destination: URL
    ) throws -> ExportResult {
        throw BackupError.unsupportedModules([DataModule.grades.displayName])
    }

    public func exportDataset(
        request: DatasetExportRequest,
        destination: URL
    ) throws -> ExportResult {
        guard request.modules.isEmpty == false else { throw BackupError.unsupportedModules(["未选择数据范围"]) }

        let supportedModules: Set<DataModule> = [.students, .contacts]
        let unsupported = request.modules.subtracting(supportedModules)
        if unsupported.isEmpty == false {
            throw BackupError.unsupportedModules(
                DataModule.allCases.filter { unsupported.contains($0) }.map(\.displayName)
            )
        }

        let details = try source.studentDetailsForExport(filters: request.filters)
        let students = request.modules.contains(.students)
            ? details.map(ExportStudentRecord.init(details:))
            : []
        let contacts = request.modules.contains(.contacts)
            ? details.flatMap { details in
                details.contacts.map { ExportContactRecord(studentID: details.id, contact: $0) }
            }
            : []

        let rows = makeRows(students: students, contacts: contacts, modules: request.modules)
        let data: Data
        switch request.format {
        case .csv:
            data = Data(makeCSV(rows).utf8)
        case .json:
            data = try makeJSON(students: students, contacts: contacts, modules: request.modules)
        case .xlsx:
            data = try XLSXExportWriter.makeWorkbook(rows: rows)
        }

        try prepareDestination(destination)
        try data.write(to: destination, options: [.atomic])
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )

        let rowCount = request.format == .json ? students.count + contacts.count : rows.count
        let orderedModules = DataModule.allCases.filter { request.modules.contains($0) }
        return ExportResult(
            outputURL: destination,
            format: request.format,
            modules: orderedModules,
            rowCount: rowCount,
            byteCount: data.count
        )
    }

    private func makeRows(
        students: [ExportStudentRecord],
        contacts: [ExportContactRecord],
        modules: Set<DataModule>
    ) -> [[String]] {
        let studentHeaders = [
            "student_id", "name", "class_name", "student_number", "gender", "id_number",
            "primary_school_name", "primary_school_class", "family_address"
        ]
        let contactHeaders = [
            "contact_id", "student_id", "contact_name", "relation", "phone", "contact_role",
            "contact_order", "is_primary"
        ]
        if modules == [.students] {
            return [studentHeaders] + students.map { student in
                [student.studentID, student.name, student.className, student.studentNumber, student.gender,
                 student.idNumber, student.primarySchoolName, student.primarySchoolClass, student.familyAddress]
                    .map { $0 ?? "" }
            }
        }
        if modules == [.contacts] {
            return [contactHeaders] + contacts.map { contact in
                [contact.contactID, contact.studentID, contact.name, contact.relation, contact.phone,
                 contact.contactRole, contact.contactOrder.map(String.init), contact.isPrimary ? "true" : "false"]
                    .map { $0 ?? "" }
            }
        }

        let headers = ["record_type"] + studentHeaders + contactHeaders.dropFirst(1)
        let contactsByStudent = Dictionary(grouping: contacts, by: \.studentID)
        var rows = [headers]
        for student in students {
            let studentValues = [
                student.studentID, student.name, student.className, student.studentNumber, student.gender,
                student.idNumber, student.primarySchoolName, student.primarySchoolClass, student.familyAddress
            ].map { $0 ?? "" }
            let matchingContacts = contactsByStudent[student.studentID] ?? []
            if matchingContacts.isEmpty {
                rows.append(["student"] + studentValues + Array(repeating: "", count: contactHeaders.count - 1))
            } else {
                for contact in matchingContacts {
                    rows.append(
                        ["student_contact"] + studentValues + [
                            contact.contactID, contact.studentID, contact.name ?? "", contact.relation ?? "",
                            contact.phone ?? "", contact.contactRole, contact.contactOrder.map(String.init) ?? "",
                            contact.isPrimary ? "true" : "false"
                        ]
                    )
                }
            }
        }
        return rows
    }

    private func makeCSV(_ rows: [[String]]) -> String {
        rows.map { row in row.map(escapeCSV).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func makeJSON(
        students: [ExportStudentRecord],
        contacts: [ExportContactRecord],
        modules: Set<DataModule>
    ) throws -> Data {
        let payload = ExportPayload(
            exportFormat: "classvault-export",
            exportVersion: 1,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modules: DataModule.allCases.filter { modules.contains($0) },
            students: students,
            contacts: contacts
        )
        return try JSONEncoder.portabilityEncoder.encode(payload)
    }

    private func prepareDestination(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }
}

private struct ExportPayload: Codable, Sendable {
    let exportFormat: String
    let exportVersion: Int
    let createdAt: String
    let modules: [DataModule]
    let students: [ExportStudentRecord]
    let contacts: [ExportContactRecord]
}

private enum PasswordKeyDerivation {
    static func derive(password: String, salt: Data, iterations: Int) throws -> Data {
        guard iterations > 0 else { throw BackupError.invalidPackage }
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        var message = salt
        message.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: message, using: passwordKey))
        var result = u
        guard iterations >= 1 else { throw BackupError.invalidPackage }
        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
            for index in result.indices {
                result[index] ^= u[index]
            }
        }
        return result
    }
}

private extension JSONEncoder {
    static var portabilityEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private enum XLSXExportWriter {
    static func makeWorkbook(rows: [[String]]) throws -> Data {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassVaultExport-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let archive = try Archive(url: archiveURL, accessMode: .create)

        let files: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", rootRelationshipsXML),
            ("xl/workbook.xml", workbookXML),
            ("xl/_rels/workbook.xml.rels", workbookRelationshipsXML),
            ("xl/worksheets/sheet1.xml", worksheetXML(rows: rows))
        ]
        for (path, content) in files {
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
        return try Data(contentsOf: archiveURL)
    }

    private static var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """
    }

    private static var rootRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
    }

    private static var workbookXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="ClassVault" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
    }

    private static var workbookRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
    }

    private static func worksheetXML(rows: [[String]]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
        """
        for (rowIndex, row) in rows.enumerated() {
            let excelRow = rowIndex + 1
            xml += "<row r=\"\(excelRow)\">"
            for (columnIndex, value) in row.enumerated() {
                let reference = columnName(columnIndex + 1) + String(excelRow)
                xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXML(value))</t></is></c>"
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func columnName(_ number: Int) -> String {
        var value = number
        var result = ""
        while value > 0 {
            let remainder = (value - 1) % 26
            result = String(UnicodeScalar(65 + remainder)!) + result
            value = (value - 1) / 26
        }
        return result
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
