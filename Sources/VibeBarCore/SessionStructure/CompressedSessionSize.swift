import Foundation

/// The size a compressed session log *parses as*: its decompressed byte
/// count, which is what every structure-parsing budget is about.
///
/// A rollout Codex has compressed to `.jsonl.zst` is read through a zstd
/// decoder that reports decompressed offsets, so the service's limits (full
/// parse at 32 MiB, a refresh round's budget, the largest file it will parse
/// in the background) must be judged on that size and not on `stat`'s — a
/// very compressible session can be ten times its on-disk size, and sizing
/// it by the file would materialize the whole thing where a plain file of
/// the same content would have been windowed.
///
/// The size comes from the frame header alone. Codex's compressor pledges
/// the source length (`zstd::stream::write::Encoder::set_pledged_src_size`
/// in `codex-rs/rollout/src/compression.rs`), so every rollout it writes
/// declares its content size up front, and reading 18 bytes is the whole
/// cost of sizing it. A stream that omits the field — nothing Codex
/// produces — is sized by its file like any other, rather than decoded
/// end to end just to be measured: that is a full read's worth of work
/// per file, before any budget or cancellation check, and would repeat
/// on every launch.
enum CompressedSessionSize {
    /// Decompressed size of the compressed log at `path` when its frame
    /// header declares one; nil otherwise.
    static func declaredSize(path: String) -> Int64? {
        ZstdFrameHeader.contentSize(of: URL(fileURLWithPath: path))
    }
}

/// The decompressed size a zstd frame header declares, when it does.
enum ZstdFrameHeader {
    private static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func contentSize(of url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 18) else { return nil }
        return contentSize(in: head)
    }

    /// RFC 8878 § 3.1.1.1: magic, Frame_Header_Descriptor, optional
    /// Window_Descriptor, optional Dictionary_ID, optional Frame_Content_Size.
    static func contentSize(in head: Data) -> Int64? {
        let bytes = [UInt8](head)
        guard bytes.count >= 6, Array(bytes[0..<4]) == magic else { return nil }
        let descriptor = bytes[4]
        let fcsCode = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        let dictionaryIDSize = [0, 1, 2, 4][Int(descriptor & 0x03)]
        let fcsSize: Int
        switch fcsCode {
        case 0: fcsSize = singleSegment ? 1 : 0
        case 1: fcsSize = 2
        case 2: fcsSize = 4
        default: fcsSize = 8
        }
        guard fcsSize > 0 else { return nil }
        let index = 5 + (singleSegment ? 0 : 1) + dictionaryIDSize
        guard bytes.count >= index + fcsSize else { return nil }
        var value: UInt64 = 0
        for offset in 0..<fcsSize {
            value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        if fcsSize == 2 { value += 256 }
        guard value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }
}
