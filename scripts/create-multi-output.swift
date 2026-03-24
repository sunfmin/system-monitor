import CoreAudio
import Foundation

// MARK: - Get all audio devices
func getAllDevices() -> [AudioObjectID] {
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
    return devices
}

// MARK: - Get device name
func getDeviceName(deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
    guard status == noErr, let cfName = name?.takeUnretainedValue() else { return nil }
    return cfName as String
}

// MARK: - Get device UID
func getDeviceUID(deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
    guard status == noErr, let cfUID = uid?.takeUnretainedValue() else { return nil }
    return cfUID as String
}

// MARK: - Check if device has output streams
func hasOutputStreams(deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
    guard status == noErr else { return false }
    return propertySize > 0
}

// MARK: - Get current default output device
func getDefaultOutputDevice() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    return deviceID
}

// MARK: - Find device by name
func findDevice(name: String) -> AudioObjectID? {
    for device in getAllDevices() {
        if getDeviceName(deviceID: device) == name {
            return device
        }
    }
    return nil
}

// MARK: - Get UID by name
func getDeviceUID(name: String) -> String? {
    guard let device = findDevice(name: name) else { return nil }
    return getDeviceUID(deviceID: device)
}

// MARK: - Get sub-device UIDs of an aggregate device
func getSubDeviceUIDs(deviceID: AudioObjectID) -> [String] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var propertySize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize)
    guard status == noErr, propertySize > 0 else { return [] }

    let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
    var subDevices = [AudioObjectID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &subDevices)
    guard status == noErr else { return [] }

    return subDevices.compactMap { getDeviceUID(deviceID: $0) }
}

// MARK: - Destroy aggregate device by UID
func destroyMonitorAggregate() {
    for device in getAllDevices() {
        if let uid = getDeviceUID(deviceID: device), uid == "com.system-monitor.multi-output" {
            AudioHardwareDestroyAggregateDevice(device)
        }
    }
}

// MARK: - Get real (non-BlackHole) sub-device UID from an aggregate
func getRealSubDeviceUID(deviceID: AudioObjectID, blackholeUID: String) -> (uid: String, name: String)? {
    let subUIDs = getSubDeviceUIDs(deviceID: deviceID)
    guard let realUID = subUIDs.first(where: { $0 != blackholeUID }) else { return nil }
    let realName = getAllDevices()
        .first(where: { getDeviceUID(deviceID: $0) == realUID })
        .flatMap { getDeviceName(deviceID: $0) } ?? "unknown"
    return (realUID, realName)
}

// MARK: - Create Multi-Output Device
func createMultiOutputDevice(name: String, subDeviceUIDs: [String]) -> AudioObjectID? {
    let subDevices: [[String: Any]] = subDeviceUIDs.map { uid in
        [kAudioSubDeviceUIDKey: uid]
    }

    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceUIDKey: "com.system-monitor.multi-output",
        kAudioAggregateDeviceSubDeviceListKey: subDevices,
        kAudioAggregateDeviceMainSubDeviceKey: subDeviceUIDs[0],
        kAudioAggregateDeviceIsStackedKey: 0,
        kAudioAggregateDeviceIsPrivateKey: 0,
    ]

    var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)

    if status != noErr {
        fputs("ERROR: Failed to create multi-output device (status: \(status))\n", stderr)
        return nil
    }

    return aggregateDeviceID
}

// MARK: - Set default output device
func setDefaultOutputDevice(deviceID: AudioObjectID) -> Bool {
    var id = deviceID
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0, nil,
        UInt32(MemoryLayout<AudioObjectID>.size),
        &id
    )

    return status == noErr
}

// MARK: - Check if device is our monitor aggregate
func isMonitorAggregate(deviceID: AudioObjectID) -> Bool {
    guard let uid = getDeviceUID(deviceID: deviceID) else { return false }
    return uid == "com.system-monitor.multi-output"
}

// MARK: - Main

let args = CommandLine.arguments
let monitorUID = "com.system-monitor.multi-output"

// Find BlackHole 2ch first
guard let blackholeUID = getDeviceUID(name: "BlackHole 2ch") else {
    fputs("ERROR: BlackHole 2ch not found\n", stderr)
    exit(1)
}

// --get-base-dir argument (positional, first non-flag arg)
let baseDir = args.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "."

// --check mode: report whether our aggregate is active or user switched away
if args.contains("--check") {
    let currentDefault = getDefaultOutputDevice()
    let currentUID = getDeviceUID(deviceID: currentDefault) ?? ""
    let currentName = getDeviceName(deviceID: currentDefault) ?? ""

    if currentUID == monitorUID {
        // Our aggregate is active — read saved real device from file
        let savedDevice = (try? String(contentsOfFile: "\(baseDir)/.original_output_device", encoding: .utf8)) ?? "unknown"
        // Find the saved device's UID
        let savedUID = findDevice(name: savedDevice).flatMap { getDeviceUID(deviceID: $0) } ?? "unknown"
        print("MULTI_REAL_UID:\(savedUID)")
        print("MULTI_REAL_NAME:\(savedDevice)")
    } else {
        // User switched away from our aggregate
        print("PLAIN_OUTPUT_UID:\(currentUID)")
        print("PLAIN_OUTPUT_NAME:\(currentName)")
    }
    exit(0)
}

// Step 1: If our aggregate is currently the default, destroy it first so we can detect
// the real device the user wants (macOS falls back to a real device after destroy)
let preDefault = getDefaultOutputDevice()
if isMonitorAggregate(deviceID: preDefault) {
    // Try to restore to saved device before destroying
    let savedDevice = (try? String(contentsOfFile: "\(baseDir)/.original_output_device", encoding: .utf8)) ?? ""
    if !savedDevice.isEmpty, let saved = findDevice(name: savedDevice) {
        _ = setDefaultOutputDevice(deviceID: saved)
    }
    destroyMonitorAggregate()
    usleep(300_000) // wait for macOS to settle
}

// Step 2: Now the default output should be a real device
let currentDefault = getDefaultOutputDevice()
let realOutputUID = getDeviceUID(deviceID: currentDefault) ?? ""
let realOutputName = getDeviceName(deviceID: currentDefault) ?? ""

// Safety check: don't use BlackHole itself as the real output
if realOutputUID == blackholeUID {
    fputs("ERROR: Current output is BlackHole itself. Please select a real audio output device.\n", stderr)
    exit(1)
}

print("REAL_OUTPUT: \(realOutputName)")
print("REAL_UID: \(realOutputUID)")
print("BLACKHOLE_UID: \(blackholeUID)")

// Save the real device name for later restoration
try? realOutputName.write(toFile: "\(baseDir)/.original_output_device", atomically: true, encoding: .utf8)

// Step 3: Destroy any remaining stale aggregates
destroyMonitorAggregate()
usleep(200_000)

// Step 4: Create a fresh aggregate with the current real device + BlackHole
guard let deviceID = createMultiOutputDevice(
    name: "Monitor Multi-Output",
    subDeviceUIDs: [realOutputUID, blackholeUID]
) else {
    exit(1)
}

print("CREATED: Monitor Multi-Output (ID: \(deviceID))")

// Wait for system to register the device
usleep(500_000)

if setDefaultOutputDevice(deviceID: deviceID) {
    print("OUTPUT_SET")
} else {
    fputs("ERROR: Failed to set default output device\n", stderr)
    exit(1)
}
