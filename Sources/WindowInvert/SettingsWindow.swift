import AppKit

/// Settings window for customizing the global shortcuts.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called when a shortcut changes; returns the actions whose shortcut couldn't be registered.
    var onShortcutsChanged: (() -> Set<ShortcutAction>)?
    /// Global hotkeys must be paused while recording, or pressing the current combo would trigger it.
    var onRecordingChanged: ((Bool) -> Void)?

    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WindowInvert Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(failures: Set<ShortcutAction>) {
        refresh(failures: failures)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let header = NSTextField(labelWithString: "Keyboard Shortcuts")
        header.font = .boldSystemFont(ofSize: 13)

        var rows: [[NSView]] = []
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder()
            recorder.onRecordingChanged = { [weak self] recording in self?.onRecordingChanged?(recording) }
            recorder.onChange = { [weak self] combo in self?.set(combo, for: action) }
            recorders[action] = recorder
            let reset = NSButton(title: "Default", target: self, action: #selector(resetShortcut(_:)))
            reset.bezelStyle = .rounded
            reset.controlSize = .small
            reset.tag = ShortcutAction.allCases.firstIndex(of: action)!
            rows.append([NSTextField(labelWithString: action.title + ":"), recorder, reset])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 150

        let help = NSTextField(wrappingLabelWithString:
            "Click a shortcut and press the new keys. Delete clears it; Esc cancels. "
            + "\"Switch invert style\" toggles between Classic and Hue-Preserving invert.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .systemRed

        let stack = NSStackView(views: [header, grid, help, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            help.widthAnchor.constraint(equalToConstant: 380),
            statusLabel.widthAnchor.constraint(equalToConstant: 380),
        ])
    }

    private func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if let combo {
            // A combo can only belong to one action.
            for other in ShortcutAction.allCases where other != action && other.combo == combo {
                other.combo = nil
            }
        }
        action.combo = combo
        refresh(failures: onShortcutsChanged?() ?? [])
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        set(action.defaultCombo, for: action)
    }

    private func refresh(failures: Set<ShortcutAction>) {
        for (action, recorder) in recorders {
            recorder.combo = action.combo
            recorder.hasConflict = failures.contains(action)
        }
        statusLabel.stringValue = failures.isEmpty ? "" : failures
            .sorted { $0.hotKeyID < $1.hotKeyID }
            .map { "\($0.combo?.displayString ?? "") is already used by another app or macOS." }
            .joined(separator: "\n")
        statusLabel.isHidden = failures.isEmpty
    }

    func windowWillClose(_ notification: Notification) {
        recorders.values.forEach { $0.cancelRecording() }
    }
}

/// A button that records a key combination when clicked.
final class ShortcutRecorder: NSButton {
    var combo: KeyCombo? { didSet { updateTitle() } }
    var hasConflict = false { didSet { updateTitle() } }
    var onChange: ((KeyCombo?) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            updateTitle()
            onRecordingChanged?(isRecording)
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() {
        if isRecording {
            cancelRecording()
        } else {
            window?.makeFirstResponder(self)
            isRecording = true
        }
    }

    func cancelRecording() {
        isRecording = false
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        let candidate = KeyCombo(event: event)
        let plain = candidate.modifiers == 0
        if plain && Int(event.keyCode) == 53 { // Esc
            isRecording = false
            return
        }
        if plain && (Int(event.keyCode) == 51 || Int(event.keyCode) == 117) { // Delete / Forward Delete
            isRecording = false
            onChange?(nil)
            return
        }
        guard candidate.isValidGlobalShortcut else {
            NSSound.beep()
            return
        }
        isRecording = false
        onChange?(candidate)
    }

    private func updateTitle() {
        let text: String
        if isRecording {
            text = "Type shortcut…"
        } else {
            text = combo?.displayString ?? "None"
        }
        let color: NSColor = hasConflict && !isRecording ? .systemRed : (combo == nil && !isRecording ? .secondaryLabelColor : .labelColor)
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }
}
