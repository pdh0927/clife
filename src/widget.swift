import Cocoa

// MARK: - Desktop widget

/// A panel that lives on the desktop, showing the same dog and the same limits.
///
/// Deliberately *not* a WidgetKit extension. That would mean a second bundle, a real
/// provisioning profile and a notarised parent app; this project signs ad-hoc on
/// purpose (see build.sh), and an unsigned widget extension simply never loads. A
/// borderless panel pinned to the desktop window level gets to the same place --
/// visible when the desktop is, invisible when something covers it -- with no
/// signing story at all.
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

    private var panel: NSPanel?
    private var header: DogHeaderView?
    private var rows: [UsageRowView] = []
    private var stack: NSView?
    private var lastLimits: [UsageLimit] = []
    private var lastStatus = ""
    /// Kept so re-showing the widget can redraw with the same wording the menu uses,
    /// instead of blank subtitles until the next refresh lands.
    private var lastReset: ((Date?) -> String)?

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
        syncAnimation()
    }

    func hide() {
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
        header?.stopAnimating()
        panel?.orderOut(nil)
    }

    /// Run the dog only while the panel is genuinely on screen.
    private func syncAnimation() {
        guard let panel, panel.isVisible, DogHeaderView.animationEnabled,
              panel.occlusionState.contains(.visible) else {
            header?.stopAnimating()
            return
        }
        header?.startAnimating()
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

        // One above the desktop picture, below every real window -- the definition of
        // "on the desktop" rather than "always in the way".
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // nothing above the desktop to cast onto
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let background = WidgetBackgroundView()
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

        // Desktop level means a fullscreen app covers this completely -- and a dog
        // running where nobody can see it is pure battery. macOS already tracks this
        // and will tell us, so the animation follows visibility rather than the
        // window merely being "open".
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.syncAnimation() }
        NotificationCenter.default.addObserver(
            forName: DogHeaderView.enabledChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.syncAnimation() }

        place(panel)
        // Saved on every move, because a borderless panel has no other way to be
        // told where it belongs.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.saveOrigin(panel) }

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
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - Self.width - 28,
                                         y: screen.visibleFrame.maxY - 320))
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

        let binding = limits.max { $0.percent < $1.percent }
        header.update(limit: binding, reset: "")
        (panel.contentView as? WidgetBackgroundView)?.status = status

        let height = Self.headerHeight + CGFloat(limits.count) * Self.rowHeight + 22
        let origin = panel.frame.origin
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: Self.width, height: height),
                       display: true)
    }
}

/// Rounded translucent card with the freshness line along the bottom.
private final class WidgetBackgroundView: NSView {
    var status: String = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }   // matches the menu's top-down row order

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
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
