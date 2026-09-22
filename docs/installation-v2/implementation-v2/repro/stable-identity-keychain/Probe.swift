import CryptoKit
import Foundation
import Security

enum ProbeFailure: Error {
    case usage
    case random(OSStatus)
    case keychain(OSStatus)
    case malformedItem
}

private func query(service: String, account: String, accessGroup: String) -> [String: Any] {
    var result: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
    ]
    if accessGroup != "login" {
        result[kSecUseDataProtectionKeychain as String] = true
    }
    if accessGroup != "-" && accessGroup != "login" {
        result[kSecAttrAccessGroup as String] = accessGroup
    }
    return result
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func create(service: String, account: String, accessGroup: String) throws {
    var bytes = [UInt8](repeating: 0, count: 32)
    let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard randomStatus == errSecSuccess else { throw ProbeFailure.random(randomStatus) }
    defer { bytes.resetBytes(in: 0..<bytes.count) }

    var attributes = query(service: service, account: account, accessGroup: accessGroup)
    attributes[kSecValueData as String] = Data(bytes)
    if accessGroup != "login" {
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
    attributes[kSecAttrLabel as String] = "Veya stable-identity Keychain reproduction"
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else { throw ProbeFailure.keychain(status) }
    print("operation=create status=0 digest=\(digest(Data(bytes)))")
}

private func read(service: String, account: String, accessGroup: String) throws {
    var attributes = query(service: service, account: account, accessGroup: accessGroup)
    attributes[kSecReturnData as String] = true
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    guard status == errSecSuccess else { throw ProbeFailure.keychain(status) }
    guard var data = result as? Data, data.count == 32 else { throw ProbeFailure.malformedItem }
    defer { data.resetBytes(in: 0..<data.count) }
    print("operation=read status=0 digest=\(digest(data))")
}

private func delete(service: String, account: String, accessGroup: String) throws {
    let status = SecItemDelete(query(service: service, account: account, accessGroup: accessGroup) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw ProbeFailure.keychain(status) }
    print("operation=delete status=\(status)")
}

do {
    guard CommandLine.arguments.count == 5 else { throw ProbeFailure.usage }
    let operation = CommandLine.arguments[1]
    let service = CommandLine.arguments[2]
    let account = CommandLine.arguments[3]
    let accessGroup = CommandLine.arguments[4]
    switch operation {
    case "create": try create(service: service, account: account, accessGroup: accessGroup)
    case "read": try read(service: service, account: account, accessGroup: accessGroup)
    case "delete": try delete(service: service, account: account, accessGroup: accessGroup)
    default: throw ProbeFailure.usage
    }
} catch ProbeFailure.keychain(let status) {
    fputs("keychain_status=\(status) message=\(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")\n", stderr)
    exit(3)
} catch {
    fputs("probe_error=\(error)\n", stderr)
    exit(2)
}
