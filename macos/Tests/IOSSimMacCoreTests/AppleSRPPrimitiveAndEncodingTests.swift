import BigInt
import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import IOSSimMacCore

final class AppleSRPPrimitiveAndEncodingTests: XCTestCase {
    func testFullSRPTraceMatchesIndependentCoreCryptoReferenceForBothSchemes() throws {
        let reference = try referenceTraces()

        for scheme in ["s2k", "s2k_fo"] {
            let client = try AppleSRPClient(randomBytes: Data((1...32).map(UInt8.init)))
            let challenge = try AppleSRPClient.parseChallenge([
                "sp": scheme,
                "s": Data(repeating: 0x5a, count: 16),
                "i": 20_000,
                "B": Data(repeating: 0x7b, count: 256),
                "c": "synthetic-cookie"
            ])
            let trace = try client.parityTrace(
                account: "fixture@example.invalid",
                password: Data("synthetic-password".utf8),
                challenge: challenge
            )
            let expectedScheme = try XCTUnwrap(reference[scheme] as? [String: Any])
            let expectedMetadata = try XCTUnwrap(expectedScheme["metadata"] as? [String: String])
            let expectedValues = try XCTUnwrap(expectedScheme["values"] as? [String: Any])

            XCTAssertEqual(trace.metadata, expectedMetadata, "Metadata mismatch for \(scheme)")
            XCTAssertEqual(Set(trace.bytes.keys), Set(expectedValues.keys), "Trace key mismatch for \(scheme)")
            for (name, bytes) in trace.bytes {
                let expectedFingerprint = try XCTUnwrap(expectedValues[name] as? [String: Any])
                let expectedLength = try XCTUnwrap(expectedFingerprint["length"] as? NSNumber).intValue
                let expectedSHA256 = try XCTUnwrap(expectedFingerprint["sha256"] as? String)
                XCTAssertEqual(bytes.count, expectedLength, "Length mismatch for \(scheme).\(name)")
                XCTAssertEqual(
                    Data(SHA256.hash(data: bytes)).fingerprintHex,
                    expectedSHA256,
                    "Fingerprint mismatch for \(scheme).\(name)"
                )
            }
        }
    }

    func testSHA256PublishedVector() throws {
        XCTAssertEqual(
            Data(SHA256.hash(data: Data("abc".utf8))),
            try XCTUnwrap(Data(hex: "ba7816bf8f01cfea414140de5dae2223" +
                                    "b00361a396177a9cb410ff61f20015ad"))
        )
    }

    func testHMACSHA256RFC4231Vector() throws {
        let key = SymmetricKey(data: Data(repeating: 0x0b, count: 20))
        let actual = Data(HMAC<SHA256>.authenticationCode(
            for: Data("Hi There".utf8),
            using: key
        ))
        XCTAssertEqual(
            actual,
            try XCTUnwrap(Data(hex: "b0344c61d8db38535ca8afceaf0bf12b" +
                                    "881dc200c9833da726e9376c2e32cff7"))
        )
    }

    func testPBKDF2HMACSHA256PublishedVector() throws {
        let input = Data("password".utf8)
        let salt = Data("salt".utf8)
        var actual = Data(count: 32)
        let outputCount = actual.count
        let status = input.withUnsafeBytes { inputBytes in
            salt.withUnsafeBytes { saltBytes in
                actual.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        inputBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        input.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        1,
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputCount
                    )
                }
            }
        }

        XCTAssertEqual(status, Int32(kCCSuccess))
        XCTAssertEqual(
            actual,
            try XCTUnwrap(Data(hex: "120fb6cffcf8b32c43e7225256c4f837" +
                                    "a86548c92ccc35480805987cb70be17b"))
        )
    }

    func testClientPublicKeyEncodesGeneratorAsUnsignedBigEndianAtModulusWidth() throws {
        var privateBytes = Data(repeating: 0, count: 32)
        privateBytes[privateBytes.index(before: privateBytes.endIndex)] = 1
        let client = try AppleSRPClient(randomBytes: privateBytes)

        XCTAssertEqual(client.clientPublicKey.count, 256)
        XCTAssertEqual(client.clientPublicKey.dropLast(), Data(repeating: 0, count: 255))
        XCTAssertEqual(client.clientPublicKey.last, 2)
    }

    func testServerPublicKeyLeadingZeroDoesNotChangeSRPResult() throws {
        let client = try AppleSRPClient(randomBytes: Data((1...32).map(UInt8.init)))
        let minimalServerKey = Data(repeating: 0x7b, count: 255)
        let fixedWidthServerKey = Data([0]) + minimalServerKey

        let minimalProof = try client.proof(
            account: "fixture@example.invalid",
            password: Data("synthetic-password".utf8),
            challenge: try challenge(serverPublicKey: minimalServerKey)
        )
        let fixedWidthProof = try client.proof(
            account: "fixture@example.invalid",
            password: Data("synthetic-password".utf8),
            challenge: try challenge(serverPublicKey: fixedWidthServerKey)
        )

        XCTAssertEqual(minimalProof.clientProof, fixedWidthProof.clientProof)
        XCTAssertEqual(minimalProof.sessionKey, fixedWidthProof.sessionKey)
        XCTAssertEqual(minimalProof.expectedServerProof, fixedWidthProof.expectedServerProof)
    }

    func testServerPublicKeyWithHighBitSetIsUnsigned() throws {
        let client = try AppleSRPClient(randomBytes: Data((1...32).map(UInt8.init)))
        let serverKey = Data([0x80]) + Data(repeating: 0, count: 255)
        let proof = try client.proof(
            account: "fixture@example.invalid",
            password: Data("synthetic-password".utf8),
            challenge: try challenge(serverPublicKey: serverKey)
        )

        XCTAssertEqual(proof.clientProof.count, 32)
        XCTAssertEqual(proof.sessionKey.count, 32)
        XCTAssertEqual(proof.expectedServerProof.count, 32)
    }

    func testBigUIntRoundTripsUnsignedBigEndianAndStripsLeadingZeroes() {
        let highBitSet = Data([0x80, 0x01])
        XCTAssertEqual(BigUInt(highBitSet).serialize(), highBitSet)
        XCTAssertEqual(BigUInt(Data([0, 0, 0x80, 0x01])).serialize(), highBitSet)
        XCTAssertEqual(BigUInt(Data()).serialize(), Data())
        XCTAssertEqual(BigUInt(Data([0])).serialize(), Data())
    }

    func testSRPPaddingCoversZeroOneGeneratorAndGroupWidths() {
        XCTAssertEqual(AppleSRPClient.pad(BigUInt(0), to: 256), Data(repeating: 0, count: 256))
        XCTAssertEqual(
            AppleSRPClient.pad(BigUInt(1), to: 256),
            Data(repeating: 0, count: 255) + Data([1])
        )
        XCTAssertEqual(
            AppleSRPClient.pad(BigUInt(2), to: 256),
            Data(repeating: 0, count: 255) + Data([2])
        )

        let short = Data([0x80]) + Data(repeating: 0x5a, count: 254)
        XCTAssertEqual(
            AppleSRPClient.pad(BigUInt(short), to: 256),
            Data([0]) + short
        )

        let exact = Data([0x80]) + Data(repeating: 0xa5, count: 255)
        XCTAssertEqual(AppleSRPClient.pad(BigUInt(exact), to: 256), exact)
    }

    private func challenge(serverPublicKey: Data) throws -> AppleSRPChallenge {
        try AppleSRPClient.parseChallenge([
            "sp": "s2k",
            "s": Data(repeating: 0x5a, count: 16),
            "i": 20_000,
            "B": serverPublicKey,
            "c": "synthetic-cookie"
        ])
    }

    private func referenceTraces() throws -> [String: Any] {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/apple_srp_reference.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "Reference fixture failed: \(String(decoding: errorOutput, as: UTF8.self))"
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }
}

private extension Data {
    var fingerprintHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
