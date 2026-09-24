#if canImport(AppKit)
import AppKit

/// What happens when he touches the picture window.
///
/// Clicks and gestures go to the window under the pointer whether or not it is
/// key, so all of this works with no focus change at all — and none of it can
/// change which window is key, because the window says it cannot be.
///
/// **A click is never a verdict.** In Compare it moves the focus ring; in The
/// Whole Burst it moves the cursor; everywhere else it does nothing but
/// activate the app. The same rule as the stage (§2.5.8).
@MainActor
public final class PictureContentView: NSView {

    var onChromeReveal: ((Bool) -> Void)?
    var onPointerMoved: (() -> Void)?

    private let state: PictureViewState
    private weak var director: DisplayDirector?
    private var tracking: NSTrackingArea?
    private var hideTimer: Task<Void, Never>?
    private var pointerHidden = false
    private var hideAfter: Double = 1.5
    private var inTitleZone = false
    private var dragOrigin: NSPoint?

    init(state: PictureViewState, director: DisplayDirector) {
        self.state = state
        self.director = director
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = true
        addGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    public override var isFlipped: Bool { true }

    /// With PhotoLab in front, the first click both activates First Edit
    /// and does its thing — and the **main** window becomes key, not this one.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public var pictureBox: CGRect { DisplayMetric.pictureBox(in: bounds) }

    func tearDown() {
        hideTimer?.cancel()
        unhidePointer()
    }

    func setDrawing(_ on: Bool) {
        if !on { unhidePointer() }
    }

    func setFrozen(_ on: Bool) {}

    func backingChanged() {}

    func setPointerHiding(after seconds: Double) {
        hideAfter = seconds
        armPointerHiding()
    }

    // MARK: - the pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        unhidePointer()
        onPointerMoved?()
        armPointerHiding()
        let p = convert(event.locationInWindow, from: nil)
        // The real title bar fades in when he reaches for it, and out again a
        // second and a half after he leaves.
        let nowInZone = p.y <= DisplayMetric.titleBarZone
        if nowInZone != inTitleZone {
            inTitleZone = nowInZone
            onChromeReveal?(nowInZone)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        unhidePointer()
        armPointerHiding()
    }

    /// The exit handler unhides unconditionally, so the hide count can never
    /// go negative.
    public override func mouseExited(with event: NSEvent) {
        hideTimer?.cancel()
        unhidePointer()
        if inTitleZone {
            inTitleZone = false
            onChromeReveal?(false)
        }
    }

    /// A stated, narrow exception to §2.15's "the pointer is never hidden": a
    /// black arrow parked in the middle of a photograph he is judging is in the
    /// frame. It comes back on the first movement.
    private func armPointerHiding() {
        hideTimer?.cancel()
        guard state.hidePointerWhenStill || state.isPresenting else { return }
        let seconds = state.isPresenting ? 2.0 : hideAfter
        hideTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hidePointer()
        }
    }

    private func hidePointer() {
        guard !pointerHidden else { return }
        pointerHidden = true
        NSCursor.hide()
    }

    private func unhidePointer() {
        guard pointerHidden else { return }
        pointerHidden = false
        NSCursor.unhide()
    }

    // MARK: - clicks

    public override func mouseDown(with event: NSEvent) {
        guard !state.isPresenting else { return }
        dragOrigin = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            director?.input?.toggleFitOneToOne(atFramePoint: framePoint(event))
            return
        }
        switch state.content {
        case .tiles(let tiles, _, _):
            if let i = tileIndex(at: convert(event.locationInWindow, from: nil), count: tiles.count) {
                director?.input?.focusTile(i)
            }
        case .burst:
            // The contact sheet's own collection view handles its clicks.
            break
        case .frame, .nothing, .job, .engineDown:
            break
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !state.isPresenting, case .frame(let stem, _, _) = state.content,
              let origin = dragOrigin else { return }
        let here = convert(event.locationInWindow, from: nil)
        guard hypot(here.x - origin.x, here.y - origin.y) > 8 else { return }
        dragOrigin = nil
        beginFrameDrag(stem: stem, event: event)
    }

    public override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    public override func rightMouseDown(with event: NSEvent) {
        guard !state.isPresenting, let menu = contextMenu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard !state.isPresenting else { return }
        // The same normalisation the light table uses: a wheel mouse counts
        // lines, a trackpad counts points, and the photograph should move the
        // same distance for the same movement of his hand.
        let d = ScrollInput.points(event)
        director?.input?.pan(byFramePoints: CGSize(width: d.dx, height: d.dy))
    }

    // MARK: - the trackpad

    private func addGestures() {
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(magnify)
    }

    @objc private func pinched(_ g: NSMagnificationGestureRecognizer) {
        guard !state.isPresenting else { return }
        let p = g.location(in: self)
        director?.input?.pinch(scaleBy: 1 + g.magnification, atFramePoint: normalised(p))
        g.magnification = 0
    }

    public override func smartMagnify(with event: NSEvent) {
        guard !state.isPresenting else { return }
        director?.input?.smartZoom(atFramePoint: framePoint(event))
    }

    /// Spring-loaded 100 % peek while held, on both windows.
    public override func pressureChange(with event: NSEvent) {
        guard !state.isPresenting else { return }
        director?.input?.peek(event.stage >= 2, atFramePoint: framePoint(event))
    }

    public override func swipe(with event: NSEvent) {
        guard !state.isPresenting, event.deltaX != 0 else { return }
        director?.input?.step(forward: event.deltaX < 0)
    }

    // MARK: - the context menu

    /// The stage's own menu, explicitly summoned, never under the cursor.
    ///
    /// **With Hold on, the verdict items are absent** — the held frame is not
    /// the frame at the cursor, and a Keep there would be a verdict on a frame
    /// he is not at.
    ///
    /// Its rows are the Frame menu's own words (`Words.Frame`): this menu was
    /// written out in English here, and said "Compare Similar" beside the
    /// menu bar's "Compare Similar Frames".
    func contextMenu(for event: NSEvent) -> NSMenu? {
        guard let director else { return nil }
        let stem: String?
        switch state.content {
        case .frame(let s, _, _): stem = s
        case .tiles(let t, let focus, _): stem = t.indices.contains(focus) ? t[focus].stem : nil
        case .burst(_, let cells, let cursor): stem = cells.indices.contains(cursor) ? cells[cursor].stem : nil
        case .nothing, .job, .engineDown: stem = nil
        }
        guard let stem else { return nil }
        let menu = NSMenu()
        let holding = director.heldStem != nil

        if !holding {
            add(menu, Words.Frame.keep, .keep, stem)
            add(menu, Words.Frame.drop, .drop, stem)
            add(menu, Words.Frame.clearMark, .clearMark, stem)
            menu.addItem(.separator())
            add(menu, Words.Frame.compare, .compare, stem)
            add(menu, DisplayStrings.Menu.hold, .hold, stem)
        } else {
            add(menu, DisplayStrings.Menu.releaseHold, .hold, stem)
        }
        menu.addItem(.separator())
        let finder = NSMenuItem(title: Words.Frame.showInFinder, action: #selector(showInFinder(_:)),
                                keyEquivalent: "")
        finder.target = self
        finder.representedObject = stem
        menu.addItem(finder)
        let copy = NSMenuItem(title: Words.Frame.copyNumber, action: #selector(copyNumber(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = stem
        menu.addItem(copy)
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: DisplayAction, _ stem: String) {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [action.rawValue, stem]
        item.isEnabled = director?.allows(action) ?? false
        menu.addItem(item)
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let action = DisplayAction(rawValue: pair[0]) else { return }
        if action == .hold { director?.toggleHold(); return }
        director?.input?.verdict(action, onStem: pair[1])
    }

    @objc private func copyNumber(_ sender: NSMenuItem) {
        guard let stem = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ShootSession.shortStem(stem), forType: .string)
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let stem = sender.representedObject as? String,
              let url = director?.exportedFile(for: stem) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - dragging a frame out

    private func beginFrameDrag(stem: String, event: NSEvent) {
        guard let director, let writer = director.pasteboardWriter(for: stem) else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        let box = pictureBox
        item.setDraggingFrame(box, contents: snapshotOfPicture())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func snapshotOfPicture() -> NSImage? {
        let box = pictureBox
        guard box.width > 1, box.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: box) else { return nil }
        cacheDisplay(in: box, to: rep)
        let image = NSImage(size: box.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - geometry

    private func framePoint(_ event: NSEvent) -> CGPoint {
        normalised(convert(event.locationInWindow, from: nil))
    }

    /// A point in the view, in the frame's own normalised coordinates.
    private func normalised(_ p: CGPoint) -> CGPoint {
        let box = pictureBox
        guard box.width > 0, box.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, (p.x - box.minX) / box.width)),
                       y: min(1, max(0, (p.y - box.minY) / box.height)))
    }

    private func tileIndex(at p: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = count <= 2 ? count : 2
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let box = pictureBox
        guard box.contains(p) else { return nil }
        let col = min(columns - 1, Int((p.x - box.minX) / (box.width / CGFloat(columns))))
        let row = min(rows - 1, Int((p.y - box.minY) / (box.height / CGFloat(rows))))
        let i = row * columns + col
        return i < count ? i : nil
    }
}

extension PictureContentView: NSDraggingSource {
    /// `.copy` outside the app and nothing at all inside it, so a drag can
    /// never be read as a move and can never re-order the strip. A drag never
    /// changes the cursor and never writes a verdict.
    public func draggingSession(_ session: NSDraggingSession,
                                sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
#endif
