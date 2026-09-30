import Cocoa
import Carbon.HIToolbox

// MARK: - Shortcut

/// A key plus Carbon modifier flags (`cmdKey`, `optionKey`, ...), the form
/// `RegisterEventHotKey` takes. Stored as-is in UserDefaults.
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From a recorded key press. Nil unless ⌘, ⌥ or ⌃ is held: a bare letter (or
    /// ⇧+letter) registered globally would swallow that character in every app.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: mods)
    }

    /// "⌃⌥⇧⌘C" -- the order macOS menus use.
    var display: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let prefix = symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        return prefix + (Self.keyNames[Int(keyCode)] ?? "Key \(keyCode)")
    }

    // Key codes are physical positions (ANSI layout), so this table is only a label;
    // on other layouts the letter shown may differ from the one printed on the key.
    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                     kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fKeys.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()
}

// MARK: - Global hotkey

/// One system-wide hotkey through Carbon's `RegisterEventHotKey`. Chosen over
/// `NSEvent.addGlobalMonitorForEvents` because it needs no Accessibility
/// permission -- a coworker who downloads the app gets no scary prompt.
final class GlobalHotKey {
    var onPress: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// False when the combo is already taken (another app registered it).
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        installHandlerOnce()
        let id = EventHotKeyID(signature: OSType(0x434C_4946), id: 1)   // 'CLIF'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerOnce() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        // The handler holds `self` unretained; this object lives as long as the app.
    }
}

// MARK: - Recorder

/// Small panel that waits for the next key press and hands it back as a Shortcut.
/// Non-modal: the rest of the app keeps running while it is up.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var monitor: Any?
    private var completion: ((Shortcut?) -> Void)?

    /// Calls `done` once: with the shortcut, or nil if cancelled (Esc or closing).
    func start(_ done: @escaping (Shortcut?) -> Void) {
        finish(nil)   // a second start cancels the first
        completion = done

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "단축키 변경"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self
        let label = NSTextField(wrappingLabelWithString: "새 단축키를 누르세요 (Esc: 취소)")
        label.alignment = .center
        label.frame = NSRect(x: 16, y: 20, width: 288, height: 50)
        panel.contentView?.addSubview(label)
        panel.center()
        self.panel = panel
        self.label = label

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil   // swallow: nothing else should react while recording
        }
        // An accessory app never gets key events unless it is active.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { finish(nil); return }
        guard let shortcut = Shortcut(keyCode: event.keyCode, flags: event.modifierFlags) else {
            label?.stringValue = "⌘, ⌥, ⌃ 중 하나와 같이 눌러 주세요 (Esc: 취소)"
            return
        }
        finish(shortcut)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ shortcut: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let done = completion
        completion = nil
        let panel = self.panel
        self.panel = nil
        panel?.delegate = nil
        panel?.close()
        done?(shortcut)
    }
}
