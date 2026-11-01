import Foundation
import Darwin

public struct LANAddress: Identifiable, Equatable {
    public let interface: String
    public let address: String
    public var id: String { "\(interface):\(address)" }
    public var label: String { "\(interface) · \(address)" }

    public static func current() -> [LANAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [LANAddress] = []
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let socket = item.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            // Wi-Fi, Ethernet and USB networking; omit tunnels and virtual bridge interfaces.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            guard !address.hasPrefix("169.254."), !address.hasPrefix("127.") else { continue }
            result.append(LANAddress(interface: name, address: address))
        }
        return result.sorted {
            if $0.interface == "en0" { return $1.interface != "en0" }
            if $1.interface == "en0" { return false }
            return $0.interface < $1.interface
        }
    }
}
