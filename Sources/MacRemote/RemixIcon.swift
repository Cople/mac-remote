import AppKit
import CoreText
import SwiftUI

@MainActor struct RemixIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Self.image(name, size: size))
            .renderingMode(.template)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static let glyphs: [String: String] = {
        let bundle = AppResources.bundle
        let fontURL = bundle.url(forResource: "remixicon", withExtension: "ttf", subdirectory: "RemixIcon")!
        let glyphURL = bundle.url(forResource: "glyphs", withExtension: "json", subdirectory: "RemixIcon")!
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        let data = try! Data(contentsOf: glyphURL)
        return try! JSONDecoder().decode([String: String].self, from: data)
    }()

    static func image(_ name: String, size: CGFloat = 18) -> NSImage {
        let glyph = glyphs[name]!
        let font = NSFont(name: "remixicon", size: size)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph, attributes: [.font: font, .foregroundColor: NSColor.black]
        ))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: (rect.width - bounds.width) / 2 - bounds.minX,
                                           y: (rect.height - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, context)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
