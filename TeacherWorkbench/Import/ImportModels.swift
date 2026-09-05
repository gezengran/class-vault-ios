import Foundation

public enum CanonicalImportField: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case studentID
    case name
    case className
    case studentNumber
    case gender
    case idNumber
    case primarySchoolName
    case primarySchoolClass
    case familyAddress
    case parentID
    case parentName
    case relation
    case phone
    case contactRole
    case isPrimary

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .studentID: "学生内部ID"
        case .name: "学生姓名"
        case .className: "当前班级"
        case .studentNumber: "学号"
        case .gender: "性别"
        case .idNumber: "身份证号"
        case .primarySchoolName: "毕业学校名称"
        case .primarySchoolClass: "小学班级"
        case .familyAddress: "家庭地址"
        case .parentID: "联系人内部ID"
        case .parentName: "家长姓名"
        case .relation: "关系"
        case .phone: "电话号码"
        case .contactRole: "联系人类型"
        case .isPrimary: "主要联系人"
        }
    }

    public var isStudentField: Bool {
        switch self {
        case .parentID, .parentName, .relation, .phone, .contactRole, .isPrimary:
            false
        default:
            true
        }
    }

    public var isOptional: Bool {
        switch self {
        case .name, .studentNumber, .phone:
            false
        default:
            true
        }
    }
}

public struct ImportMapping: Codable, Equatable, Sendable {
    public var sourceToCanonical: [String: CanonicalImportField]

    public init(sourceToCanonical: [String: CanonicalImportField] = [:]) {
        self.sourceToCanonical = sourceToCanonical
    }

    public func field(for sourceColumn: String) -> CanonicalImportField? {
        sourceToCanonical[sourceColumn]
    }

    public mutating func set(_ field: CanonicalImportField?, for sourceColumn: String) {
        if let field {
            sourceToCanonical[sourceColumn] = field
        } else {
            sourceToCanonical.removeValue(forKey: sourceColumn)
        }
    }

    public func sourceColumns(for field: CanonicalImportField) -> [String] {
        sourceToCanonical
            .filter { $0.value == field }
            .map(\.key)
            .sorted()
    }
}

public struct ImportAliasDictionary: Sendable {
    public var aliases: [CanonicalImportField: [String]]

    public init(aliases: [CanonicalImportField: [String]]? = nil) {
        self.aliases = aliases ?? Self.defaultAliases
    }

    public func proposedMapping(for headers: [String]) -> ImportMapping {
        var mapping = ImportMapping()
        for header in headers {
            let normalized = ValueNormalizer.normalizedHeader(header)
            let matches = aliases.filter { _, values in
                values.contains { ValueNormalizer.normalizedHeader($0) == normalized }
            }.map(\.key)
            if matches.count == 1, let field = matches.first {
                mapping.set(field, for: header)
            }
        }
        return mapping
    }

    public static let defaultAliases: [CanonicalImportField: [String]] = [
        .studentID: ["student_id", "学生ID", "学生标识", "学生内部ID"],
        .name: ["学生姓名", "姓名", "学生", "name"],
        .className: ["班级", "行政班", "所在班级", "当前班级", "年级班级", "班级名称", "class", "class_name"],
        .studentNumber: ["学号", "学籍号", "学生学号", "编号", "学生编号", "student number", "student_number"],
        .gender: ["性别", "gender"],
        .idNumber: ["身份证", "身份证号", "身份证号码", "证件号", "证件号码", "id number", "id_number"],
        .primarySchoolName: ["毕业学校名称", "毕业学校", "毕业小学", "小学学校", "小学毕业学校", "primary school", "primary_school_name"],
        .primarySchoolClass: ["小学班级", "小学毕业班级", "毕业班级", "primary school class", "primary_school_class"],
        .familyAddress: ["家庭地址", "家庭住址", "住址", "家庭地址（现）", "family address", "family_address"],
        .parentID: ["parent_id", "家长ID", "联系人ID", "监护人ID"],
        .parentName: ["家长姓名", "联系人", "监护人", "联系人姓名", "parent name", "parent_name"],
        .relation: ["关系", "家长关系", "联系人关系", "relation"],
        .phone: ["家长电话", "家长联系电话", "监护人电话", "家长手机号", "联系电话", "手机号", "手机号码", "联系方式", "电话", "phone", "联系方式一", "联系方式二", "联系方式1", "联系方式2"],
        .contactRole: ["联系人类型", "联系人角色", "contact role", "contact_role"],
        .isPrimary: ["是否主要联系人", "主要联系人", "是否主联系人", "is primary", "is_primary"]
    ]
}

public struct ParsedImportDocument: Sendable {
    public let sourceFilename: String?
    public let sourceHash: String
    public let headers: [String]
    public let rows: [[String]]
    public let headerRowNumber: Int

    public init(
        sourceFilename: String?,
        sourceHash: String,
        headers: [String],
        rows: [[String]],
        headerRowNumber: Int = 1
    ) {
        self.sourceFilename = sourceFilename
        self.sourceHash = sourceHash
        self.headers = headers
        self.rows = rows
        self.headerRowNumber = max(headerRowNumber, 1)
    }

    public var sampleRows: [[String]] {
        Array(rows.prefix(5))
    }
}

public enum ImportIssueSeverity: String, Codable, Hashable, Sendable {
    case error
    case warning
}

public struct ImportIssue: Identifiable, Codable, Hashable, Sendable {
    public let rowNumber: Int?
    public let code: String
    public let message: String
    public let severity: ImportIssueSeverity

    public init(rowNumber: Int?, code: String, message: String, severity: ImportIssueSeverity = .error) {
        self.rowNumber = rowNumber
        self.code = code
        self.message = message
        self.severity = severity
    }

    public var id: String {
        "\(rowNumber.map { String($0) } ?? "header")-\(code)-\(message)"
    }

    public var isBlocking: Bool {
        severity == .error
    }
}

public struct ImportPreview: Identifiable, Sendable {
    public let id: String
    public let document: ParsedImportDocument
    public let mapping: ImportMapping
    public let acceptedRows: [NormalizedImportRow]
    public let issues: [ImportIssue]
    public let strictMatching: Bool

    public init(
        document: ParsedImportDocument,
        mapping: ImportMapping,
        acceptedRows: [NormalizedImportRow],
        issues: [ImportIssue],
        strictMatching: Bool
    ) {
        self.id = document.sourceHash
        self.document = document
        self.mapping = mapping
        self.acceptedRows = acceptedRows
        self.issues = issues
        self.strictMatching = strictMatching
    }

    public var rejectedRowNumbers: [Int] {
        Array(Set(issues.compactMap(\.rowNumber))).sorted()
    }

    public var rejectedRowCount: Int { rejectedRowNumbers.count }

    public var hasBlockingMappingIssue: Bool {
        issues.contains { $0.rowNumber == nil && $0.isBlocking }
    }

    public var canCommit: Bool {
        !acceptedRows.isEmpty && !hasBlockingMappingIssue
    }

    public func addingIssues(_ additionalIssues: [ImportIssue]) -> ImportPreview {
        guard !additionalIssues.isEmpty else { return self }
        let allIssues = issues + additionalIssues
        let rejectedRows = Set(additionalIssues.compactMap(\.rowNumber))
        return ImportPreview(
            document: document,
            mapping: mapping,
            acceptedRows: acceptedRows.filter { !rejectedRows.contains($0.rowNumber) },
            issues: allIssues,
            strictMatching: strictMatching
        )
    }
}

public enum ImportError: LocalizedError, Equatable, Sendable {
    case unsupportedFileType
    case unreadableFile
    case emptyTable
    case invalidTableStructure(String)
    case cannotCommitPreview

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType: "仅支持 CSV 和 XLSX 文件。"
        case .unreadableFile: "所选文件无法读取。"
        case .emptyTable: "所选文件不包含有效表头。"
        case .invalidTableStructure(let reason): "表格结构无法识别：\(reason)"
        case .cannotCommitPreview: "导入预览中存在阻塞性的字段映射问题。"
        }
    }
}
