import Foundation

public struct ConnectedDevice: Equatable {
    public let address: String
    public let name: String
    public let lastSeen: Date

    public var summary: String { "\(name)\n\(address)" }

    init(address: String, userAgent: String, lastSeen: Date) {
        self.address = address
        self.lastSeen = lastSeen
        let platform: String
        if userAgent.contains("iPad") || (userAgent.contains("Macintosh") && userAgent.contains("Mobile/")) {
            platform = "iPad"
        } else if userAgent.contains("iPhone") || userAgent.contains("iPod") {
            platform = "iPhone"
        } else if userAgent.contains("Android") {
            platform = "Android"
        } else if userAgent.contains("Windows NT") {
            platform = "Windows"
        } else if userAgent.contains("CrOS") {
            platform = "ChromeOS"
        } else if userAgent.contains("Macintosh") || userAgent.contains("Mac OS X") {
            platform = "macOS"
        } else if userAgent.contains("Linux") {
            platform = "Linux"
        } else {
            platform = "未知设备"
        }
        // Check browsers that include Chrome or Safari tokens before their base browser.
        let browsers = [
            ("Edge", ["Edg/", "EdgA/", "EdgiOS/"]),
            ("Firefox", ["Firefox/", "FxiOS/"]),
            ("Samsung Internet", ["SamsungBrowser/"]),
            ("Opera", ["OPR/", "OPiOS/"]),
            ("Chrome", ["Chrome/", "CriOS/"]),
            ("Safari", ["Safari/"])
        ]
        let browser = browsers.first { rule in rule.1.contains { userAgent.contains($0) } }?.0 ?? "未知浏览器"
        name = "\(platform) · \(browser)"
    }
}
