import CoreAudio
import Foundation

/// The default input's native mute control; never input gain, never the output device.
enum MicrophoneMuteRunner {
    private static let confirmationAttempts = 10
    private static let confirmationInterval = Duration.milliseconds(50)

    /// Returns the state the device confirmed, so feedback never names a change that did not land.
    static func toggle() async throws -> Bool {
        let device = try defaultInputDevice()
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else {
            throw SystemActionFailure("The current microphone does not support software mute.")
        }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
            settable.boolValue
        else {
            throw SystemActionFailure("The current microphone mute is controlled externally.")
        }

        let requested = try !isMuted(device)
        var value: UInt32 = requested ? 1 : 0
        try Task.checkCancellation()
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw SystemActionFailure("macOS could not change microphone mute (error \(status)).")
        }

        // CoreAudio applies a property write asynchronously, so the result is read back.
        for _ in 0..<confirmationAttempts {
            if try isMuted(device) == requested { return requested }
            try await Task.sleep(for: confirmationInterval)
        }
        guard try isMuted(device) == requested else {
            throw SystemActionFailure("The microphone did not confirm the mute change. Try again.")
        }
        return requested
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw SystemActionFailure("No audio input device is available.")
        }
        return device
    }

    private static func isMuted(_ device: AudioDeviceID) throws -> Bool {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw SystemActionFailure("macOS could not read microphone mute (error \(status)).")
        }
        return value != 0
    }
}
