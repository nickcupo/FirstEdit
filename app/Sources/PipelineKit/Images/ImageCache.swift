import Foundation
import CoreGraphics

/// The pump's memory, readable from any thread.
///
/// A lock and three small stores rather than actor state, because
/// `ImagePump.cached(_:)` is nonisolated: the viewer asks for whatever is
/// already decoded on the frame it is drawing, and a hop onto an actor is a
/// frame it would not have.
///
/// - compressed thumbnail bytes, cost-limited (`Budget.thumbBytes`);
/// - decoded bitmaps in an LRU ring capped by count *and* bytes;
/// - `/crop` tiles in their own small LRU, because one 1:1 tile is the size of
///   several fitted frames and must not push the burst out of the ring.
final class ImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: ImagePump.Budget

    private var compressed: [ImagePump.Key: Data] = [:]
    private var compressedOrder: [ImagePump.Key] = []
    private var compressedBytes = 0

    private var decoded: [ImagePump.Key: CGImage] = [:]
    private var decodedOrder: [ImagePump.Key] = []
    private var decodedBytes = 0

    private var tiles: [ImagePump.Key: CGImage] = [:]
    private var tileOrder: [ImagePump.Key] = []

    init(budget: ImagePump.Budget) { self.budget = budget }

    var currentBudget: ImagePump.Budget { lock.withLock { budget } }

    func setBudget(_ b: ImagePump.Budget) {
        lock.withLock {
            budget = b
            trimLocked()
        }
    }

    // MARK: compressed

    func data(_ k: ImagePump.Key) -> Data? {
        lock.withLock {
            guard let d = compressed[k] else { return nil }
            touch(&compressedOrder, k)
            return d
        }
    }

    func store(_ d: Data, for k: ImagePump.Key) {
        lock.withLock {
            if let old = compressed[k] { compressedBytes -= old.count }
            compressed[k] = d
            compressedBytes += d.count
            touch(&compressedOrder, k)
            trimLocked()
        }
    }

    // MARK: decoded

    func image(_ k: ImagePump.Key) -> CGImage? {
        lock.withLock {
            if case .crop = k.tier {
                guard let i = tiles[k] else { return nil }
                touch(&tileOrder, k)
                return i
            }
            guard let i = decoded[k] else { return nil }
            touch(&decodedOrder, k)
            return i
        }
    }

    func store(_ i: CGImage, for k: ImagePump.Key) {
        lock.withLock {
            if case .crop = k.tier {
                tiles[k] = i
                touch(&tileOrder, k)
            } else {
                if let old = decoded[k] { decodedBytes -= Downsampler.cost(of: old) }
                decoded[k] = i
                decodedBytes += Downsampler.cost(of: i)
                touch(&decodedOrder, k)
            }
            trimLocked()
        }
    }

    /// Drop everything for one shoot — a re-cull, or the shoot being closed.
    func evict(shoot: String) {
        lock.withLock {
            for k in compressed.keys where k.shoot == shoot {
                compressedBytes -= compressed[k]?.count ?? 0
                compressed[k] = nil
            }
            compressedOrder.removeAll { $0.shoot == shoot }
            for k in decoded.keys where k.shoot == shoot {
                decodedBytes -= decoded[k].map(Downsampler.cost(of:)) ?? 0
                decoded[k] = nil
            }
            decodedOrder.removeAll { $0.shoot == shoot }
            for k in tiles.keys where k.shoot == shoot { tiles[k] = nil }
            tileOrder.removeAll { $0.shoot == shoot }
        }
    }

    struct Counts { var thumbBytes, decodedCount, decodedBytes, tileCount: Int }
    var counts: Counts {
        lock.withLock {
            Counts(thumbBytes: compressedBytes, decodedCount: decoded.count,
                   decodedBytes: decodedBytes, tileCount: tiles.count)
        }
    }

    // MARK: -

    private func touch(_ order: inout [ImagePump.Key], _ k: ImagePump.Key) {
        if let i = order.lastIndex(of: k) { order.remove(at: i) }
        order.append(k)
    }

    private func trimLocked() {
        while compressedBytes > budget.thumbBytes, let k = compressedOrder.first {
            compressedOrder.removeFirst()
            compressedBytes -= compressed.removeValue(forKey: k)?.count ?? 0
        }
        while decoded.count > budget.decodedCount || decodedBytes > budget.decodedBytes,
              let k = decodedOrder.first {
            decodedOrder.removeFirst()
            if let i = decoded.removeValue(forKey: k) { decodedBytes -= Downsampler.cost(of: i) }
        }
        while tiles.count > budget.tileCount, let k = tileOrder.first {
            tileOrder.removeFirst()
            tiles[k] = nil
        }
    }
}
