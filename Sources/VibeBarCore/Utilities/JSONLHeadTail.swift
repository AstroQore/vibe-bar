import Foundation

/// Byte-level head / tail line access for append-only JSONL logs.
///
/// Session metadata only needs the first and last handful of lines of a
/// rollout file. Reading a multi-megabyte transcript to learn its title
/// would make a session list unusable, so files above
/// `wholeFileThreshold` are seeked into instead: the tail window starts
/// at `length - wholeFileThreshold`, and the (almost certainly partial)
/// first line inside that window is discarded.
///
/// Everything works on raw bytes and splits on `0x0A`, which cannot
/// appear inside a multi-byte UTF-8 sequence, so a window boundary can
/// never cut a scalar in half.
public enum JSONLHeadTail {
    /// Files at or below this size are read whole.
    public static let wholeFileThreshold: Int64 = 16 * 1024

    private static let chunkSize = 16 * 1024

    /// First `count` non-empty lines, reading only as far as needed.
    public static func headLines(url: URL, count: Int) -> [Data] {
        guard count > 0 else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var out: [Data] = []
        var buffer: [UInt8] = []
        var lineStart = 0
        do {
            while out.count < count,
                  let chunk = try handle.read(upToCount: chunkSize),
                  !chunk.isEmpty {
                buffer.append(contentsOf: chunk)
                let end = buffer.count
                var i = lineStart
                while i < end {
                    if buffer[i] == 0x0A {
                        if i > lineStart {
                            out.append(Data(buffer[lineStart..<i]))
                        }
                        lineStart = i + 1
                        if out.count >= count { return out }
                    }
                    i += 1
                }
                if lineStart > chunkSize {
                    buffer.removeFirst(lineStart)
                    lineStart = 0
                }
            }
            if out.count < count, lineStart < buffer.count {
                let tail = Data(buffer[lineStart..<buffer.count])
                if !tail.isEmpty { out.append(tail) }
            }
        } catch {
            return out
        }
        return out
    }

    /// Last `count` non-empty lines.
    ///
    /// Files at or below `wholeFileThreshold` are read whole. Larger
    /// files are seeked to `length - wholeFileThreshold`; the byte just
    /// before that offset decides whether the window opens on a line
    /// boundary or mid-line, and a mid-line opening drops its first
    /// (partial) segment.
    ///
    /// The window is fixed, so a `count` larger than the number of
    /// lines inside `wholeFileThreshold` bytes returns fewer lines than
    /// asked for. That is the point: metadata extraction must stay
    /// bounded no matter how large the transcript grew.
    public static func tailLines(url: URL, count: Int) -> [Data] {
        guard count > 0 else { return [] }
        let size = fileSize(url)
        guard size > 0 else { return [] }

        var segments: [Data]
        if size <= wholeFileThreshold {
            guard let whole = try? Data(contentsOf: url) else { return [] }
            segments = splitLines(whole)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            // Seek one byte early so we can tell a boundary-aligned
            // window from one that opens in the middle of a line.
            let probe = UInt64(size - wholeFileThreshold) - 1
            var read: Data?
            do {
                try handle.seek(toOffset: probe)
                read = try handle.readToEnd()
            } catch {
                return []
            }
            guard let window = read, !window.isEmpty else { return [] }

            if window.first == 0x0A {
                segments = splitLines(Data(window.dropFirst()))
            } else {
                segments = splitLines(window)
                if !segments.isEmpty { segments.removeFirst() }
            }
        }

        segments.removeAll { $0.isEmpty }
        if segments.count > count {
            segments.removeFirst(segments.count - count)
        }
        return segments
    }

    /// Non-empty line count, but only for files small enough that a
    /// whole-file read is free. Returns `nil` for anything larger so
    /// callers can record a "not counted" sentinel instead of paying
    /// for a full scan during metadata extraction.
    public static func lineCountIfSmall(url: URL, maxBytes: Int64 = wholeFileThreshold) -> Int? {
        let size = fileSize(url)
        guard size >= 0, size <= maxBytes else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var count = 0
        var segmentLength = 0
        for byte in data {
            if byte == 0x0A {
                if segmentLength > 0 { count += 1 }
                segmentLength = 0
            } else {
                segmentLength += 1
            }
        }
        if segmentLength > 0 { count += 1 }
        return count
    }

    public static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return -1
        }
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Split on `0x0A`, keeping empty segments so positional decisions
    /// (like "drop the first, partial line") stay accurate.
    private static func splitLines(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var out: [Data] = []
        var start = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                out.append(Data(bytes[start..<i]))
                start = i + 1
            }
            i += 1
        }
        if start < bytes.count {
            out.append(Data(bytes[start..<bytes.count]))
        }
        return out
    }
}
