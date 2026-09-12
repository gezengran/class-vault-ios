import Foundation

/// The durable, domain-level modules that may participate in portability.
/// This list intentionally is not a list of SQLite tables.
public enum DataModule: String, CaseIterable, Codable, Hashable, Sendable {
    case students
    case contacts
    case grades
    case exams
    case attendance
    case notes
    case customFields

    public var displayName: String {
        switch self {
        case .students: "学生信息"
        case .contacts: "联系人信息"
        case .grades: "成绩"
        case .exams: "考试"
        case .attendance: "考勤"
        case .notes: "备注"
        case .customFields: "自定义字段"
        }
    }
}

public enum ExportFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case csv
    case xlsx
    case json

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .xlsx: "Excel（XLSX）"
        case .json: "JSON"
        }
    }
}

public struct ExportFilters: Codable, Hashable, Sendable {
    public let className: String?
    public let studentIDs: Set<String>
    public let includeArchived: Bool

    public init(
        className: String? = nil,
        studentIDs: Set<String> = [],
        includeArchived: Bool = false
    ) {
        self.className = className
        self.studentIDs = studentIDs
        self.includeArchived = includeArchived
    }
}

public struct StudentExportRequest: Codable, Sendable {
    public let filters: ExportFilters
    public let format: ExportFormat

    public init(filters: ExportFilters = ExportFilters(), format: ExportFormat) {
        self.filters = filters
        self.format = format
    }
}

public struct GradeExportRequest: Codable, Sendable {
    public let filters: ExportFilters
    public let format: ExportFormat

    public init(filters: ExportFilters = ExportFilters(), format: ExportFormat) {
        self.filters = filters
        self.format = format
    }
}

public struct DatasetExportRequest: Codable, Sendable {
    public let modules: Set<DataModule>
    public let format: ExportFormat
    public let filters: ExportFilters

    public init(
        modules: Set<DataModule>,
        format: ExportFormat,
        filters: ExportFilters = ExportFilters()
    ) {
        self.modules = modules
        self.format = format
        self.filters = filters
    }
}

public struct ExportResult: Codable, Sendable, Equatable {
    public let outputURL: URL
    public let format: ExportFormat
    public let modules: [DataModule]
    public let rowCount: Int
    public let byteCount: Int

    public init(
        outputURL: URL,
        format: ExportFormat,
        modules: [DataModule],
        rowCount: Int,
        byteCount: Int
    ) {
        self.outputURL = outputURL
        self.format = format
        self.modules = modules
        self.rowCount = rowCount
        self.byteCount = byteCount
    }
}

/// Domain-shaped records used by the external export formats. Internal
/// change events, migration metadata, indexes, and database keys never enter
/// these types.
public struct ExportStudentRecord: Codable, Sendable, Equatable {
    public let studentID: String
    public let name: String
    public let className: String?
    public let studentNumber: String?
    public let gender: String?
    public let idNumber: String?
    public let primarySchoolName: String?
    public let primarySchoolClass: String?
    public let familyAddress: String?

    public init(details: StudentDetails) {
        studentID = details.id
        name = details.name
        className = details.className
        studentNumber = details.studentNumber
        gender = details.gender
        idNumber = details.idNumber
        primarySchoolName = details.primarySchoolName
        primarySchoolClass = details.primarySchoolClass
        familyAddress = details.familyAddress
    }
}

public struct ExportContactRecord: Codable, Sendable, Equatable {
    public let contactID: String
    public let studentID: String
    public let name: String?
    public let relation: String?
    public let phone: String?
    public let contactRole: String
    public let contactOrder: Int?
    public let isPrimary: Bool

    public init(studentID: String, contact: ParentContact) {
        contactID = contact.id
        self.studentID = studentID
        name = contact.name
        relation = contact.relation
        phone = contact.phone
        contactRole = contact.contactRole
        contactOrder = contact.contactOrder
        isPrimary = contact.isPrimary
    }
}

public struct BackupContent: Codable, Sendable, Equatable {
    public let modules: [DataModule]
    public let students: Bool
    public let contacts: Bool
    public let grades: Bool
    public let exams: Bool
    public let attendance: Bool
    public let notes: Bool
    public let customFields: Bool
    public let history: Bool
    public let attachments: Bool

    public init(modules: [DataModule], history: Bool = true, attachments: Bool) {
        self.modules = modules
        students = modules.contains(.students)
        contacts = modules.contains(.contacts)
        grades = modules.contains(.grades)
        exams = modules.contains(.exams)
        attendance = modules.contains(.attendance)
        notes = modules.contains(.notes)
        customFields = modules.contains(.customFields)
        self.history = history
        self.attachments = attachments
    }
}

public struct BackupEncryptionMetadata: Codable, Sendable, Equatable {
    public let algorithm: String
    public let keyDerivation: String
    public let iterations: Int
    public let salt: String

    public init(algorithm: String, keyDerivation: String, iterations: Int, salt: String) {
        self.algorithm = algorithm
        self.keyDerivation = keyDerivation
        self.iterations = iterations
        self.salt = salt
    }
}

public struct BackupComponentDescriptor: Codable, Sendable, Equatable {
    public let componentIdentifier: String
    public let componentVersion: Int
    public let entryPath: String

    public init(componentIdentifier: String, componentVersion: Int, entryPath: String) {
        self.componentIdentifier = componentIdentifier
        self.componentVersion = componentVersion
        self.entryPath = entryPath
    }
}

/// Metadata-only attachment model reserved for the future file store. Binary
/// content belongs under an attachments directory, never inside the live DB.
public struct AttachmentMetadata: Codable, Sendable, Equatable {
    public let attachmentID: String
    public let ownerType: String
    public let ownerID: String
    public let filename: String
    public let mediaType: String
    public let relativePath: String
    public let checksum: String

    public init(
        attachmentID: String,
        ownerType: String,
        ownerID: String,
        filename: String,
        mediaType: String,
        relativePath: String,
        checksum: String
    ) {
        self.attachmentID = attachmentID
        self.ownerType = ownerType
        self.ownerID = ownerID
        self.filename = filename
        self.mediaType = mediaType
        self.relativePath = relativePath
        self.checksum = checksum
    }
}

public struct BackupMetadata: Codable, Sendable, Equatable {
    public let backupFormat: String
    public let formatVersion: Int
    public let createdAt: String
    public let appVersion: String
    public let databaseSchemaVersion: Int
    public let content: BackupContent
    public let encryption: BackupEncryptionMetadata
    public let components: [BackupComponentDescriptor]

    public init(
        backupFormat: String,
        formatVersion: Int,
        createdAt: String,
        appVersion: String,
        databaseSchemaVersion: Int,
        content: BackupContent,
        encryption: BackupEncryptionMetadata,
        components: [BackupComponentDescriptor]
    ) {
        self.backupFormat = backupFormat
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.databaseSchemaVersion = databaseSchemaVersion
        self.content = content
        self.encryption = encryption
        self.components = components
    }
}

public struct BackupResult: Codable, Sendable, Equatable {
    public let outputURL: URL
    public let metadata: BackupMetadata
    public let byteCount: Int

    public init(outputURL: URL, metadata: BackupMetadata, byteCount: Int) {
        self.outputURL = outputURL
        self.metadata = metadata
        self.byteCount = byteCount
    }
}

public struct BackupValidationResult: Codable, Sendable, Equatable {
    public let isValid: Bool
    public let metadata: BackupMetadata
    public let studentCount: Int
    public let contactCount: Int
    public let unknownComponents: [String]

    public init(
        isValid: Bool,
        metadata: BackupMetadata,
        studentCount: Int,
        contactCount: Int,
        unknownComponents: [String]
    ) {
        self.isValid = isValid
        self.metadata = metadata
        self.studentCount = studentCount
        self.contactCount = contactCount
        self.unknownComponents = unknownComponents
    }
}

public enum RestoreMode: String, Codable, Hashable, Sendable {
    case replaceCurrentData
}

public struct RestoreResult: Codable, Sendable, Equatable {
    public let metadata: BackupMetadata
    public let safetyCopyURL: URL
    public let studentCount: Int
    public let contactCount: Int
    public let unknownComponents: [String]

    public init(
        metadata: BackupMetadata,
        safetyCopyURL: URL,
        studentCount: Int,
        contactCount: Int,
        unknownComponents: [String]
    ) {
        self.metadata = metadata
        self.safetyCopyURL = safetyCopyURL
        self.studentCount = studentCount
        self.contactCount = contactCount
        self.unknownComponents = unknownComponents
    }
}

public enum BackupError: LocalizedError, Equatable, Sendable {
    case passwordTooShort
    case invalidPackage
    case unsupportedFormatVersion(Int)
    case wrongPassword
    case validationFailed
    case restoreFailed
    case unsupportedModules([String])

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            "备份密码至少需要 8 个字符。"
        case .invalidPackage:
            "备份文件格式无效或内容不完整。"
        case .unsupportedFormatVersion(let version):
            "备份格式版本 " + String(version) + " 暂不受支持。"
        case .wrongPassword:
            "备份密码不正确，或备份文件已损坏。"
        case .validationFailed:
            "备份验证失败；当前数据库未被修改。"
        case .restoreFailed:
            "备份恢复失败；当前数据库应保持不变。"
        case .unsupportedModules(let modules):
            "当前版本暂不支持导出：" + modules.joined(separator: "、") + "。"
        }
    }
}

public struct BackupComponent: Sendable, Equatable {
    public let identifier: String
    public let version: Int
    public let data: Data

    public init(identifier: String, version: Int, data: Data) {
        self.identifier = identifier
        self.version = version
        self.data = data
    }
}

/// Boundary for future independent backup providers. The current release
/// uses the encrypted database as the core component; future modules can add
/// their own entries without changing the package contract.
public protocol BackupComponentProvider: AnyObject {
    var componentIdentifier: String { get }
    var componentVersion: Int { get }
    func prepareBackup() throws -> BackupComponent
    func restore(_ component: BackupComponent) throws
}

public protocol DataBackupService: AnyObject {
    func createBackup(destination: URL, password: String) throws -> BackupResult
    func inspectBackup(at url: URL) throws -> BackupMetadata
    func validateBackup(at url: URL, password: String) throws -> BackupValidationResult
    func restoreBackup(
        from url: URL,
        password: String,
        mode: RestoreMode
    ) throws -> RestoreResult
}

public protocol DataExportSource: AnyObject {
    func studentDetailsForExport(filters: ExportFilters) throws -> [StudentDetails]
}

public protocol DataExportService: AnyObject {
    func exportStudents(
        request: StudentExportRequest,
        destination: URL
    ) throws -> ExportResult
    func exportGrades(
        request: GradeExportRequest,
        destination: URL
    ) throws -> ExportResult
    func exportDataset(
        request: DatasetExportRequest,
        destination: URL
    ) throws -> ExportResult
}
