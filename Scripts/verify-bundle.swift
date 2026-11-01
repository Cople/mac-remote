import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Bundle check failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("expected an .app path") }
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let resources = app.appendingPathComponent("Contents/Resources/MacRemote_MacRemote.bundle")
guard let bundle = Bundle(url: resources),
      let web = bundle.url(forResource: "Web", withExtension: nil),
      let font = bundle.url(forResource: "remixicon", withExtension: "ttf", subdirectory: "RemixIcon"),
      let glyphs = bundle.url(forResource: "glyphs", withExtension: "json", subdirectory: "RemixIcon") else {
    fail("web resources or Remix Icon assets cannot be resolved")
}

let files = ["index.html", "app.css", "app.js", "icon.svg", "manifest.webmanifest",
             "icons/icon-192.png", "icons/icon-512.png", "icons/icon-maskable-512.png",
             "icons/apple-touch-icon.png"].map { web.appendingPathComponent($0) } + [font, glyphs]
for file in files {
    guard let data = try? Data(contentsOf: file), !data.isEmpty else { fail("missing or empty \(file.lastPathComponent)") }
}
let icons = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: glyphs))
for name in ["remote-control-line", "logout-box-r-line", "external-link-line"] {
    guard icons[name] != nil else { fail("missing \(name) glyph") }
}
print("Application resources verified.")
