import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// System audio capture using ScreenCaptureKit (macOS 12.3+)
// No BlackHole or Multi-Output device needed.
// Usage: capture-audio -o <output.wav> -d <duration_seconds> [-m <mic_device_index>]

class SystemAudioRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var micEngine: AVAudioEngine?
    private let duration: TimeInterval
    private let outputPath: String
    private let micDeviceIndex: Int?
    private let streamMode: Bool
    private let dispatchQueue = DispatchQueue(label: "com.system-monitor.audio")
    private var startTime: Date?
    private var sampleCount: Int = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var converter: AVAudioConverter?

    init(outputPath: String, duration: TimeInterval, micDeviceIndex: Int?, streamMode: Bool = false) {
        self.outputPath = outputPath
        self.duration = duration
        self.micDeviceIndex = micDeviceIndex
        self.streamMode = streamMode
        super.init()
    }

    func record() async throws {
        // Get a display for content filter (required even for audio-only)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        // Configure for audio capture with minimal video
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 16000
        config.channelCount = 1
        // Minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 60, timescale: 1) // 1 frame per 60s

        // Use includingApplications with all running apps — required for audio capture
        // on macOS 14+. The excludingWindows/excludingApplications variants deliver zeroed audio.
        let apps = content.applications
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = stream

        // Prepare output file
        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: url)

        // Add audio output
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: dispatchQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: dispatchQueue)

        // Start mic recording if requested
        if let micIndex = micDeviceIndex {
            startMicRecording(deviceIndex: micIndex)
        }

        // Start capture
        startTime = Date()
        try await stream.startCapture()
        fputs("Recording system audio for \(Int(duration))s -> \(outputPath)\n", stderr)

        // Wait for duration
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                cont.resume()
            }
        }

        // Stop
        try await stream.stopCapture()
        stopMicRecording()

        // Close files
        audioFile = nil
        micFile = nil

        fputs("Saved \(sampleCount) audio samples\n", stderr)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        do {
            guard let desc = sampleBuffer.formatDescription,
                  let asbd = desc.audioStreamBasicDescription else { return }

            // Lazy-init audio file using the actual format from first buffer
            if audioFile == nil && !streamMode {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]

                audioFile = try AVAudioFile(
                    forWriting: URL(fileURLWithPath: outputPath),
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                fputs("Audio file created. Source format: \(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch, \(asbd.mBitsPerChannel)bit, bytesPerFrame=\(asbd.mBytesPerFrame), interleaved=\(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)\n", stderr)
            }

            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            let srcChannels = max(Int(asbd.mChannelsPerFrame), 1)
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0


            // Create source format matching the actual delivery format
            // ScreenCaptureKit delivers non-interleaved float32
            let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AVAudioChannelCount(srcChannels),
                interleaved: !isNonInterleaved
            )!

            // Create PCM buffer
            let frameCount = AVAudioFrameCount(numSamples)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
            pcmBuffer.frameLength = frameCount

            // Extract audio data using CMBlockBufferCopyDataBytes (most reliable method)
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let dataLength = CMBlockBufferGetDataLength(blockBuffer)

            if let floatChannelData = pcmBuffer.floatChannelData {
                let bytesPerSample = MemoryLayout<Float>.size
                if isNonInterleaved && srcChannels > 1 {
                    // Non-interleaved multi-channel: data is in consecutive planes
                    let bytesPerChannel = numSamples * bytesPerSample
                    for ch in 0..<srcChannels {
                        let offset = ch * bytesPerChannel
                        let copySize = min(bytesPerChannel, dataLength - offset)
                        if copySize > 0 {
                            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: offset, dataLength: copySize, destination: floatChannelData[ch])
                        }
                    }
                } else {
                    // Single channel or interleaved: copy all data to first channel buffer
                    let copySize = min(numSamples * srcChannels * bytesPerSample, dataLength)
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: copySize, destination: floatChannelData[0])
                }
            }

            if streamMode {
                // Stream mode: output mono 16kHz float32 to stdout
                let needsConversion = srcFormat.sampleRate != 16000 || srcFormat.channelCount != 1

                if !needsConversion {
                    // Already 16kHz mono float32 — write directly to stdout (no converter needed)
                    if let floatData = pcmBuffer.floatChannelData?[0] {
                        let byteCount = Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size
                        let data = Data(bytes: floatData, count: byteCount)
                        FileHandle.standardOutput.write(data)
                    }
                } else {
                    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

                    if converter == nil {
                        converter = AVAudioConverter(from: srcFormat, to: outFormat)
                        fputs("Stream converter: \(srcFormat.sampleRate)Hz \(srcFormat.channelCount)ch -> 16kHz mono\n", stderr)
                    }

                    if let conv = converter {
                        let ratio = 16000.0 / srcFormat.sampleRate
                        let outFrames = max(AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio), 1)
                        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames) else { return }

                        var error: NSError?
                        var isDone = false
                        conv.convert(to: outBuffer, error: &error) { _, outStatus in
                            if isDone {
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                            isDone = true
                            outStatus.pointee = .haveData
                            return pcmBuffer
                        }

                        if outBuffer.frameLength > 0, let floatData = outBuffer.floatChannelData?[0] {
                            let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Float>.size
                            let data = Data(bytes: floatData, count: byteCount)
                            FileHandle.standardOutput.write(data)
                        }
                    }
                }
            } else {
                try audioFile?.write(from: pcmBuffer)
            }
            sampleCount += numSamples

        } catch {
            fputs("Audio write error: \(error)\n", stderr)
        }
    }

    // MARK: - Microphone Recording

    private func startMicRecording(deviceIndex: Int) {
        let engine = AVAudioEngine()

        // Find mic device by index
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified)
        let devices = discoverySession.devices
        guard deviceIndex < devices.count else {
            fputs("Mic device index \(deviceIndex) not found (have \(devices.count) devices)\n", stderr)
            return
        }
        let device = devices[deviceIndex]

        // Set the input device on the audio engine
        let audioUnit = engine.inputNode.audioUnit!
        var deviceID = AudioDeviceID(device.uniqueID.hashValue)

        // Find the actual CoreAudio device ID by matching UID
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &deviceIDs)

        for did in deviceIDs {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(did, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
               let uidStr = uid?.takeUnretainedValue() as String?,
               uidStr == device.uniqueID {
                deviceID = did
                break
            }
        }

        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if err != noErr {
            fputs("Failed to set mic device: \(err)\n", stderr)
        }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        // Create mic output file
        let micPath = outputPath.replacingOccurrences(of: ".wav", with: "_mic.wav")
        let micSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let micURL = URL(fileURLWithPath: micPath)
            try? FileManager.default.removeItem(at: micURL)
            micFile = try AVAudioFile(
                forWriting: micURL,
                settings: micSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
                try? self?.micFile?.write(from: buffer)
            }

            try engine.start()
            self.micEngine = engine
            fputs("Mic recording started (device: \(device.localizedName))\n", stderr)
        } catch {
            fputs("Mic recording error: \(error)\n", stderr)
        }
    }

    private func stopMicRecording() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
    }
}

// MARK: - Entry Point

func parseArgs() -> (output: String, duration: Double, micDevice: Int?, stream: Bool) {
    let args = CommandLine.arguments
    var output = "output.wav"
    var duration = 10.0
    var mic: Int? = nil
    var stream = false

    var i = 1
    while i < args.count {
        switch args[i] {
        case "-o", "--output":
            if i + 1 < args.count { output = args[i + 1]; i += 2 } else { i += 1 }
        case "-d", "--duration":
            if i + 1 < args.count, let d = Double(args[i + 1]) { duration = d; i += 2 } else { i += 1 }
        case "-m", "--mic":
            if i + 1 < args.count, let m = Int(args[i + 1]) { mic = m; i += 2 } else { i += 1 }
        case "--stream":
            stream = true; i += 1
        default:
            i += 1
        }
    }
    return (output, duration, mic, stream)
}

let config = parseArgs()
let recorder = SystemAudioRecorder(outputPath: config.output, duration: config.duration, micDeviceIndex: config.micDevice, streamMode: config.stream)

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        try await recorder.record()
    } catch {
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
