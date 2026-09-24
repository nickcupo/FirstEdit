import SwiftUI
import AVKit

/// The last reel cut from this shoot, at 9:16, in a real `AVPlayerView` with
/// the system's own controls (DESIGN.md §2.6). It does not play when the page
/// comes on screen — a page he opens to choose frames is not a page that
/// should start moving — but a reel he has just cut from here plays when it
/// comes out: he asked for it, and it sat paused until he found play. Its
/// share button sends the file by AirDrop without a trip to the folder.
struct ReelPreview: View {
    let model: ReelsModel
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many reels he had cut from the page when it came on screen. A
    /// player made later — the shoot's first reel has none before it — still
    /// knows the reel it loads is new.
    @State private var cutsOnArrival: Int

    init(model: ReelsModel, height: CGFloat) {
        self.model = model
        self.height = height
        _cutsOnArrival = State(initialValue: model.reelsCut)
    }

    var body: some View {
        let width = (height * 9 / 16).rounded()
        VStack(alignment: .leading, spacing: Tokens.Metric.labelValueGap) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tokens.Palette.viewerBackground)
                if let url = model.lastReelURL, let r = model.lastReel {
                    ReelPlayer(url: url, version: "\(r.bytes)|\(r.at)", cuts: model.reelsCut,
                               cutsOnArrival: cutsOnArrival, playsNew: !reduceMotion)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(Text(Strings.Reels.lastCut))
                } else {
                    Text(Strings.Reels.noneYet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(10)
                }
            }
            .frame(width: width, height: height)
            if let r = model.lastReel {
                // Beside "Burst 93" the player read as burst 93's reel. It is
                // the shoot's newest, whichever burst it was cut from, and the
                // first line says so; the name is one line, where it wrapped
                // to four in the narrow layout, less the shoot's name this
                // page is already in. What does not fit goes from the front,
                // which every reel of the shoot shares: cut in the middle, the
                // part that differs from reel to reel was the part lost.
                Text(Strings.Reels.lastCutAt(Self.when(r.at)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.shown(r.name, shoot: model.session.name))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .help("\(r.name) · \(ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file))")
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

extension ReelPreview {
    /// A reel's file name without the shoot's name in front of it, when it
    /// starts with it; any other name is left whole. The page is in that
    /// shoot already, and in the narrow layout the shoot's name was most of
    /// what the line had room for.
    static func shown(_ name: String, shoot: String) -> String {
        for joint in ["-", "_", " "] where !shoot.isEmpty && name.hasPrefix(shoot + joint) {
            let rest = name.dropFirst(shoot.count + joint.count)
            if !rest.isEmpty { return String(rest) }
        }
        return name
    }

    /// The engine's "2026-09-20 15:16", said as a person would: "Today at
    /// 3:16 PM", "Yesterday at 3:16 PM", "Sep 20, 3:16 PM", with the year
    /// only when it is not this one. As written when it is not a time.
    static func when(_ at: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let read = DateFormatter()
        read.locale = Locale(identifier: "en_US_POSIX")
        read.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = read.date(from: at) else { return at }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 99
        if daysAgo == 0 || daysAgo == 1 {
            let say = DateFormatter()
            say.dateStyle = .medium
            say.timeStyle = .short
            say.doesRelativeDateFormatting = true
            return say.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = sameYear ? Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
                             : Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute()
        return date.formatted(style)
    }
}

/// `AVPlayerView`, looping and muted: paused until he presses play, except
/// for a reel he has just cut, which plays as it loads.
///
/// Cutting the same burst again writes the same file name, so the URL alone
/// does not say the reel changed: `version` (its size and time) does, and the
/// player loads the new cut rather than playing the one it replaced.
struct ReelPlayer: NSViewRepresentable {
    let url: URL
    var version = ""
    /// `ReelsModel.reelsCut`: when it has moved since the player last looked,
    /// the next reel it loads is the one he just cut.
    var cuts = 0
    /// The count when the page came on screen, which the player starts from.
    var cutsOnArrival = 0
    /// Off under Reduce Motion: nothing on the page starts moving by itself.
    var playsNew = true

    final class Coordinator {
        var loaded: String?
        var looper: AVPlayerLooper?
        /// The count of reels cut the last time one was loaded, or when the
        /// page came on screen: a reel cut before he arrived is not played
        /// at him.
        var cuts: Int

        init(cuts: Int) { self.cuts = cuts }
    }

    nonisolated static func identity(_ url: URL, _ version: String) -> String { url.path + "#" + version }

    /// Whether the reel being loaded is one he has just cut, to be played.
    nonisolated static func playsOnLoad(cuts: Int, seen: Int, playsNew: Bool) -> Bool { playsNew && cuts != seen }

    func makeCoordinator() -> Coordinator { Coordinator(cuts: cutsOnArrival) }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        // AirDrop, Messages and the rest, from the reel itself: sending it to
        // the phone to post was Show in Finder and a drag.
        v.showsSharingServiceButton = true
        v.allowsPictureInPicturePlayback = false
        load(url, into: v, context.coordinator)
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if context.coordinator.loaded != Self.identity(url, version) { load(url, into: v, context.coordinator) }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: Coordinator) {
        v.player?.pause()
        v.player = nil
        coordinator.looper = nil
    }

    private func load(_ url: URL, into v: AVPlayerView, _ c: Coordinator) {
        c.loaded = Self.identity(url, version)
        v.player?.pause()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        c.looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        v.player = player
        if Self.playsOnLoad(cuts: cuts, seen: c.cuts, playsNew: playsNew) { player.play() }
        c.cuts = cuts
    }
}
