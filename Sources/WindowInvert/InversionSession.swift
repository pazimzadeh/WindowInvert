import AppKit
import CoreMedia
import ScreenCaptureKit

enum InvertScope {
    /// Invert the whole window including title bar and toolbar.
    case window
    /// Invert only the document area (skips window chrome).
    case content
}

/// Captures one window with ScreenCaptureKit and keeps an inverted, click-through copy on top of it.
final class InversionSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let target: TargetWindow
    var scope: InvertScope {
        didSet {
            guard scope != oldValue else { return }
            refreshInsets()
            render()
        }
    }
    var colorMode: ColorMode {
        didSet { render() }
    }
    var onEnded: ((InversionSession) -> Void)?

    private struct Frame {
        let pixelBuffer: CVPixelBuffer
        /// Region of the pixel buffer holding the window, in buffer pixels.
        let contentRect: CGRect
    }

    private let overlay = OverlayWindow()
    private let sampleQueue = DispatchQueue(label: "WindowInvert.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var latestFrame: Frame?
    private var bounds: CGRect = .null
    private var isTargetVisible = false
    private var insets = EdgeInsets.zero
    /// Target-app windows above the target (sheets, popovers), in CG global coordinates.
    private var holes: [CGRect] = []
    private static let holeCornerRadius: CGFloat = 19
    private var configuredPixelSize = CGSize.zero
    private var configuredScale: CGFloat = 0
    private var isUpdatingConfig = false
    private var needsConfigUpdate = false
    private var insetsWorkItem: DispatchWorkItem?
    private var ended = false

    init(target: TargetWindow, scope: InvertScope, colorMode: ColorMode) {
        self.target = target
        self.scope = scope
        self.colorMode = colorMode
        super.init()
    }

    // MARK: - Lifecycle

    @MainActor
    func start() async throws {
        guard let state = WindowLocator.state(of: target.windowID) else {
            Log.write("start: window \(target.windowID) not in window list")
            throw SessionError.windowGone
        }
        Log.write("start: window \(target.windowID) bounds=\(state.bounds) onScreen=\(state.isOnScreen) scope=\(scope)")
        bounds = state.bounds
        isTargetVisible = state.isOnScreen
        refreshInsets()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == target.windowID }) else {
            Log.write("start: ScreenCaptureKit has no window \(target.windowID); it lists "
                      + content.windows.filter { $0.owningApplication?.processID == target.pid }
                          .map { "\($0.windowID) \($0.frame) onScreen=\($0.isOnScreen)" }.joined(separator: ", "))
            throw SessionError.windowGone
        }
        Log.write("start: SCWindow \(scWindow.windowID) frame=\(scWindow.frame) layer=\(scWindow.windowLayer) onScreen=\(scWindow.isOnScreen)")
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = max(CGFloat(filter.pointPixelScale), screenScale(for: bounds))
        let config = makeConfiguration(size: bounds.size, scale: scale)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        try await stream.startCapture()
        Log.write("start: capture started (\(config.width)x\(config.height) px, scale \(scale))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.ended else { return }
            let counts = self.sampleQueue.sync { self.statusCounts }
            Log.write("after 2s: frame statuses \(counts), overlay visible=\(self.overlay.isVisible), "
                      + "target visible=\(self.isTargetVisible), overlay frame=\(self.overlay.frame)")
        }
    }

    /// Frame status histogram (accessed on sampleQueue), for diagnostics.
    private var statusCounts: [String: Int] = [:]

    func stop() {
        guard !ended else { return }
        ended = true
        insetsWorkItem?.cancel()
        overlay.orderOut(nil)
        if let stream {
            stream.stopCapture { _ in }
        }
        stream = nil
        latestFrame = nil
    }

    private func end() {
        guard !ended else { return }
        stop()
        onEnded?(self)
    }

    // MARK: - Tracking (called every display refresh)

    func tick() {
        guard !ended else { return }
        guard let state = WindowLocator.state(of: target.windowID) else {
            end()
            return
        }

        let visible = state.isOnScreen && state.bounds.width > 1 && state.bounds.height > 1
        if visible != isTargetVisible {
            isTargetVisible = visible
            if !visible { overlay.orderOut(nil) }
        }
        guard visible else { return }

        if state.bounds != bounds {
            let sizeChanged = state.bounds.size != bounds.size
            bounds = state.bounds
            if sizeChanged {
                updateStreamSizeIfNeeded()
                scheduleInsetsRefresh()
            }
            render()
        }
        if overlay.isVisible {
            updateStacking()
        } else if latestFrame != nil {
            render()
        }
    }

    /// Keeps the overlay directly above the target and cuts holes where the target app's own sheets,
    /// popovers and panels are. The window server keeps those grouped with their parent window, so the
    /// overlay can't be ordered between them; instead they show through the holes, un-inverted.
    private func updateStacking() {
        let overlayID = CGWindowID(overlay.windowNumber)
        let above = WindowLocator.windowsAbove(target.windowID)
        if let index = above.firstIndex(where: { $0.id == overlayID }) {
            if above[(index + 1)...].contains(where: { $0.pid != target.pid }) {
                overlay.order(.above, relativeTo: Int(target.windowID))
            }
        } else {
            overlay.order(.above, relativeTo: Int(target.windowID))
        }

        let newHoles = above
            .filter { $0.pid == target.pid && $0.layer == 0 && $0.id != overlayID }
            // Skip tiny helper windows such as the title-bar button strip.
            .filter { $0.bounds.width >= 100 && $0.bounds.height >= 40 && $0.bounds.intersects(bounds) }
            .map(\.bounds)
        if newHoles != holes {
            holes = newHoles
            render()
        }
    }

    // MARK: - Content insets

    private func refreshInsets() {
        guard scope == .content else {
            insets = .zero
            return
        }
        if let ax = target.axWindow {
            insets = WindowLocator.contentInsets(for: ax, windowBounds: bounds)
        } else {
            insets = EdgeInsets(top: 28)
        }
    }

    /// AX queries go to the target app's main thread, which is busy during a live resize, so the
    /// insets from the last query are reused while resizing and re-measured once it settles.
    private func scheduleInsetsRefresh() {
        guard scope == .content else { return }
        insetsWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.ended else { return }
            let old = self.insets
            self.refreshInsets()
            if self.insets != old { self.render() }
        }
        insetsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    // MARK: - Stream configuration

    private func screenScale(for cgRect: CGRect) -> CGFloat {
        let rect = cgRect.flippedToCocoa
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func makeConfiguration(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let pixelSize = CGSize(width: max(1, (size.width * scale).rounded()),
                               height: max(1, (size.height * scale).rounded()))
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 4
        let fps = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(60, fps)))
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        configuredPixelSize = pixelSize
        configuredScale = scale
        return config
    }

    private func updateStreamSizeIfNeeded() {
        guard let stream else { return }
        if isUpdatingConfig {
            needsConfigUpdate = true
            return
        }
        let scale = screenScale(for: bounds)
        let wanted = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard wanted != configuredPixelSize || scale != configuredScale else { return }
        isUpdatingConfig = true
        needsConfigUpdate = false
        stream.updateConfiguration(makeConfiguration(size: bounds.size, scale: scale)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { Log.write("updateConfiguration failed: \(error)") }
                self.isUpdatingConfig = false
                if self.needsConfigUpdate { self.updateStreamSizeIfNeeded() }
            }
        }
    }

    // MARK: - Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int else { return }
        let status = SCFrameStatus(rawValue: statusRaw)
        let key = status.map { "\($0)" } ?? "raw\(statusRaw)"
        statusCounts[key, default: 0] += 1
        guard status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        var contentRect = CGRect(origin: .zero, size: bufferSize)
        if let dict = info[.contentRect] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) {
            // contentRect is in points; scaleFactor converts to buffer pixels.
            let scaleFactor = (info[.scaleFactor] as? CGFloat) ?? 1
            let contentScale = (info[.contentScale] as? CGFloat) ?? 1
            let pixelRect = CGRect(x: rect.minX * scaleFactor, y: rect.minY * scaleFactor,
                                   width: rect.width * scaleFactor * contentScale,
                                   height: rect.height * scaleFactor * contentScale)
            if Self.debug {
                NSLog("WindowInvert frame buf=\(bufferSize) contentRect=\(rect) contentScale=\(contentScale) scaleFactor=\(scaleFactor)")
            }
            contentRect = pixelRect.intersection(CGRect(origin: .zero, size: bufferSize))
            if contentRect.isNull || contentRect.width < 1 || contentRect.height < 1 {
                contentRect = CGRect(origin: .zero, size: bufferSize)
            }
        }
        let frame = Frame(pixelBuffer: pixelBuffer, contentRect: contentRect)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.ended else { return }
            self.latestFrame = frame
            self.render()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("stream stopped: \(error)")
        DispatchQueue.main.async { [weak self] in self?.end() }
    }

    static let debug = ProcessInfo.processInfo.environment["WINDOWINVERT_DEBUG"] != nil

    // MARK: - Rendering

    private func render() {
        guard !ended, isTargetVisible, let frame = latestFrame, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }

        let overlayRect = scope == .content ? bounds.inset(by: insets) : bounds
        let cocoaRect = overlayRect.flippedToCocoa

        let buffer = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let cr = frame.contentRect
        let fx0 = (overlayRect.minX - bounds.minX) / bounds.width
        let fy0 = (overlayRect.minY - bounds.minY) / bounds.height
        let fw = overlayRect.width / bounds.width
        let fh = overlayRect.height / bounds.height
        let crop = CGRect(x: (cr.minX + fx0 * cr.width) / buffer.width,
                          y: (cr.minY + fy0 * cr.height) / buffer.height,
                          width: fw * cr.width / buffer.width,
                          height: fh * cr.height / buffer.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if overlay.frame != cocoaRect {
            overlay.setFrame(cocoaRect, display: false, animate: false)
        }
        let scale = overlay.backingScaleFactor
        let layer = overlay.metalLayer
        layer.frame = CGRect(origin: .zero, size: cocoaRect.size)
        layer.contentsScale = scale
        let drawableSize = CGSize(width: max(1, (cocoaRect.width * scale).rounded()),
                                  height: max(1, (cocoaRect.height * scale).rounded()))
        if layer.drawableSize != drawableSize { layer.drawableSize = drawableSize }
        let pixelHoles = holes.map { hole in
            CGRect(x: (hole.minX - overlayRect.minX) * scale, y: (hole.minY - overlayRect.minY) * scale,
                   width: hole.width * scale, height: hole.height * scale)
        }
        InvertRenderer.shared.draw(pixelBuffer: frame.pixelBuffer, crop: crop, mode: colorMode,
                                   holes: pixelHoles, holeRadius: Self.holeCornerRadius * scale, into: layer)
        CATransaction.commit()

        if !overlay.isVisible {
            overlay.order(.above, relativeTo: Int(target.windowID))
        }
    }

    enum SessionError: LocalizedError {
        case windowGone
        var errorDescription: String? { "The window could not be found for capture." }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
