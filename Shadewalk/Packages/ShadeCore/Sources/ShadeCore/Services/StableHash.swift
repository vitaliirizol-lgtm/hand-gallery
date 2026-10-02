import Foundation

/// Deterministic, process-independent hashing (Swift's `Hasher` is randomly seeded per launch, so it can't name files).
public enum StableHash {
    private static let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    /// 64-bit FNV-1a over `bytes`.
    public static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash = fnvOffsetBasis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    /// 64-bit FNV-1a over the UTF-8 encoding of `string`.
    public static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(string.utf8)
    }

    /// FNV-1a of `string` as 16 lowercase, zero-padded hex digits (e.g. `"af63dc4c8601ec8c"` for `"a"`).
    public static func hexDigest(_ string: String) -> String {
        let hex = String(fnv1a64(string), radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
