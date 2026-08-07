import Compression
import Foundation
@testable import VibeBarCore

/// ZIP fixtures for the archive tests.
///
/// Two ways to get an archive, both used on purpose:
///
/// 1. `/usr/bin/zip` — a real encoder, so the reader is checked against bytes
///    it did not produce (deflate streams, directory entries, the flags and
///    Unix attributes a genuine tool writes). `Process` is fine in tests; the
///    product code has no way to reach a shell.
/// 2. `RawZipBuilder` — a hand-written encoder for the archives no sane tool
///    will emit: a `..` in an entry name, a lying uncompressed size, a bogus
///    entry count in the end-of-central-directory record, a compression method
///    that does not exist. Deterministic, byte-for-byte, and no dependency on
///    what version of `zip` a machine happens to ship.
enum SkillZipFixtures {
    /// Zips `name` (a directory in `parent`) into `parent/<name>.zip` and
    /// returns the archive URL. `-X` keeps extra attributes out so the
    /// extraction compares cleanly.
    @discardableResult
    static func zipDirectory(
        named name: String,
        in parent: URL,
        extraArguments: [String] = []
    ) throws -> URL {
        let archive = parent.appendingPathComponent("\(name).zip")
        try? FileManager.default.removeItem(at: archive)
        let status = try run(
            "/usr/bin/zip",
            arguments: ["-r", "-X", "-q"] + extraArguments + [archive.lastPathComponent, name],
            in: parent
        )
        guard status == 0 else {
            throw NSError(domain: "SkillZipFixtures", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "/usr/bin/zip exited with \(status)"
            ])
        }
        return archive
    }

    @discardableResult
    static func run(_ tool: String, arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Raw DEFLATE, the same stream ZIP method 8 stores.
    static func rawDeflate(_ payload: Data) -> Data {
        let capacity = payload.count + 64 * 1024
        var output = Data(count: capacity)
        let produced: Int = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                guard
                    let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                    let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        output.removeSubrange(produced...)
        return output
    }
}

/// Minimal ZIP writer with every field overridable, so a test can produce
/// exactly the malformed archive it wants to see refused.
struct RawZipBuilder {
    struct Entry {
        var name: String
        /// Overrides the UTF-8 encoding of `name` — for invalid-UTF-8 tests.
        var rawName: Data?
        var payload = Data()
        var method: UInt16 = 0
        /// Bit 11 marks the name as UTF-8, which is what modern encoders set.
        var flags: UInt16 = 0x0800
        /// High byte 3 = Unix, which is what makes the mode bits meaningful.
        var versionMadeBy: UInt16 = 0x031E
        var externalAttributes: UInt32 = UInt32(0o100_644) << 16
        var crc: UInt32?
        var declaredUncompressedSize: UInt32?

        static func file(_ name: String, _ contents: String) -> Entry {
            Entry(name: name, payload: Data(contents.utf8))
        }

        static func directory(_ name: String) -> Entry {
            Entry(
                name: name.hasSuffix("/") ? name : name + "/",
                externalAttributes: UInt32(0o040_755) << 16
            )
        }

        static func symlink(_ name: String, target: String) -> Entry {
            Entry(
                name: name,
                payload: Data(target.utf8),
                externalAttributes: (UInt32(S_IFLNK) | 0o777) << 16
            )
        }

        /// A deflated entry whose header claims a different uncompressed size.
        static func deflated(_ name: String, payload: Data, declaredSize: UInt32?) -> Entry {
            Entry(
                name: name,
                payload: SkillZipFixtures.rawDeflate(payload),
                method: 8,
                crc: CRC32.checksum(payload),
                declaredUncompressedSize: declaredSize
            )
        }
    }

    var entries: [Entry] = []
    /// Lets a test claim more entries than it wrote.
    var entryCountOverride: UInt16?

    func build() -> Data {
        var body = Data()
        var central = Data()
        for entry in entries {
            let nameBytes = entry.rawName ?? Data(entry.name.utf8)
            let offset = UInt32(body.count)
            let crc = entry.crc ?? CRC32.checksum(entry.payload)
            let compressedSize = UInt32(entry.payload.count)
            let uncompressedSize = entry.declaredUncompressedSize ?? compressedSize

            body += Self.u32(0x0403_4b50)
            body += Self.u16(20) + Self.u16(entry.flags) + Self.u16(entry.method)
            body += Self.u16(0) + Self.u16(0x21)
            body += Self.u32(crc) + Self.u32(compressedSize) + Self.u32(uncompressedSize)
            body += Self.u16(UInt16(nameBytes.count)) + Self.u16(0)
            body += nameBytes
            body += entry.payload

            central += Self.u32(0x0201_4b50)
            central += Self.u16(entry.versionMadeBy) + Self.u16(20)
            central += Self.u16(entry.flags) + Self.u16(entry.method)
            central += Self.u16(0) + Self.u16(0x21)
            central += Self.u32(crc) + Self.u32(compressedSize) + Self.u32(uncompressedSize)
            central += Self.u16(UInt16(nameBytes.count)) + Self.u16(0) + Self.u16(0)
            central += Self.u16(0) + Self.u16(0) + Self.u32(entry.externalAttributes)
            central += Self.u32(offset)
            central += nameBytes
        }

        let centralOffset = UInt32(body.count)
        let count = entryCountOverride ?? UInt16(entries.count)
        var archive = body
        archive += central
        archive += Self.u32(0x0605_4b50)
        archive += Self.u16(0) + Self.u16(0)
        archive += Self.u16(count) + Self.u16(count)
        archive += Self.u32(UInt32(central.count)) + Self.u32(centralOffset)
        archive += Self.u16(0)
        return archive
    }

    @discardableResult
    func write(to url: URL) throws -> URL {
        try build().write(to: url)
        return url
    }

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
