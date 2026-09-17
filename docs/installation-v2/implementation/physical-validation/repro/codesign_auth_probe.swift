// LOCAL_SYSTEM decisive reproduction for PHYSICAL_DEFECT_001.
//
// For each candidate ACL shape: create an IOSSim-shaped RSA signing key in the
// default (login) Keychain, issue a code-signing leaf for it with a throwaway
// openssl CA, then run a REAL /usr/bin/codesign against it in a child process
// with a hard timeout. A child that has to be timed out is one that raised a
// SecurityAgent prompt -- i.e. codesign was NOT authorized for the key.
import Foundation
import Security

let run = UUID().uuidString.uppercased()
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iossim-auth-probe-\(run)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var createdTags: [Data] = []
var createdCertSHA: [String] = []

enum ASN1 {
    static let null = Data([0x05, 0x00])
    static func sequence(_ v: [Data]) -> Data { item(0x30, v.reduce(Data(), +)) }
    static func set(_ v: Data) -> Data { item(0x31, v) }
    static func integer(_ v: UInt8) -> Data { item(0x02, Data([v])) }
    static func oid(_ b: [UInt8]) -> Data { item(0x06, Data(b)) }
    static func printable(_ s: String) -> Data { item(0x13, Data(s.utf8)) }
    static func utf8(_ s: String) -> Data { item(0x0C, Data(s.utf8)) }
    static func bitString(_ v: Data) -> Data { item(0x03, Data([0]) + v) }
    static func item(_ t: UInt8, _ c: Data) -> Data { Data([t]) + length(c.count) + c }
    static func length(_ v: Int) -> Data {
        if v < 128 { return Data([UInt8(v)]) }
        var raw: [UInt8] = []; var r = v
        while r > 0 { raw.insert(UInt8(r & 0xff), at: 0); r >>= 8 }
        return Data([0x80 | UInt8(raw.count)] + raw)
    }
}

func csr(_ key: SecKey, team: String) -> String? {
    guard let pub = SecKeyCopyPublicKey(key) else { return nil }
    var e: Unmanaged<CFError>?
    guard let pkcs1 = SecKeyCopyExternalRepresentation(pub, &e) as Data? else { return nil }
    let subject = ASN1.sequence([
        ASN1.set(ASN1.sequence([ASN1.oid([0x55,0x04,0x06]), ASN1.printable("US")])),
        ASN1.set(ASN1.sequence([ASN1.oid([0x55,0x04,0x0A]), ASN1.utf8("IOSSim")])),
        ASN1.set(ASN1.sequence([ASN1.oid([0x55,0x04,0x0B]), ASN1.utf8(team)])),
        ASN1.set(ASN1.sequence([ASN1.oid([0x55,0x04,0x03]), ASN1.utf8("IOSSim Probe \(run)")])),
    ])
    let alg = ASN1.sequence([ASN1.oid([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01]), ASN1.null])
    let info = ASN1.sequence([ASN1.integer(0), subject, ASN1.sequence([alg, ASN1.bitString(pkcs1)]), Data([0xA0,0x00])])
    guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, &e) as Data? else { return nil }
    let sigAlg = ASN1.sequence([ASN1.oid([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x0B]), ASN1.null])
    let der = ASN1.sequence([info, sigAlg, ASN1.bitString(sig)])
    return "-----BEGIN CERTIFICATE REQUEST-----\n"
        + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        + "-----END CERTIFICATE REQUEST-----\n"
}

@discardableResult
func sh(_ exe: String, _ args: [String], timeout: TimeInterval? = nil) -> (Int32, String, Bool) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.currentDirectoryURL = root; p.standardInput = FileHandle.nullDevice
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    var out = Data()
    let q = DispatchQueue(label: "io"); let done = DispatchSemaphore(value: 0)
    try! p.run()
    q.async { out = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
    var timedOut = false
    if let timeout {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(100_000) }
        if p.isRunning { timedOut = true; p.terminate(); usleep(300_000); kill(p.processIdentifier, SIGKILL) }
    }
    p.waitUntilExit(); _ = done.wait(timeout: .now() + 5)
    return (p.terminationStatus, String(decoding: out, as: UTF8.self), timedOut)
}

func trustedApps(_ paths: [String]) -> [SecTrustedApplication] {
    var apps: [SecTrustedApplication] = []
    var cur: SecTrustedApplication?
    if SecTrustedApplicationCreateFromPath(nil, &cur) == errSecSuccess, let cur { apps.append(cur) }
    for p in paths { var a: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(p, &a) == errSecSuccess, let a { apps.append(a) } }
    return apps
}

func access(_ label: String, _ paths: [String], grantChangeACL: Bool, anyApp: Bool = false) -> SecAccess? {
    var acc: SecAccess?
    guard SecAccessCreate(label as CFString, trustedApps(paths) as CFArray, &acc) == errSecSuccess, let acc else { return nil }
    if anyApp {
        var l: CFArray?
        if SecAccessCopyACLList(acc, &l) == errSecSuccess, let acls = l as? [SecACL] {
            for a in acls where (SecACLCopyAuthorizations(a) as? [String] ?? []).contains(kSecACLAuthorizationSign as String) {
                _ = SecACLSetContents(a, nil, label as CFString, SecKeychainPromptSelector())
            }
        }
    }
    if grantChangeACL {
        var l: CFArray?
        if SecAccessCopyACLList(acc, &l) == errSecSuccess, let acls = l as? [SecACL] {
            for a in acls where (SecACLCopyAuthorizations(a) as? [String] ?? []).contains(kSecACLAuthorizationChangeACL as String) {
                _ = SecACLSetContents(a, trustedApps(paths) as CFArray, label as CFString, SecKeychainPromptSelector())
            }
        }
    }
    return acc
}

var ownedKeychains: [SecKeychain] = []
var ownedKeychainPassword = ""
var ownedKeychainPath = ""

func makeOwnedKeychain() -> SecKeychain? {
    let path = root.appendingPathComponent("VeyaSigning-\(run)-\(UUID().uuidString.prefix(8)).keychain-db").path
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
    let pw = Data(bytes).base64EncodedString()
    var kc: SecKeychain?
    let s = pw.withCString { p in
        SecKeychainCreate(path, UInt32(strlen(p)), p, false, nil, &kc)
    }
    guard s == errSecSuccess, let kc else { print("  SecKeychainCreate -> \(s)"); return nil }
    var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                       lockOnSleep: false, useLockInterval: false, lockInterval: .max)
    _ = SecKeychainSetSettings(kc, &settings)
    _ = SecKeychainUnlock(kc, UInt32(pw.utf8.count), pw, true)
    ownedKeychainPassword = pw
    ownedKeychainPath = path
    ownedKeychains.append(kc)
    return kc
}

func makeKey(tag: Data, label: String, acc: SecAccess?, nested: Bool, keychain: SecKeychain? = nil) -> SecKey? {
    var kc: SecKeychain? = keychain
    if kc == nil { guard SecKeychainCopyDefault(&kc) == errSecSuccess, kc != nil else { return nil } }
    guard let kc else { return nil }
    var priv: [String: Any] = [
        kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
        kSecAttrLabel as String: label, kSecAttrSynchronizable as String: false,
    ]
    var attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
        kSecUseKeychain as String: kc,
    ]
    if let acc { if nested { priv[kSecAttrAccess as String] = acc } else { attrs[kSecAttrAccess as String] = acc } }
    attrs[kSecPrivateKeyAttrs as String] = priv
    var e: Unmanaged<CFError>?
    guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &e) else {
        print("   key create failed: \(e.map { String(describing: $0.takeRetainedValue()) } ?? "?")"); return nil }
    createdTags.append(tag)
    return k
}

func keychainItem(tag: Data, keychain: SecKeychain? = nil) -> SecKeychainItem? {
    var r: CFTypeRef?
    var q: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                            kSecReturnPersistentRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    if let keychain { q[kSecMatchSearchList as String] = [keychain] as CFArray }
    guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let pref = r as? Data else { return nil }
    var item: SecKeychainItem?
    guard SecKeychainItemCopyFromPersistentReference(pref as CFData, &item) == errSecSuccess else { return nil }
    return item
}

/// Rewrites ONLY the PartitionID ACL description, preserving every other ACL.
func repairPartitions(tag: Data, partitions: [String], password: String? = nil, keychain: SecKeychain? = nil) -> OSStatus {
    guard let item = keychainItem(tag: tag, keychain: keychain) else { return errSecItemNotFound }
    var acc: SecAccess?
    let s = SecKeychainItemCopyAccess(item, &acc)
    guard s == errSecSuccess, let acc else { return s }
    var l: CFArray?
    guard SecAccessCopyACLList(acc, &l) == errSecSuccess, let acls = l as? [SecACL] else { return errSecInvalidACL }
    let data = try! PropertyListSerialization.data(fromPropertyList: ["Partitions": partitions], format: .xml, options: 0)
    let hex = data.map { String(format: "%02x", $0) }.joined()
    for a in acls where (SecACLCopyAuthorizations(a) as? [String] ?? []).contains(kSecACLAuthorizationPartitionID as String) {
        let r = SecACLSetContents(a, nil, hex as CFString, SecKeychainPromptSelector())
        if r != errSecSuccess { return r }
    }
    return SecKeychainItemSetAccess(item, acc)
}

func describeACL(tag: Data, keychain: SecKeychain? = nil) -> String {
    guard let item = keychainItem(tag: tag, keychain: keychain) else { return "no-item" }
    var acc: SecAccess?
    guard SecKeychainItemCopyAccess(item, &acc) == errSecSuccess, let acc else { return "no-access" }
    var l: CFArray?
    guard SecAccessCopyACLList(acc, &l) == errSecSuccess, let acls = l as? [SecACL] else { return "no-acls" }
    var parts: [String] = []
    for a in acls {
        let auths = SecACLCopyAuthorizations(a) as? [String] ?? []
        var apps: CFArray?; var desc: CFString?; var pr = SecKeychainPromptSelector()
        _ = SecACLCopyContents(a, &apps, &desc, &pr)
        let names = (apps as? [SecTrustedApplication])?.compactMap { a -> String in
            var d: CFData?
            guard SecTrustedApplicationCopyData(a, &d) == errSecSuccess, let d = d as Data? else { return "?" }
            return URL(fileURLWithPath: String(decoding: d, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))).lastPathComponent
        }
        if auths.contains(kSecACLAuthorizationSign as String) { parts.append("Sign=[\(names?.joined(separator: ",") ?? "ANY")]") }
        if auths.contains(kSecACLAuthorizationPartitionID as String) {
            let h = (desc as String?) ?? ""
            var b = Data(); var i = h.startIndex
            while i < h.endIndex, let j = h.index(i, offsetBy: 2, limitedBy: h.endIndex) { b.append(UInt8(h[i..<j], radix: 16) ?? 0); i = j }
            let s = String(decoding: b, as: UTF8.self)
            let found = ["apple-tool:", "apple:", "cdhash:"].filter { s.contains($0) }
            parts.append("Partitions=\(found)")
        }
        if auths.contains(kSecACLAuthorizationChangeACL as String) { parts.append("ChangeACL=[\(names?.joined(separator: ",") ?? "ANY")]") }
    }
    return parts.joined(separator: " ")
}

// Throwaway CA
let caKey = root.appendingPathComponent("ca.key"), caCrt = root.appendingPathComponent("ca.pem")
sh("/usr/bin/openssl", ["req","-new","-x509","-newkey","rsa:2048","-nodes","-keyout",caKey.path,"-out",caCrt.path,
                        "-days","1","-subj","/C=US/O=IOSSim Probe CA/CN=IOSSim Probe CA \(run)"])
sh("/usr/bin/openssl", ["x509","-in",caCrt.path,"-outform","DER","-out",root.appendingPathComponent("ca.der").path])
let ext = root.appendingPathComponent("ext.cnf")
try! Data("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n".utf8).write(to: ext)

struct Variant { let name: String; let nested: Bool; let trustCodesign: Bool; let partitions: [String]?; var owned = false; var anyApp = false; var caInLogin = false }
let variants = [
    Variant(name: "V0 PRODUCTION-AS-SHIPPED (kSecAttrAccess nested in kSecPrivateKeyAttrs)", nested: true,  trustCodesign: true,  partitions: nil),
    Variant(name: "V1 top-level kSecAttrAccess incl. /usr/bin/codesign, no partition repair", nested: false, trustCodesign: true,  partitions: nil),
    Variant(name: "V2 login Keychain + top-level access + partition repair WITHOUT password", nested: false, trustCodesign: true,  partitions: ["apple-tool:", "apple:"]),
    Variant(name: "V3 VEYA-OWNED Keychain + top-level access, NO partition repair", nested: false, trustCodesign: true, partitions: nil, owned: true),
    Variant(name: "V4 VEYA-OWNED Keychain + top-level access + partition repair WITH owned password", nested: false, trustCodesign: true, partitions: ["apple-tool:", "apple:"], owned: true),
    Variant(name: "V5 VEYA-OWNED Keychain + ACL trusting ANY application (control: isolates chain trust)", nested: false, trustCodesign: true, partitions: nil, owned: true, anyApp: true),
    Variant(name: "V6 login Keychain + ACL trusting ANY application (control)", nested: false, trustCodesign: true, partitions: nil, owned: false, anyApp: true),
    Variant(name: "V7 VEYA-OWNED Keychain (key+leaf) + codesign in ACL + CA reachable for chain building", nested: false, trustCodesign: true, partitions: nil, owned: true, caInLogin: true),
]

for (i, v) in variants.enumerated() where ProcessInfo.processInfo.environment["ONLY"].map { $0.split(separator: ",").map(String.init).contains("V\(i)") } ?? true {
    print("\n================ \(v.name) ================")
    let tag = Data("com.iossim.authprobe.\(i).\(run)".utf8)
    let label = "IOSSim Auth Probe \(i) \(run)"
    let paths = v.trustCodesign ? ["/usr/bin/codesign"] : []
    var keychain: SecKeychain? = nil
    if v.owned {
        guard let kc = makeOwnedKeychain() else { continue }
        keychain = kc
    }
    guard let key = makeKey(tag: tag, label: label,
                            acc: access(label, paths, grantChangeACL: v.partitions != nil, anyApp: v.anyApp),
                            nested: v.nested, keychain: keychain) else { continue }
    guard let request = csr(key, team: "PROBE\(i)") else { print("  CSR failed"); continue }
    let csrURL = root.appendingPathComponent("r\(i).csr"), derURL = root.appendingPathComponent("r\(i).der")
    try! Data(request.replacingOccurrences(of: "-----END CERTIFICATE REQUEST-----", with: "\n-----END CERTIFICATE REQUEST-----").utf8).write(to: csrURL)
    let (xs, xo, _) = sh("/usr/bin/openssl", ["x509","-req","-in",csrURL.path,"-CA",caCrt.path,"-CAkey",caKey.path,
                                              "-CAcreateserial","-outform","DER","-out",derURL.path,"-days","1","-extfile",ext.path])
    guard xs == 0, let der = try? Data(contentsOf: derURL) else { print("  cert issuance failed: \(xo)"); continue }
    guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { print("  bad cert"); continue }
    var addQuery: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert,
                                   kSecAttrLabel as String: label]
    if let keychain { addQuery[kSecUseKeychain as String] = keychain }
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else { print("  cert add \(addStatus)"); continue }
    var sha1 = [UInt8](repeating: 0, count: 20)
    der.withUnsafeBytes { _ = CC_SHA1_shim($0.baseAddress!, CC_LONG(der.count), &sha1) }
    let fp = sha1.map { String(format: "%02X", $0) }.joined()
    createdCertSHA.append(fp)

    // Put the throwaway CA wherever the leaf lives so codesign can build a chain.
    if let caDER = try? Data(contentsOf: root.appendingPathComponent("ca.der")),
       let caCert = SecCertificateCreateWithData(nil, caDER as CFData) {
        var caQuery: [String: Any] = [kSecClass as String: kSecClassCertificate,
                                      kSecValueRef as String: caCert,
                                      kSecAttrLabel as String: "IOSSim Probe CA \(run)"]
        if let keychain, !v.caInLogin { caQuery[kSecUseKeychain as String] = keychain }
        let s = SecItemAdd(caQuery as CFDictionary, nil)
        print("  CA add -> \(s == errSecSuccess || s == errSecDuplicateItem ? "ok" : String(s))")
    }
    if let partitions = v.partitions {
        if v.owned {
            let (ps, po, _) = sh("/usr/bin/security", ["set-key-partition-list",
                                                       "-S", partitions.joined(separator: ","),
                                                       "-s", "-l", label,
                                                       "-k", ownedKeychainPassword,
                                                       ownedKeychainPath], timeout: 20)
            print("  security set-key-partition-list -> exit \(ps) \(po.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            let r = repairPartitions(tag: tag, partitions: partitions, keychain: keychain)
            print("  in-process partition repair -> OSStatus \(r)\(r == -25293 ? " (errSecAuthFailed)" : "")")
        }
    }
    print("  ACL: \(describeACL(tag: tag, keychain: keychain))")
    if v.owned {
        let (fs, fo, _) = sh("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", ownedKeychainPath], timeout: 20)
        print("  find-identity(owned) exit=\(fs): \(fo.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
        let (cs, co, _) = sh("/usr/bin/security", ["find-certificate", "-a", "-c", "IOSSim Probe", ownedKeychainPath], timeout: 20)
        print("  cert-in-owned exit=\(cs) found=\(co.contains("labl"))")
        let (fs2, fo2, _) = sh("/usr/bin/security", ["find-identity", ownedKeychainPath], timeout: 20)
        print("  find-identity(all,owned): \(fo2.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
        var ident: SecIdentity?
        let istat = SecIdentityCreateWithCertificate(keychain, cert, &ident)
        print("  SecIdentityCreateWithCertificate(ownedKeychain) -> \(istat)")
        var ident2: SecIdentity?
        let istat2 = SecIdentityCreateWithCertificate(nil, cert, &ident2)
        print("  SecIdentityCreateWithCertificate(nil) -> \(istat2)")
        // what does the key's application label look like vs the cert public key hash?
        if let pub = SecCertificateCopyKey(cert),
           let attrs = SecKeyCopyAttributes(pub) as? [String: Any],
           let al = attrs[kSecAttrApplicationLabel as String] as? Data {
            print("  cert pubkey applicationLabel: \(al.map { String(format: "%02X", $0) }.joined())")
        }
        var kr: CFTypeRef?
        if SecItemCopyMatching([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                kSecMatchSearchList as String: [keychain!] as CFArray,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne] as CFDictionary, &kr) == errSecSuccess,
           let ka = kr as? [String: Any], let al = ka[kSecAttrApplicationLabel as String] as? Data {
            print("  privkey applicationLabel:     \(al.map { String(format: "%02X", $0) }.joined())")
        }
    }

    let app = root.appendingPathComponent("Probe\(i).app", isDirectory: true)
    try? FileManager.default.removeItem(at: app)
    try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try! PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": "com.iossim.authprobe\(i)", "CFBundleExecutable": "Probe",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1"] as [String: Any], format: .binary, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Probe"))

    var csArgs = ["--force","--sign",fp,"--timestamp=none"]
    if v.owned, ProcessInfo.processInfo.environment["USE_KEYCHAIN_FLAG"] == "1" {
        csArgs += ["--keychain", ownedKeychainPath]
    }
    csArgs.append(app.path)
    var savedSearchList: String? = nil
    if v.owned, ProcessInfo.processInfo.environment["USE_KEYCHAIN_FLAG"] != "1" {
        let (_, cur, _) = sh("/usr/bin/security", ["list-keychains", "-d", "user"], timeout: 20)
        savedSearchList = cur
        let existing = cur.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
            return t.isEmpty ? nil : t
        }
        let (ls, lo, _) = sh("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + existing + [ownedKeychainPath], timeout: 20)
        print("  search-list append -> exit \(ls) \(lo.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let (st, out, timedOut) = sh("/usr/bin/codesign", csArgs, timeout: 12)
    if let saved = savedSearchList {
        let restore = saved.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
            return t.isEmpty ? nil : t
        }
        _ = sh("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + restore, timeout: 20)
        print("  search-list restored")
    }
    if timedOut {
        print("  RESULT: ** codesign BLOCKED on a SecurityAgent keychain prompt (NOT authorized) **")
    } else if st == 0 {
        print("  RESULT: codesign SUCCEEDED with no prompt (authorized)")
    } else {
        print("  RESULT: codesign FAILED exit=\(st): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

// cleanup
for kc in ownedKeychains { _ = SecKeychainDelete(kc) }
for t in createdTags {
    _ = SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: t] as CFDictionary)
}
for fp in createdCertSHA {
    _ = fp // certificates removed by label sweep below
}
var r: CFTypeRef?
if SecItemCopyMatching([kSecClass as String: kSecClassCertificate, kSecReturnRef as String: true,
                        kSecReturnAttributes as String: true,
                        kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &r) == errSecSuccess,
   let items = r as? [[String: Any]] {
    for it in items {
        guard let lbl = it[kSecAttrLabel as String] as? String, lbl.contains(run),
              let ref = it[kSecValueRef as String] else { continue }
        _ = SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: ref] as CFDictionary)
    }
}
try? FileManager.default.removeItem(at: root)
print("\ncleaned up probe keys and certificates")
