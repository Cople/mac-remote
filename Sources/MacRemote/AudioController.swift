import CoreAudio
import Foundation
import MacRemoteCore

final class AudioController {
    struct Snapshot {
        let volume: Double?
        let muted: Bool?
        let controllable: Bool
    }

    func snapshot() -> Snapshot {
        guard let device = outputDevice() else { return Snapshot(volume: nil, muted: nil, controllable: false) }
        let channels = volumeChannels(device)
        let values = channels.compactMap { getFloat(device, selector: kAudioDevicePropertyVolumeScalar, element: $0) }
        let volume = values.isEmpty ? nil : Double(values.reduce(0, +) / Float32(values.count))
        let muted = getUInt(device, selector: kAudioDevicePropertyMute).map { $0 != 0 }
        return Snapshot(volume: volume, muted: muted, controllable: !channels.isEmpty && channels.allSatisfy {
            isSettable(device, selector: kAudioDevicePropertyVolumeScalar, element: $0)
        })
    }

    func setVolume(_ value: Double) throws {
        guard let device = outputDevice() else { throw RemoteError("没有可用的音频输出设备", status: 503) }
        let channels = volumeChannels(device)
        guard !channels.isEmpty, channels.allSatisfy({ isSettable(device, selector: kAudioDevicePropertyVolumeScalar, element: $0) }) else {
            throw RemoteError("当前音频设备不支持系统音量调节，请使用音箱或显示器的音量控制", status: 409)
        }
        var scalar = Float32(min(1, max(0, value)))
        for channel in channels {
            var address = property(kAudioDevicePropertyVolumeScalar, element: channel)
            guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr else {
                throw RemoteError("音量调节失败，音频输出设备可能已切换", status: 503)
            }
        }
        if value > 0, isSettable(device, selector: kAudioDevicePropertyMute) { try setMute(false, device: device) }
    }

    func step(_ amount: Double) throws {
        guard let volume = snapshot().volume else { throw RemoteError("无法读取当前音量", status: 409) }
        try setVolume(volume + amount)
    }

    func toggleMute() throws {
        guard let device = outputDevice(), let value = getUInt(device, selector: kAudioDevicePropertyMute),
              isSettable(device, selector: kAudioDevicePropertyMute) else {
            throw RemoteError("当前音频设备不支持系统静音控制", status: 409)
        }
        try setMute(value == 0, device: device)
    }

    private func setMute(_ muted: Bool, device: AudioDeviceID) throws {
        var address = property(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
            throw RemoteError("静音状态切换失败", status: 503)
        }
    }

    private func outputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func volumeChannels(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if getFloat(device, selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) != nil {
            return [kAudioObjectPropertyElementMain]
        }
        // Devices without a master scalar expose one scalar per output channel.
        var address = property(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let count = list.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard count > 0 else { return [] }
        return (1...count).filter { getFloat(device, selector: kAudioDevicePropertyVolumeScalar, element: $0) != nil }
    }

    private func property(_ selector: AudioObjectPropertySelector,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func isSettable(_ device: AudioDeviceID, selector: AudioObjectPropertySelector,
                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = property(selector, element: element)
        var value = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &value) == noErr && value.boolValue
    }

    private func getFloat(_ device: AudioDeviceID, selector: AudioObjectPropertySelector,
                          element: AudioObjectPropertyElement) -> Float32? {
        var address = property(selector, element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func getUInt(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
