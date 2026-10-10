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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isExcludedFromWindowsMenu = true

        InvertRenderer.shared.configure(metalLayer)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.layer = metalLayer
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
