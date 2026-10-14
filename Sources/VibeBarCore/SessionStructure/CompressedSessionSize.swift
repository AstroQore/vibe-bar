import Foundation
import Synchronization

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
/// The frame header carries the decompressed size when the compressor knew
/// it; when it does not, the stream is decoded once, counting bytes and
/// stopping past `measureCap`, and the answer is remembered against the
/// file's fingerprint. A compressed rollout never changes — Codex only
/// compresses a thread idle for a week — so the first measurement is the
/// last.
enum CompressedSessionSize {
    /// Above this, a measurement stops and reports "larger than any limit";
    /// no budget distinguishes sizes past it.
    static let measureCap: Int64 = 1 << 30

    /// Decompressed size of the compressed log at `path`, or nil when it is
    /// not a readable zstd stream.
    static func logicalSize(path: String, mtimeNs: Int64, compressedSize: Int64) -> Int64? {
        let key = "\(path)\u{0}\(mtimeNs)\u{0}\(compressedSize)"
        if let known = cache.withLock({ $0[key] }) { return known }
        let url = URL(fileURLWithPath: path)
        let size = ZstdFrameHeader.contentSize(of: url) ?? measure(url)
        guard let size else { return nil }
        cache.withLock { store in
            if store.count >= 512 { store.removeAll(keepingCapacity: true) }
            store[key] = size
        }
        return size
    }

    private static let cache = Mutex<[String: Int64]>([:])

    private static func measure(_ url: URL) -> Int64? {
        guard let reader = SessionLogByteReader(url: url) else { return nil }
        defer { reader.close() }
        var total: Int64 = 0
        while total <= measureCap {
            let chunk: Data?
            do {
                chunk = try autoreleasepool { try reader.read(upToCount: 1 << 20) }
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { return total }
            total += Int64(chunk.count)
        }
        return measureCap + 1
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
        var index = 5 + (singleSegment ? 0 : 1) + dictionaryIDSize
        guard bytes.count >= index + fcsSize else { return nil }
        var value: UInt64 = 0
        for offset in 0..<fcsSize {
            value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
        }
        index += fcsSize
        if fcsSize == 2 { value += 256 }
        guard value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }
}
