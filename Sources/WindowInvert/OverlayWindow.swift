import AppKit
import QuartzCore

struct OverlayActivation {
    private var deadline: CFTimeInterval?

    mutating func begin(at time: CFTimeInterval) { deadline = time + 0.25 }
    mutating func cancel() { deadline = nil }

    mutating func level(aboveWindowsLevel level: NSWindow.Level, at time: CFTimeInterval) -> NSWindow.Level {
        guard let deadline else { return level }
        // Activation arrives before the compositor's window-order list catches up.
        if level == .floating || time >= deadline {
            cancel()
            return level
        }
        return .floating
    }
}

/// A borderless, click-through window that shows the inverted copy of the target window.
final class OverlayWindow: NSWindow {
    let metalLayer = CAMetalLayer()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .normal
        updateCollectionBehavior()
        isExcludedFromWindowsMenu = true

        InvertRenderer.shared.configure(metalLayer)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.layer = metalLayer
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        contentView = view
    }

    private func updateCollectionBehavior() {
        // Track/hide explicitly: .transient fades a full-size copy while the target moves away.
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    /// Full-screen windows cover the menu bar area; don't let AppKit push the overlay below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
