import Foundation

enum AppResources {
    static let bundle: Bundle = {
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("MacRemote_MacRemote.bundle"))
        }
        return packaged ?? Bundle.module
    }()
}
