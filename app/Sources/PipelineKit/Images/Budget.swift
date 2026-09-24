import Foundation

extension ImagePump {
    /// How much the pump may hold. DESIGN.md §3.5, scaled with the Mac.
    ///
    /// At 16 GB: compressed thumbnails in 96 MB; decoded bitmaps for the
    /// current burst in a ring of 24 or 512 MB, whichever is smaller; at most 8
    /// `/crop` tiles. Every cap scales with `physicalMemory / 16 GB`, so a
    /// 64 GB Mac holds four times as much and an 8 GB one half.
    public struct Budget: Sendable, Equatable {
        public var thumbBytes: Int
        public var decodedCount: Int
        public var decodedBytes: Int
        public var tileCount: Int

        public init(thumbBytes: Int, decodedCount: Int, decodedBytes: Int, tileCount: Int) {
            self.thumbBytes = thumbBytes
            self.decodedCount = decodedCount
            self.decodedBytes = decodedBytes
            self.tileCount = tileCount
        }

        public static let base = Budget(thumbBytes: 96 << 20, decodedCount: 24,
                                        decodedBytes: 512 << 20, tileCount: 8)

        public static let automatic = scaled(forPhysicalMemory: ProcessInfo.processInfo.physicalMemory)

        public static func scaled(forPhysicalMemory bytes: UInt64) -> Budget {
            let sixteen = Double(16 << 30)
            // Clamped: a 4 GB machine still gets a working ring, and a 192 GB
            // one does not hold a whole shoot of decoded bitmaps it will never
            // look at twice.
            let k = min(4, max(0.5, Double(bytes) / sixteen))
            return Budget(thumbBytes: Int(Double(base.thumbBytes) * k),
                          decodedCount: max(4, Int((Double(base.decodedCount) * k).rounded())),
                          decodedBytes: Int(Double(base.decodedBytes) * k),
                          tileCount: max(2, Int((Double(base.tileCount) * k).rounded())))
        }

        /// Under memory pressure: the thumbnail cache halves and the ring
        /// drops to 4.
        public var underPressure: Budget {
            Budget(thumbBytes: thumbBytes / 2, decodedCount: min(decodedCount, 4),
                   decodedBytes: min(decodedBytes, decodedBytes / 2), tileCount: min(tileCount, 2))
        }
    }

    /// What the bench harness cross-checks against the process footprint.
    public struct Report: Sendable, Equatable {
        public var budget: Budget
        public var thumbBytes: Int
        public var decodedCount: Int
        public var decodedBytes: Int
        public var tileCount: Int
        public var inFlight: Int
        public var inFlightColdFull: Int
        public var peakColdFull: Int
        public var prefetches: Int
        public var fetched: Int
        public var cancelled: Int
        public var underPressure: Bool
    }
}
