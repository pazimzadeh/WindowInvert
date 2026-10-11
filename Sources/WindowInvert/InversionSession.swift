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
    var contrast: Contrast {
        didSet { render() }
    }
    var onEnded: ((InversionSession) -> Void)?

    private struct Frame {
        let pixelBuffer: CVPixelBuffer
        /// Region of the pixel buffer holding the window, in buffer pixels.
        let contentRect: CGRect
        /// Size in points of what `contentRect` shows. Can exceed the window's CG bounds: a full-screen
        /// window is captured together with its hidden title bar/toolbar strip above the screen.
        let capturedPoints: CGSize
    }

    private let overlay = OverlayWindow()
    private let sampleQueue = DispatchQueue(label: "WindowInvert.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var latestFrame: Frame?
    private var bounds: CGRect = .null
    private var isTargetVisible = false
    private var insets = EdgeInsets.zero
    /// True while one of the target app's sheets or popovers covers the target. macOS already dims
    /// the window behind a sheet, and inverting that dimming would brighten it, so the overlay hides.
    private var isPausedForSheet = false
    /// When off, inversion stays on behind sheets, which show through rounded holes instead.
    var pausesBehindSheets = true {
        didSet {
            isPausedForSheet = false
            holes = []
            render()
        }
    }
    var hidesInMissionControl: Bool {
        get { overlay.hidesInMissionControl }
        set { overlay.hidesInMissionControl = newValue }
    }
    private var holes: [CGRect] = []
    /// Matches the corner radius of sheets on macOS 26.
    private static let holeCornerRadius: CGFloat = 19
    /// Height of a full-screen window's hidden title bar/toolbar strip, which capture includes.
    private var captureExtraTop: CGFloat = 0
    private var captureSize: CGSize { CGSize(width: bounds.width, height: bounds.height + captureExtraTop) }
    /// Where to sample the document background, relative to the window's top-left
    /// (see WindowLocator.backgroundSamplePoints).
    private var backgroundSamples: [CGPoint] = []
    private var lastKeep = SIMD4<Float>.zero
    private var loggedBackgroundMeasurement = false
    private var backgroundArea = CGRect.null
    private var lastSampleTime: CFTimeInterval = 0
    private var lastSampleBounds: CGRect = .null
    private var isSampling = false
    private static let axQueue = DispatchQueue(label: "WindowInvert.ax", qos: .utility)
    private var configuredPixelSize = CGSize.zero
    private var configuredScale: CGFloat = 0
    private var isUpdatingConfig = false
    private var needsConfigUpdate = false
    private var insetsWorkItem: DispatchWorkItem?
    private var ended = false

    init(target: TargetWindow, scope: InvertScope, colorMode: ColorMode, contrast: Contrast) {
        self.target = target
        self.scope = scope
        self.colorMode = colorMode
        self.contrast = contrast
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
        // Order the still-empty (transparent) overlay in now, so it is already on screen when the
        // first frame arrives instead of appearing a few frames later.
        if isTargetVisible {
            overlay.setFrame(bounds.flippedToCocoa, display: false)
            overlay.level = preferredLevel(above: WindowLocator.windowsAbove(target.windowID))
            overlay.order(.above, relativeTo: Int(target.windowID))
        }

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
        let config = makeConfiguration(size: captureSize, scale: scale)
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
            Log.write("window \(target.windowID): target \(visible ? "visible again" : "not on screen"), bounds \(state.bounds)")
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
        updateStacking()
        if !overlay.isVisible && latestFrame != nil {
            render()
        }
    }

    /// Keeps the overlay directly above the target. The window server keeps an app's sheets and
    /// popovers grouped with their parent, so the overlay always ends up above them; while one is
    /// open over the target, the overlay is hidden instead.
    private func updateStacking() {
        refreshBackgroundSamplesIfNeeded()
        let overlayID = CGWindowID(overlay.windowNumber)
        let above = WindowLocator.windowsAbove(target.windowID)
        let sheets = above.filter { window in
            window.pid == target.pid && window.layer == 0 && window.id != overlayID && window.title.isEmpty
                // Skip tiny helper windows such as the title-bar button strip.
                && window.bounds.width >= 100 && window.bounds.height >= 40 && window.bounds.intersects(bounds)
        }
        let sheetOpen = pausesBehindSheets && !sheets.isEmpty
        let newHoles = pausesBehindSheets ? [] : sheets.map(\.bounds)
        if newHoles != holes {
            holes = newHoles
            render()
        }
        if sheetOpen != isPausedForSheet {
            isPausedForSheet = sheetOpen
            Log.write("window \(target.windowID): \(sheetOpen ? "sheet/popover open, pausing" : "resuming")")
            if sheetOpen {
                overlay.orderOut(nil)
            } else {
                render()
            }
        }
        guard overlay.isVisible else { return }
        // While the target is the front-most normal window, float the overlay one level up. Clicking the
        // window's frame raises it above normal-level windows on every frame until mouse-up, and fighting
        // that with restacking makes the inversion flicker.
        let level = preferredLevel(above: above)
        let targetIsFront = level == .floating
        if overlay.level != level {
            Log.write("window \(target.windowID): \(targetIsFront ? "front-most, floating overlay" : "covered, normal-level overlay")")
            overlay.level = level
            overlay.order(.above, relativeTo: Int(target.windowID))
            return
        }
        guard !targetIsFront else { return }
        if let index = above.firstIndex(where: { $0.id == overlayID }) {
            if above[(index + 1)...].contains(where: { $0.pid != target.pid }) {
                overlay.order(.above, relativeTo: Int(target.windowID))
            }
        } else {
            overlay.order(.above, relativeTo: Int(target.windowID))
        }
    }

    private func preferredLevel(above: [WindowLocator.StackedWindow]) -> NSWindow.Level {
        let me = getpid()
        return above.contains { $0.layer == 0 && $0.pid != target.pid && $0.pid != me } ? .normal : .floating
    }

    /// Re-measured once a second while the window isn't being resized. AX calls block until the target app
    /// answers, so they run off the main thread; otherwise a busy app would stall overlay restacking.
    private func refreshBackgroundSamplesIfNeeded() {
        defer { lastSampleBounds = bounds }
        let now = CACurrentMediaTime()
        guard let ax = target.axWindow, bounds.size == lastSampleBounds.size, !isSampling, now - lastSampleTime > 1 else { return }
        lastSampleTime = now
        isSampling = true
        Self.axQueue.async { [weak self] in
            let (samples, area) = WindowLocator.backgroundSamplePoints(in: ax)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSampling = false
                if samples.isEmpty != self.backgroundSamples.isEmpty {
                    Log.write("window \(self.target.windowID): background samples \(samples)")
                }
                let changed = samples != self.backgroundSamples || area != self.backgroundArea
                self.backgroundSamples = samples
                self.backgroundArea = area
                // A still window delivers no new frames, so redraw the last one with the new samples.
                if changed { self.render() }
            }
        }
    }

    /// The document background colour if most sample points agree and it's a dark neutral grey
    /// (inverting it would make the area around the pages light). Once found, the colour is kept
    /// while the PDF view exists, so a miss (window dragged, page scrolled over the sample points)
    /// doesn't flicker the background.
    private func keepColor(for frame: Frame) -> SIMD4<Float> {
        guard !backgroundArea.isNull else { return .zero }
        let measured = measuredKeepColor(for: frame)
        if measured.w > 0 {
            if lastKeep.w == 0 {
                Log.write("window \(target.windowID): keeping background colour \(measured)")
            }
            lastKeep = measured
        }
        return lastKeep
    }

    private func measuredKeepColor(for frame: Frame) -> SIMD4<Float> {
        guard !backgroundSamples.isEmpty, bounds.width > 0, bounds.height > 0 else { return .zero }
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .zero }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let cr = windowPixelRect(of: frame)
        var colors: [SIMD3<Float>] = []
        for point in backgroundSamples {
            let x = Int(cr.minX + point.x / bounds.width * cr.width)
            let y = Int(cr.minY + point.y / bounds.height * cr.height)
            guard x >= 0, y >= 0, x < width, y < height else { continue }
            let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            colors.append(SIMD3(Float(pixel[2]), Float(pixel[1]), Float(pixel[0])) / 255) // BGRA
        }
        if !loggedBackgroundMeasurement {
            loggedBackgroundMeasurement = true
            Log.write("window \(target.windowID): initial background colours \(colors)")
        }
        return Self.backgroundColor(from: colors)
    }

    static func backgroundColor(from colors: [SIMD3<Float>]) -> SIMD4<Float> {
        let needed = colors.count / 2 + 1
        guard let first = colors.first(where: { c in
            colors.filter { (($0 - c) * ($0 - c)).max() < 0.0004 }.count >= needed
        }), colors.count >= 2 else { return .zero }
        let luma = first.x * 0.299 + first.y * 0.587 + first.z * 0.114
        // Allow Preview's slightly blue-tinted dark gutter as well as neutral greys.
        guard luma > 0.03, luma < 0.4, first.max() - first.min() < 0.1 else { return .zero }
        return SIMD4(first, 1)
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
        let wanted = CGSize(width: (captureSize.width * scale).rounded(), height: (captureSize.height * scale).rounded())
        guard wanted != configuredPixelSize || scale != configuredScale else { return }
        isUpdatingConfig = true
        needsConfigUpdate = false
        stream.updateConfiguration(makeConfiguration(size: captureSize, scale: scale)) { [weak self] error in
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
        var capturedPoints = CGSize.zero
        if let dict = info[.contentRect] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) {
            // contentRect is in points; scaleFactor converts to buffer pixels.
            let scaleFactor = (info[.scaleFactor] as? CGFloat) ?? 1
            let contentScale = (info[.contentScale] as? CGFloat) ?? 1
            let pixelRect = CGRect(x: rect.minX * scaleFactor, y: rect.minY * scaleFactor,
                                   width: rect.width * scaleFactor, height: rect.height * scaleFactor)
            capturedPoints = CGSize(width: rect.width / contentScale, height: rect.height / contentScale)
            if Self.debug {
                NSLog("WindowInvert frame buf=\(bufferSize) contentRect=\(rect) contentScale=\(contentScale) scaleFactor=\(scaleFactor)")
            }
            contentRect = pixelRect.intersection(CGRect(origin: .zero, size: bufferSize))
            if contentRect.isNull || contentRect.width < 1 || contentRect.height < 1 {
                contentRect = CGRect(origin: .zero, size: bufferSize)
                capturedPoints = .zero
            }
        }
        let frame = Frame(pixelBuffer: pixelBuffer, contentRect: contentRect, capturedPoints: capturedPoints)
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

    /// The part of the frame showing the window's CG bounds, in buffer pixels.
    private func windowPixelRect(of frame: Frame) -> CGRect {
        let cr = frame.contentRect
        let captured = frame.capturedPoints
        let extraTop = captured.height - bounds.height
        guard captured.height > 0, abs(captured.width - bounds.width) < 2, extraTop > 8 else { return cr }
        let pixelsPerPoint = cr.height / captured.height
        return CGRect(x: cr.minX, y: cr.minY + extraTop * pixelsPerPoint,
                      width: cr.width, height: bounds.height * pixelsPerPoint)
    }

    private func updateCaptureExtraTop(from frame: Frame) {
        let captured = frame.capturedPoints
        guard captured.height > 0, abs(captured.width - bounds.width) < 2 else { return }
        let extra = captured.height - bounds.height
        let newExtra = extra > 8 ? extra : (abs(extra) < 2 ? 0 : captureExtraTop)
        if abs(newExtra - captureExtraTop) > 0.5 {
            Log.write("window \(target.windowID): capture includes \(newExtra) pt above the window")
            captureExtraTop = newExtra
            updateStreamSizeIfNeeded()
        }
    }

    private func render() {
        guard !ended, isTargetVisible, !isPausedForSheet, let frame = latestFrame, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }

        let overlayRect = scope == .content ? bounds.inset(by: insets) : bounds
        let cocoaRect = overlayRect.flippedToCocoa

        updateCaptureExtraTop(from: frame)
        let buffer = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let cr = windowPixelRect(of: frame)
        let fx0 = (overlayRect.minX - bounds.minX) / bounds.width
        let fy0 = (overlayRect.minY - bounds.minY) / bounds.height
        let fw = overlayRect.width / bounds.width
        let fh = overlayRect.height / bounds.height
        let crop = CGRect(x: (cr.minX + fx0 * cr.width) / buffer.width,
                          y: (cr.minY + fy0 * cr.height) / buffer.height,
                          width: fw * cr.width / buffer.width,
                          height: fh * cr.height / buffer.height)
        // Only the PDF view's gutter keeps its colour; elsewhere (sidebars, inspector) the same grey inverts.
        let keepRect = backgroundArea.isNull ? CGRect.zero : CGRect(
            x: (cr.minX + backgroundArea.minX / bounds.width * cr.width) / buffer.width,
            y: (cr.minY + backgroundArea.minY / bounds.height * cr.height) / buffer.height,
            width: backgroundArea.width / bounds.width * cr.width / buffer.width,
            height: backgroundArea.height / bounds.height * cr.height / buffer.height)

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
        let captureScale = cr.height / max(1, bounds.height)
        InvertRenderer.shared.draw(pixelBuffer: frame.pixelBuffer, crop: crop, mode: colorMode,
                                   contrast: contrast, keep: keepColor(for: frame), keepRect: keepRect, edge: Float(3 * captureScale),
                                   holes: pixelHoles, holeRadius: Self.holeCornerRadius * scale, into: layer)
        CATransaction.commit()

        if !overlay.isVisible {
            Log.write("window \(target.windowID): showing overlay")
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
