//
//  ShareLinkCrypto.swift
//  md-preview
//
//  Seals and opens share-link envelopes (format `MDP1`, see
//  docs/share-link-plan.md §2). The server only ever stores the envelope;
//  the key travels in the link's URL fragment. Kept free of AppKit so the
//  SPM helper tests can exercise it without a GUI host.
//

import CommonCrypto
import Compression
import CryptoKit
import Foundation

nonisolated enum ShareLinkCrypto {

    enum Failure: Error, Equatable {
        /// Not an `MDP1` envelope, or truncated.
        case malformedEnvelope
        /// A sealing key that is not `keyByteCount` long.
        case invalidKey
        /// The envelope is password-protected and no password was given.
        case passwordRequired
        /// Authentication failed: wrong key, wrong password, or tampering.
        case authenticationFailed
        /// Over `maxEnvelopeBytes` when sealing, or over
        /// `maxPlaintextBytes` when inflating.
        case tooLarge
        case compressionFailed
    }

    static let magic = Data("MDP1".utf8)
    static let keyByteCount = 32
    static let saltByteCount = 16
    static let nonceByteCount = 12
    static let tagByteCount = 16
    /// magic (4) + flags (1) + iterations (4) + salt (16) + nonce (12).
    static let headerByteCount = 37
    static let passwordIterations: UInt32 = 600_000
    /// The server's upload limit; sealing refuses anything larger.
    static let maxEnvelopeBytes = 5 * 1024 * 1024
    /// Cap on the inflated plaintext, so a small hostile envelope cannot
    /// expand into gigabytes.
    static let maxPlaintextBytes = 64 * 1024 * 1024
    /// Cap on the iteration count read from a hostile header.
    static let maxIterations: UInt32 = 10_000_000

    private static let passwordFlag: UInt8 = 0b1
    private static let info = Data("md-preview share v1".utf8)

    static func randomKey() -> Data {
        randomBytes(keyByteCount)
    }

    /// Compresses and encrypts `plaintext` with a fresh salt and nonce.
    static func seal(_ plaintext: Data, key: Data, password: String?) throws -> Data {
        try seal(plaintext,
                 key: key,
                 password: password,
                 salt: randomBytes(saltByteCount),
                 nonce: randomBytes(nonceByteCount),
                 iterations: passwordIterations)
    }

    /// Deterministic form for the test vectors. Production code calls the
    /// overload above, which never reuses a salt or nonce.
    static func seal(_ plaintext: Data,
                     key: Data,
                     password: String?,
                     salt: Data,
                     nonce: Data,
                     iterations: UInt32) throws -> Data {
        // The key can come from a damaged Keychain item; salt and nonce only
        // ever come from code.
        guard key.count == keyByteCount else { throw Failure.invalidKey }
        precondition(salt.count == saltByteCount && nonce.count == nonceByteCount)
        // `open` refuses to inflate more than this, so a larger plaintext
        // would seal into a link nobody can open.
        guard plaintext.count <= maxPlaintextBytes else { throw Failure.tooLarge }

        guard let deflated = try? (plaintext as NSData).compressed(using: .zlib) as Data else {
            throw Failure.compressionFailed
        }
        // GCM's ciphertext is as long as its input, so the envelope's size
        // is known before the encryption pass.
        guard headerByteCount + deflated.count + tagByteCount <= maxEnvelopeBytes else {
            throw Failure.tooLarge
        }

        var header = magic
        header.append(password == nil ? 0 : passwordFlag)
        withUnsafeBytes(of: (password == nil ? 0 : iterations).bigEndian) {
            header.append(contentsOf: $0)
        }
        header.append(salt)
        header.append(nonce)

        let contentKey = try deriveKey(key: key,
                                       password: password,
                                       salt: salt,
                                       iterations: iterations)
        let box = try AES.GCM.seal(deflated,
                                   using: contentKey,
                                   nonce: AES.GCM.Nonce(data: nonce),
                                   authenticating: header)

        return header + box.ciphertext + box.tag
    }

    /// Decrypts and inflates an envelope. `password` is ignored when the
    /// envelope has no password flag.
    static func open(_ envelope: Data, key: Data, password: String?) throws -> Data {
        let bytes = Data(envelope)
        guard key.count == keyByteCount,
              bytes.count >= headerByteCount + tagByteCount,
              bytes.prefix(magic.count) == magic
        else { throw Failure.malformedEnvelope }

        let flags = bytes[4]
        let iterations = bytes[5..<9].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let salt = bytes[9..<25]
        let nonce = bytes[25..<37]
        let header = bytes[0..<headerByteCount]
        let ciphertext = bytes[headerByteCount..<(bytes.count - tagByteCount)]
        let tag = bytes[(bytes.count - tagByteCount)...]

        let hasPassword = flags & passwordFlag != 0
        if hasPassword {
            guard password != nil else { throw Failure.passwordRequired }
            guard iterations > 0, iterations <= maxIterations else {
                throw Failure.malformedEnvelope
            }
        }

        let contentKey = try deriveKey(key: key,
                                       password: hasPassword ? password : nil,
                                       salt: salt,
                                       iterations: iterations)
        let deflated: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: ciphertext,
                                            tag: tag)
            deflated = try AES.GCM.open(box, using: contentKey, authenticating: header)
        } catch {
            throw Failure.authenticationFailed
        }
        return try inflate(deflated, limit: maxPlaintextBytes)
    }

    /// Reads the password flag without decrypting, so the caller can ask
    /// for a password before `open`.
    static func requiresPassword(_ envelope: Data) -> Bool {
        let bytes = Data(envelope.prefix(5))
        return bytes.count == 5
            && bytes.prefix(magic.count) == magic
            && bytes[4] & passwordFlag != 0
    }

    // MARK: - Key derivation

    private static func deriveKey(key: Data,
                                  password: String?,
                                  salt: Data,
                                  iterations: UInt32) throws -> SymmetricKey {
        var inputKeyMaterial = key
        if let password {
            inputKeyMaterial.append(try pbkdf2(password: password,
                                               salt: salt,
                                               iterations: iterations))
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
                                      salt: salt,
                                      info: info,
                                      outputByteCount: keyByteCount)
    }

    private static func pbkdf2(password: String, salt: Data, iterations: UInt32) throws -> Data {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: keyByteCount)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.withMemoryRebound(to: Int8.self) { password in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         password.baseAddress, password.count,
                                         saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                                         saltBuffer.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         iterations,
                                         &derived, derived.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.authenticationFailed }
        return Data(derived)
    }

    // MARK: - Compression

    /// Raw DEFLATE inflate (the stream `NSData.compressed(using: .zlib)`
    /// writes) that stops once the output passes `limit`.
    private static func inflate(_ data: Data, limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else { throw Failure.compressionFailed }
        defer { compression_stream_destroy(stream) }

        let chunkSize = 64 * 1024
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        var output = Data()
        return try data.withUnsafeBytes { input in
            stream.pointee.src_ptr = input.bindMemory(to: UInt8.self).baseAddress
                ?? UnsafePointer(chunk)
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = chunk
                stream.pointee.dst_size = chunkSize
                let status = compression_stream_process(stream,
                                                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.compressionFailed }
                output.append(chunk, count: chunkSize - stream.pointee.dst_size)
                guard output.count <= limit else { throw Failure.tooLarge }
                if status == COMPRESSION_STATUS_END { return output }
                // No progress with input left means a truncated stream.
                if stream.pointee.dst_size == chunkSize && stream.pointee.src_size == 0 {
                    throw Failure.compressionFailed
                }
            }
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}
