import AudioToolbox
import CoreAudio
import Foundation
import os

/// Output volume of the default output device, with change tracking (SPEC §15.4).
///
/// All CoreAudio state lives on `queue`; that confinement is why the class is
/// `@unchecked Sendable`.
final class VolumeController: @unchecked Sendable {
    struct Reading: Sendable, Equatable {
        var value: Float
        var muted: Bool
    }

    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).volume")
    private let report: @Sendable (Reading?) -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var watched: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var started = false

    /// `report` is called on a private queue with the current reading, or nil
    /// when the output device has no adjustable volume.
    init(report: @escaping @Sendable (Reading?) -> Void) {
        self.report = report
    }

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.deviceChanged() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            deviceListener = listener
            deviceChanged()
        }
    }

    /// Reports the current state again.
    func refresh() {
        queue.async { [self] in publish() }
    }

    func set(value: Float?, muted: Bool?) {
        queue.sync {
            let device = self.device
            guard device != kAudioObjectUnknown else { return }
            if let value {
                let clamped = Float32(min(max(value.isFinite ? value : 0, 0), 1))
                var main = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
                if Self.isSettable(device, &main) {
                    Self.write(clamped, device, &main)
                } else {
                    for channel in Self.stereoChannels(device) {
                        var address = Self.address(kAudioDevicePropertyVolumeScalar, element: channel)
                        if Self.isSettable(device, &address) { Self.write(clamped, device, &address) }
                    }
                }
            }
            if let muted {
                var address = Self.address(kAudioDevicePropertyMute)
                if Self.isSettable(device, &address) { Self.write(UInt32(muted ? 1 : 0), device, &address) }
            }
            publish()
        }
    }

    // MARK: Private (on `queue`)

    private func deviceChanged() {
        for (object, address, block) in watched {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        watched.removeAll()
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        device = Self.read(AudioObjectID(kAudioObjectSystemObject), &address) ?? AudioObjectID(kAudioObjectUnknown)
        if device != kAudioObjectUnknown {
            var selectors: [AudioObjectPropertyAddress] = [
                Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                Self.address(kAudioDevicePropertyMute),
            ]
            for channel in Self.stereoChannels(device) {
                selectors.append(Self.address(kAudioDevicePropertyVolumeScalar, element: channel))
            }
            for var address in selectors where AudioObjectHasProperty(device, &address) {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publish() }
                if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                    watched.append((device, address, block))
                }
            }
        }
        publish()
    }

    private func publish() {
        report(currentReading())
    }

    private func currentReading() -> Reading? {
        guard device != kAudioObjectUnknown else { return nil }
        var main = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &main), let value: Float32 = Self.read(device, &main) else { return nil }
        var mute = Self.address(kAudioDevicePropertyMute)
        let muted: UInt32 = AudioObjectHasProperty(device, &mute) ? (Self.read(device, &mute) ?? 0) : 0
        return Reading(value: value, muted: muted != 0)
    }

    // MARK: CoreAudio helpers

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> T? {
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
            size == UInt32(MemoryLayout<T>.size)
        else { return nil }
        return pointer.load(as: T.self)
    }

    private static func write<T: BitwiseCopyable>(_ value: T, _ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) {
        var value = value
        let status = withUnsafeBytes(of: &value) { bytes in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!)
        }
        if status != noErr { Logger.app.error("volume: set property failed (\(status))") }
    }

    private static func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func stereoChannels(_ device: AudioObjectID) -> [UInt32] {
        var address = address(kAudioDevicePropertyPreferredChannelsForStereo)
        guard AudioObjectHasProperty(device, &address) else { return [] }
        var channels: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout.size(ofValue: channels))
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels) == noErr else { return [] }
        return [channels.0, channels.1].filter { $0 != 0 }
    }
}

