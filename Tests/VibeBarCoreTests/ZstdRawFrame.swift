import Foundation

/// A valid Zstandard frame made of raw (stored) blocks, so tests can turn
/// any JSONL into the `.jsonl.zst` Codex writes without a compressor in the
/// package. Mirrors agent-session-kit's test helper of the same shape.
enum ZstdRawFrame {
    static let maxBlockSize = 128 * 1024

    static func wrap(_ content: Data) -> Data {
        var out = Data([0x28, 0xB5, 0x2F, 0xFD])
        out.append(0xE0) // Single_Segment, 8-byte Frame_Content_Size
        var size = UInt64(content.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        let bytes = [UInt8](content)
        var cursor = 0
        repeat {
            let length = min(maxBlockSize, bytes.count - cursor)
            let isLast = cursor + length >= bytes.count
            let header = UInt32(length) << 3 | (isLast ? 1 : 0)
            out.append(UInt8(header & 0xFF))
            out.append(UInt8((header >> 8) & 0xFF))
            out.append(UInt8((header >> 16) & 0xFF))
            out.append(contentsOf: bytes[cursor..<cursor + length])
            cursor += length
        } while cursor < bytes.count
        return out
    }

    /// Replace `plain` (a `.jsonl`) with its compressed twin, the way
    /// Codex's compression worker does: write `<name>.jsonl.zst`, remove
    /// the original. Returns the compressed file's URL.
    @discardableResult
    static func compressInPlace(_ plain: URL) throws -> URL {
        let compressed = plain.appendingPathExtension("zst")
        try wrap(try Data(contentsOf: plain)).write(to: compressed)
        try FileManager.default.removeItem(at: plain)
        return compressed
    }
}
