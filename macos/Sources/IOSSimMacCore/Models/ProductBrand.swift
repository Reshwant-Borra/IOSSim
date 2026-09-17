import Foundation

public enum ProductBrand {
    public static let displayName = "Veya"
    public static let migrationDisplayName = "Veya (formerly IOSSim)"
    public static let legacyDisplayName = "IOSSim"

    // Stability contract for the migration release. Display branding must not
    // move or duplicate setup state, signing keys, pairing records, or phone
    // payload identities.
    public static let macBundleIdentifier = "com.iossim.mac-provisioner"
    public static let applicationSupportNamespace = "IOSSim"
    public static let preferencesNamespace = "IOSSimMac"
    public static let phoneBundleIdentifier = "com.iossim.on-device-dvt-poc"
    public static let runnerBundleIdentifier = "com.iossim.location-control-uitests.xctrunner"
    public static let pairingKeychainService = "com.iossim.on-device-dvt-poc.rppairing"

    public static func userFacing(_ value: String) -> String {
        value.replacingOccurrences(of: legacyDisplayName, with: displayName)
    }
}
