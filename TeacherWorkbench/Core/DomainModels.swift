import Foundation

public struct StudentSummary: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let className: String?
    public let studentNumber: String?
    public let gender: String?

    public init(
        id: String,
        name: String,
        className: String?,
        studentNumber: String?,
        gender: String? = nil
    ) {
        self.id = id
        self.name = name
        self.className = className
        self.studentNumber = studentNumber
        self.gender = gender
    }
}

public struct StudentDraft: Codable, Sendable, Equatable {
    public var name: String
    public var className: String?
    public var studentNumber: String?
    public var gender: String?
    public var idNumber: String?
    public var primarySchoolName: String?
    public var primarySchoolClass: String?
    public var familyAddress: String?

    public init(
        name: String = "",
        className: String? = nil,
        studentNumber: String? = nil,
        gender: String? = nil,
        idNumber: String? = nil,
        primarySchoolName: String? = nil,
        primarySchoolClass: String? = nil,
        familyAddress: String? = nil
    ) {
        self.name = name
        self.className = className
        self.studentNumber = studentNumber
        self.gender = gender
        self.idNumber = idNumber
        self.primarySchoolName = primarySchoolName
        self.primarySchoolClass = primarySchoolClass
        self.familyAddress = familyAddress
    }
}

public struct StudentDetails: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let className: String?
    public let studentNumber: String?
    public let gender: String?
    public let idNumber: String?
    public let primarySchoolName: String?
    public let primarySchoolClass: String?
    public let familyAddress: String?
    public let contacts: [ParentContact]

    public init(
        id: String,
        name: String,
        className: String?,
        studentNumber: String?,
        gender: String?,
        idNumber: String?,
        primarySchoolName: String?,
        primarySchoolClass: String?,
        familyAddress: String?,
        contacts: [ParentContact]
    ) {
        self.id = id
        self.name = name
        self.className = className
        self.studentNumber = studentNumber
        self.gender = gender
        self.idNumber = idNumber
        self.primarySchoolName = primarySchoolName
        self.primarySchoolClass = primarySchoolClass
        self.familyAddress = familyAddress
        self.contacts = contacts
    }

    public var bestAvailableClassName: String? {
        className
    }
}

public struct ParentContact: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let relation: String?
    public let phone: String?
    public let contactRole: String
    public let contactOrder: Int?
    public let sourceColumn: String?
    public let isPrimary: Bool

    public init(
        id: String,
        name: String?,
        relation: String?,
        phone: String?,
        contactRole: String,
        contactOrder: Int?,
        sourceColumn: String?,
        isPrimary: Bool
    ) {
        self.id = id
        self.name = name
        self.relation = relation
        self.phone = phone
        self.contactRole = contactRole
        self.contactOrder = contactOrder
        self.sourceColumn = sourceColumn
        self.isPrimary = isPrimary
    }

    public var displayName: String {
        name ?? "未命名联系人"
    }

    public var displaySourceLabel: String {
        sourceColumn ?? "联系人"
    }
}

public struct ParentContactDraft: Codable, Sendable, Equatable {
    public var name: String?
    public var relation: String?
    public var phone: String?
    public var contactRole: String
    public var isPrimary: Bool

    public init(
        name: String? = nil,
        relation: String? = nil,
        phone: String? = nil,
        contactRole: String = ContactRole.unknown.rawValue,
        isPrimary: Bool = false
    ) {
        self.name = name
        self.relation = relation
        self.phone = phone
        self.contactRole = contactRole
        self.isPrimary = isPrimary
    }
}

public enum ContactRole: String, CaseIterable, Codable, Hashable, Sendable {
    case parent
    case guardian
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .parent: "家长"
        case .guardian: "监护人"
        case .other: "其他"
        case .unknown: "未分类"
        }
    }
}

/// A normalized student candidate produced by the import layer. It contains
/// only values that are about to be committed, and is never written to logs.
public struct ImportedStudentCandidate: Codable, Sendable, Equatable {
    public let studentID: String?
    public let name: String
    public let className: String?
    public let studentNumber: String?
    public let gender: String?
    public let idNumber: String?
    public let primarySchoolName: String?
    public let primarySchoolClass: String?
    public let familyAddress: String?

    public init(
        studentID: String?,
        name: String,
        className: String?,
        studentNumber: String?,
        gender: String?,
        idNumber: String?,
        primarySchoolName: String?,
        primarySchoolClass: String?,
        familyAddress: String?
    ) {
        self.studentID = studentID
        self.name = name
        self.className = className
        self.studentNumber = studentNumber
        self.gender = gender
        self.idNumber = idNumber
        self.primarySchoolName = primarySchoolName
        self.primarySchoolClass = primarySchoolClass
        self.familyAddress = familyAddress
    }
}

public struct ImportedContactCandidate: Codable, Sendable, Equatable {
    public let parentID: String?
    public let name: String?
    public let relation: String?
    public let phone: String
    public let contactRole: String?
    public let contactOrder: Int?
    public let sourceColumn: String?
    public let isPrimary: Bool?

    public init(
        parentID: String?,
        name: String?,
        relation: String?,
        phone: String,
        contactRole: String?,
        contactOrder: Int?,
        sourceColumn: String?,
        isPrimary: Bool?
    ) {
        self.parentID = parentID
        self.name = name
        self.relation = relation
        self.phone = phone
        self.contactRole = contactRole
        self.contactOrder = contactOrder
        self.sourceColumn = sourceColumn
        self.isPrimary = isPrimary
    }
}

public struct NormalizedImportRow: Codable, Sendable, Equatable {
    public let rowNumber: Int
    public let student: ImportedStudentCandidate
    public let contacts: [ImportedContactCandidate]

    public init(rowNumber: Int, student: ImportedStudentCandidate, contacts: [ImportedContactCandidate]) {
        self.rowNumber = rowNumber
        self.student = student
        self.contacts = contacts
    }
}

public struct ImportResult: Identifiable, Codable, Sendable, Equatable {
    public let importID: String
    public let sourceFilename: String?
    public let sourceHash: String
    public let insertedCount: Int
    public let updatedCount: Int
    public let rejectedCount: Int
    public let reviewedRowNumbers: [Int]

    public init(
        importID: String,
        sourceFilename: String?,
        sourceHash: String,
        insertedCount: Int,
        updatedCount: Int,
        rejectedCount: Int,
        reviewedRowNumbers: [Int] = []
    ) {
        self.importID = importID
        self.sourceFilename = sourceFilename
        self.sourceHash = sourceHash
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.rejectedCount = rejectedCount
        self.reviewedRowNumbers = reviewedRowNumbers
    }

    public var id: String { importID }
}

public struct DatabaseImportRequest: Sendable {
    public let sourceFilename: String?
    public let sourceHash: String
    public let rows: [NormalizedImportRow]
    public let rejectedRowCount: Int

    public init(
        sourceFilename: String?,
        sourceHash: String,
        rows: [NormalizedImportRow],
        rejectedRowCount: Int
    ) {
        self.sourceFilename = sourceFilename
        self.sourceHash = sourceHash
        self.rows = rows
        self.rejectedRowCount = rejectedRowCount
    }
}

public struct ChangeEventRecord: Codable, Sendable, Equatable {
    public let eventID: String
    public let entityType: String
    public let entityID: String
    public let operation: String
    public let beforeJSON: String?
    public let afterJSON: String?
    public let importID: String?
    public let createdAt: String

    public init(
        eventID: String,
        entityType: String,
        entityID: String,
        operation: String,
        beforeJSON: String?,
        afterJSON: String?,
        importID: String?,
        createdAt: String
    ) {
        self.eventID = eventID
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.beforeJSON = beforeJSON
        self.afterJSON = afterJSON
        self.importID = importID
        self.createdAt = createdAt
    }
}
