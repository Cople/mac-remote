import XCTest
@testable import MacRemoteCore

final class ConnectedDeviceTests: XCTestCase {
    func testRecognizesPlatformsAndBrowsersWithoutTreatingChromeAsSafari() {
        let cases = [
            ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/147.0.0.0 Mobile Safari/537.36", "Android · Chrome"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", "iPhone · Safari"),
            ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) CriOS/147.0.0.0 Mobile/15E148 Safari/604.1", "iPhone · Chrome"),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", "iPad · Safari"),
            ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/147.0.0.0 Safari/537.36 Edg/147.0.0.0", "Windows · Edge"),
            ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/147.0", "macOS · Firefox"),
            ("Mozilla/5.0 (Linux; Android 10; K) SamsungBrowser/30.0 Chrome/147.0.0.0 Mobile Safari/537.36", "Android · Samsung Internet"),
            ("", "未知设备 · 未知浏览器")
        ]
        for (agent, name) in cases {
            let device = ConnectedDevice(address: "192.168.1.10", userAgent: agent, lastSeen: Date())
            XCTAssertEqual(device.name, name)
            XCTAssertEqual(device.summary, "\(name)\n192.168.1.10")
        }
    }
}
