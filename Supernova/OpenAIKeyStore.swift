import Foundation
import Security

actor OpenAIKeyStore {
    static let shared: OpenAIKeyStore = {
        let service = Bundle.main.bundleIdentifier ?? "dev.qiyang.Supernova"
        #if DEBUG
            if let namespace = ProcessInfo.processInfo.environment[
                "SUPERNOVA_UI_TEST_KEYCHAIN_NAMESPACE"
            ] {
                return OpenAIKeyStore(
                    service: "\(service).ui-tests.\(namespace)"
                )
            }
        #endif
        return OpenAIKeyStore(service: service)
    }()

    private let service: String

    init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "OpenAI API Key",
        ]
    }

    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            throw KeychainError(status: errSecDecode)
        }
        return key
    }

    func save(_ key: String) throws {
        guard !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = Data(key.utf8)
        var item = query
        item[kSecValueData as String] = data
        #if !os(macOS)
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif

        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes = [kSecValueData as String: data]
            status = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}
