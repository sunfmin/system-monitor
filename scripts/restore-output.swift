import CoreAudio
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: restore-output.swift <device-name>\n", stderr)
    exit(1)
}

let targetName = CommandLine.arguments[1]

// Get all devices
var propertySize: UInt32 = 0
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize)
let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
var devices = [AudioObjectID](repeating: 0, count: count)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices)

// Find device by name
for device in devices {
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &size, &name)
    guard let cfName = name?.takeUnretainedValue() else { continue }

    if (cfName as String) == targetName {
        var id = device
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id
        )
        if status == noErr {
            print("Audio output restored to: \(targetName)")
        } else {
            fputs("ERROR: Failed to set output device (status: \(status))\n", stderr)
            exit(1)
        }
        exit(0)
    }
}

fputs("ERROR: Device '\(targetName)' not found\n", stderr)
exit(1)
