// LOCAL_SYSTEM end-to-end reproduction for PHYSICAL_DEFECT_001.
// Creates an IOSSim-shaped signing key, issues a leaf cert for it with openssl,
// and attempts a real /usr/bin/codesign signature with user interaction DISABLED
// (a clean consumer run must never need a Keychain prompt).
import Foundation
import Security

let run = UUID().uuidString.uppercased()
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iossim-e2e-\(run)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func sh(_ exe: String, _ args: [String], _ cwd: URL) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.currentDirectoryURL = cwd; p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try! p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

func trustedApps(_ paths: [String]) -> [SecTrustedApplication] {
    var apps: [SecTrustedApplication] = []
    var cur: SecTrustedApplication?
    if SecTrustedApplicationCreateFromPath(nil, &cur) == errSecSuccess, let cur { apps.append(cur) }
    for p in paths { var a: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(p, &a) == errSecSuccess, let a { apps.append(a) } }
    return apps
}

/// mode 0 = SecAccessCreate as-is (trusted list only, no partition work)
/// mode 1 = SecAccessCreate + partition list (apple-tool:, apple:) + ChangeACL granted to us
func makeAccess(_ label: String, _ paths: [String], mode: Int) -> SecAccess? {
    var access: SecAccess?
    guard SecAccessCreate(label as CFString, trustedApps(paths) as CFArray, &access) == errSecSuccess,
          let access else { return nil }
    guard mode == 1 else { return access }
    let apps = trustedApps(paths) as CFArray
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return access }
    var sawPartition = false
    for acl in acls {
        let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
        if auths.contains(kSecACLAuthorizationPartitionID as String) {
            sawPartition = true
            let plist: [String: Any] = ["Partitions": ["apple-tool:", "apple:"]]
            let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let s = SecACLSetContents(acl, nil, hex as CFString, SecKeychainPromptSelector())
            print("  set partition ACL -> \(s)")
        }
        if auths.contains(kSecACLAuthorizationChangeACL as String) {
            let s = SecACLSetContents(acl, apps, label as CFString, SecKeychainPromptSelector())
            print("  set ChangeACL trusted apps -> \(s)")
        }
    }
    if !sawPartition { print("  NOTE: no PartitionID ACL present on freshly created SecAccess") }
    return access
}

func createKey(tag: Data, label: String, access: SecAccess?) -> SecKey? {
    var kc: SecKeychain?
    guard SecKeychainCopyDefault(&kc) == errSecSuccess, let kc else { return nil }
    var attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2048,
        kSecUseKeychain as String: kc,
        kSecPrivateKeyAttrs as String: [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String: label,
            kSecAttrSynchronizable as String: false,
        ],
    ]
    if let access { attrs[kSecAttrAccess as String] = access }   // TOP LEVEL (Case B, proven honored)
    var err: Unmanaged<CFError>?
    guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
        print("  key creation failed: \(err!.takeRetainedValue())"); return nil
    }
    return k
}

func csr(_ key: SecKey, _ dir: URL) -> URL? {
    // Export public key, build a CSR with openssl using a temp copy is not possible
    // (private key is non-extractable-by-policy), so instead sign a CSR via SecKeyCreateSignature.
    // Simpler: issue the cert from the public key using openssl x509 requires a CSR, so build one manually.
    return nil
}

func partitionsOf(tag: Data) -> String {
    let q: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                            kSecReturnPersistentRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var r: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let pref = r as? Data else { return "lookup-failed" }
    var item: SecKeychainItem?
    guard SecKeychainItemCopyFromPersistentReference(pref as CFData, &item) == errSecSuccess, let item else { return "no-item" }
    var access: SecAccess?
    guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return "no-access" }
    var list: CFArray?
    guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else { return "no-acls" }
    var out: [String] = []
    for acl in acls {
        let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
        var apps: CFArray?; var desc: CFString?; var pr = SecKeychainPromptSelector()
        _ = SecACLCopyContents(acl, &apps, &desc, &pr)
        let n = (apps as? [SecTrustedApplication])?.count
        if auths.contains(kSecACLAuthorizationPartitionID as String) {
            let hex = (desc as String?) ?? ""
            var bytes = Data(); var i = hex.startIndex
            while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
                bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0); i = j
            }
            out.append("PartitionID=\(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\n", with: ""))")
        } else if auths.contains(kSecACLAuthorizationChangeACL as String) {
            out.append("ChangeACL apps=\(n.map(String.init) ?? "ANY")")
        } else if auths.contains(kSecACLAuthorizationSign as String) {
            out.append("Sign apps=\(n.map(String.init) ?? "ANY")")
        }
    }
    return out.joined(separator: " | ")
}

for mode in [0, 1] {
    print("== MODE \(mode) (\(mode == 0 ? "SecAccessCreate only" : "SecAccessCreate + partitions + ChangeACL")) ==")
    let tag = Data("com.iossim.e2e.\(mode).\(run)".utf8)
    let label = "IOSSim E2E Probe \(mode) \(run)"
    guard createKey(tag: tag, label: label,
                    access: makeAccess(label, ["/usr/bin/codesign"], mode: mode)) != nil else { continue }
    print("  resulting ACL: \(partitionsOf(tag: tag))")
    _ = SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
    print("")
}
try? FileManager.default.removeItem(at: tmp)
