import Foundation

public enum CSVParser {
    public static func parse(data: Data) throws -> (headers: [String], rows: [[String]], headerRowNumber: Int) {
        guard let text = decode(data) else {
            throw ImportError.unreadableFile
        }
        let records = try parseRecords(text)
        guard let first = records.first, !first.isEmpty else {
            throw ImportError.emptyTable
        }

        let headers = first.map { $0.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard headers.contains(where: { !$0.isEmpty }) else {
            throw ImportError.emptyTable
        }
        guard headers.count == Set(headers.filter { !$0.isEmpty }).count else {
            throw ImportError.invalidTableStructure("表头名称重复。")
        }

        var rows: [[String]] = []
        rows.reserveCapacity(max(records.count - 1, 0))
        for record in records.dropFirst() {
            if record.allSatisfy({ ValueNormalizer.optionalText($0) == nil }) {
                continue
            }
            if record.count > headers.count {
                throw ImportError.invalidTableStructure("数据行的列数超过表头列数。")
            }
            rows.append(record + Array(repeating: "", count: max(headers.count - record.count, 0)))
        }
        return (headers, rows, 1)
    }

    private static func decode(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8) {
            return value
        }
        if let value = String(data: data, encoding: .utf16) {
            return value
        }
        if let value = String(data: data, encoding: .unicode) {
            return value
        }
        return nil
    }

    private static func parseRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var characters = Array(text)
        characters.append("\n")
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    record.append(field)
                    field = ""
                case "\n":
                    if field.last == "\r" {
                        field.removeLast()
                    }
                    record.append(field)
                    field = ""
                    if !(record.count == 1 && record[0].isEmpty) {
                        records.append(record)
                    }
                    record = []
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        if inQuotes {
            throw ImportError.invalidTableStructure("CSV 引号没有正确闭合。")
        }
        return records
    }
}
