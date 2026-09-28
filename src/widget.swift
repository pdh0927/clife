import Cocoa

// MARK: - Desktop widget

/// Where the widget parks. Named corners rather than only free dragging, because a
/// window at desktop level is the hardest kind to grab: anything on top of it takes
/// the click, so "just drag it" can be advice the user cannot follow.
enum WidgetCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var label: String {
        switch self {
        case .topLeft:     return "좌측 상단"
        case .topRight:    return "우측 상단"
        case .bottomLeft:  return "좌측 하단"
        case .bottomRight: return "우측 하단"
        }
    }
}

// MARK: - Card

/// The card itself: glass, the dog, the limit rows and the freshness line.
///
/// One implementation for every place the card appears -- the desktop widget and the
/// hotkey peek both host an instance of this, and the rows and the header are the
/// dropdown's own `DogHeaderView` and `UsageRowView`. Two copies of this layout would
/// drift the first time either one was touched, and then two surfaces would disagree
/// about the same numbers, which is worse than having only one of them.
///
/// Always Apple's *large* widget size, 344x344. A card of any other size cannot line
/// up with the system widgets next to it however the grid is tuned; this one is two
/// cells by two, so it sits flush with Calendar or Weather in any slot.
final class UsageCardView: NSView {
    static let size = NSSize(width: 344, height: 344)
    static let cornerRadius: CGFloat = 22
    /// Horizontal inset; the rows and the header carry their own 12-14pt on top.
    static let padding: CGFloat = 8
    static let headerTop: CGFloat = 12
    static let headerHeight: CGFloat = 68
    private static let rowHeight: CGFloat = 54
    private static let rowGap: CGFloat = 12
    private static let statusHeight: CGFloat = 16
    private static let statusBottom: CGFloat = 16

    let header = DogHeaderView()
    private var rows: [UsageRowView] = []
    private let statusLabel = NSTextField(labelWithString: "")
    private let glass = NSVisualEffectView()
    private let edge = CardEdgeView()

    /// Right-click target. Set by the widget to the app's own menu -- with the menu
    /// bar icon switched off this is the only way back to the settings, including the
    /// one that turns the icon on again, which is why hiding it is allowed at all.
    var contextMenu: NSMenu?
    /// A plain click. Nil means "let the window have it", which is what makes the
    /// widget draggable by its background.
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }   // matches the menu's top-down row order

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        // The system's desktop widgets are glass, not paint: dark in dark mode,
        // light in light mode, and blurred over whatever is behind them. A material
        // that follows the effective appearance gets both for free, and "Reduce
        // transparency" turns it opaque without any code here.
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        // A behind-window blur is composited by the window server, which ignores the
        // layer's corner radius -- only a mask image rounds it.
        glass.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        for view in [glass, header, statusLabel, edge] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `reset` turns a limit's reset date into the same wording the menu uses.
    func update(limits: [UsageLimit], status: String, reset: (Date?) -> String) {
        // ponytail: a fixed card fits four rows under the header; the API returns three
        // today. More than four are left to the menu -- compact rows if that changes.
        let shown = Array(limits.prefix(Self.maxRows))
        while rows.count < shown.count {
            let row = UsageRowView()
            addSubview(row, positioned: .below, relativeTo: edge)
            rows.append(row)
        }
        while rows.count > shown.count { rows.removeLast().removeFromSuperview() }

        for (row, limit) in zip(rows, shown) {
            row.update(title: limit.title, percent: limit.percent, subtitle: reset(limit.resetsAt))
        }
        header.update(limit: limits.dogBinding, reset: "")
        statusLabel.stringValue = status
        needsLayout = true
    }

    private static var rowsTop: CGFloat { headerTop + headerHeight }
    private static var rowsBottom: CGFloat { size.height - statusBottom - statusHeight - 4 }
    static var maxRows: Int { Int((rowsBottom - rowsTop + rowGap) / (rowHeight + rowGap)) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        edge.frame = bounds
        let width = bounds.width - Self.padding * 2
        header.frame = NSRect(x: Self.padding, y: Self.headerTop, width: width, height: Self.headerHeight)
        statusLabel.frame = NSRect(x: Self.padding + 12,
                                   y: bounds.height - Self.statusBottom - Self.statusHeight,
                                   width: width - 24, height: Self.statusHeight)

        // Rows as one block, centred in the space between the header and the status
        // line. Three rows leave a little air above and below; one row sits in the
        // middle rather than hanging under the header with a hole beneath it.
        let count = CGFloat(rows.count)
        let block = count * Self.rowHeight + max(count - 1, 0) * Self.rowGap
        var y = (Self.rowsTop + (Self.rowsBottom - Self.rowsTop - block) / 2).rounded()
        for row in rows {
            row.frame = NSRect(x: Self.padding, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight + Self.rowGap
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    /// Ctrl-click is the same gesture on a Mac, and a trackpad user may have no
    /// second button configured at all.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        if let onClick { onClick(); return }
        super.mouseDown(with: event)
    }

    /// For the offscreen preview only: the blur is done by the window server and does
    /// not exist in a bitmap, so `--cardsheet` removes it and paints a stand-in.
    func removeGlassForPreview() { glass.removeFromSuperview() }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The card's hairline edge, drawn over everything else. A view rather than a layer
/// border so the colour is resolved at draw time and follows light/dark on its own,
/// and so the offscreen preview shows it too.
private final class CardEdgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = UsageCardView.cornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        path.stroke()
    }
}

// MARK: - Desktop panel

/// A panel that lives on the desktop, showing the same dog and the same limits.
///
/// Deliberately *not* a WidgetKit extension. That would mean a second bundle, a real
/// provisioning profile and a notarised parent app; this project signs ad-hoc on
/// purpose (see build.sh), and an unsigned widget extension simply never loads. A
/// borderless panel pinned just above the desktop icons gets to the same place --
/// visible when the desktop is, covered when something is over it -- with no signing
/// story at all. It lands on the system's own widget grid rather than wherever it was
/// dropped, which is most of what separates a widget from a window that happens to
/// be behind things.
final class DesktopWidget {
    private static let visibleKey = "widgetVisible"
    /// The **top**-left corner, not the origin.
    ///
    /// A new key on purpose: the old one stored the bottom-left, and reading those
    /// values as a top-left would teleport every existing install once. Storing the
    /// top is what the grid actually measures from. Anchors saved on an older grid are
    /// off the current one, so `place` snaps whatever it restores.
    private static let anchorKey  = "widgetAnchor"

    /// Desktop grid, measured from the system's own widget windows on a 1512x945
    /// display (windows owned by Notification Center, via CGWindowList).
    ///
    /// Each system widget is a window on a 180pt pitch whose visible card is inset
    /// 8pt on every side: small cards are 164x164, medium 344x164, large 344x344, with
    /// a 16pt gutter between them. So visible cards start 16pt in from the left of the
    /// usable area and 30pt below its top, one pitch apart in both directions, and a
    /// card may come within 8pt of the right and bottom edges (the window's inset).
    ///
    /// Using the system's numbers is the whole point: a grid of our own, however
    /// well it tiles our card, puts it a few points off every system widget beside it,
    /// and that mismatch is what reads as "stuck somewhere odd".
    static let gridPitch: CGFloat = 180
    static let gridLeft: CGFloat = 16
    static let gridTop: CGFloat = 30
    static let gridEdge: CGFloat = 8
    /// One grid cell as the system draws it: a small widget.
    static let cellSize = NSSize(width: gridPitch - 16, height: gridPitch - 16)

    private var panel: NSPanel?
    private let card = UsageCardView()

    /// Right-click target, so the settings are reachable even with the menu bar icon
    /// switched off. Set by the app to the same menu the status item uses -- a second
    /// menu would be a second place for the two to disagree.
    var contextMenu: NSMenu? {
        get { card.contextMenu }
        set { card.contextMenu = newValue }
    }

    /// Called when the widget goes from covered to uncovered. The app uses it to
    /// refresh: looking at the desktop is someone looking at these numbers, and it is
    /// the only moment the widget is worth spending a request on.
    var onExposed: (() -> Void)?

    /// Whether the widget is currently uncovered. Starts true so the first check is
    /// a real one rather than a transition out of an assumed state.
    private var exposed = true

    var isVisible: Bool { panel?.isVisible == true }

    /// Restored across launches -- a widget you have to re-summon every login is one
    /// you stop using.
    var shouldRestore: Bool { UserDefaults.standard.bool(forKey: Self.visibleKey) }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.visibleKey)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFront(nil)
        // Assume visible and let the check correct it: a widget that was just asked
        // for should animate immediately, not after the next space change.
        exposed = true
        syncAnimation()
        refreshExposure()
    }

    func hide() {
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
        card.header.stopAnimating()
        panel?.orderOut(nil)
    }

    /// Run the dog while the widget is open, uncovered, and running is switched on.
    ///
    /// `occlusionState` was tried here first and does not work: macOS keeps reporting
    /// a desktop-level window as visible no matter what is stacked on top of it, so
    /// the check saved nothing -- and then one day reported the opposite and stopped
    /// the animation for good, with nothing in the UI to say why. `isExposed` asks
    /// the window server the question directly instead of asking the window how it
    /// feels, and it is only ever asked on an event, never on a timer.
    private func syncAnimation() {
        guard let panel, panel.isVisible, DogHeaderView.animationEnabled, exposed else {
            card.header.stopAnimating()
            return
        }
        card.header.startAnimating()
    }

    /// Is anything covering the dog right now?
    ///
    /// The window server knows, and `CGWindowListCopyWindowInfo` will say -- ask for
    /// the on-screen windows ordered above this one and see whether any of their
    /// frames overlap. That covers every way the desktop gets revealed: windows
    /// minimised, moved to another space, swept aside by Show Desktop (which moves
    /// their frames off the screen rather than reordering them), or simply never
    /// opened over this corner in the first place.
    ///
    /// The test rect is the dog's corner, not the whole card. The dog is the only
    /// thing that animates -- the rows below it cost nothing whether they are covered
    /// or not -- and testing the whole panel made a window clipping six pixels off the
    /// far edge read as "hidden", which froze a widget that was plainly visible.
    private func isExposed(_ panel: NSPanel) -> Bool {
        let id = CGWindowID(panel.windowNumber)
        guard id != 0,
              let above = CGWindowListCopyWindowInfo(
                [.optionOnScreenAboveWindow, .excludeDesktopElements], id) as? [[String: Any]]
        else { return true }   // can't tell: assume visible rather than silently freeze

        // CGWindow bounds are y-down from the top of the *main* display; AppKit frames
        // are y-up from the bottom. Convert ours once rather than each of theirs.
        guard let primary = NSScreen.screens.first else { return true }
        let frame = panel.frame
        let mine = CGRect(x: frame.minX + UsageCardView.padding,
                          y: primary.frame.maxY - frame.maxY + UsageCardView.headerTop,
                          width: 86, height: UsageCardView.headerHeight)
        let enough = mine.width * mine.height * 0.2

        for window in above {
            // Our own menus and tooltips sit above the widget and must not count as
            // something covering it -- they only exist because it is being looked at.
            if window[kCGWindowOwnerPID as String] as? Int32 == ProcessInfo.processInfo.processIdentifier {
                continue
            }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            let overlap = rect.intersection(mine)
            if !overlap.isNull, overlap.width * overlap.height >= enough { return false }
        }
        return true
    }

    /// Re-asks whether the widget is covered, and reacts only to a change.
    ///
    /// Revealing the desktop is animated, so the honest answer isn't available at the
    /// instant the triggering event arrives -- the check runs after a short settle.
    /// Edge-triggered on purpose: app activation fires constantly, and a refresh on
    /// every one of them would spend the whole rate limit on alt-tabbing.
    func refreshExposure() {
        guard let panel, panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let now = self.isExposed(panel)
            guard now != self.exposed else { return }
            self.exposed = now
            self.syncAnimation()
            if now { self.onExposed?() }
        }
    }

    private var pointerInside = false

    /// The pointer arriving over the widget is the same signal as the pointer arriving
    /// in the menu bar: someone is looking. A rect test, run on the mouse monitor the
    /// app already has -- and it catches the reveals the workspace notifications miss,
    /// since Show Desktop fires neither an activation nor a space change.
    func pointerMoved(to point: NSPoint) {
        guard let panel, panel.isVisible else { return }
        let inside = panel.frame.contains(point)
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { refreshExposure() }
    }

    /// Snap the panel onto the nearest grid slot of whichever screen it is on.
    private func snapToGrid(_ panel: NSPanel) {
        let frame = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
                ?? NSScreen.main
        else { return }
        withoutSnapping {
            panel.setFrameOrigin(Self.snapped(frame, in: screen.visibleFrame,
                                              avoiding: Self.systemWidgetFrames()))
        }
    }

    /// The visible cards of the system's own desktop widgets, in AppKit coordinates.
    ///
    /// The grid alone put the card on top of Reminders when dropped there: the system
    /// widgets make room for each other, but they do not know this panel exists, so
    /// it has to stay out of their way itself. Their windows belong to Notification
    /// Center and carry an 8pt transparent margin around the card.
    static func systemWidgetFrames() -> [NSRect] {
        guard let primary = NSScreen.screens.first,
              let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return all.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                    == "com.apple.notificationcenterui",
                  let layer = window[kCGWindowLayer as String] as? Int, layer < 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width < primary.frame.width   // not the full-screen host window
            else { return nil }
            // CGWindow bounds are y-down from the top of the main display.
            return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY,
                          width: rect.width, height: rect.height).insetBy(dx: 8, dy: 8)
        }
    }

    /// The nearest slot, which by construction keeps the whole card on screen. Pure
    /// arithmetic, so it can be checked without a display.
    ///
    /// The grid runs from the top-left of the visible area, as the system's does: the
    /// bottom moves when the Dock appears and the right moves when the display
    /// changes, and a widget that drifts on either is back to floating.
    ///
    /// Slots overlapping anything in `occupied` (the system's widgets) are skipped, so
    /// the nearest *free* slot wins. With nothing free it stays where it was dropped.
    ///
    /// Only a *nearby* slot pulls: past `snapDistance` the card stays exactly where it
    /// was dropped (kept on screen). Snapping every drop to the nearest slot measured
    /// from the top-left corner kept landing somewhere other than the gap the user
    /// aimed at -- a widget that refuses to go where it is put is worse than one that
    /// is a few points off the grid.
    static func snapped(_ frame: NSRect, in area: NSRect, avoiding occupied: [NSRect] = []) -> NSPoint {
        let candidates = slots(in: area, size: frame.size).filter { slot in
            !occupied.contains { $0.intersects(slot) }
        }
        let distance = { (slot: NSRect) in hypot(slot.minX - frame.minX, slot.maxY - frame.maxY) }
        if let nearest = candidates.min(by: { distance($0) < distance($1) }),
           distance(nearest) <= snapDistance {
            return nearest.origin
        }
        let x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        let y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return NSPoint(x: x, y: y)
    }

    static let snapDistance: CGFloat = 40

    /// Every slot a card of `size` fits in, top-left first. `snapped` and the corner
    /// presets land only on these; the overlay draws the grid from the same function.
    /// One function so the picture cannot disagree with the behaviour.
    static func slots(in area: NSRect, size: NSSize) -> [NSRect] {
        var out: [NSRect] = []
        var top = area.maxY - gridTop
        while top - size.height >= area.minY + gridEdge {
            var x = area.minX + gridLeft
            while x + size.width <= area.maxX - gridEdge {
                out.append(NSRect(x: x, y: top - size.height, width: size.width, height: size.height))
                x += gridPitch
            }
            top -= gridPitch
        }
        return out
    }

    /// The grid's extreme slot in a corner -- not the raw screen corner, so a widget
    /// parked "top right" lines up with system widgets there too.
    static func corner(_ corner: WidgetCorner, in area: NSRect, size: NSSize) -> NSPoint? {
        let all = slots(in: area, size: size)
        guard let first = all.first else { return nil }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let x = left ? first.minX : all.map(\.minX).max()!
        let y = top ? first.minY : all.map(\.minY).min()!
        return NSPoint(x: x, y: y)
    }

    /// Snap once the drag is actually over.
    ///
    /// `isMovableByWindowBackground` gives no "finished moving" notification, only a
    /// stream of `didMove` while the pointer travels -- and snapping on each of those
    /// would fight the drag. So: debounce, and if the button is still down, the user
    /// has merely paused. Wait for them to let go.
    private var snapWork: DispatchWorkItem?

    /// Set while the code is moving the panel itself.
    ///
    /// A programmatic move emits `didMove` exactly like a drag does, and treating it
    /// as one would re-run the snap a fifth of a second after every placement. The
    /// `didMove` observer is registered with `queue: nil` so it runs synchronously on
    /// the posting thread; with an operation queue the flag would already be back to
    /// false by the time the block ran.
    private var movingProgrammatically = false

    private func withoutSnapping(_ body: () -> Void) {
        movingProgrammatically = true
        body()
        movingProgrammatically = false
    }

    private func scheduleSnap(_ panel: NSPanel) {
        guard !movingProgrammatically else { return }
        snapWork?.cancel()
        // Still holding the button: this is a drag in progress, so show where it will
        // land. A grid you cannot see is indistinguishable from the widget deciding
        // for itself where to go.
        if NSEvent.pressedMouseButtons != 0 { showGrid(for: panel) }
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard NSEvent.pressedMouseButtons == 0 else { self.scheduleSnap(panel); return }
            self.hideGrid()
            self.snapToGrid(panel)
            self.saveOrigin(panel)
            self.refreshExposure()
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Grid overlay

    private var overlay: NSPanel?

    /// The grid, drawn only while something is being dragged.
    ///
    /// One panel covering the screen rather than a placeholder panel that moves:
    /// the complaint was not just that the landing spot was invisible but that the
    /// positions felt arbitrary, and a single highlighted rectangle does not answer
    /// that. Showing the grid does -- the arrangement stops being a secret the moment
    /// you can see there is one.
    private func showGrid(for panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
                ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame

        let overlay = self.overlay ?? makeOverlay()
        self.overlay = overlay
        overlay.setFrame(area, display: false)

        // In the overlay's own coordinates, which start at the visible frame.
        let shift = NSPoint(x: -area.minX, y: -area.minY)
        let size = panel.frame.size
        let target = Self.snapped(panel.frame, in: area, avoiding: Self.systemWidgetFrames())
        let view = overlay.contentView as? GridOverlayView
        view?.cells = Self.slots(in: area, size: Self.cellSize)
            .map { $0.offsetBy(dx: shift.x, dy: shift.y) }
        view?.target = NSRect(origin: NSPoint(x: target.x + shift.x, y: target.y + shift.y),
                              size: size)

        overlay.orderFront(nil)
        overlay.order(.below, relativeTo: panel.windowNumber)
    }

    private func hideGrid() { overlay?.orderOut(nil) }

    private func makeOverlay() -> NSPanel {
        let overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        // Never take a click: the drag belongs to the widget, and an overlay that
        // swallowed the mouse would end the gesture it exists to illustrate.
        overlay.ignoresMouseEvents = true
        overlay.contentView = GridOverlayView()
        return overlay
    }

    /// Park in a named corner of whichever screen the pointer is on, so "put it top
    /// right" means the display being looked at rather than always the primary one.
    func move(to corner: WidgetCorner) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        guard let origin = Self.corner(corner, in: screen.visibleFrame, size: panel.frame.size)
        else { return }
        snapWork?.cancel()
        withoutSnapping { panel.setFrameOrigin(origin) }
        saveOrigin(panel)
        refreshExposure()
    }

    func update(limits: [UsageLimit], status: String, reset: (Date?) -> String) {
        card.update(limits: limits, status: status, reset: reset)
    }

    // MARK: Building

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: UsageCardView.size),
            // Non-activating: clicking the widget must not pull focus out of whatever
            // the user is actually working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        // Above the desktop icons, below every real window -- where Weather and
        // Reminders sit. One level higher than the desktop *picture* is not enough:
        // Finder draws the icons in their own window above that one, and a widget
        // with a folder on top of it is a widget you cannot read.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // system desktop widgets cast none either
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentView = card

        NotificationCenter.default.addObserver(
            forName: DogHeaderView.enabledChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.syncAnimation() }

        place(panel)
        // Saved on every move, because a borderless panel has no other way to be
        // told where it belongs. Moving it can also uncover or bury it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in self?.scheduleSnap(panel) }

        // The two things that change what is stacked over the desktop. Neither is a
        // timer: nothing here polls, and with the desktop hidden the widget costs
        // exactly nothing until one of these fires.
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshExposure() }
        }

        return panel
    }

    /// Restores the saved **top**-left corner, then snaps: an anchor saved on an
    /// older grid, or on a display that has since changed, lands on the nearest slot
    /// of the current one instead of staying a few points off it.
    private func place(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.anchorKey) {
            let anchor = NSPointFromString(saved)
            // Only honour a saved spot that is still on a screen -- an unplugged
            // display would otherwise strand the widget somewhere unreachable.
            if NSScreen.screens.contains(where: { $0.frame.contains(anchor) }) {
                panel.setFrameOrigin(NSPoint(x: anchor.x, y: anchor.y - panel.frame.height))
                snapToGrid(panel)
                saveOrigin(panel)
                return
            }
        }
        // No saved spot: the top-right corner, where the system's own widgets start.
        if let screen = NSScreen.main,
           let origin = Self.corner(.topRight, in: screen.visibleFrame, size: panel.frame.size) {
            panel.setFrameOrigin(origin)
        }
    }

    private func saveOrigin(_ panel: NSPanel) {
        let frame = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)),
                                  forKey: Self.anchorKey)
    }
}

/// The grid, shown under the widget while it is being dragged.
///
/// Not private: it exists only during a drag, so the only way to look at it is to
/// render it offscreen. `--gridsheet` does that.
final class GridOverlayView: NSView {
    /// Every grid cell, at the system's small-widget size, in this view's coordinates.
    /// Cells rather than every position the card could take: at a 180pt pitch those
    /// overlap each other, and a pile of overlapping outlines is no grid at all. The
    /// card covers exactly two by two of these, so its landing spot sits on the lines.
    var cells: [NSRect] = [] { didSet { needsDisplay = true } }
    var target: NSRect = .zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.13).setStroke()
        for cell in cells {
            let path = NSBezierPath(roundedRect: cell, xRadius: 16, yRadius: 16)
            path.lineWidth = 1.5
            path.setLineDash([6, 5], count: 2, phase: 0)
            path.stroke()
        }

        guard !target.isEmpty else { return }
        let r = UsageCardView.cornerRadius
        let landing = NSBezierPath(roundedRect: target, xRadius: r, yRadius: r)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        landing.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        landing.lineWidth = 2
        landing.stroke()
    }
}

// MARK: - Hotkey peek

/// The card, summoned over whatever is on screen by the Raycast hotkey
/// (`clife://peek`).
///
/// The text HUD Raycast shows for a script is one line of numbers; the card is the
/// thing the rest of the app has taught people to read. Same `UsageCardView`, so the
/// peek cannot say anything the widget and the menu do not.
final class PeekPanel {
    /// Long enough to read three rows, short enough not to need dismissing.
    private static let visibleFor: TimeInterval = 2.5

    private var panel: NSPanel?
    private let card = UsageCardView()
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible == true }

    func update(limits: [UsageLimit], status: String, reset: (Date?) -> String) {
        card.update(limits: limits, status: status, reset: reset)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Horizontally centred on the screen with the pointer, its middle a third of
        // the way down: where the eye already is, and clear of the menu bar.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let size = UsageCardView.size
        let top = min(area.maxY - 16, area.maxY - area.height / 3 + size.height / 2)
        panel.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                     y: (top - size.height).rounded()))

        panel.alphaValue = 0
        // Never key: the hotkey is pressed mid-typing, and a card that took the
        // keyboard would eat the next keystroke meant for the app underneath.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        if DogHeaderView.animationEnabled { card.header.startAnimating() }
        scheduleHide(after: Self.visibleFor)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        card.header.stopAnimating()
        panel?.orderOut(nil)
    }

    /// Stays while the pointer rests on it: that is someone still reading.
    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) { self.scheduleHide(after: 1); return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: UsageCardView.size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        // Over everything, fullscreen apps included -- the hotkey exists for exactly
        // the moments the menu bar is out of reach.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true           // floating over windows, unlike the widget
        panel.hidesOnDeactivate = false
        panel.contentView = card
        card.onClick = { [weak self] in self?.hide() }
        return panel
    }
}
