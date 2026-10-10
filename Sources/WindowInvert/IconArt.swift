import CoreGraphics

/// Vector artwork shared by the menu bar icon and the app icon: a rounded "window" split
/// diagonally into a filled and an outlined half, with a disc in the middle whose halves are inverted.
enum IconArt {
    /// Draws the glyph in `rect` (y-up). Parts that should be "paper" are cleared, so draw into a
    /// transparent layer or bitmap.
    static func drawGlyph(in rect: CGRect, context ctx: CGContext, ink: CGColor,
                          lineWidth: CGFloat, mirrored: Bool = false) {
        let frame = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = frame.width * 0.24
        let window = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Top-left half (above the bottom-left → top-right diagonal), or bottom-right when mirrored.
        let filledHalf = CGMutablePath()
        if mirrored {
            filledHalf.addLines(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                          CGPoint(x: rect.maxX, y: rect.maxY)])
        } else {
            filledHalf.addLines(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                                          CGPoint(x: rect.maxX, y: rect.maxY)])
        }
        filledHalf.closeSubpath()
        let otherHalf = CGMutablePath()
        otherHalf.addRect(rect)
        otherHalf.addPath(filledHalf)

        ctx.saveGState()
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)

        ctx.setLineWidth(lineWidth)
        ctx.addPath(window)
        ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(window)
        ctx.clip()
        ctx.addPath(filledHalf)
        ctx.fillPath()
        ctx.restoreGState()

        let discRadius = rect.width * 0.2
        let disc = CGPath(ellipseIn: CGRect(x: rect.midX - discRadius, y: rect.midY - discRadius,
                                            width: discRadius * 2, height: discRadius * 2), transform: nil)
        ctx.saveGState()
        ctx.addPath(filledHalf)
        ctx.clip()
        ctx.setBlendMode(.clear)
        ctx.addPath(disc)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(otherHalf)
        ctx.clip(using: .evenOdd)
        ctx.addPath(disc)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    /// Full-color app icon on a macOS-style tile, drawn into a square `size`×`size` y-up context.
    static func drawAppIcon(size: CGFloat, context ctx: CGContext, dark: Bool = false) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let unit = size / 1024
        let tile = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit,
                      color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(tilePath)
        ctx.setFillColor(CGColor(gray: dark ? 0.2 : 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: (dark ? [
            CGColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1),
            CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
        ] : [
            CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
            CGColor(srgbRed: 0.86, green: 0.87, blue: 0.90, alpha: 1),
        ]) as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        ctx.restoreGState()

        // Draw the glyph in its own transparency layer so its cleared parts reveal the tile.
        let glyphRect = tile.insetBy(dx: 170 * unit, dy: 170 * unit)
        let ink = dark ? CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
                       : CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawGlyph(in: glyphRect, context: ctx, ink: ink, lineWidth: 40 * unit)
        // Title-bar dots on the filled half, to read as a window.
        let dot = 26 * unit
        let start = CGPoint(x: glyphRect.minX + 70 * unit, y: glyphRect.maxY - 70 * unit)
        ctx.setFillColor(dark ? CGColor(gray: 0.15, alpha: 0.95) : CGColor(gray: 1, alpha: 0.9))
        for i in 0..<3 {
            ctx.fillEllipse(in: CGRect(x: start.x + CGFloat(i) * dot * 1.7 - dot / 2, y: start.y - dot / 2,
                                       width: dot, height: dot))
        }
        ctx.endTransparencyLayer()
    }

    /// The glyph alone on a transparent 1024-pt canvas, for the layered `.icon` (macOS 26+ draws the
    /// tile, and its own dark/tinted variants, around it).
    static func drawIconLayer(size: CGFloat, context ctx: CGContext, dark: Bool) {
        let unit = size / 1024
        let glyphRect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 230 * unit, dy: 230 * unit)
        let ink = dark ? CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
                       : CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawGlyph(in: glyphRect, context: ctx, ink: ink, lineWidth: 48 * unit)
        let dot = 32 * unit
        let start = CGPoint(x: glyphRect.minX + 85 * unit, y: glyphRect.maxY - 85 * unit)
        ctx.setBlendMode(.clear)
        for i in 0..<3 {
            ctx.fillEllipse(in: CGRect(x: start.x + CGFloat(i) * dot * 1.7 - dot / 2, y: start.y - dot / 2,
                                       width: dot, height: dot))
        }
        ctx.endTransparencyLayer()
    }
}
