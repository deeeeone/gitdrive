import Foundation

/// Content-defined chunking (FastCDC with normalized chunking).
///
/// Boundaries depend on the content, so an edit in the middle of a big file only changes the chunks
/// around it, and identical data in different files produces identical chunks that are stored once.
/// The gear table comes from the folder key, so boundaries can't be used to fingerprint known files.
public struct Chunker: Sendable {
    public let minSize: Int
    public let avgSize: Int
    public let maxSize: Int
    private let gear: [UInt64]
    private let maskSmall: UInt64
    private let maskLarge: UInt64

    public init(gearSeed: Data, minSize: Int = 256 * 1024, avgSize: Int = 1024 * 1024, maxSize: Int = 4 * 1024 * 1024) {
        precondition(gearSeed.count >= 2048, "gear seed needs 2048 bytes")
        self.minSize = minSize
        self.avgSize = avgSize
        self.maxSize = maxSize
        gear = gearSeed.withUnsafeBytes { raw in
            (0..<256).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self) }
        }
        // The rolling hash shifts left, so only the high bits depend on a full window of bytes.
        let bits = Int(log2(Double(avgSize)).rounded())
        maskSmall = Self.highMask(bits: bits + 2)
        maskLarge = Self.highMask(bits: bits - 2)
    }

    private static func highMask(bits: Int) -> UInt64 {
        bits >= 64 ? .max : ((1 << UInt64(bits)) - 1) << UInt64(64 - bits)
    }

    /// Byte ranges of each chunk. Empty data has no chunks.
    public func chunks(of data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { raw -> [Range<Int>] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var out: [Range<Int>] = []
            var start = 0
            while start < bytes.count {
                let end = cut(bytes, from: start)
                out.append(start..<end)
                start = end
            }
            return out
        }
    }

    private func cut(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let remaining = bytes.count - start
        if remaining <= minSize { return bytes.count }
        let limit = min(remaining, maxSize)
        let normal = min(avgSize, limit)
        var hash: UInt64 = 0
        var i = minSize
        while i < normal {
            hash = (hash << 1) &+ gear[Int(bytes[start + i])]
            if hash & maskSmall == 0 { return start + i + 1 }
            i += 1
        }
        while i < limit {
            hash = (hash << 1) &+ gear[Int(bytes[start + i])]
            if hash & maskLarge == 0 { return start + i + 1 }
            i += 1
        }
        return start + limit
    }
}

/// Padmé padding: rounds a length up so it leaks at most O(log log n) bits, with under 12% overhead.
/// See "Reducing Metadata Leakage from Encrypted Files and Communication with PURBs" (Nikitin et al.).
public func padme(_ length: Int) -> Int {
    guard length > 1 else { return length }
    let e = Int(log2(Double(length)))
    let s = Int(log2(Double(e))) + 1
    let lastBits = e - s
    let mask = (1 << lastBits) - 1
    return (length + mask) & ~mask
}
