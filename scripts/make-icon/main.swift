// Renders the app icon from IconArt: a light + dark asset catalog and a light .icns fallback.
// Run: scripts/make-icon.sh
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let appiconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
for dir in [iconset, appiconset] {
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

func png(size px: Int, dark: Bool) throws -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    IconArt.drawAppIcon(size: CGFloat(px), context: ctx, dark: dark)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

var images: [[String: Any]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix)"
        let light = try png(size: px, dark: false)
        try light.write(to: iconset.appendingPathComponent("\(name).png"))
        try light.write(to: appiconset.appendingPathComponent("\(name).png"))
        try png(size: px, dark: true).write(to: appiconset.appendingPathComponent("\(name)-dark.png"))
        let base: [String: Any] = ["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"]
        images.append(base.merging(["filename": "\(name).png"]) { $1 })
        images.append(base.merging([
            "filename": "\(name)-dark.png",
            "appearances": [["appearance": "luminosity", "value": "dark"]],
        ]) { $1 })
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appiconset.appendingPathComponent("Contents.json"))

// Layered Icon Composer document: macOS 26 renders light, dark and tinted variants from it.
if CommandLine.arguments.count > 3 {
    let icon = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let assets = icon.appendingPathComponent("Assets", isDirectory: true)
    try? FileManager.default.removeItem(at: icon)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for dark in [false, true] {
        let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        IconArt.drawIconLayer(size: 1024, context: ctx, dark: dark)
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: assets.appendingPathComponent(dark ? "glyph-dark.png" : "glyph.png"))
    }
    let json = """
    {
      "fill-specializations" : [
        { "value" : { "linear-gradient" : [ "srgb:0.97000,0.97000,0.98000,1.00000", "srgb:0.86000,0.87000,0.90000,1.00000" ] } },
        { "appearance" : "dark", "value" : { "linear-gradient" : [ "srgb:0.25000,0.25000,0.27000,1.00000", "srgb:0.12000,0.12000,0.13000,1.00000" ] } }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "image-name-specializations" : [
                { "value" : "glyph.png" },
                { "appearance" : "dark", "value" : "glyph-dark.png" }
              ],
              "name" : "glyph"
            }
          ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
}
