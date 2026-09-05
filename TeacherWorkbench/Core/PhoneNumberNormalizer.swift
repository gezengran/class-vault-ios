import Foundation

public enum PhoneNumberError: LocalizedError, Equatable, Sendable {
    case empty
    case invalidCharacters
    case invalidLength
    case suspiciousFormat

    public var errorDescription: String? {
        switch self {
        case .empty: "电话号码为空。"
        case .invalidCharacters: "电话号码包含不支持的字符。"
        case .invalidLength: "电话号码长度不合理。"
        case .suspiciousFormat: "电话号码格式可疑。"
        }
    }
}

public enum PhoneNumberNormalizer {
    /// Normalizes common Chinese mobile/landline input while retaining an
    /// international '+' prefix. The normalized value is also safe to use in
    /// a `tel:` URL; no contact data is logged by this type.
    public static func normalize(_ raw: String) throws -> String {
        guard let trimmed = ValueNormalizer.optionalText(raw) else {
            throw PhoneNumberError.empty
        }

        let fullWidthNormalized = trimmed.replacingOccurrences(of: "＋", with: "+")
        let allowed = CharacterSet(charactersIn: "0123456789+ -().")
        guard fullWidthNormalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PhoneNumberError.invalidCharacters
        }

        let hasPlus = fullWidthNormalized.first == "+"
        let hasUnexpectedPlus = fullWidthNormalized.dropFirst().contains("+")
        guard !hasUnexpectedPlus else { throw PhoneNumberError.invalidCharacters }

        var digits = fullWidthNormalized.filter { $0.isNumber }
        if fullWidthNormalized.hasPrefix("00") {
            digits = String(digits.dropFirst(2))
        }

        if !hasPlus, digits.hasPrefix("86"), digits.count == 13 {
            return try validateInternational("+\(digits)")
        }

        if fullWidthNormalized.hasPrefix("0086") {
            return try validateInternational("+86\(digits.dropFirst(2))")
        }

        if hasPlus {
            return try validateInternational("+\(digits)")
        }

        guard digits.count >= 7, digits.count <= 15 else {
            throw PhoneNumberError.invalidLength
        }

        if digits.count == 11 {
            guard digits.first == "1", let second = digits.dropFirst().first, ("3"..."9").contains(second) else {
                throw PhoneNumberError.suspiciousFormat
            }
        }
        return digits
    }

    public static func validNormalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return try? normalize(raw)
    }

    public static func telURL(_ raw: String) -> URL? {
        guard let normalized = try? normalize(raw) else { return nil }
        return URL(string: "tel:\(normalized)")
    }

    private static func validateInternational(_ value: String) throws -> String {
        let digits = value.filter { $0.isNumber }
        guard digits.count >= 7, digits.count <= 15 else {
            throw PhoneNumberError.invalidLength
        }
        return value
    }
}
