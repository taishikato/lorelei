//
//  AudioInputDeviceStore.swift
//  Lorelei
//
//  Persists and resolves the microphone input device selected in settings.
//

import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

protocol AudioInputDeviceEnumerating {
    func availableInputDevices() -> [AudioInputDevice]
    func defaultInputDeviceUID() -> String?
    func defaultInputDeviceID() -> AudioDeviceID?
    func deviceID(for uid: String) -> AudioDeviceID?
}

struct CoreAudioInputDeviceEnumerator: AudioInputDeviceEnumerating {
    func availableInputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard inputChannelCount(for: deviceID) > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
                  let name = stringProperty(kAudioObjectPropertyName, for: deviceID)
            else {
                return nil
            }

            return AudioInputDevice(id: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func defaultInputDeviceUID() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID)
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    func deviceID(for uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { deviceID in
            stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) == uid
        }
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            return []
        }

        return deviceIDs
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )

        guard sizeStatus == noErr, dataSize > 0 else {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferListPointer
        )

        guard status == noErr else {
            return 0
        }

        let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(audioBufferList)
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            return nil
        }

        return value as String
    }
}

@MainActor
final class AudioInputDeviceStore: ObservableObject {
    static let selectedInputDeviceUIDDefaultsKey = "selectedAudioInputDeviceUID"

    private let enumerator: AudioInputDeviceEnumerating
    private let defaults: UserDefaults

    @Published var selectedDeviceUID: String? {
        didSet {
            if let selectedDeviceUID {
                defaults.set(selectedDeviceUID, forKey: Self.selectedInputDeviceUIDDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.selectedInputDeviceUIDDefaultsKey)
            }
        }
    }

    @Published private(set) var availableDevices: [AudioInputDevice]

    init(
        enumerator: AudioInputDeviceEnumerating = CoreAudioInputDeviceEnumerator(),
        defaults: UserDefaults = .standard
    ) {
        self.enumerator = enumerator
        self.defaults = defaults
        selectedDeviceUID = defaults.string(forKey: Self.selectedInputDeviceUIDDefaultsKey)
        availableDevices = enumerator.availableInputDevices()
    }

    func refreshDevices() {
        availableDevices = enumerator.availableInputDevices()
    }

    func resolvedDeviceID() -> AudioDeviceID? {
        guard let selectedDeviceUID,
              availableDevices.contains(where: { $0.id == selectedDeviceUID })
        else {
            return nil
        }

        return enumerator.deviceID(for: selectedDeviceUID)
    }

    /// The device the audio engine should be pinned to this session: the
    /// chosen device when connected, otherwise the current system default.
    /// Always returning a concrete device (not nil) lets the engine RESET
    /// off a previously pinned device when the user picks System Default or
    /// unplugs the chosen one - AVAudioEngine keeps the last set device
    /// otherwise, because the engine instance is long-lived.
    func effectiveInputDeviceID() -> AudioDeviceID? {
        resolvedDeviceID() ?? enumerator.defaultInputDeviceID()
    }
}
