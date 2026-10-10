import AppKit
import QuartzCore

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

    /// .transient hides the overlay during Mission Control instead of animating it separately (which
    /// can lag or come loose); .stationary keeps it on screen, moving with the desktop.
    var hidesInMissionControl = true {
        didSet { updateCollectionBehavior() }
    }

    private func updateCollectionBehavior() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
                              hidesInMissionControl ? .transient : .stationary]
    }

    /// Full-screen windows cover the menu bar area; don't let AppKit push the overlay below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
