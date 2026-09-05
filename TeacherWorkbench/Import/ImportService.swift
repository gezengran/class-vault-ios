import CryptoKit
import Foundation

public struct ImportService: Sendable {
    public let aliasDictionary: ImportAliasDictionary

    public init(aliasDictionary: ImportAliasDictionary = ImportAliasDictionary()) {
        self.aliasDictionary = aliasDictionary
    }

    public func load(url: URL) throws -> ParsedImportDocument {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImportError.unreadableFile
        }

        let table: (headers: [String], rows: [[String]], headerRowNumber: Int)
        switch url.pathExtension.lowercased() {
        case "csv":
            table = try CSVParser.parse(data: data)
        case "xlsx":
            table = try XLSXParser.parse(data: data)
        default:
            throw ImportError.unsupportedFileType
        }

        return ParsedImportDocument(
            sourceFilename: url.lastPathComponent,
            sourceHash: Self.sha256Hex(data),
            headers: table.headers,
            rows: table.rows,
            headerRowNumber: table.headerRowNumber
        )
    }

    public func buildPreview(
        from document: ParsedImportDocument,
        mapping suppliedMapping: ImportMapping? = nil,
        strictMatching: Bool
    ) -> ImportPreview {
        let mapping = suppliedMapping ?? aliasDictionary.proposedMapping(for: document.headers)
        var issues = mappingIssues(mapping: mapping, headers: document.headers)
        var candidates: [NormalizedImportRow] = []

        for (offset, values) in document.rows.enumerated() {
            let rowNumber = document.headerRowNumber + offset + 1
            var rowIssues: [ImportIssue] = []

            guard let name = value(for: .name, headers: document.headers, values: values, mapping: mapping) else {
                rowIssues.append(ImportIssue(rowNumber: rowNumber, code: "missing_name", message: "缺少学生姓名。"))
                issues.append(contentsOf: rowIssues)
                continue
            }

            let studentNumber = value(for: .studentNumber, headers: document.headers, values: values, mapping: mapping)
            let studentID = value(for: .studentID, headers: document.headers, values: values, mapping: mapping)
            let className = value(for: .className, headers: document.headers, values: values, mapping: mapping)
            let primarySchoolClass = value(for: .primarySchoolClass, headers: document.headers, values: values, mapping: mapping)

            if strictMatching, studentNumber == nil {
                rowIssues.append(ImportIssue(rowNumber: rowNumber, code: "missing_student_number", message: "严格学号匹配模式下必须填写学号。"))
            }
            if studentNumber == nil && studentID == nil && className == nil && primarySchoolClass == nil {
                rowIssues.append(ImportIssue(rowNumber: rowNumber, code: "manual_review", message: "没有可确定匹配的字段，需要人工复核。"))
            }

            let phoneColumns = document.headers.filter { mapping.field(for: $0) == .phone }
            var contacts: [ImportedContactCandidate] = []
            let parentName = value(for: .parentName, headers: document.headers, values: values, mapping: mapping)
            let relation = value(for: .relation, headers: document.headers, values: values, mapping: mapping)
            let contactRole = value(for: .contactRole, headers: document.headers, values: values, mapping: mapping)
            let isPrimary = ValueNormalizer.parseBoolean(value(for: .isPrimary, headers: document.headers, values: values, mapping: mapping))

            for (index, column) in phoneColumns.enumerated() {
                guard let rawPhone = value(forColumn: column, headers: document.headers, values: values) else {
                    continue
                }
                do {
                    let phone = try PhoneNumberNormalizer.normalize(rawPhone)
                    contacts.append(
                        ImportedContactCandidate(
                            parentID: value(for: .parentID, headers: document.headers, values: values, mapping: mapping),
                            name: parentName,
                            relation: relation,
                            phone: phone,
                            contactRole: contactRole,
                            contactOrder: contactOrder(for: column, fallback: index + 1),
                            sourceColumn: column,
                            isPrimary: isPrimary
                        )
                    )
                } catch {
                    rowIssues.append(ImportIssue(rowNumber: rowNumber, code: "invalid_phone", message: "第 \(column) 列的电话号码格式无效或可疑。"))
                }
            }

            issues.append(contentsOf: rowIssues)
            candidates.append(
                NormalizedImportRow(
                    rowNumber: rowNumber,
                    student: ImportedStudentCandidate(
                        studentID: studentID,
                        name: name,
                        className: className,
                        studentNumber: studentNumber,
                        gender: value(for: .gender, headers: document.headers, values: values, mapping: mapping),
                        idNumber: value(for: .idNumber, headers: document.headers, values: values, mapping: mapping),
                        primarySchoolName: value(for: .primarySchoolName, headers: document.headers, values: values, mapping: mapping),
                        primarySchoolClass: primarySchoolClass,
                        familyAddress: value(for: .familyAddress, headers: document.headers, values: values, mapping: mapping)
                    ),
                    contacts: contacts
                )
            )
        }

        addDuplicateIssues(to: &issues, candidates: candidates)
        let rejectedRows = Set(issues.compactMap(\.rowNumber).filter { row in
            issues.contains { $0.rowNumber == row && $0.isBlocking }
        })
        let acceptedRows = candidates.filter { !rejectedRows.contains($0.rowNumber) }

        return ImportPreview(
            document: document,
            mapping: mapping,
            acceptedRows: acceptedRows,
            issues: issues,
            strictMatching: strictMatching
        )
    }

    private func mappingIssues(mapping: ImportMapping, headers: [String]) -> [ImportIssue] {
        var issues: [ImportIssue] = []
        if mapping.sourceColumns(for: .name).isEmpty {
            issues.append(ImportIssue(rowNumber: nil, code: "missing_name_mapping", message: "请将一个源数据列映射为学生姓名。"))
        }

        let fieldsThatAllowMultiple: Set<CanonicalImportField> = [.phone]
        for field in CanonicalImportField.allCases where !fieldsThatAllowMultiple.contains(field) {
            let count = mapping.sourceColumns(for: field).count
            if count > 1 {
                issues.append(ImportIssue(rowNumber: nil, code: "ambiguous_mapping", message: "字段“\(field.displayName)”只能映射一个源数据列。"))
            }
        }

        let mappedHeaders = Set(mapping.sourceToCanonical.keys)
        for header in headers where !mappedHeaders.contains(header) {
            issues.append(ImportIssue(rowNumber: nil, code: "unmapped_column", message: "源数据列“\(header)”未映射，导入时将忽略。", severity: .warning))
        }
        return issues
    }

    private func value(
        for field: CanonicalImportField,
        headers: [String],
        values: [String],
        mapping: ImportMapping
    ) -> String? {
        guard let column = headers.first(where: { mapping.field(for: $0) == field }) else { return nil }
        return value(forColumn: column, headers: headers, values: values)
    }

    private func value(forColumn column: String, headers: [String], values: [String]) -> String? {
        guard let index = headers.firstIndex(of: column), values.indices.contains(index) else { return nil }
        return ValueNormalizer.optionalText(values[index])
    }

    private func addDuplicateIssues(to issues: inout [ImportIssue], candidates: [NormalizedImportRow]) {
        var groups: [String: [NormalizedImportRow]] = [:]
        for candidate in candidates {
            if let number = ValueNormalizer.normalizedMatchValue(candidate.student.studentNumber) {
                groups["student-number:\(number)", default: []].append(candidate)
            } else if let studentID = ValueNormalizer.normalizedMatchValue(candidate.student.studentID) {
                groups["student-id:\(studentID)", default: []].append(candidate)
            } else if let classValue = candidate.student.className ?? candidate.student.primarySchoolClass,
                      let name = ValueNormalizer.normalizedMatchValue(candidate.student.name) {
                let classKind = candidate.student.className == nil ? "primary" : "current"
                groups["name-class:\(name)|\(ValueNormalizer.normalizedMatchValue(classValue) ?? "")|\(classKind)", default: []].append(candidate)
            }
        }

        for (key, rows) in groups where rows.count > 1 {
            if key.hasPrefix("name-class:") {
                for row in rows {
                    issues.append(ImportIssue(
                        rowNumber: row.rowNumber,
                        code: "ambiguous_duplicate",
                        message: "多行记录的姓名和班级相同，且没有更强的唯一标识，需要人工复核。"
                    ))
                }
                continue
            }

            let payloads = Set(rows.map(conflictSignature))
            if payloads.count > 1 {
                for row in rows {
                    issues.append(ImportIssue(rowNumber: row.rowNumber, code: "conflicting_duplicate", message: "重复学生标识对应的字段内容相互冲突。"))
                }
            } else {
                for row in rows.dropFirst() {
                    issues.append(ImportIssue(rowNumber: row.rowNumber, code: "duplicate_row", message: "发现重复学生行，只使用第一行记录。"))
                }
            }
        }
    }

    private func conflictSignature(_ row: NormalizedImportRow) -> String {
        let student = row.student
        let studentValues = [
            student.studentID,
            student.name,
            student.className,
            student.studentNumber,
            student.gender,
            student.idNumber,
            student.primarySchoolName,
            student.primarySchoolClass,
            student.familyAddress
        ]
        let contactValues = row.contacts.map { contact in
            [
                contact.parentID,
                contact.name,
                contact.relation,
                contact.phone,
                contact.contactRole,
                contact.contactOrder.map { String($0) },
                contact.sourceColumn,
                contact.isPrimary.map { $0 ? "1" : "0" }
            ].map { $0 ?? "" }.joined(separator: "\u{1F}")
        }
        return (studentValues.map { $0 ?? "" } + contactValues).joined(separator: "\u{1E}")
    }

    private func contactOrder(for column: String, fallback: Int) -> Int {
        let normalized = ValueNormalizer.normalizedHeader(column)
        if normalized.contains("一") || normalized.hasSuffix("1") { return 1 }
        if normalized.contains("二") || normalized.hasSuffix("2") { return 2 }
        return fallback
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
