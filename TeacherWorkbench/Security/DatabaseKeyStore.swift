import Foundation
import Security

public protocol DatabaseKeyStore: AnyObject {
    func loadOrCreateKey() throws -> Data
}

public enum DatabaseKeyStoreError: LocalizedError, Equatable, Sendable {
    case keychainReadFailed(OSStatus)
    case keyGenerationFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidKeyLength

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed: "无法从 Keychain 读取数据库密钥。"
        case .keyGenerationFailed: "无法生成安全的数据库密钥。"
        case .keychainWriteFailed: "无法将数据库密钥保存到 Keychain。"
        case .invalidKeyLength: "Keychain 中的数据库密钥长度无效。"
        }
    }
}

public final class KeychainDatabaseKeyStore: DatabaseKeyStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.example.TeacherWorkbench",
        account: String = "sqlcipher-database-key-v1"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data {
        if let key = try readKey() {
            guard key.count == 32 else { throw DatabaseKeyStoreError.invalidKeyLength }
            return key
        }

        var bytes = Data(repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw DatabaseKeyStoreError.keyGenerationFailed(randomStatus)
        }

        let addStatus = addKey(bytes)
        if addStatus == errSecDuplicateItem, let existing = try readKey() {
            guard existing.count == 32 else { throw DatabaseKeyStoreError.invalidKeyLength }
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw DatabaseKeyStoreError.keychainWriteFailed(addStatus)
        }
        return bytes
    }

    private func readKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw DatabaseKeyStoreError.keychainReadFailed(status)
        }
    }

    private func addKey(_ key: Data) -> OSStatus {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

#if DEBUG
public final class FixedDatabaseKeyStore: DatabaseKeyStore, @unchecked Sendable {
    private let key: Data

    public init(key: Data) {
        self.key = key
    }

    public func loadOrCreateKey() throws -> Data { key }
}
#endif
