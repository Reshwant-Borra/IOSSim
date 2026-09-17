// LOCAL_SYSTEM reproduction probe for PHYSICAL_DEFECT_001.
// Mirrors IOSSimIdentityMetadataStore.createPrivateKey and dumps the resulting
// legacy Keychain ACL so we can see exactly which authorizations/trusted apps
// the generated signing key actually receives.
import Foundation
import Security

func trustedApps(_ paths: [String]) -> [SecTrustedApplication] {
    var apps: [SecTrustedApplication] = []
    var current: SecTrustedApplication?
    if SecTrustedApplicationCreateFromPath(nil, &current) == errSecSuccess, let current { apps.append(current) }
    for p in paths {
        var a: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(p, &a) == errSecSuccess, let a { apps.append(a) }
    }
    return apps
}

func makeAccess(_ label: String, _ paths: [String]) -> SecAccess? {
    var access: SecAccess?
    let s = SecAccessCreate(label as CFString, trustedApps(paths) as CFArray, &access)
    if s != errSecSuccess { print("  SecAccessCreate failed \(s)"); return nil }
    return access
}

func createKey(tag: Data, label: String, access: SecAccess?, nested: Bool) -> SecKey? {
    var defaultKeychain: SecKeychain?
    guard SecKeychainCopyDefault(&defaultKeychain) == errSecSuccess, let defaultKeychain else {
        print("  no default keychain"); return nil
    }
    var priv: [String: Any] = [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrLabel as String: label,
        kSecAttrSynchronizable as String: false,
    ]
    var attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2048,
        kSecUseKeychain as String: defaultKeychain,
    ]
    if let access {
        if nested { priv[kSecAttrAccess as String] = access } else { attrs[kSecAttrAccess as String] = access }
    }
    attrs[kSecPrivateKeyAttrs as String] = priv
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
        print("  SecKeyCreateRandomKey failed: \(error!.takeRetainedValue())"); return nil
    }
    return key
}

func dumpACL(tag: Data, title: String) {
    print("--- ACL dump: \(title)")
    let q: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        kSecAttrSynchronizable as String: false,
        kSecReturnPersistentRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var r: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &r)
    guard st == errSecSuccess, let pref = r as? Data else { print("  lookup failed \(st)"); return }
    var item: SecKeychainItem?
    let ist = SecKeychainItemCopyFromPersistentReference(pref as CFData, &item)
    guard ist == errSecSuccess, let item else { print("  persistent-ref -> keychain item failed \(ist) (NOT a legacy keychain item)"); return }
    var access: SecAccess?
    let ast = SecKeychainItemCopyAccess(item, &access)
    guard ast == errSecSuccess, let access else { print("  SecKeychainItemCopyAccess failed \(ast)"); return }
    var aclList: CFArray?
    let lst = SecAccessCopyACLList(access, &aclList)
    guard lst == errSecSuccess, let acls = aclList as? [SecACL] else { print("  SecAccessCopyACLList failed \(lst)"); return }
    for acl in acls {
        var apps: CFArray?
        var desc: CFString?
        var prompt = SecKeychainPromptSelector()
        let cst = SecACLCopyContents(acl, &apps, &desc, &prompt)
        let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
        let appList = apps as? [SecTrustedApplication]
        var names: [String] = []
        if let appList {
            for a in appList {
                var d: CFData?
                if SecTrustedApplicationCopyData(a, &d) == errSecSuccess, let d = d as Data? {
                    let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    names.append(s.isEmpty ? "<opaque \(d.count)B>" : s)
                }
            }
        }
        print("  ACL contents=\(cst) desc=\(desc as String? ?? "") promptSelector=\(prompt.rawValue)")
        print("    authorizations: \(auths)")
        print("    trustedApps: \(appList == nil ? "ANY (nil == unrestricted)" : "\(appList!.count) -> \(names)")")
    }
}

func deleteKey(tag: Data) {
    _ = SecItemDelete([
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: tag,
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrSynchronizable as String: false,
    ] as CFDictionary)
}

let run = UUID().uuidString.uppercased()
let trusted = ["/usr/bin/codesign"]

print("== CASE A: kSecAttrAccess NESTED inside kSecPrivateKeyAttrs (current production shape) ==")
let tagA = Data("com.iossim.acl-probe.nested.\(run)".utf8)
if createKey(tag: tagA, label: "IOSSim ACL Probe Nested \(run)", access: makeAccess("IOSSim ACL Probe Nested \(run)", trusted), nested: true) != nil {
    dumpACL(tag: tagA, title: "nested kSecAttrAccess")
}

print("")
print("== CASE B: kSecAttrAccess at TOP level ==")
let tagB = Data("com.iossim.acl-probe.top.\(run)".utf8)
if createKey(tag: tagB, label: "IOSSim ACL Probe Top \(run)", access: makeAccess("IOSSim ACL Probe Top \(run)", trusted), nested: false) != nil {
    dumpACL(tag: tagB, title: "top-level kSecAttrAccess")
}

print("")
print("== CASE C: no kSecAttrAccess at all (baseline default) ==")
let tagC = Data("com.iossim.acl-probe.none.\(run)".utf8)
if createKey(tag: tagC, label: "IOSSim ACL Probe None \(run)", access: nil, nested: true) != nil {
    dumpACL(tag: tagC, title: "no access object")
}

deleteKey(tag: tagA); deleteKey(tag: tagB); deleteKey(tag: tagC)
print("\ncleaned up probe keys")
