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

/// A panel that lives on the desktop, showing the same dog and the same limits.
///
/// Deliberately *not* a WidgetKit extension. That would mean a second bundle, a real
/// provisioning profile and a notarised parent app; this project signs ad-hoc on
/// purpose (see build.sh), and an unsigned widget extension simply never loads. A
/// borderless panel pinned just above the desktop icons gets to the same place --
/// visible when the desktop is, covered when something is over it -- with no signing
/// story at all. It lands on a grid rather than wherever it was dropped, which is
/// most of what separates a widget from a window that happens to be behind things.
///
/// The content is the menu's own `DogHeaderView` and `UsageRowView`, not a
/// reimplementation. Two copies of this layout would drift the first time either one
/// was touched, and then the widget and the dropdown would disagree about the same
/// numbers, which is worse than not having a widget.
final class DesktopWidget {
    private static let visibleKey = "widgetVisible"
    private static let originKey  = "widgetOrigin"
    private static let width: CGFloat = 268
    private static let headerHeight: CGFloat = 68
    private static let rowHeight: CGFloat = 54
    /// Matches the dog's slot in `DogHeaderView`; the coverage test uses it.
    private static let dogWidth: CGFloat = 86

    /// Desktop widget grid, measured from the top-left of the usable screen.
    ///
    /// A system widget cannot be dropped at an arbitrary pixel -- it lands on a slot,
    /// which is most of what makes it read as furniture rather than as a window that
    /// happens to be behind everything. These are the system's own numbers for a
    /// small widget: a 158pt cell with a 16pt gutter.
    private static let gridPitch: CGFloat = 174
    private static let gridMargin: CGFloat = 16

    private var panel: NSPanel?
    private var header: DogHeaderView?
    private var rows: [UsageRowView] = []
    private var stack: NSView?
    private var lastLimits: [UsageLimit] = []
    private var lastStatus = ""
    /// Kept so re-showing the widget can redraw with the same wording the menu uses,
    /// instead of blank subtitles until the next refresh lands.
    private var lastReset: ((Date?) -> String)?

    /// Right-click target, so the settings are reachable even with the menu bar icon
    /// switched off. Set by the app to the same menu the status item uses -- a second
    /// menu would be a second place for the two to disagree.
    var contextMenu: NSMenu?

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
        apply(limits: lastLimits, status: lastStatus, reset: lastReset)
        panel.orderFront(nil)
        // Assume visible and let the check correct it: a widget that was just asked
        // for should animate immediately, not after the next space change.
        exposed = true
        syncAnimation()
        refreshExposure()
    }

    func hide() {
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
        header?.stopAnimating()
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
            header?.stopAnimating()
            return
        }
        header?.startAnimating()
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
        let mine = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                          width: Self.dogWidth, height: Self.headerHeight)
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

    /// Snap the panel onto the nearest grid slot, and keep it fully on screen.
    ///
    /// The grid runs from the top-left of the visible area, because that is the edge
    /// that stays put: the bottom moves when the Dock appears and the right moves when
    /// the display changes, and a widget that drifts on either is back to floating.
    /// The panel's own height varies with the number of limit rows, so it is the *top*
    /// edge that lands on a row line, not the origin.
    private func snapToGrid(_ panel: NSPanel) {
        let frame = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
                ?? NSScreen.main
        else { return }
        withoutSnapping { panel.setFrameOrigin(Self.snapped(frame, in: screen.visibleFrame)) }
    }

    /// The arithmetic on its own, so it can be checked without a window or a display.
    static func snapped(_ frame: NSRect, in area: NSRect) -> NSPoint {
        let pitch = gridPitch, inset = gridMargin
        let column = ((frame.minX - area.minX - inset) / pitch).rounded()
        let row = ((area.maxY - inset - frame.maxY) / pitch).rounded()

        // Clamp after snapping, not before: a slot that would hang off the edge gets
        // pulled back to the last position that fits, rather than snapping to nothing.
        let x = min(max(area.minX + inset + column * pitch, area.minX + inset),
                    area.maxX - inset - frame.width)
        let top = min(max(area.maxY - inset - row * pitch, area.minY + inset + frame.height),
                      area.maxY - inset)
        return NSPoint(x: x, y: top - frame.height)
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
    /// as one would snap a corner placement onto the grid a fifth of a second after
    /// the user chose the corner -- and re-snap on every data refresh besides, since
    /// the panel resizes whenever the row count changes. The `didMove` observer is
    /// registered with `queue: nil` so it runs synchronously on the posting thread;
    /// with an operation queue the flag would already be back to false by the time
    /// the block ran.
    private var movingProgrammatically = false

    private func withoutSnapping(_ body: () -> Void) {
        movingProgrammatically = true
        body()
        movingProgrammatically = false
    }

    private func scheduleSnap(_ panel: NSPanel) {
        guard !movingProgrammatically else { return }
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            guard NSEvent.pressedMouseButtons == 0 else { self.scheduleSnap(panel); return }
            self.snapToGrid(panel)
            self.saveOrigin(panel)
            self.refreshExposure()
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Park in a named corner of whichever screen the pointer is on, so "put it top
    /// right" means the display being looked at rather than always the primary one.
    ///
    /// Corners deliberately do not go through the grid. They are the four extremes,
    /// and rounding "top right" to the nearest column could leave it most of a cell
    /// short of the edge -- which is not what anyone means by the corner.
    func move(to corner: WidgetCorner) {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        let size = panel.frame.size
        let inset = Self.gridMargin
        let x = corner == .topLeft || corner == .bottomLeft
            ? area.minX + inset
            : area.maxX - size.width - inset
        let y = corner == .topLeft || corner == .topRight
            ? area.maxY - size.height - inset
            : area.minY + inset
        snapWork?.cancel()
        withoutSnapping { panel.setFrameOrigin(NSPoint(x: x, y: y)) }
        saveOrigin(panel)
        refreshExposure()
    }

    func update(limits: [UsageLimit], status: String, reset: @escaping (Date?) -> String) {
        lastLimits = limits
        lastStatus = status
        lastReset = reset
        guard isVisible else { return }
        apply(limits: limits, status: status, reset: reset)
    }

    // MARK: Building

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.headerHeight),
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
        panel.hasShadow = false          // nothing above the desktop to cast onto
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let background = WidgetBackgroundView()
        background.owner = self
        panel.contentView = background

        let header = DogHeaderView()
        header.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)
        self.header = header

        let stack = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        self.stack = stack

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

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

    private func place(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            // Only honour a saved spot that is still on a screen -- an unplugged
            // display would otherwise strand the widget somewhere unreachable.
            if NSScreen.screens.contains(where: { $0.frame.contains(origin) }) {
                panel.setFrameOrigin(origin)
                return
            }
        }
        // No saved spot: the top-right corner, where the system's own widgets start.
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - Self.width - Self.gridMargin,
                                         y: area.maxY - panel.frame.height - Self.gridMargin))
        }
    }

    private func saveOrigin(_ panel: NSPanel) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    private func apply(limits: [UsageLimit], status: String,
                       reset: ((Date?) -> String)?) {
        guard let panel, let header, let stack else { return }

        // Grow or shrink the row pool to match what the API actually returned.
        while rows.count < limits.count {
            let row = UsageRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addSubview(row)
            rows.append(row)
        }
        while rows.count > limits.count {
            rows.removeLast().removeFromSuperview()
        }

        NSLayoutConstraint.deactivate(stack.constraints)
        var previous: NSView?
        for (index, row) in rows.enumerated() {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
                row.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? stack.topAnchor),
            ])
            let limit = limits[index]
            row.update(title: limit.title, percent: limit.percent,
                       subtitle: reset?(limit.resetsAt) ?? "")
            previous = row
        }

        header.update(limit: limits.dogBinding, reset: "")
        (panel.contentView as? WidgetBackgroundView)?.status = status

        // Grow downward, keeping the top edge where it is. Keeping the *origin* fixed
        // instead would move the top every time the API returned a different number of
        // rows, and the grid is measured from the top -- so the widget would walk off
        // its slot on its own.
        let height = Self.headerHeight + CGFloat(limits.count) * Self.rowHeight + 22
        let frame = panel.frame
        withoutSnapping {
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - height,
                                  width: Self.width, height: height), display: true)
        }
        // Back onto a slot, every time. This is what catches a position saved before
        // the grid existed, or on a display layout that has since changed -- and it
        // is safe to run unconditionally because all four corners are fixed points of
        // the snap (the clamps pull them back to the edge they were already on), so
        // a deliberate corner placement survives it untouched.
        snapToGrid(panel)
    }
}

/// Rounded translucent card with the freshness line along the bottom.
private final class WidgetBackgroundView: NSView {
    var status: String = "" { didSet { needsDisplay = true } }
    weak var owner: DesktopWidget?

    override var isFlipped: Bool { true }   // matches the menu's top-down row order

    /// Right-click opens the app's menu here too. With the menu bar icon switched
    /// off this is the only way back to the settings -- including the one that turns
    /// the icon on again, which is why hiding it is allowed at all.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.contextMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Ctrl-click is the same gesture on a Mac, and a trackpad user may have no
    /// second button configured at all.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        // Nearly opaque: the card sits over desktop icons now, not just wallpaper,
        // and file names bleeding through the numbers is worse than losing the tint.
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        card.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        card.lineWidth = 1
        card.stroke()

        guard !status.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (status as NSString).draw(
            in: NSRect(x: 10, y: bounds.maxY - 19, width: bounds.width - 20, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: style])
    }
}
