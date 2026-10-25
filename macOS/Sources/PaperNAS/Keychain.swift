import Foundation
import Security

enum CredentialVault {
    private static var previewBundle:Bool {Bundle.main.bundleIdentifier == "com.harryhan.paper-nas.preview"}
    private static var ephemeral:Bool {previewBundle || CommandLine.arguments.contains("--preview-connection-file")}
    private static let service = "com.harryhan.paper-nas"
    private static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,
                                               kSecAttrService as String:service,
                                               kSecAttrAccount as String:"primary-server"] }
    static func restore(arguments:[String]) throws -> Credentials? {
        // UI verification may use a separate server without changing the user's saved connection.
        if let index = arguments.firstIndex(of:"--preview-connection-file"),arguments.count > index+1 {
            let data = try Data(contentsOf:URL(fileURLWithPath:arguments[index+1]))
            let value = try JSONDecoder().decode(Credentials.self,from:data)
            _ = try APIClient(baseURL:value.serverURL,token:value.token,apiVersion:value.apiVersion ?? 1)
            return value
        }
        // Explicit local provisioning; consume the file only after a successful secure save.
        if let index = arguments.firstIndex(of:"--connection-file"),arguments.count > index+1 {
            let file = URL(fileURLWithPath:arguments[index+1])
            let value = try JSONDecoder().decode(Credentials.self,from:Data(contentsOf:file))
            _ = try APIClient(baseURL:value.serverURL,token:value.token)
            try save(value)
            try? FileManager.default.removeItem(at:file)
            return value
        }
        return previewBundle ? nil : load()
    }
    static func load() -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ value: Credentials) throws {
        guard !ephemeral else {return}
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(q as CFDictionary, nil)
            guard result == errSecSuccess else { throw ServerError(message:"无法将登录保存到钥匙串（\(result)）") }
        } else if status != errSecSuccess { throw ServerError(message:"无法更新钥匙串（\(status)）") }
    }
    static func remove() {if !ephemeral {SecItemDelete(query as CFDictionary)}}
}
