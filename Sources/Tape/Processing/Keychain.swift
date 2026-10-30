import Foundation
import Security

/// The API keys, in the login Keychain (never in a file or the defaults).
enum APIKeys {
    enum Service: String, CaseIterable {
        case gemini, anthropic

        var title: String {
            switch self {
            case .gemini: "Gemini API key"
            case .anthropic: "Anthropic API key"
            }
        }

        /// Where to make one.
        var consoleURL: URL {
            switch self {
            case .gemini: URL(string: "https://aistudio.google.com/apikey")!
            case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
            }
        }
    }

    private static let keychainService = "io.github.h-thavy.tape"

    static func get(_ service: Service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func set(_ service: Service, _ key: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: service.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static var complete: Bool { Service.allCases.allSatisfy { get($0) != nil } }
}
