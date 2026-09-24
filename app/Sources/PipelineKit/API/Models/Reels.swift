import Foundation

// MARK: - GET /api/reel/options, /api/reel/watch

public struct ReelOptions: FieldDecodable {
    public let sequences: [BurstOption]
    public let cuts: [BurstOption]
    public let frames: [ReelFrame]
    public let sources: [ReelSource]
    public let exports_found: Int
    public let exports_dir: String
    public let tags: [ReelTag]?
    public let visible: Int?
    public let reels: [ReelFile]
    public let reel_dir: String
    /// Sent by the engine, not in DESIGN.md §3.4: which pictures the list was
    /// built from.
    public let source: String
    public let error: String?
    /// Further things the crop can follow, beyond the three every build has
    /// (whatever is moving, the people, nothing). DESIGN.md §2.6: any option
    /// past those is the extension's, contributed at runtime, so no name of
    /// one is ever written into the app. Today's engine sends none, and then
    /// this is empty and the picker has the three.
    public let follow: [ReelFollow]

    public init(fields f: Fields) throws {
        sequences = try f.objects("sequences").map(BurstOption.init(fields:))
        cuts = try f.objects("cuts").map(BurstOption.init(fields:))
        frames = try f.objects("frames").map(ReelFrame.init(fields:))
        sources = try f.objects("sources").map(ReelSource.init(fields:))
        exports_found = f.int("exports_found")
        exports_dir = f.string("exports_dir")
        tags = f.has("tags") ? try f.objects("tags").map(ReelTag.init(fields:)) : nil
        visible = f.intOrNil("visible")
        reels = try f.objects("reels").map(ReelFile.init(fields:))
        reel_dir = f.string("reel_dir")
        source = f.string("source")
        error = f.stringOrNil("error")
        // One at a time: an entry the extension sent without an `id` is
        // left out, rather than taking the whole answer and the page with it.
        follow = f.objects("follow").compactMap { try? ReelFollow(fields: $0) }
    }
}

extension ReelOptions: CarriesRefusal {}

/// One thing the crop can follow that the extension offers. `id` is the word
/// sent back to the engine as `follow`; `label` is what the picker says.
public struct ReelFollow: FieldDecodable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let note: String
    public init(fields f: Fields) throws {
        id = try f.requireString("id")
        label = f.string("label", id)
        note = f.string("note")
    }
    public init(id: String, label: String, note: String = "") {
        self.id = id; self.label = label; self.note = note
    }
}

public struct BurstOption: FieldDecodable, Identifiable {
    public var id: String { burst }
    public let burst: String
    public let frames: Int
    public let exported: Int
    public let lands_on: String?
    /// Also sent, and named on the tile: how many of the burst's frames can be
    /// used, how long it would run, how much movement there is, and how many
    /// he kept.
    public let usable: Int?
    public let seconds: Double?
    public let action: Double?
    public let kept: Int?

    public init(fields f: Fields) throws {
        burst = try f.requireString("burst")
        frames = f.int("frames")
        exported = f.int("exported")
        lands_on = f.stringOrNil("lands_on")
        usable = f.intOrNil("usable")
        seconds = f.doubleOrNil("seconds")
        action = f.doubleOrNil("action")
        kept = f.intOrNil("kept")
    }
}

public struct ReelFrame: FieldDecodable, Identifiable, Equatable {
    public var id: String { stem }
    public let stem: String
    /// A frame not yet exported is dimmed and says so; it is never hidden.
    public let exported: Bool
    /// Whether there is a picture of it to cut from at all: his export, or
    /// the cull's own decode of the RAW. A frame that is neither cannot go in
    /// a reel. Absent on an older lister, which only listed what it could
    /// show, so absent is true.
    public let visible: Bool
    /// The cull's stars for it, when the lister says. Never his verdict.
    public let rating: Int?
    public init(fields f: Fields) throws {
        stem = try f.requireString("stem")
        exported = f.bool("exported")
        visible = f.bool("visible", true)
        rating = f.intOrNil("rating")
    }
    public init(stem: String, exported: Bool, visible: Bool = true, rating: Int? = nil) {
        self.stem = stem; self.exported = exported; self.visible = visible; self.rating = rating
    }
}

public struct ReelSource: FieldDecodable {
    public let path: String
    public let frames: Int
    public init(fields f: Fields) throws {
        path = f.string("path")
        frames = f.int("frames")
    }
}

public struct ReelTag: FieldDecodable {
    public let name: String
    public let frames: Int
    public init(fields f: Fields) throws {
        name = f.string("name")
        frames = f.int("frames")
    }
}

public struct ReelFile: FieldDecodable, Identifiable {
    public var id: String { name }
    public let name: String
    public let bytes: Int
    public let at: String
    public init(fields f: Fields) throws {
        name = try f.requireString("name")
        bytes = f.int("bytes")
        at = f.string("at")
    }
}

public struct ReelWatch: FieldDecodable {
    public let jpegs: Int
    public let burst: String
    public init(fields f: Fields) throws {
        jpegs = f.int("jpegs")
        burst = f.string("burst")
    }
}
