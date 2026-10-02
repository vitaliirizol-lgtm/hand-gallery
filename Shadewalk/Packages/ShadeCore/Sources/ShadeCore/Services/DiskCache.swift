import Foundation

/// Small persistent file cache: one file per key, named by the key's 64-bit FNV-1a hash.
///
/// Each file holds a short header (write date + the full key, so a hash collision reads as a miss) followed by the
/// payload. Files are written atomically, so the date and the data can never disagree. Cache I/O never throws:
/// a failed read is a miss and a failed write is a no-op. Safe for concurrent use: operations on one instance are
/// serialised by a lock, and atomic renames keep separate instances (or processes) sharing a directory consistent.
public final class DiskCache: @unchecked Sendable {
    /// A cached payload and the date it was written.
    public struct Entry: Hashable, Sendable {
        public var data: Data
        public var date: Date

        public init(data: Data, date: Date) {
            self.data = data
            self.date = date
        }
    }

    /// Extension of cache files; `removeAll()` and `prune` only touch files with it.
    public static let fileExtension = "swcache"

    private static let magic: [UInt8] = Array("SWC1".utf8)
    /// magic (4) + date bit pattern (8) + key length (4).
    private static let fixedHeaderSize = 16

    /// Directory holding the cache files (created on first write).
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// File that stores `key`: `<16 hex digits of FNV-1a(key)>.swcache`.
    public func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent(StableHash.hexDigest(key) + "." + Self.fileExtension, isDirectory: false)
    }

    /// Cached data for `key` if it was written less than `maxAge` seconds before `now`, else nil.
    public func read(key: String, maxAge: TimeInterval, now: Date = Date()) -> Data? {
        entry(forKey: key, maxAge: maxAge, now: now)?.data
    }

    /// Cached entry for `key` if it was written less than `maxAge` seconds before `now`, else nil.
    /// Entries dated after `now` (clock moved backwards) count as stale.
    public func entry(forKey key: String, maxAge: TimeInterval, now: Date = Date()) -> Entry? {
        let url = fileURL(forKey: key)
        lock.lock(); defer { lock.unlock() }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        guard let header = Self.decodeHeader(raw) else {
            // Truncated or foreign file: drop it so it doesn't linger.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard raw[header.keyRange].elementsEqual(key.utf8),
              Self.isFresh(header.date, maxAge: maxAge, now: now) else { return nil }
        return Entry(data: raw.subdata(in: header.keyRange.upperBound..<raw.endIndex), date: header.date)
    }

    /// Stores `data` for `key`, stamped with `date`. Failures are ignored (the next read simply misses).
    public func write(key: String, data: Data, date: Date = Date()) {
        let keyBytes = Array(key.utf8)
        guard let keyLength = UInt32(exactly: keyBytes.count) else { return }
        var encoded = Data(capacity: Self.fixedHeaderSize + keyBytes.count + data.count)
        encoded.append(contentsOf: Self.magic)
        Self.appendBigEndian(date.timeIntervalSince1970.bitPattern, to: &encoded)
        Self.appendBigEndian(UInt64(keyLength), byteCount: 4, to: &encoded)
        encoded.append(contentsOf: keyBytes)
        encoded.append(data)

        let url = fileURL(forKey: key)
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            try encoded.write(to: url, options: .atomic)
        } catch {
            // Best effort: a lost cache write only costs a refetch later.
        }
    }

    /// Removes the entry for `key`, if any.
    public func remove(key: String) {
        let url = fileURL(forKey: key)
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every cache file in `directory` (other files are left alone).
    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        for url in cacheFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes entries that are not fresh for `maxAge` at `now` (and unreadable files).
    public func prune(maxAge: TimeInterval, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        for url in cacheFiles() {
            if let date = Self.readDate(at: url), Self.isFresh(date, maxAge: maxAge, now: now) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    /// Cache files in `directory`. Caller holds the lock.
    private func cacheFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix("." + Self.fileExtension) }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    private static func isFresh(_ date: Date, maxAge: TimeInterval, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < maxAge
    }

    private struct Header {
        var date: Date
        /// Range of the key bytes in the raw file data; the payload follows it.
        var keyRange: Range<Data.Index>
    }

    private static func decodeHeader(_ raw: Data) -> Header? {
        guard raw.count >= fixedHeaderSize else { return nil }
        let base = raw.startIndex
        guard raw[base..<base + 4].elementsEqual(magic) else { return nil }
        let seconds = Double(bitPattern: readBigEndian(raw, at: base + 4, byteCount: 8))
        guard seconds.isFinite else { return nil }
        guard let keyLength = Int(exactly: readBigEndian(raw, at: base + 12, byteCount: 4)),
              raw.count - fixedHeaderSize >= keyLength else { return nil }
        let keyStart = base + fixedHeaderSize
        return Header(date: Date(timeIntervalSince1970: seconds), keyRange: keyStart..<keyStart + keyLength)
    }

    /// Reads only the fixed header of the file at `url` and returns its write date.
    private static func readDate(at url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: fixedHeaderSize), prefix.count == fixedHeaderSize,
              prefix.prefix(4).elementsEqual(magic) else { return nil }
        let seconds = Double(bitPattern: readBigEndian(prefix, at: prefix.startIndex + 4, byteCount: 8))
        return seconds.isFinite ? Date(timeIntervalSince1970: seconds) : nil
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int = 8, to data: inout Data) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readBigEndian(_ data: Data, at index: Data.Index, byteCount: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in index..<index + byteCount {
            value = value << 8 | UInt64(data[i])
        }
        return value
    }
}
