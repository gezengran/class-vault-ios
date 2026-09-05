import Foundation
import OSLog

public final class SafeLogger: @unchecked Sendable {
    public static let shared = SafeLogger()

    private let logger = Logger(subsystem: "com.example.TeacherWorkbench", category: "privacy")
    private let sink: ((String) -> Void)?

    public init(sink: ((String) -> Void)? = nil) {
        self.sink = sink
    }

    public func record(
        operation: String,
        rowCount: Int? = nil,
        insertedCount: Int? = nil,
        updatedCount: Int? = nil,
        rejectedCount: Int? = nil,
        importID: String? = nil,
        sourceHash: String? = nil,
        errorCategory: String? = nil
    ) {
        let message = Self.safeMessage(
            operation: operation,
            rowCount: rowCount,
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            rejectedCount: rejectedCount,
            importID: importID,
            sourceHash: sourceHash,
            errorCategory: errorCategory
        )
        sink?(message)
        logger.info("\(message, privacy: .public)")
    }

    public static func safeMessage(
        operation: String,
        rowCount: Int? = nil,
        insertedCount: Int? = nil,
        updatedCount: Int? = nil,
        rejectedCount: Int? = nil,
        importID: String? = nil,
        sourceHash: String? = nil,
        errorCategory: String? = nil
    ) -> String {
        var fields = ["operation=\(operation)"]
        if let rowCount { fields.append("rows=\(rowCount)") }
        if let insertedCount { fields.append("inserted=\(insertedCount)") }
        if let updatedCount { fields.append("updated=\(updatedCount)") }
        if let rejectedCount { fields.append("rejected=\(rejectedCount)") }
        if let importID { fields.append("import_id=\(importID)") }
        if let sourceHash { fields.append("source_hash=\(sourceHash)") }
        if let errorCategory { fields.append("error_category=\(errorCategory)") }
        return fields.joined(separator: " ")
    }
}
