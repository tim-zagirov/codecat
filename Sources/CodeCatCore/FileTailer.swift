import Foundation

/// Remembers an offset per file and hands out only new, complete lines.
public final class FileTailer {
    private struct FileState {
        var inode: UInt64
        var offset: UInt64
        var partial: String?
    }

    private var states: [String: FileState] = [:]

    public init() {}

    public func newLines(of url: URL) -> [String] {
        let key = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        // The inode is read from the already-open handle (fstat) so there is no gap
        // between checking and reading (TOCTOU).
        guard let inode = Self.inode(ofOpen: handle) else { return [] }
        let size = (try? handle.seekToEnd()) ?? 0

        guard let known = states[key] else {
            // first time we see this file — history is not replayed
            states[key] = FileState(inode: inode, offset: size, partial: nil)
            return []
        }

        if known.inode != inode {
            // The file at this path was recreated: deleted and made again, or
            // atomically rewritten (temp file + rename, as String.write(atomically:
            // true) does). The old offset belongs to the previous inode and means
            // nothing for the new content — read the new file from its own beginning.
            return readAndAdvance(handle: handle, key: key, inode: inode, from: 0, partial: nil)
        }

        if size < known.offset {
            // The file was truncated in place (same inode, now shorter). Since the
            // inode did not change, the remaining bytes must be a prefix of what we
            // have already READ. But "read" is not the same as "handed to the caller":
            // offset counts the bytes sitting in partial too (the tail with no "\n",
            // never yet returned from newLines). If the truncation falls STRICTLY
            // INSIDE that undelivered tail, the missing part of partial cannot actually
            // be gone — all of it is still in the file, merely undelivered — and
            // naively resetting partial to nil would lose those bytes forever.
            //
            // The boundary of already-DELIVERED bytes is offset minus the length of the
            // partial buffer (in UTF-8 bytes, since offset counts bytes, not characters).
            let partialByteCount = UInt64(known.partial?.utf8.count ?? 0)
            let deliveredBoundary = known.offset - partialByteCount

            if size > deliveredBoundary {
                // The truncation landed strictly inside the buffered partial: keep the
                // surviving prefix of partial (its first size - deliveredBoundary
                // bytes) instead of discarding it.
                let survivingByteCount = Int(size - deliveredBoundary)
                if let partial = known.partial,
                    let survivingPrefix = Self.utf8Prefix(of: partial, byteCount: survivingByteCount)
                {
                    states[key] = FileState(inode: inode, offset: size, partial: survivingPrefix)
                    return []
                }
                // The cut fell in the middle of a multi-byte character — there is no
                // correct way to split it. Fall back to a full reset rather than return
                // invalid text.
                states[key] = FileState(inode: inode, offset: size, partial: nil)
                return []
            }

            // The truncation did not touch the buffered partial (it had been delivered
            // earlier, and/or the cut went below the delivered boundary) — previous
            // behaviour: just jump the offset to the end of the file and say nothing.
            states[key] = FileState(inode: inode, offset: size, partial: nil)
            return []
        }

        guard size > known.offset else { return [] }
        return readAndAdvance(handle: handle, key: key, inode: inode, from: known.offset, partial: known.partial)
    }

    private func readAndAdvance(
        handle: FileHandle, key: String, inode: UInt64, from offset: UInt64, partial: String?
    ) -> [String] {
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        let newOffset = offset + UInt64(data.count)

        let text = (partial ?? "") + (String(data: data, encoding: .utf8) ?? "")
        var lines = text.components(separatedBy: "\n")
        var newPartial: String? = lines.removeLast() // the last chunk with no \n goes to the buffer
        if newPartial?.isEmpty == true { newPartial = nil }

        states[key] = FileState(inode: inode, offset: newOffset, partial: newPartial)
        return lines.filter { !$0.isEmpty }
    }

    private static func inode(ofOpen handle: FileHandle) -> UInt64? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    /// Returns the first `byteCount` bytes of `string`'s UTF-8 representation as a
    /// string, or nil if that boundary would cut a multi-byte character in half (in
    /// which case no correct prefix string exists).
    private static func utf8Prefix(of string: String, byteCount: Int) -> String? {
        let bytes = Array(string.utf8)
        guard byteCount >= 0, byteCount <= bytes.count else { return nil }
        return String(bytes: bytes[0..<byteCount], encoding: .utf8)
    }
}
