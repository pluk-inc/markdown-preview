//
//  ZIPArchiveWriter.swift
//  md-preview
//

import Foundation
import zlib

/// The small part of ZIP that EPUB export needs: stored or deflated entries
/// held in memory, UTF-8 names, no ZIP64 and no encryption.
nonisolated struct ZIPArchiveWriter {
    enum Compression {
        case stored
        case deflated
    }

    enum ArchiveError: Error {
        /// An entry or the archive is beyond what ZIP can describe without ZIP64.
        case tooLarge
    }

    private var archive = Data()
    private var centralDirectory = Data()
    private var entryCount = 0

    /// Entries keep the order they are added in. EPUB requires `mimetype` to
    /// be the first entry and stored, so readers can sniff it at a fixed offset.
    mutating func add(_ contents: Data, at path: String,
                      compression: Compression = .deflated) throws {
        let name = Data(path.utf8)
        var method: UInt16 = 0
        var payload = contents
        if compression == .deflated, !contents.isEmpty,
           // NSData's zlib algorithm is the raw DEFLATE stream ZIP expects.
           let deflated = try? (contents as NSData).compressed(using: .zlib) as Data,
           deflated.count < contents.count {
            method = 8
            payload = deflated
        }
        guard entryCount < Int(UInt16.max),
              let nameLength = UInt16(exactly: name.count),
              let size = UInt32(exactly: contents.count),
              let compressedSize = UInt32(exactly: payload.count),
              let offset = UInt32(exactly: archive.count)
        else { throw ArchiveError.tooLarge }

        let checksum = contents.withUnsafeBytes { buffer in
            UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
        var fields = Data()
        fields.append(littleEndian: UInt16(method == 8 ? 20 : 10))  // version needed
        fields.append(littleEndian: UInt16(0x0800))                 // UTF-8 names
        fields.append(littleEndian: method)
        // A fixed timestamp (1980-01-01): the archive records no export time.
        fields.append(littleEndian: UInt16(0))
        fields.append(littleEndian: UInt16(0x0021))
        fields.append(littleEndian: checksum)
        fields.append(littleEndian: compressedSize)
        fields.append(littleEndian: size)
        fields.append(littleEndian: nameLength)
        fields.append(littleEndian: UInt16(0))                      // extra field

        archive.append(littleEndian: UInt32(0x0403_4b50))
        archive.append(fields)
        archive.append(name)
        archive.append(payload)

        centralDirectory.append(littleEndian: UInt32(0x0201_4b50))
        centralDirectory.append(littleEndian: UInt16(20))           // version made by
        centralDirectory.append(fields)
        centralDirectory.append(littleEndian: UInt16(0))            // comment
        centralDirectory.append(littleEndian: UInt16(0))            // disk number
        centralDirectory.append(littleEndian: UInt16(0))            // internal attributes
        centralDirectory.append(littleEndian: UInt32(0))            // external attributes
        centralDirectory.append(littleEndian: offset)
        centralDirectory.append(name)
        entryCount += 1
    }

    func finish() throws -> Data {
        guard let directoryOffset = UInt32(exactly: archive.count),
              let directorySize = UInt32(exactly: centralDirectory.count)
        else { throw ArchiveError.tooLarge }
        var data = archive
        data.append(centralDirectory)
        data.append(littleEndian: UInt32(0x0605_4b50))
        data.append(littleEndian: UInt16(0))                        // this disk
        data.append(littleEndian: UInt16(0))                        // directory disk
        data.append(littleEndian: UInt16(entryCount))
        data.append(littleEndian: UInt16(entryCount))
        data.append(littleEndian: directorySize)
        data.append(littleEndian: directoryOffset)
        data.append(littleEndian: UInt16(0))                        // comment
        return data
    }
}

nonisolated private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
