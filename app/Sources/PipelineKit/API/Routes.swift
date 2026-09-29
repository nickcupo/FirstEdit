import Foundation

/// One static per route the engine serves. Nothing in the app builds a path by
/// hand: a name in a URL is one typo away from a 404 that reads like a broken
/// shoot, and this table is what the decoding tests are indexed by.
public enum Routes {

    // MARK: GET

    public static func shoots() -> Route<ShootsResponse> {
        Route(.get, "/api/shoots")
    }

    public static func shoot(_ name: String, full: Bool = false) -> Route<ShootResponse> {
        Route(.get, "/api/shoot", full ? ["name": name, "full": "1"] : ["name": name])
    }

    /// The cheap poll: `Shoot.info()` and nothing else. The Edit step's export
    /// count falls back to it when the file-system watcher cannot be used.
    public static func shootLight(_ name: String) -> Route<ShootLightResponse> {
        Route(.get, "/api/shoot", ["name": name, "light": "1"])
    }

    public static func job() -> Route<Job> {
        Route(.get, "/api/job")
    }

    public static func storage(_ name: String) -> Route<Storage> {
        Route(.get, "/api/storage", ["name": name])
    }

    /// Fetched only on the first expand of the fold: 1,157 rows are never
    /// built for a panel nobody has unfolded.
    public static func storageFrames(_ name: String) -> Route<StorageFrames> {
        Route(.get, "/api/storage/frames", ["name": name])
    }

    /// Reads back the plan the engine drew. The app never computes one.
    public static func storagePlan(_ name: String, what: String,
                                   opts: PlanOptions = .none) -> Route<Plan> {
        var q = opts.query
        q["name"] = name
        q["what"] = what
        return Route(.get, "/api/storage/plan", q)
    }

    public static func storageLibrary() -> Route<LibraryLine> {
        Route(.get, "/api/storage/library")
    }

    public static func reelOptions(_ name: String, burst: String? = nil,
                                   src: String? = nil) -> Route<ReelOptions> {
        var q = ["name": name]
        if let burst { q["burst"] = burst }
        if let src { q["src"] = src }
        return Route(.get, "/api/reel/options", q)
    }

    public static func reelWatch(_ name: String, burst: String) -> Route<ReelWatch> {
        Route(.get, "/api/reel/watch", ["name": name, "burst": burst])
    }

    /// The Instagram step's wall (DESIGN.md §2.17). Answers at once and
    /// starts nothing.
    public static func instagram(_ name: String) -> Route<InstagramStatus> {
        Route(.get, "/api/instagram", ["name": name])
    }

    public static func cards() -> Route<CardsResponse> {
        Route(.get, "/api/cards")
    }

    public static func update(force: Bool = false) -> Route<UpdateInfo> {
        Route(.get, "/api/update", force ? ["force": "1"] : [:])
    }

    public static func learned() -> Route<Learned> {
        Route(.get, "/api/learned")
    }

    /// Whatever the extension serves under its own name, carried untyped.
    public static func ext(_ name: String) -> Route<JSONValue> {
        Route(.get, "/ext/\(name)")
    }

    // MARK: POST

    public static let rating = Route<RatingResult>(.post, "/api/rating")
    public static let review = Route<ReviewResult>(.post, "/api/review")
    public static let kind = Route<KindResult>(.post, "/api/kind")
    public static let label = Route<OK>(.post, "/api/label")
    public static let open = Route<OpenResult>(.post, "/api/open")
    public static let cull = Route<OK>(.post, "/api/cull")
    public static let presets = Route<OK>(.post, "/api/presets")
    public static let selects = Route<SelectsResult>(.post, "/api/selects")
    public static let ingest = Route<OKName>(.post, "/api/ingest")
    public static let reel = Route<OK>(.post, "/api/reel")
    public static let spread = Route<OK>(.post, "/api/spread")
    /// Works out the cuts of every frame that has none, in the background.
    public static let instagramPlan = Route<InstagramPlanAnswer>(.post, "/api/instagram/plan")
    /// Makes exactly the cuts named: a job, and it can go on Up Next.
    public static let instagramMake = Route<OK>(.post, "/api/instagram/make")
    /// One frame's cut saved; a copy already made is made again at once.
    public static let instagramCrop = Route<InstagramCropAnswer>(.post, "/api/instagram/crop")
    /// The shoot's shape, and every cut redrawn from it.
    public static let instagramShape = Route<InstagramStatus>(.post, "/api/instagram/shape")
    public static let setup = Route<OK>(.post, "/api/setup")
    public static let jobStop = Route<OK>(.post, "/api/job/stop")
    /// The same endpoint. With an id in the body it takes that waiting
    /// request out of the line instead of stopping what is running; named
    /// separately so the call site says which of the two it means.
    public static let jobCancel = Route<OK>(.post, "/api/job/stop")
    public static let updateDownload = Route<OK>(.post, "/api/update/download")
    public static let updateInstall = Route<OK>(.post, "/api/update/install")
    public static let storageRetain = Route<RetainResult>(.post, "/api/storage/retain")
    public static let storageCheck = Route<OK>(.post, "/api/storage/check")
    public static let storagePlanDraw = Route<OK>(.post, "/api/storage/plan")
    public static let storageApply = Route<ApplyResult>(.post, "/api/storage/apply")
    public static let learnedRun = Route<OK>(.post, "/api/learned/run")
    public static let learnedBack = Route<OK>(.post, "/api/learned/back")
    public static let learnedStop = Route<OK>(.post, "/api/learned/stop")
    public static let learnedUseAnyway = Route<OK>(.post, "/api/learned/use-anyway")
}
