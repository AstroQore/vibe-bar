import Compression
import Foundation

public enum SkillArchiveError: Error, Equatable, Sendable {
    case notAZipArchive
    case corruptArchive(String)
    case unsupportedZip64
    case unsupportedCompressionMethod(UInt16)
    case encryptedEntry(String)
    case tooManyEntries(limit: Int)
    case archiveTooLarge(limit: Int64)
    case unsafeEntryPath(String)
    case symlinkEntry(String)
    case duplicateEntry(String)
    case invalidEntryName
    case checksumMismatch(String)
}

extension SkillArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "The downloaded file is not a ZIP archive."
        case let .corruptArchive(detail):
            return "The ZIP archive is corrupt (\(detail))."
        case .unsupportedZip64:
            return "ZIP64 archives are not supported."
        case let .unsupportedCompressionMethod(method):
            return "Unsupported ZIP compression method \(method)."
        case let .encryptedEntry(name):
            return "The archive entry \"\(name)\" is encrypted."
        case let .tooManyEntries(limit):
            return "The archive holds more than \(limit) entries."
        case let .archiveTooLarge(limit):
            return "The archive expands past its \(limit)-byte limit."
        case let .unsafeEntryPath(name):
            return "The archive entry \"\(name)\" points outside the extraction directory."
        case let .symlinkEntry(name):
            return "The archive entry \"\(name)\" is a symbolic link."
        case let .duplicateEntry(name):
            return "The archive holds \"\(name)\" more than once."
        case .invalidEntryName:
            return "The archive holds an entry whose name is not valid UTF-8."
        case let .checksumMismatch(name):
            return "The archive entry \"\(name)\" failed its checksum."
        }
    }
}

/// Minimal, deliberately hostile-input-hardened ZIP reader.
///
/// Vibe Bar downloads zipballs of arbitrary third-party GitHub repositories, so
/// extraction is the sharpest edge in the whole feature. Shelling out to
/// `/usr/bin/unzip` or `ditto` is not an option (no `Process` in product code,
/// and neither tool would enforce our budgets anyway), and no dependency is
/// worth adding for it — macOS already ships the one hard part, raw DEFLATE, in
/// the `Compression` framework.
///
/// What is supported: the single-disk, non-ZIP64 subset the whole world
/// actually produces — an end-of-central-directory record found by scanning the
/// tail, central-directory headers as the authority for sizes and attributes
/// (never the local header, whose sizes are zero when a data descriptor is
/// used), and entries stored (method 0) or deflated (method 8). CRC-32 is
/// verified for every file. Anything else — ZIP64 sentinels, encryption,
/// multi-disk, another compression method — is refused by name rather than
/// guessed at.
///
/// What is refused, entry by entry:
/// - absolute paths, `..` in any component, empty components, backslashes,
///   control characters, and over-long components;
/// - symlinks, recognized from the Unix mode in the central-directory external
///   attributes (a link is the classic way to turn a "safe" relative path into
///   a write anywhere on disk);
/// - names that are not valid UTF-8;
/// - duplicate paths, compared case- and Unicode-normalization-insensitively,
///   because the destination filesystem usually is — a second entry must never
///   silently overwrite what the first one wrote;
/// - anything past the entry-count budget or the running extracted-byte budget.
///
/// The byte budget is checked twice: once against the sizes the central
/// directory declares (a cheap up-front rejection) and again against bytes
/// actually produced by the inflater, so a lying header buys nothing.
public struct SkillArchiveExtractor {
    /// Enough for the largest skill repository by a wide margin;
    /// `anthropics/skills` is ~200 files.
    public static let maxEntries = 10_000
    public static let maxExtractedBytes: Int64 = 512 * 1024 * 1024
    /// One path component. Well under `NAME_MAX`, and past any real filename.
    public static let maxComponentLength = 200

    /// Extracts every file entry of `zipFileURL` under `destination`, creating
    /// intermediate directories as needed. Returns the number of files written.
    ///
    /// The budgets are parameters so callers (and tests) can tighten them; the
    /// defaults are the ones the skills feature runs with.
    @discardableResult
    public static func extract(
        zipFileURL: URL,
        into destination: URL,
        maxEntries: Int = SkillArchiveExtractor.maxEntries,
        maxExtractedBytes: Int64 = SkillArchiveExtractor.maxExtractedBytes
    ) throws -> Int {
        let data = try Data(contentsOf: zipFileURL, options: [.mappedIfSafe])
        let reader = ByteReader(data: data)
        let directory = try readCentralDirectory(reader, maxEntries: maxEntries)

        var declared: Int64 = 0
        for entry in directory where !entry.isDirectory {
            declared += Int64(entry.uncompressedSize)
            if declared > maxExtractedBytes { throw SkillArchiveError.archiveTooLarge(limit: maxExtractedBytes) }
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var written = 0
        var produced: Int64 = 0
        for entry in directory {
            let target = try resolve(components: entry.components, under: destination)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try payload(
                for: entry,
                reader: reader,
                remainingBudget: maxExtractedBytes - produced
            )
            produced += Int64(payload.count)
            if produced > maxExtractedBytes { throw SkillArchiveError.archiveTooLarge(limit: maxExtractedBytes) }
            try payload.write(to: target, options: [.atomic])
            // Only the execute bit is carried over, and only from a Unix
            // archive: setuid/setgid/sticky are never restored from content
            // fetched off the network.
            if let mode = entry.unixMode, mode & 0o111 != 0 {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: target.path
                )
            }
            written += 1
        }
        return written
    }

    // MARK: - Central directory

    struct Entry {
        let name: String
        let components: [String]
        let isDirectory: Bool
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let unixMode: UInt16?
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let zip64Sentinel32: UInt32 = 0xFFFF_FFFF

    private static func readCentralDirectory(_ reader: ByteReader, maxEntries: Int) throws -> [Entry] {
        guard reader.count >= 22 else { throw SkillArchiveError.notAZipArchive }
        guard let eocd = locateEndOfCentralDirectory(reader) else {
            throw SkillArchiveError.notAZipArchive
        }
        let totalEntries = Int(try reader.u16(eocd + 10))
        let centralSize = try reader.u32(eocd + 12)
        let centralOffset = try reader.u32(eocd + 16)
        guard centralSize != Self.zip64Sentinel32, centralOffset != Self.zip64Sentinel32 else {
            throw SkillArchiveError.unsupportedZip64
        }
        guard totalEntries <= maxEntries else {
            throw SkillArchiveError.tooManyEntries(limit: maxEntries)
        }

        var cursor = Int(centralOffset)
        let end = min(reader.count, cursor + Int(centralSize))
        var entries: [Entry] = []
        var seen = Set<String>()
        while cursor + 46 <= end {
            guard try reader.u32(cursor) == Self.centralHeaderSignature else { break }
            let versionMadeBy = try reader.u16(cursor + 4)
            let flags = try reader.u16(cursor + 8)
            let method = try reader.u16(cursor + 10)
            let crc = try reader.u32(cursor + 16)
            let compressedSize = try reader.u32(cursor + 20)
            let uncompressedSize = try reader.u32(cursor + 24)
            let nameLength = Int(try reader.u16(cursor + 28))
            let extraLength = Int(try reader.u16(cursor + 30))
            let commentLength = Int(try reader.u16(cursor + 32))
            let externalAttributes = try reader.u32(cursor + 38)
            let localOffset = try reader.u32(cursor + 42)

            let nameData = try reader.slice(cursor + 46, nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw SkillArchiveError.invalidEntryName
            }
            if flags & 0x0001 != 0 { throw SkillArchiveError.encryptedEntry(name) }
            guard
                compressedSize != Self.zip64Sentinel32,
                uncompressedSize != Self.zip64Sentinel32,
                localOffset != Self.zip64Sentinel32
            else { throw SkillArchiveError.unsupportedZip64 }

            entries.append(
                try makeEntry(
                    name: name,
                    versionMadeBy: versionMadeBy,
                    method: method,
                    crc: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localOffset: localOffset,
                    externalAttributes: externalAttributes,
                    seen: &seen
                )
            )
            guard entries.count <= maxEntries else {
                throw SkillArchiveError.tooManyEntries(limit: maxEntries)
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func makeEntry(
        name: String,
        versionMadeBy: UInt16,
        method: UInt16,
        crc: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        localOffset: UInt32,
        externalAttributes: UInt32,
        seen: inout Set<String>
    ) throws -> Entry {
        // Host system 3 is Unix; only then do the high 16 bits of the external
        // attributes carry a `st_mode`.
        let unixMode: UInt16? = (versionMadeBy >> 8) == 3 ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : nil
        if let unixMode, unixMode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
            throw SkillArchiveError.symlinkEntry(name)
        }
        let isDirectory = name.hasSuffix("/")
        let components = try safeComponents(of: name)
        let normalized = components
            .joined(separator: "/")
            .precomposedStringWithCanonicalMapping
            .lowercased()
        guard seen.insert(normalized).inserted else {
            throw SkillArchiveError.duplicateEntry(name)
        }
        if !isDirectory, method != 0, method != 8 {
            throw SkillArchiveError.unsupportedCompressionMethod(method)
        }
        return Entry(
            name: name,
            components: components,
            isDirectory: isDirectory,
            method: method,
            crc32: crc,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            localHeaderOffset: localOffset,
            unixMode: unixMode
        )
    }

    /// Scans the tail for the EOCD signature, newest first. The record can sit
    /// up to 64 KiB from the end because of the archive comment, so the window
    /// is that plus the record itself.
    private static func locateEndOfCentralDirectory(_ reader: ByteReader) -> Int? {
        let maximumComment = 0xFFFF
        let lowest = max(0, reader.count - maximumComment - 22)
        var offset = reader.count - 22
        while offset >= lowest {
            if let signature = try? reader.u32(offset), signature == Self.endOfCentralDirectorySignature {
                let commentLength = (try? reader.u16(offset + 20)).map(Int.init) ?? -1
                if commentLength >= 0, offset + 22 + commentLength <= reader.count { return offset }
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Payloads

    private static func payload(
        for entry: Entry,
        reader: ByteReader,
        remainingBudget: Int64
    ) throws -> Data {
        let header = Int(entry.localHeaderOffset)
        guard header + 30 <= reader.count, try reader.u32(header) == Self.localHeaderSignature else {
            throw SkillArchiveError.corruptArchive("local header for \(entry.name)")
        }
        let nameLength = Int(try reader.u16(header + 26))
        let extraLength = Int(try reader.u16(header + 28))
        let start = header + 30 + nameLength + extraLength
        let compressed = try reader.slice(start, Int(entry.compressedSize))

        let payload: Data
        switch entry.method {
        case 0:
            payload = compressed
        case 8:
            payload = try RawDeflate.inflate(
                compressed,
                expectedSize: Int(entry.uncompressedSize),
                limit: max(0, remainingBudget)
            )
        default:
            throw SkillArchiveError.unsupportedCompressionMethod(entry.method)
        }
        guard payload.count == Int(entry.uncompressedSize) else {
            throw SkillArchiveError.corruptArchive("size mismatch for \(entry.name)")
        }
        guard CRC32.checksum(payload) == entry.crc32 else {
            throw SkillArchiveError.checksumMismatch(entry.name)
        }
        return payload
    }

    // MARK: - Path safety

    /// Splits an entry name into components, refusing everything that could
    /// escape the destination. Directory entries lose their trailing slash.
    static func safeComponents(of name: String) throws -> [String] {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\") else {
            throw SkillArchiveError.unsafeEntryPath(name)
        }
        // A Windows drive prefix ("C:/x") is not a relative path either.
        if isDrivePrefixed(name) { throw SkillArchiveError.unsafeEntryPath(name) }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            throw SkillArchiveError.unsafeEntryPath(name)
        }
        var trimmed = Substring(name)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard !trimmed.isEmpty else { throw SkillArchiveError.unsafeEntryPath(name) }

        var components: [String] = []
        for raw in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw)
            guard
                !component.isEmpty,
                component != ".",
                component != "..",
                component.utf8.count <= maxComponentLength
            else {
                throw SkillArchiveError.unsafeEntryPath(name)
            }
            components.append(component)
        }
        guard !components.isEmpty else { throw SkillArchiveError.unsafeEntryPath(name) }
        return components
    }

    private static func isDrivePrefixed(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars.prefix(2))
        guard scalars.count == 2, scalars[1] == ":" else { return false }
        let letter = scalars[0]
        return ("a"..."z").contains(letter) || ("A"..."Z").contains(letter)
    }

    /// Appends validated components one at a time and re-asserts containment on
    /// the result: the component check is the guarantee, this is the audit.
    private static func resolve(components: [String], under destination: URL) throws -> URL {
        var url = destination
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: false)
        }
        let root = destination.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw SkillArchiveError.unsafeEntryPath(components.joined(separator: "/"))
        }
        return url
    }
}

/// Bounds-checked little-endian view over the archive bytes. Every read goes
/// through here so a truncated or hand-crafted file produces an error instead
/// of a trap.
struct ByteReader {
    let data: Data

    var count: Int { data.count }

    func byte(_ offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < data.count else {
            throw SkillArchiveError.corruptArchive("read past end")
        }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        UInt16(try byte(offset)) | (UInt16(try byte(offset + 1)) << 8)
    }

    func u32(_ offset: Int) throws -> UInt32 {
        UInt32(try u16(offset)) | (UInt32(try u16(offset + 2)) << 16)
    }

    func slice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw SkillArchiveError.corruptArchive("read past end")
        }
        let start = data.startIndex + offset
        return Data(data[start..<(start + length)])
    }
}

/// Raw DEFLATE (RFC 1951) decode over `Compression`.
///
/// `COMPRESSION_ZLIB` in Apple's framework is the *raw* deflate stream — no
/// zlib header, no trailer — which is exactly what ZIP method 8 stores, so no
/// wrapper stripping is needed. The output is bounded as it is produced: a
/// bomb is stopped at the budget rather than after materializing gigabytes.
enum RawDeflate {
    static func inflate(_ source: Data, expectedSize: Int, limit: Int64) throws -> Data {
        if source.isEmpty { return Data() }
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: bufferSize,
            src_ptr: destination,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SkillArchiveError.corruptArchive("inflate init")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        output.reserveCapacity(min(expectedSize, 8 * 1024 * 1024))
        var overflowed = false
        try source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw SkillArchiveError.corruptArchive("empty deflate stream")
            }
            stream.src_ptr = base
            stream.src_size = raw.count
            stream.dst_ptr = destination
            stream.dst_size = bufferSize

            var status = COMPRESSION_STATUS_OK
            repeat {
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        output.append(destination, count: produced)
                        stream.dst_ptr = destination
                        stream.dst_size = bufferSize
                    } else if status == COMPRESSION_STATUS_OK {
                        // No progress with the whole input available means the
                        // stream cannot be finished — refuse rather than spin.
                        throw SkillArchiveError.corruptArchive("stalled deflate stream")
                    }
                    if Int64(output.count) > limit {
                        overflowed = true
                        return
                    }
                default:
                    throw SkillArchiveError.corruptArchive("deflate stream")
                }
            } while status == COMPRESSION_STATUS_OK
        }
        if overflowed { throw SkillArchiveError.archiveTooLarge(limit: limit) }
        return output
    }
}

/// CRC-32 (IEEE 802.3), the checksum ZIP records for every entry. Verifying it
/// costs one pass over data we already hold and turns a silently corrupted
/// download into an error.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
