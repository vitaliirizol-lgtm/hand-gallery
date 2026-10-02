import XCTest
@testable import ShadeCore

final class DiskCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 24 * 3600

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testFNV1aKnownVectors() {
        XCTAssertEqual(StableHash.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableHash.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
        XCTAssertEqual(StableHash.hexDigest("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(StableHash.hexDigest("foobar"), "85944171f73967e8")
        // Always 16 digits, even with leading zeros.
        for key in ["", "x", "query 1", "[out:json];node(1);out;"] {
            XCTAssertEqual(StableHash.hexDigest(key).count, 16)
        }
    }

    func testWriteThenReadRoundTrip() {
        let cache = DiskCache(directory: makeTempDirectory().appendingPathComponent("nested/dir", isDirectory: true))
        let payload = Data("{\"elements\":[]}".utf8)
        cache.write(key: "query", data: payload, date: t0)
        XCTAssertEqual(cache.read(key: "query", maxAge: day, now: t0), payload)
        XCTAssertEqual(cache.entry(forKey: "query", maxAge: day, now: t0)?.date, t0)
        XCTAssertNil(cache.read(key: "other", maxAge: day, now: t0))
    }

    func testFileIsNamedByStableHash() throws {
        let dir = makeTempDirectory()
        let cache = DiskCache(directory: dir)
        cache.write(key: "some key", data: Data([1, 2, 3]), date: t0)
        let expected = StableHash.hexDigest("some key") + ".swcache"
        XCTAssertEqual(cache.fileURL(forKey: "some key").lastPathComponent, expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [expected])
    }

    func testExpiryUsesWriteDateAndInjectedNow() {
        let cache = DiskCache(directory: makeTempDirectory())
        cache.write(key: "k", data: Data([42]), date: t0)
        XCTAssertNotNil(cache.read(key: "k", maxAge: 7 * day, now: t0.addingTimeInterval(7 * day - 1)))
        XCTAssertNil(cache.read(key: "k", maxAge: 7 * day, now: t0.addingTimeInterval(7 * day)))
        XCTAssertNil(cache.read(key: "k", maxAge: 0, now: t0))
        // Written "in the future" relative to now (clock moved back): stale.
        XCTAssertNil(cache.read(key: "k", maxAge: 7 * day, now: t0.addingTimeInterval(-60)))
        // Expired reads don't delete: a reader with a longer max age still sees it.
        XCTAssertNotNil(cache.read(key: "k", maxAge: 30 * day, now: t0.addingTimeInterval(8 * day)))
    }

    func testOverwriteReplacesDataAndDate() {
        let cache = DiskCache(directory: makeTempDirectory())
        cache.write(key: "k", data: Data([1]), date: t0)
        cache.write(key: "k", data: Data([2, 2]), date: t0.addingTimeInterval(day))
        let entry = cache.entry(forKey: "k", maxAge: 7 * day, now: t0.addingTimeInterval(day))
        XCTAssertEqual(entry?.data, Data([2, 2]))
        XCTAssertEqual(entry?.date, t0.addingTimeInterval(day))
    }

    func testEmptyPayloadAndLongUnicodeKey() {
        let cache = DiskCache(directory: makeTempDirectory())
        let key = String(repeating: "서울 shade ☀️ ", count: 400)
        cache.write(key: key, data: Data(), date: t0)
        XCTAssertEqual(cache.read(key: key, maxAge: day, now: t0), Data())
    }

    func testHashCollisionReadsAsMiss() throws {
        let dir = makeTempDirectory()
        let cache = DiskCache(directory: dir)
        cache.write(key: "A", data: Data([1]), date: t0)
        // Simulate a collision: key B's file slot holds key A's entry.
        try FileManager.default.copyItem(at: cache.fileURL(forKey: "A"), to: cache.fileURL(forKey: "B"))
        XCTAssertNil(cache.read(key: "B", maxAge: day, now: t0))
        XCTAssertEqual(cache.read(key: "A", maxAge: day, now: t0), Data([1]))
    }

    func testCorruptFilesAreMissesAndGetRemoved() throws {
        let dir = makeTempDirectory()
        let cache = DiskCache(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corrupt: [Data] = [Data(), Data("not a cache file".utf8), Data([0x53, 0x57, 0x43, 0x31, 0, 0])]
        for (i, bytes) in corrupt.enumerated() {
            let url = cache.fileURL(forKey: "k\(i)")
            try bytes.write(to: url)
            XCTAssertNil(cache.read(key: "k\(i)", maxAge: day, now: t0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        // Header claims a key longer than the file.
        cache.write(key: "long", data: Data(), date: t0)
        let url = cache.fileURL(forKey: "long")
        let truncated = try Data(contentsOf: url).prefix(18)
        try truncated.write(to: url)
        XCTAssertNil(cache.read(key: "long", maxAge: day, now: t0))
    }

    func testUnwritableDirectoryNeverThrowsAndMisses() throws {
        let dir = makeTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The cache "directory" is actually a regular file, so every write fails.
        let blocker = dir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        let cache = DiskCache(directory: blocker)
        cache.write(key: "k", data: Data([1]), date: t0)
        XCTAssertNil(cache.read(key: "k", maxAge: day, now: t0))
        cache.remove(key: "k")
        cache.removeAll()
        cache.prune(maxAge: day, now: t0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path))
    }

    func testMissingDirectoryReadsAsMiss() {
        let cache = DiskCache(directory: makeTempDirectory().appendingPathComponent("never-created"))
        XCTAssertNil(cache.read(key: "k", maxAge: day, now: t0))
        cache.removeAll()
        cache.prune(maxAge: day, now: t0)
    }

    func testRemoveAndRemoveAllOnlyTouchCacheFiles() throws {
        let dir = makeTempDirectory()
        let cache = DiskCache(directory: dir)
        cache.write(key: "a", data: Data([1]), date: t0)
        cache.write(key: "b", data: Data([2]), date: t0)
        cache.write(key: "c", data: Data([3]), date: t0)
        let foreign = dir.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: foreign)

        cache.remove(key: "a")
        XCTAssertNil(cache.read(key: "a", maxAge: day, now: t0))
        XCTAssertNotNil(cache.read(key: "b", maxAge: day, now: t0))

        cache.removeAll()
        XCTAssertNil(cache.read(key: "b", maxAge: day, now: t0))
        XCTAssertNil(cache.read(key: "c", maxAge: day, now: t0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))

        // Still usable afterwards.
        cache.write(key: "d", data: Data([4]), date: t0)
        XCTAssertEqual(cache.read(key: "d", maxAge: day, now: t0), Data([4]))
    }

    func testPruneRemovesOnlyStaleEntries() throws {
        let dir = makeTempDirectory()
        let cache = DiskCache(directory: dir)
        cache.write(key: "old", data: Data([1]), date: t0)
        cache.write(key: "fresh", data: Data([2]), date: t0.addingTimeInterval(6 * day))
        cache.write(key: "future", data: Data([3]), date: t0.addingTimeInterval(30 * day))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("0000000000000000.swcache"))

        let now = t0.addingTimeInterval(8 * day)
        cache.prune(maxAge: 7 * day, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       [cache.fileURL(forKey: "fresh").lastPathComponent])
        XCTAssertEqual(cache.read(key: "fresh", maxAge: 7 * day, now: now), Data([2]))
    }

    func testConcurrentReadsAndWritesAreSafe() {
        let dir = makeTempDirectory()
        let cache = DiskCache(directory: dir)
        let other = DiskCache(directory: dir)  // second instance on the same directory
        let t0 = self.t0
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let key = "key-\(i % 10)"
            let payload = Data(repeating: UInt8(i % 10), count: 512 + i % 7)
            (i % 2 == 0 ? cache : other).write(key: key, data: payload, date: t0)
            if let read = cache.read(key: key, maxAge: 60, now: t0) {
                // Whatever version is read must be a complete one for this key.
                XCTAssertTrue(read.allSatisfy { $0 == UInt8(i % 10) })
                XCTAssertTrue((512..<519).contains(read.count))
            }
            if i % 50 == 0 { other.prune(maxAge: 60, now: t0) }
        }
        for k in 0..<10 {
            let read = cache.read(key: "key-\(k)", maxAge: 60, now: t0)
            XCTAssertNotNil(read)
            XCTAssertTrue(read?.allSatisfy { $0 == UInt8(k) } ?? false)
        }
    }
}
