import Foundation

/// Frames that look alike, grouped the way DESIGN.md says they may be grouped.
///
/// The rules here are short and they are all refusals:
///
/// * A stack is a **contiguous run inside one burst**. Two frames with the same
///   stack id either side of a frame that is not in it are two stacks, because
///   a bracket drawn under a gap says something that is not true.
/// * **Nothing is ever hidden.** Every frame of the burst is in the filmstrip
///   in shutter order; a stack draws a bracket over its members and dims the
///   ones under the top, and that is the whole of it.
/// * The top frame is **the cull's guess**, never "the best" — measured, the
///   quality top holds a keeper in 30 of 57 stacks against 25.7 by chance
///   (DUP-11).
/// * **Compare never opens by itself** (§2.5.12). A stack is an invitation
///   printed under the picture, and C takes it.
///
/// And the word this type never uses, anywhere, in any form, is the one the
/// old detector was named after (DUP-5). A stack is "4 similar".
public struct Stack: Equatable, Sendable, Identifiable {
    public let id: String
    /// Shutter order, contiguous inside the burst.
    public let frames: [String]
    /// The cull's guess. Never called the best one.
    public let top: String
    /// Where the run starts in the burst's own frame list.
    public let start: Int

    public var count: Int { frames.count }
    public var range: Range<Int> { start..<(start + frames.count) }

    public init(id: String, frames: [String], top: String, start: Int) {
        self.id = id; self.frames = frames; self.top = top; self.start = start
    }

    public func contains(_ stem: String) -> Bool { frames.contains(stem) }
}

public enum Stacks {

    /// The stacks of one burst, from the `stack` / `stack_top` columns.
    ///
    /// A frame with no stack id is in no stack — absent means "this frame is in
    /// no stack", not "unknown". A run of one is not a stack either: a bracket
    /// over a single frame says nothing.
    public static func of(burst frames: [String], rows: [String: Row]) -> [Stack] {
        var out: [Stack] = []
        var i = 0
        while i < frames.count {
            guard let id = rows[frames[i]]?.stack, !id.isEmpty else { i += 1; continue }
            var j = i + 1
            while j < frames.count, rows[frames[j]]?.stack == id { j += 1 }
            let run = Array(frames[i..<j])
            if run.count > 1 {
                let top = run.first { rows[$0]?.stack_top == 1 } ?? run[0]
                out.append(Stack(id: id, frames: run, top: top, start: i))
            }
            i = j
        }
        return out
    }

    /// The stack a frame belongs to, if any.
    public static func stack(for stem: String, in stacks: [Stack]) -> Stack? {
        stacks.first { $0.contains(stem) }
    }

    /// ↑ / ↓ inside a burst: the next frame the cull put forward, and — when
    /// the cursor is inside a stack — the next **stack**, not the next frame.
    /// Moving one at a time through eleven frames that look alike is the thing
    /// this key exists to skip.
    public static func nextPick(from index: Int, frames: [String], rows: [String: Row],
                                stacks: [Stack], forward: Bool) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        if let here = stack(for: frames[index], in: stacks) {
            // Out of this stack, into the next one's top — or, if the next run
            // is loose frames, the first of them.
            let target = forward ? here.range.upperBound : here.range.lowerBound - 1
            guard frames.indices.contains(target) else { return nil }
            if let next = stack(for: frames[target], in: stacks) {
                return frames.firstIndex(of: next.top) ?? target
            }
            return target
        }
        let step = forward ? 1 : -1
        var i = index + step
        while frames.indices.contains(i) {
            if let s = stack(for: frames[i], in: stacks) {
                return frames.firstIndex(of: s.top) ?? i
            }
            if (rows[frames[i]]?.rating ?? 0) >= VerdictValue.inThreshold { return i }
            i += step
        }
        return nil
    }

    /// The first frame of the burst he has not marked, for the
    /// "Go to the one you haven't marked (↓)" link at the end of a burst.
    public static func firstUnmarked(in frames: [String], rows: [String: Row]) -> Int? {
        frames.firstIndex { stem in
            guard let r = rows[stem] else { return false }
            return VerdictValue.his(r) == .unmarked
        }
    }
}
