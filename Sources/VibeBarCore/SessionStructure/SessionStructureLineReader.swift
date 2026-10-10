import Foundation

/// Streams a JSONL file line by line in 64 KiB chunks, reporting each
/// line's byte offset and honouring an optional byte window.
///
/// Differences from `JSONLLineScanner.forEachLine` (which this otherwise
/// mirrors, O(n) with a moving cursor):
///
/// - every line carries its absolute file offset, which is what a turn's
///   `byteOffset` is and what a later windowed re-read seeks to;
/// - a `ByteRange` restricts the walk to lines that *start* inside the
///   window — the reader seeks to the window, resynchronizes on the next
///   newline, and stops reading as soon as a line starts past the end, so
///   parsing one turn of a 3 GB rollout reads that turn and nothing else;
/// - a line longer than `maxLineBytes` (a base64 screenshot in a tool
///   result) is not buffered whole: only its first `headBytes` are kept and
///   the line is flagged `isTruncated`. Memory stays bounded by
///   `max(maxLineBytes, chunk)` no matter what the file holds.
enum SessionStructureLineReader {
    static let chunkSize = 64 * 1024
    static let defaultMaxLineBytes = 8 * 1024 * 1024
    static let defaultHeadBytes = 64 * 1024

    struct Line {
        /// The line without its newline — or only its head when truncated.
        let data: Data
        let offset: Int64
        /// Full length of the line in the file (excluding the newline).
        let length: Int64
        let isTruncated: Bool

        /// Offset just past this line's newline.
        var end: Int64 { offset + length + 1 }
    }

    struct Outcome {
        /// The walk reached the end of the file or of the window.
        var completed: Bool
        var bytesRead: Int64
        /// Offset just past the last delivered line (or the window start).
        var lastLineEnd: Int64
    }

    /// - Parameters:
    ///   - isCancelled: polled once per chunk.
    ///   - body: return `false` to stop early.
    @discardableResult
    static func forEachLine(
        in url: URL,
        range: SessionStructure.ByteRange? = nil,
        maxLineBytes: Int = defaultMaxLineBytes,
        headBytes: Int = defaultHeadBytes,
        isCancelled: () -> Bool = { false },
        _ body: (Line) -> Bool
    ) -> Outcome {
        // `SessionLogByteReader` reads a compressed rollout (`.jsonl.zst`)
        // through zstd and reports *decompressed* offsets, so a turn's
        // byte window recorded against the plain file still lands on the
        // same line after Codex compresses it.
        guard let handle = SessionLogByteReader(url: url) else {
            return Outcome(completed: false, bytesRead: 0, lastLineEnd: range?.lowerBound ?? 0)
        }
        defer { handle.close() }

        let lower = range?.lowerBound ?? 0
        let upper = range?.upperBound ?? Int64.max
        var fileOffset: Int64 = 0
        var skippingToNewline = false
        if lower > 0 {
            do {
                try handle.seek(toOffset: lower - 1)
            } catch {
                return Outcome(completed: false, bytesRead: 0, lastLineEnd: lower)
            }
            fileOffset = lower - 1
            skippingToNewline = true
        }
        let startOffset = fileOffset
        let headCap = max(0, min(headBytes, maxLineBytes))

        var lineBuffer: [UInt8] = []
        var lineStart: Int64 = fileOffset
        var lineLength: Int64 = 0
        var lineTruncated = false
        var lastLineEnd: Int64 = lower
        var stopped = false
        var reachedEnd = false

        func append(_ base: UnsafePointer<UInt8>, _ count: Int) {
            guard count > 0 else { return }
            lineLength += Int64(count)
            if lineTruncated {
                return
            }
            if lineBuffer.count + count <= maxLineBytes {
                lineBuffer.append(contentsOf: UnsafeBufferPointer(start: base, count: count))
                return
            }
            lineTruncated = true
            if lineBuffer.count > headCap {
                lineBuffer.removeSubrange(headCap...)
            } else {
                let room = headCap - lineBuffer.count
                lineBuffer.append(contentsOf: UnsafeBufferPointer(start: base, count: min(room, count)))
            }
        }

        func emit() -> Bool {
            defer {
                lineBuffer.removeAll(keepingCapacity: lineBuffer.capacity <= 4 * chunkSize)
                lineLength = 0
                lineTruncated = false
            }
            guard lineLength > 0 else { return true }
            let line = Line(
                data: Data(lineBuffer),
                offset: lineStart,
                length: lineLength,
                isTruncated: lineTruncated
            )
            lastLineEnd = line.end
            return body(line)
        }

        do {
            while !stopped {
                if isCancelled() { stopped = true; break }
                // `read(upToCount:)` hands back autoreleased storage; without
                // a pool per chunk every chunk of the file stays resident
                // until the caller's pool drains — memory linear in file size.
                let chunk: Data? = try autoreleasepool { try handle.read(upToCount: chunkSize) }
                guard let chunk, !chunk.isEmpty else {
                    reachedEnd = true
                    break
                }
                let chunkBase = fileOffset
                chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    let count = raw.count
                    var i = 0
                    while i < count {
                        if skippingToNewline {
                            if let hit = memchr(base + i, 0x0A, count - i) {
                                let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                                i = at + 1
                                skippingToNewline = false
                                lineStart = chunkBase + Int64(i)
                            } else {
                                i = count
                            }
                            continue
                        }
                        if lineLength == 0, lineStart >= upper {
                            stopped = true
                            return
                        }
                        if let hit = memchr(base + i, 0x0A, count - i) {
                            let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                            append(base + i, at - i)
                            if !emit() {
                                stopped = true
                                return
                            }
                            i = at + 1
                            lineStart = chunkBase + Int64(i)
                        } else {
                            append(base + i, count - i)
                            i = count
                        }
                    }
                }
                fileOffset += Int64(chunk.count)
            }
        } catch {
            return Outcome(completed: false, bytesRead: fileOffset - startOffset, lastLineEnd: lastLineEnd)
        }
        if reachedEnd, !skippingToNewline, lineLength > 0, lineStart < upper {
            if !emit() { stopped = true }
        }
        let completed = reachedEnd || (stopped && lineStart >= upper)
        return Outcome(completed: completed, bytesRead: fileOffset - startOffset, lastLineEnd: lastLineEnd)
    }

    // MARK: - Head sniffing for truncated lines

    /// The first string value of `"key":"…"` in `data`, without decoding
    /// JSON. Only for truncated lines, whose tail is gone; tolerant of a
    /// space after the colon, not of escaped quotes inside the value (ids
    /// and type tags never contain them).
    static func sniffString(_ key: String, in data: Data) -> String? {
        guard let needle = "\"\(key)\":".data(using: .utf8),
              let found = data.range(of: needle)
        else { return nil }
        var index = found.upperBound
        while index < data.endIndex, data[index] == 0x20 { index += 1 }
        guard index < data.endIndex, data[index] == 0x22 else { return nil }
        let valueStart = data.index(after: index)
        guard let close = data[valueStart...].firstIndex(of: 0x22) else { return nil }
        return String(data: data[valueStart..<close], encoding: .utf8)
    }

    static func sniffInt(_ key: String, in data: Data) -> Int? {
        guard let needle = "\"\(key)\":".data(using: .utf8),
              let found = data.range(of: needle)
        else { return nil }
        var index = found.upperBound
        while index < data.endIndex, data[index] == 0x20 { index += 1 }
        var value = 0
        var digits = 0
        var negative = false
        if index < data.endIndex, data[index] == 0x2D { negative = true; index += 1 }
        while index < data.endIndex, data[index] >= 0x30, data[index] <= 0x39, digits < 18 {
            value = value * 10 + Int(data[index] - 0x30)
            digits += 1
            index += 1
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }

    static func contains(_ ascii: String, in data: Data) -> Bool {
        guard let needle = ascii.data(using: .utf8) else { return false }
        return data.range(of: needle) != nil
    }
}
