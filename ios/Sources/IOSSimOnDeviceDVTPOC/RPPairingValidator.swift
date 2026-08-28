import Foundation

public struct RPPairingSummary: Codable, Equatable, Sendable {
    public let pairingLoaded: Bool
    public let identifierRedacted: String
    public let publicKeyPresent: Bool
    public let privateKeyPresent: Bool
    public let altIRKPresent: Bool

    public init(
        pairingLoaded: Bool,
        identifierRedacted: String,
        publicKeyPresent: Bool,
        privateKeyPresent: Bool,
        altIRKPresent: Bool
    ) {
        self.pairingLoaded = pairingLoaded
        self.identifierRedacted = identifierRedacted
        self.publicKeyPresent = publicKeyPresent
        self.privateKeyPresent = privateKeyPresent
        self.altIRKPresent = altIRKPresent
    }
}

public enum RPPairingValidator {
    public static func validate(_ data: Data) throws -> RPPairingSummary {
        let root: Any
        do {
            root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw POCError(.pairingFileInvalid, "File is not a readable XML or binary plist.", stage: .pairingValidated)
        }

        guard let plist = root as? [String: Any] else {
            throw POCError(.pairingFileInvalid, "RPPairing file must be a top-level dictionary.", stage: .pairingValidated)
        }

        guard hasData(plist["public_key"], count: 32) else {
            throw POCError(.pairingCredentialMissing, "RPPairing public_key is missing or not 32 bytes.", stage: .pairingValidated)
        }

        guard hasData(plist["private_key"], count: 32) else {
            throw POCError(.pairingCredentialMissing, "RPPairing private_key is missing or not 32 bytes.", stage: .pairingValidated)
        }

        guard let identifier = plist["identifier"] as? String, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw POCError(.pairingCredentialMissing, "RPPairing identifier is missing.", stage: .pairingValidated)
        }

        if let altIRK = plist["alt_irk"], !hasData(altIRK, count: 16) {
            throw POCError(.pairingCredentialMissing, "RPPairing alt_irk is present but not 16 bytes.", stage: .pairingValidated)
        }

        return RPPairingSummary(
            pairingLoaded: true,
            identifierRedacted: redact(identifier),
            publicKeyPresent: true,
            privateKeyPresent: true,
            altIRKPresent: plist["alt_irk"] != nil
        )
    }

    public static func redact(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "<empty>" }
        guard cleaned.count > 10 else { return "<redacted:\(cleaned.count)>" }
        let prefix = cleaned.prefix(4)
        let suffix = cleaned.suffix(4)
        return "\(prefix)...\(suffix) (\(cleaned.count) chars)"
    }

    private static func hasData(_ value: Any?, count: Int) -> Bool {
        if let data = value as? Data {
            return data.count == count
        }
        if let bytes = value as? [UInt8] {
            return bytes.count == count
        }
        return false
    }
}
