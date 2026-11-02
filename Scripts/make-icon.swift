import AppKit
import CoreText

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = project.appendingPathComponent("Sources/MacRemote/Resources/RemixIcon")
CTFontManagerRegisterFontsForURL(assets.appendingPathComponent("remixicon.ttf") as CFURL, .process, nil)
let glyphs = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: assets.appendingPathComponent("glyphs.json")))
let font = CTFontCreateWithName("remixicon" as CFString, 680, nil)
var character = Array(glyphs["remote-control-line"]!.utf16)[0]
var glyph = CGGlyph()
precondition(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil)!

func render(size: Int, fullBleed: Bool = false, glyphScale: CGFloat = 1) -> Data {
    // Explicit pixels avoid Retina's implicit 2× scaling in NSImage.lockFocus().
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSAffineTransform(transform: AffineTransform(scale: scale)).concat()
    let shape = fullBleed
        ? NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        : NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.94, green: 0.39, blue: 0.23, alpha: 1),
                              ending: NSColor(srgbRed: 0.80, green: 0.22, blue: 0.12, alpha: 1))!
    gradient.draw(in: shape, angle: -70)
    // Font line bounds include side bearings; center the actual outline instead.
    let bounds = glyphPath.boundingBoxOfPath
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 512 - bounds.midX * glyphScale, y: 512 - bounds.midY * glyphScale)
    context.scaleBy(x: glyphScale, y: glyphScale)
    context.setFillColor(NSColor(srgbRed: 1, green: 0.97, blue: 0.90, alpha: 1).cgColor)
    context.addPath(glyphPath)
    context.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.dropFirst().first == "--web" {
    let directory = project.appendingPathComponent("Sources/MacRemote/Web/icons")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Android launchers can enlarge shortcut icons. Keep one opaque composition
    // with extra foreground padding for the Android icon sources.
    for size in [192, 512] {
        try render(size: size, fullBleed: true, glyphScale: 0.8).write(to: directory.appendingPathComponent("icon-\(size).png"))
    }
    try render(size: 512, fullBleed: true, glyphScale: 0.8).write(to: directory.appendingPathComponent("icon-maskable-512.png"))
    try render(size: 180, fullBleed: true).write(to: directory.appendingPathComponent("apple-touch-icon.png"))
    exit(0)
}

let destination = CommandLine.arguments[1]
let root = URL(fileURLWithPath: destination).deletingLastPathComponent()
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
