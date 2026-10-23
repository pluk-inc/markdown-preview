import Foundation
import XCTest
@testable import MarkdownHelpers

final class ShareLinkCryptoTests: XCTestCase {

    private let key = Data(repeating: 7, count: 32)
    private let salt = Data(repeating: 1, count: 16)
    private let nonce = Data(repeating: 2, count: 12)
    private let plaintext = Data(#"{"v":1,"title":"a.md"}"#.utf8)

    /// Fewer PBKDF2 rounds than production, so password tests stay fast.
    private func sealFast(_ data: Data, password: String?) throws -> Data {
        try ShareLinkCrypto.seal(data, key: key, password: password,
                                 salt: salt, nonce: nonce, iterations: 1_000)
    }

    // MARK: - Shared test vectors

    func testVectorsOpenAndSealToTheSameBytes() throws {
        let vectors = try ShareLinkVectors.load()
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let key = try XCTUnwrap(Base64URL.decode(vector.key))
            let envelope = try XCTUnwrap(Data(hex: vector.envelope))
            let opened = try ShareLinkCrypto.open(envelope, key: key, password: vector.password)
            XCTAssertEqual(String(decoding: opened, as: UTF8.self), vector.plaintext, vector.name)

            let sealed = try ShareLinkCrypto.seal(Data(vector.plaintext.utf8),
                                                  key: key,
                                                  password: vector.password,
                                                  salt: try XCTUnwrap(Data(hex: vector.salt)),
                                                  nonce: try XCTUnwrap(Data(hex: vector.nonce)),
                                                  iterations: UInt32(vector.iterations == 0
                                                      ? Int(ShareLinkCrypto.passwordIterations)
                                                      : vector.iterations))
            XCTAssertEqual(sealed, envelope, vector.name)
        }
    }

    // MARK: - Round trips

    func testRoundTripWithoutPassword() throws {
        let envelope = try ShareLinkCrypto.seal(plaintext, key: key, password: nil)
        XCTAssertEqual(try ShareLinkCrypto.open(envelope, key: key, password: nil), plaintext)
        XCTAssertFalse(ShareLinkCrypto.requiresPassword(envelope))
    }

    func testEachSealUsesAFreshSaltAndNonce() throws {
        let first = try ShareLinkCrypto.seal(plaintext, key: key, password: nil)
        let second = try ShareLinkCrypto.seal(plaintext, key: key, password: nil)
        XCTAssertNotEqual(first[9..<37], second[9..<37])
    }

    func testRandomKeysAreThirtyTwoDistinctBytes() {
        XCTAssertEqual(ShareLinkCrypto.randomKey().count, 32)
        XCTAssertNotEqual(ShareLinkCrypto.randomKey(), ShareLinkCrypto.randomKey())
    }

    func testIgnoresAPasswordWhenTheEnvelopeHasNone() throws {
        let envelope = try sealFast(plaintext, password: nil)
        XCTAssertEqual(try ShareLinkCrypto.open(envelope, key: key, password: "unused"), plaintext)
    }

    // MARK: - Passwords

    func testPasswordRoundTrip() throws {
        let envelope = try sealFast(plaintext, password: "hunter2")
        XCTAssertTrue(ShareLinkCrypto.requiresPassword(envelope))
        XCTAssertEqual(try ShareLinkCrypto.open(envelope, key: key, password: "hunter2"), plaintext)
    }

    func testMissingPasswordIsReported() throws {
        let envelope = try sealFast(plaintext, password: "hunter2")
        XCTAssertThrowsError(try ShareLinkCrypto.open(envelope, key: key, password: nil)) {
            XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .passwordRequired)
        }
    }

    func testWrongPasswordFailsAuthentication() throws {
        let envelope = try sealFast(plaintext, password: "hunter2")
        XCTAssertThrowsError(try ShareLinkCrypto.open(envelope, key: key, password: "hunter3")) {
            XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .authenticationFailed)
        }
    }

    func testPasswordIsNormalizedToNFC() throws {
        let envelope = try sealFast(plaintext, password: "caf\u{E9}")
        XCTAssertEqual(try ShareLinkCrypto.open(envelope, key: key, password: "cafe\u{301}"), plaintext)
    }

    func testRejectsZeroIterationsOnAPasswordEnvelope() throws {
        var envelope = try sealFast(plaintext, password: "hunter2")
        envelope.replaceSubrange(5..<9, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try ShareLinkCrypto.open(envelope, key: key, password: "hunter2")) {
            XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .malformedEnvelope)
        }
    }

    // MARK: - Tampering and malformed input

    func testWrongKeyFailsAuthentication() throws {
        let envelope = try sealFast(plaintext, password: nil)
        XCTAssertThrowsError(try ShareLinkCrypto.open(envelope, key: Data(repeating: 8, count: 32),
                                                      password: nil)) {
            XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .authenticationFailed)
        }
    }

    func testAlteredHeaderOrCiphertextFailsAuthentication() throws {
        let envelope = try sealFast(plaintext, password: nil)
        for index in [10, 30, ShareLinkCrypto.headerByteCount, envelope.count - 1] {
            var altered = envelope
            altered[index] ^= 0x01
            XCTAssertThrowsError(try ShareLinkCrypto.open(altered, key: key, password: nil),
                                 "byte \(index)") {
                XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .authenticationFailed)
            }
        }
    }

    func testRejectsMalformedEnvelopes() throws {
        let envelope = try sealFast(plaintext, password: nil)
        var wrongMagic = envelope
        wrongMagic[0] = UInt8(ascii: "X")
        for bad in [Data(), envelope.prefix(52), wrongMagic] {
            XCTAssertThrowsError(try ShareLinkCrypto.open(bad, key: key, password: nil)) {
                XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .malformedEnvelope)
            }
        }
        XCTAssertThrowsError(try ShareLinkCrypto.open(envelope, key: key.prefix(16), password: nil))
    }

    func testOpensAnEnvelopeSlice() throws {
        let envelope = try sealFast(plaintext, password: nil)
        let slice = (Data([0xFF]) + envelope).dropFirst()
        XCTAssertEqual(try ShareLinkCrypto.open(slice, key: key, password: nil), plaintext)
    }

    // MARK: - Size limits

    func testRefusesToSealOverTheUploadLimit() {
        var incompressible = Data(count: ShareLinkCrypto.maxEnvelopeBytes)
        incompressible.withUnsafeMutableBytes {
            _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        XCTAssertThrowsError(try sealFast(incompressible, password: nil)) {
            XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .tooLarge)
        }
    }

    func testStopsInflatingPastThePlaintextLimit() throws {
        let bomb = Data(count: ShareLinkCrypto.maxPlaintextBytes + 1)
        let envelope = try sealFast(bomb, password: nil)
        XCTAssertLessThan(envelope.count, 1024 * 1024)
        XCTAssertThrowsError(try ShareLinkCrypto.open(envelope, key: key, password: nil)) {
            XCTAssertEqual($0 as? ShareLinkCrypto.Failure, .tooLarge)
        }
    }

    func testInflatesAcrossManyChunks() throws {
        let large = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 * 31 / 7) })
        let envelope = try sealFast(large, password: nil)
        XCTAssertEqual(try ShareLinkCrypto.open(envelope, key: key, password: nil), large)
    }
}

/// `tests/fixtures/share-link/vectors.json`, shared with the web viewer's
/// tests so the two implementations cannot drift.
struct ShareLinkVectors: Decodable {
    struct Vector: Decodable {
        let name: String
        let key: String
        let password: String?
        let salt: String
        let nonce: String
        let iterations: Int
        let plaintext: String
        let envelope: String
        let link: String
    }

    let vectors: [Vector]

    static func load() throws -> [Vector] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot.appendingPathComponent("tests/fixtures/share-link/vectors.json")
        return try JSONDecoder().decode(ShareLinkVectors.self, from: Data(contentsOf: url)).vectors
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
