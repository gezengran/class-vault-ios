import Foundation

public enum ValueNormalizer {
    private static let nullPlaceholders: Set<String> = [
        "-", "—", "无", "未填写", "未录入", "暂无", "未知", "空", "/", "--",
        "n/a", "na", "null", "nil"
    ]

    public static func optionalText(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.replacingOccurrences(of: "\u{FEFF}", with: "")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if nullPlaceholders.contains(value.lowercased()) { return nil }
        return value
    }

    public static func normalizedHeader(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    public static func normalizedMatchValue(_ value: String?) -> String? {
        optionalText(value)?.lowercased()
    }

    public static func parseBoolean(_ value: String?) -> Bool? {
        guard let value = optionalText(value)?.lowercased() else { return nil }
        switch value {
        case "1", "true", "yes", "y", "是", "有", "主要", "主联系人":
            return true
        case "0", "false", "no", "n", "否", "无", "非主要":
            return false
        default:
            return nil
        }
    }
}
