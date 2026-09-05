import Foundation
import ZIPFoundation

public enum XLSXParser {
    public static func parse(data: Data) throws -> (headers: [String], rows: [[String]], headerRowNumber: Int) {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw ImportError.invalidTableStructure("无法打开 XLSX 压缩包。")
        }

        let sharedStrings = try readSharedStrings(from: archive)
        let workbookData = try readEntry(named: "xl/workbook.xml", from: archive)
        let workbookSheets = try parseWorkbook(workbookData)

        // workbook.xml.rels is required by the normal XLSX format. If a
        // spreadsheet writer emits unusual relationship metadata, worksheet
        // entries discovered directly in the archive provide a safe fallback.
        var relationships: [String: String] = [:]
        if let relationshipsData = try? readEntry(named: "xl/_rels/workbook.xml.rels", from: archive) {
            relationships = (try? parseRelationships(relationshipsData)) ?? [:]
        }

        var worksheetPaths: [String] = []
        for sheet in workbookSheets {
            if let target = relationships[sheet.relationshipID] {
                worksheetPaths.append(normalizedWorksheetPath(target))
            }
        }

        for entry in archive {
            if entry.path.hasPrefix("xl/worksheets/") && entry.path.hasSuffix(".xml") {
                worksheetPaths.append(entry.path)
            }
        }

        var seenPaths = Set<String>()
        var fallbackTable: (headers: [String], rows: [[String]], headerRowNumber: Int)?
        var bestFallbackScore = Int.min
        var lastError: Error?

        for worksheetPath in worksheetPaths where seenPaths.insert(worksheetPath).inserted {
            do {
                let worksheetData = try readEntry(named: worksheetPath, from: archive)
                let worksheet = try parseWorksheet(worksheetData, sharedStrings: sharedStrings)
                guard let table = try normalizeTable(worksheet.rows, rowNumbers: worksheet.rowNumbers) else { continue }

                // A workbook can contain an empty cover sheet before the real
                // data sheet. Prefer the first worksheet that resembles a
                // student table, while retaining a non-empty fallback.
                let score = score(for: table)
                if score > bestFallbackScore {
                    fallbackTable = table
                    bestFallbackScore = score
                }
                if isLikelyStudentTable(headers: table.headers) {
                    return table
                }
            } catch {
                lastError = error
            }
        }

        if let fallbackTable {
            return fallbackTable
        }
        if let lastError as ImportError {
            throw lastError
        }
        throw ImportError.invalidTableStructure("XLSX 文件中没有可读取的工作表。")
    }

    private static func normalizeTable(
        _ rows: [[String]],
        rowNumbers: [Int]
    ) throws -> (headers: [String], rows: [[String]], headerRowNumber: Int)? {
        guard !rows.isEmpty else { return nil }

        var firstNonEmptyHeader: (index: Int, headers: [String])?
        let searchLimit = min(rows.count, 20)
        for index in 0..<searchLimit {
            let headers = rows[index].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard headers.contains(where: { !$0.isEmpty }) else { continue }
            if firstNonEmptyHeader == nil {
                firstNonEmptyHeader = (index, headers)
            }

            // Excel files often contain a merged title row above the actual
            // header. Locate the first recognizable student-table header.
            if isLikelyStudentTable(headers: headers) {
                return try makeTable(
                    rows: rows,
                    rowNumbers: rowNumbers,
                    headerIndex: index,
                    headers: headers
                )
            }
        }

        guard let firstNonEmptyHeader else { return nil }
        return try makeTable(
            rows: rows,
            rowNumbers: rowNumbers,
            headerIndex: firstNonEmptyHeader.index,
            headers: firstNonEmptyHeader.headers
        )
    }

    private static func makeTable(
        rows: [[String]],
        rowNumbers: [Int],
        headerIndex: Int,
        headers: [String]
    ) throws -> (headers: [String], rows: [[String]], headerRowNumber: Int) {
        guard headers.count == Set(headers.filter { !$0.isEmpty }).count else {
            throw ImportError.invalidTableStructure("表头名称重复。")
        }

        var normalizedRows: [[String]] = []
        for row in rows.dropFirst(headerIndex + 1) {
            if row.allSatisfy({ ValueNormalizer.optionalText($0) == nil }) {
                continue
            }
            if row.count > headers.count {
                throw ImportError.invalidTableStructure("数据行的列数超过表头列数。")
            }
            normalizedRows.append(row + Array(repeating: "", count: max(headers.count - row.count, 0)))
        }
        let headerRowNumber = rowNumbers.indices.contains(headerIndex) ? rowNumbers[headerIndex] : headerIndex + 1
        return (headers, normalizedRows, headerRowNumber)
    }

    private static func isLikelyStudentTable(headers: [String]) -> Bool {
        let normalized = Set(headers.map(ValueNormalizer.normalizedHeader))
        let nameAliases = ["学生姓名", "姓名", "学生", "姓名（学生）", "name"]
        let identityAliases = [
            "学号", "学籍号", "学生学号", "编号", "学生编号", "联系方式", "联系方式一", "联系方式二",
            "联系电话", "家长联系电话", "监护人电话", "手机号", "手机号码", "家长手机号",
            "班级", "年级班级", "小学班级", "家庭地址", "身份证", "身份证号", "身份证号码"
        ]
        let hasName = nameAliases.contains { normalized.contains(ValueNormalizer.normalizedHeader($0)) }
        let hasIdentity = identityAliases.contains { normalized.contains(ValueNormalizer.normalizedHeader($0)) }
        return hasName && hasIdentity
    }

    private static func score(
        for table: (headers: [String], rows: [[String]], headerRowNumber: Int)
    ) -> Int {
        let normalizedHeaders = Set(table.headers.map(ValueNormalizer.normalizedHeader))
        let recognizedHeaders = ImportAliasDictionary.defaultAliases.values
            .flatMap { $0 }
            .map(ValueNormalizer.normalizedHeader)
            .filter { normalizedHeaders.contains($0) }
            .count
        let populatedRowCount = table.rows.reduce(into: 0) { count, row in
            if row.contains(where: { ValueNormalizer.optionalText($0) != nil }) {
                count += 1
            }
        }
        return recognizedHeaders * 1_000 + min(populatedRowCount, 100) * 10 + min(table.headers.count, 50)
    }

    private static func readEntry(named path: String, from archive: Archive) throws -> Data {
        guard let entry = archive[path] else {
            throw ImportError.invalidTableStructure("XLSX 内部文件缺失。")
        }
        var data = Data()
        do {
            try archive.extract(entry, consumer: { chunk in
                data.append(chunk)
            })
        } catch {
            throw ImportError.invalidTableStructure("XLSX 内部文件无法读取。")
        }
        return data
    }

    private static func readSharedStrings(from archive: Archive) throws -> [String] {
        guard archive["xl/sharedStrings.xml"] != nil else { return [] }
        let data = try readEntry(named: "xl/sharedStrings.xml", from: archive)
        return try SharedStringsXMLParser.parse(data: data)
    }

    private static func parseWorkbook(_ data: Data) throws -> [WorkbookSheet] {
        try WorkbookXMLParser.parse(data: data)
    }

    private static func parseRelationships(_ data: Data) throws -> [String: String] {
        try RelationshipsXMLParser.parse(data: data)
    }

    private static func normalizedWorksheetPath(_ target: String) -> String {
        let cleaned = target.replacingOccurrences(of: "\\", with: "/")
        let rooted = cleaned.hasPrefix("/")
            ? String(cleaned.dropFirst())
            : (cleaned.hasPrefix("xl/") ? cleaned : "xl/\(cleaned)")

        var components: [String] = []
        for component in rooted.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    private static func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init) ?? value
    }

    private static func attribute(named name: String, in attributes: [String: String]) -> String? {
        if let direct = attributes[name] { return direct }
        let local = localName(name)
        return attributes.first(where: { localName($0.key) == local })?.value
    }

    private struct WorkbookSheet {
        let relationshipID: String
    }

    private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
        private var values: [String] = []
        private var currentString = ""
        private var isInsideSharedString = false
        private var isInsideText = false

        static func parse(data: Data) throws -> [String] {
            let delegate = SharedStringsXMLParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse() else {
                throw ImportError.invalidTableStructure("XLSX 共享字符串结构无效。")
            }
            return delegate.values
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch XLSXParser.localName(elementName) {
            case "si":
                isInsideSharedString = true
                currentString = ""
            case "t":
                if isInsideSharedString { isInsideText = true }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideText { currentString.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch XLSXParser.localName(elementName) {
            case "t": isInsideText = false
            case "si":
                values.append(currentString)
                isInsideSharedString = false
            default:
                break
            }
        }
    }

    private final class WorkbookXMLParser: NSObject, XMLParserDelegate {
        private var sheets: [WorkbookSheet] = []

        static func parse(data: Data) throws -> [WorkbookSheet] {
            let delegate = WorkbookXMLParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse(), !delegate.sheets.isEmpty else {
                throw ImportError.invalidTableStructure("XLSX 工作簿中没有可用的工作表。")
            }
            return delegate.sheets
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard XLSXParser.localName(elementName) == "sheet" else { return }
            if let relationshipID = XLSXParser.attribute(named: "r:id", in: attributeDict)
                ?? XLSXParser.attribute(named: "id", in: attributeDict) {
                sheets.append(WorkbookSheet(relationshipID: relationshipID))
            }
        }
    }

    private final class RelationshipsXMLParser: NSObject, XMLParserDelegate {
        private var relationships: [String: String] = [:]

        static func parse(data: Data) throws -> [String: String] {
            let delegate = RelationshipsXMLParser()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            guard parser.parse(), !delegate.relationships.isEmpty else {
                throw ImportError.invalidTableStructure("XLSX 工作表关系结构无效。")
            }
            return delegate.relationships
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard XLSXParser.localName(elementName) == "Relationship" else { return }
            let id = XLSXParser.attribute(named: "Id", in: attributeDict)
            let target = XLSXParser.attribute(named: "Target", in: attributeDict)
            if let id, let target { relationships[id] = target }
        }
    }

    private final class WorksheetXMLParser: NSObject, XMLParserDelegate {
        fileprivate var rows: [[Int: String]] = []
        fileprivate var rowNumbers: [Int] = []
        private var currentRow: [Int: String]?
        private var currentRowNumber: Int?
        private var currentColumn: Int?
        private var currentType: String?
        private var currentCellValue = ""
        private var isReadingCellValue = false

        fileprivate var typesForRows: [Int: [Int: String]] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch XLSXParser.localName(elementName) {
            case "row":
                currentRow = [:]
                currentRowNumber = XLSXParser.attribute(named: "r", in: attributeDict).flatMap(Int.init)
            case "c":
                if let reference = XLSXParser.attribute(named: "r", in: attributeDict),
                   let column = Self.columnIndex(from: reference) {
                    currentColumn = column
                    currentType = XLSXParser.attribute(named: "t", in: attributeDict)
                    currentCellValue = ""
                }
            case "v", "t":
                if currentColumn != nil { isReadingCellValue = true }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isReadingCellValue { currentCellValue.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch XLSXParser.localName(elementName) {
            case "v", "t":
                isReadingCellValue = false
            case "c":
                if let column = currentColumn {
                    currentRow?[column] = currentCellValue
                    if let type = currentType {
                        let rowIndex = rows.count
                        typesForRows[rowIndex, default: [:]][column] = type
                    }
                }
                currentColumn = nil
                currentType = nil
                currentCellValue = ""
            case "row":
                if let currentRow {
                    rows.append(currentRow)
                    rowNumbers.append(currentRowNumber ?? rows.count)
                }
                currentRow = nil
                currentRowNumber = nil
            default:
                break
            }
        }

        private static func columnIndex(from reference: String) -> Int? {
            var value = 0
            var foundLetter = false
            for scalar in reference.unicodeScalars {
                guard (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122) else {
                    break
                }
                foundLetter = true
                let uppercase = scalar.value >= 97 ? scalar.value - 32 : scalar.value
                value = value * 26 + Int(uppercase - 64)
            }
            return foundLetter ? value - 1 : nil
        }
    }

    private static func parseWorksheet(
        _ data: Data,
        sharedStrings: [String]
    ) throws -> (rows: [[String]], rowNumbers: [Int]) {
        let delegate = WorksheetXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ImportError.invalidTableStructure("XLSX 工作表内容结构无效。")
        }

        let maxColumn = delegate.rows.flatMap { $0.keys }.max() ?? -1
        guard maxColumn >= 0 else { return ([], []) }
        let rows = delegate.rows.enumerated().map { rowIndex, row in
            (0...maxColumn).map { column in
                guard let raw = row[column] else { return "" }
                let type = delegate.typesForRows[rowIndex]?[column]
                if type == "s", let sharedIndex = Int(raw), sharedStrings.indices.contains(sharedIndex) {
                    return sharedStrings[sharedIndex]
                }
                if type == "b" { return raw == "1" ? "是" : "否" }
                return raw
            }
        }
        return (rows, delegate.rowNumbers)
    }
}
