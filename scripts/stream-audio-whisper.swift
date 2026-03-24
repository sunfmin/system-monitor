import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Network
import CWhisper
import CGGML

// stream-audio-whisper: Single-process system audio capture + whisper.cpp transcription + WebSocket push
// Captures system audio via ScreenCaptureKit, feeds directly to whisper.cpp C API.
// Pushes results to connected WebSocket clients in real-time.
//
// Usage: stream-audio-whisper --model <path> [--chunk-sec 2] [--final-interval 5]
//        [--raw-file <path>] [--t2s-script <path>] [--ws-port 8421]

// MARK: - WebSocket Server (Network.framework)

class WebSocketServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let connectionsLock = NSLock()
    let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        let params = NWParameters(tls: nil)
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            fputs("WebSocket: Failed to create listener on port \(port): \(error)\n", stderr)
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                fputs("WebSocket server ready on port \(self.port)\n", stderr)
            case .failed(let err):
                fputs("WebSocket server failed: \(err)\n", stderr)
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .utility))
    }

    private func handleNewConnection(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                fputs("WebSocket: client connected\n", stderr)
                self?.connectionsLock.lock()
                self?.connections.append(conn)
                self?.connectionsLock.unlock()
            case .failed, .cancelled:
                self?.removeConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
        receiveLoop(conn)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] content, context, isComplete, error in
            if let error = error {
                self?.removeConnection(conn)
                return
            }
            // Keep receiving (ignore incoming messages, we only push)
            self?.receiveLoop(conn)
        }
    }

    private func removeConnection(_ conn: NWConnection) {
        connectionsLock.lock()
        connections.removeAll { $0 === conn }
        connectionsLock.unlock()
        conn.cancel()
    }

    /// Broadcast a text message to all connected WebSocket clients
    func broadcast(_ message: String) {
        let data = message.data(using: .utf8)!
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])

        connectionsLock.lock()
        let conns = connections
        connectionsLock.unlock()

        for conn in conns {
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.removeConnection(conn)
                }
            })
        }
    }

    var clientCount: Int {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        return connections.count
    }
}

// MARK: - Whisper Manager

class WhisperManager {
    private var ctx: OpaquePointer?
    private let lock = NSLock()
    // Prompt to nudge whisper into outputting punctuation for Chinese
    private let promptCString: [CChar] = Array("以下是普通话的句子，使用标点符号。".utf8CString)

    init(modelPath: String) {
        ggml_backend_load_all()

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true

        fputs("Loading whisper model: \(modelPath)\n", stderr)
        let start = Date()
        ctx = whisper_init_from_file_with_params(modelPath, params)
        if ctx == nil {
            fputs("ERROR: Failed to load whisper model\n", stderr)
            _exit(1)
        }
        let elapsed = Date().timeIntervalSince(start)
        fputs("Model loaded in \(String(format: "%.1f", elapsed))s\n", stderr)
    }

    deinit {
        if let ctx = ctx { whisper_free(ctx) }
    }

    /// Quick transcribe for 2s partial chunks (no timestamps, single string)
    func transcribe(samples: [Float]) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = ctx else { return nil }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.language = nil  // auto-detect
        params.n_threads = 4
        // No initial_prompt for short 2s chunks — causes prompt leakage

        let result = samples.withUnsafeBufferPointer { buffer -> Int32 in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }

        if result != 0 { return nil }

        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cStr)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Segment with text and end time in samples
    struct Segment {
        let text: String
        let endSample: Int  // end position in samples (16kHz)
    }

    /// Full transcribe for 30s final chunks — returns individual segments with timestamps
    func transcribeSegments(samples: [Float]) -> [Segment]? {
        lock.lock()
        defer { lock.unlock() }

        guard let ctx = ctx else { return nil }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = true
        params.no_timestamps = false  // enable timestamps for sentence segmentation
        params.language = nil
        params.n_threads = 4
        promptCString.withUnsafeBufferPointer { buf in
            params.initial_prompt = buf.baseAddress
        }

        let result = samples.withUnsafeBufferPointer { buffer -> Int32 in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }

        if result != 0 { return nil }

        let nSegments = whisper_full_n_segments(ctx)
        var segments: [Segment] = []
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                var text = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    text = Self.addPunctuation(text)
                    // Get end timestamp in centiseconds, convert to samples
                    let t1 = whisper_full_get_segment_t1(ctx, i)  // centiseconds
                    let endSample = Int(t1) * 160  // 16000 Hz / 100 cs = 160 samples per cs
                    segments.append(Segment(text: text, endSample: min(endSample, samples.count)))
                }
            }
        }

        return segments.isEmpty ? nil : segments
    }

    /// Add sentence-ending punctuation if missing
    private static func addPunctuation(_ text: String) -> String {
        let endPuncts: Set<Character> = ["。", "？", "！", ".", "?", "!", "…", "；", ",", "，"]
        if let last = text.last, endPuncts.contains(last) {
            return text
        }
        // Detect if mostly CJK characters → use Chinese punctuation
        let cjkCount = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let isChinese = cjkCount > text.count / 3
        // Check if it's a question (common question words)
        let questionWords = ["吗", "呢", "啊", "吧", "么", "嘛", "不", "没"]
        let isQuestion = questionWords.contains(where: { text.hasSuffix($0) })
        if isQuestion {
            return text + (isChinese ? "？" : "?")
        }
        return text + (isChinese ? "。" : ".")
    }
}

// MARK: - Streaming Transcriber

class StreamingTranscriber: NSObject, SCStreamOutput {
    private var scStream: SCStream?
    private let dispatchQueue = DispatchQueue(label: "com.stream-whisper.audio")
    private let whisper: WhisperManager
    private let wsServer: WebSocketServer
    private let chunkSec: Double
    private let finalInterval: Int
    private let rawFile: String
    private let partialDir: String?
    private let t2sScript: String?
    private let audioFile: String?
    private var audioFileHandle: FileHandle?
    private var audioDataSize: UInt32 = 0

    // Audio buffer
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let samplesPerChunk: Int
    private var converter: AVAudioConverter?

    // State
    private var window: [String] = []
    private var windowSize: Int { finalInterval }  // keep all text until final replaces it
    private var accumTexts: [String] = []
    private var accumAudio: [Float] = []   // raw audio for re-transcription of final
    private var carryoverAudio: [Float] = []  // incomplete sentence audio carried to next round
    private var chunkCount = 0
    private var isRunning = true

    init(whisper: WhisperManager, wsServer: WebSocketServer, chunkSec: Double,
         finalInterval: Int, rawFile: String, partialDir: String?, t2sScript: String?, audioFile: String?) {
        self.whisper = whisper
        self.wsServer = wsServer
        self.chunkSec = chunkSec
        self.finalInterval = finalInterval
        self.rawFile = rawFile
        self.partialDir = partialDir
        self.t2sScript = t2sScript
        self.audioFile = audioFile
        self.samplesPerChunk = Int(16000.0 * chunkSec)
        super.init()
    }

    /// Initialize WAV file with placeholder header (44 bytes). Data size will be finalized on stop.
    private func initAudioFile() {
        guard let path = audioFile else { return }
        // WAV header: 16kHz, mono, 16-bit PCM
        let sampleRate: UInt32 = 16000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var header = Data(count: 44)
        // RIFF header
        header.replaceSubrange(0..<4, with: "RIFF".data(using: .ascii)!)
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }) // placeholder
        header.replaceSubrange(8..<12, with: "WAVE".data(using: .ascii)!)
        // fmt chunk
        header.replaceSubrange(12..<16, with: "fmt ".data(using: .ascii)!)
        header.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.replaceSubrange(20..<22, with: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        header.replaceSubrange(22..<24, with: withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        header.replaceSubrange(24..<28, with: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.replaceSubrange(28..<32, with: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.replaceSubrange(32..<34, with: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.replaceSubrange(34..<36, with: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        // data chunk
        header.replaceSubrange(36..<40, with: "data".data(using: .ascii)!)
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) }) // placeholder

        FileManager.default.createFile(atPath: path, contents: header)
        audioFileHandle = FileHandle(forWritingAtPath: path)
        audioFileHandle?.seekToEndOfFile()
        audioDataSize = 0
        fputs("Audio recording to: \(path)\n", stderr)
    }

    /// Write float32 samples as 16-bit PCM to WAV file
    private func writeAudioSamples(_ samples: [Float]) {
        guard let fh = audioFileHandle else { return }
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: int16.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        fh.write(pcmData)
        audioDataSize += UInt32(pcmData.count)
    }

    /// Finalize WAV header with actual data size
    func finalizeAudioFile() {
        guard let fh = audioFileHandle else { return }
        // Update data chunk size at offset 40
        fh.seek(toFileOffset: 40)
        fh.write(withUnsafeBytes(of: audioDataSize.littleEndian) { Data($0) })
        // Update RIFF chunk size at offset 4
        let riffSize = audioDataSize + 36
        fh.seek(toFileOffset: 4)
        fh.write(withUnsafeBytes(of: riffSize.littleEndian) { Data($0) })
        fh.synchronizeFile()
        fh.closeFile()
        audioFileHandle = nil
        let mb = Double(audioDataSize) / 1_048_576.0
        fputs("Audio file finalized: \(String(format: "%.1f", mb)) MB, \(String(format: "%.0f", Double(audioDataSize) / 32000.0))s\n", stderr)
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            fputs("ERROR: No display found\n", stderr)
            _exit(1)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 60, timescale: 1)

        let apps = content.applications
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.scStream = stream

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: dispatchQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: dispatchQueue)

        try await stream.startCapture()
        fputs("Audio capture started (16kHz mono, chunk=\(chunkSec)s)\n", stderr)

        initAudioFile()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processingLoop()
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ s: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        guard let desc = sampleBuffer.formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let srcChannels = max(Int(asbd.mChannelsPerFrame), 1)
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(srcChannels),
            interleaved: !isNonInterleaved
        )!

        let frameCount = AVAudioFrameCount(numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let dataLength = CMBlockBufferGetDataLength(blockBuffer)

        if let floatChannelData = pcmBuffer.floatChannelData {
            let bytesPerSample = MemoryLayout<Float>.size
            if isNonInterleaved && srcChannels > 1 {
                let bytesPerChannel = numSamples * bytesPerSample
                for ch in 0..<srcChannels {
                    let offset = ch * bytesPerChannel
                    let copySize = min(bytesPerChannel, dataLength - offset)
                    if copySize > 0 {
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: offset, dataLength: copySize, destination: floatChannelData[ch])
                    }
                }
            } else {
                let copySize = min(numSamples * srcChannels * bytesPerSample, dataLength)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: copySize, destination: floatChannelData[0])
            }
        }

        let needsConversion = srcFormat.sampleRate != 16000 || srcFormat.channelCount != 1

        if !needsConversion {
            if let floatData = pcmBuffer.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: floatData, count: Int(pcmBuffer.frameLength)))
                bufferLock.lock()
                audioBuffer.append(contentsOf: samples)
                bufferLock.unlock()
                writeAudioSamples(samples)
            }
        } else {
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

            if converter == nil {
                converter = AVAudioConverter(from: srcFormat, to: outFormat)
                fputs("Converter: \(srcFormat.sampleRate)Hz \(srcFormat.channelCount)ch -> 16kHz mono\n", stderr)
            }

            if let conv = converter {
                let ratio = 16000.0 / srcFormat.sampleRate
                let outFrames = max(AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio), 1)
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames) else { return }

                var isDone = false
                conv.convert(to: outBuffer, error: nil) { _, outStatus in
                    if isDone { outStatus.pointee = .noDataNow; return nil }
                    isDone = true
                    outStatus.pointee = .haveData
                    return pcmBuffer
                }

                if outBuffer.frameLength > 0, let floatData = outBuffer.floatChannelData?[0] {
                    let samples = Array(UnsafeBufferPointer(start: floatData, count: Int(outBuffer.frameLength)))
                    bufferLock.lock()
                    audioBuffer.append(contentsOf: samples)
                    bufferLock.unlock()
                    writeAudioSamples(samples)
                }
            }
        }
    }

    // MARK: - Processing Loop

    private func processingLoop() {
        fputs("Processing loop started (chunk=\(chunkSec)s, final every \(finalInterval) chunks)\n", stderr)

        while isRunning {
            bufferLock.lock()
            let available = audioBuffer.count
            bufferLock.unlock()

            if available < samplesPerChunk {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            bufferLock.lock()
            let chunk = Array(audioBuffer.prefix(samplesPerChunk))
            audioBuffer.removeFirst(min(samplesPerChunk, audioBuffer.count))
            bufferLock.unlock()

            // Check energy for silence detection
            let energy = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)
            let isSilent = energy < 1e-7

            // ALWAYS accumulate audio for final re-transcription (even silence)
            // This prevents gaps in the 30s audio that cause missing text
            accumAudio.append(contentsOf: chunk)

            if isSilent {
                // Still count toward final interval so we don't accumulate forever
                accumTexts.append("")
                if accumTexts.count >= finalInterval {
                    // Trigger final even if some chunks were silent
                    // (handled below)
                } else {
                    continue
                }
            }

            if !isSilent {
                chunkCount += 1
                let chunkStart = Date()

                guard var text = whisper.transcribe(samples: chunk) else {
                    accumTexts.append("")
                    continue
                }

                let inferenceTime = Date().timeIntervalSince(chunkStart)

                if let script = t2sScript {
                    text = convertT2S(text: text, script: script)
                }

                if text.isEmpty {
                    accumTexts.append("")
                } else {
                    accumTexts.append(text)

                    let timestamp = Self.currentTimestamp()
                    let tsEpoch = Date().timeIntervalSince1970

                    fputs("[\(timestamp) \(String(format: "%.1fs", inferenceTime))] \(text)\n", stderr)

                    // Update rolling window
                    window.append(text)
                    if window.count > windowSize {
                        window = Array(window.suffix(windowSize))
                    }

                    // Push partial via WebSocket
                    let displayText = window.joined(separator: " ")
                    let partialMsg = jsonString(["type": "partial", "t": timestamp, "ts": tsEpoch, "text": displayText] as [String: Any])
                    wsServer.broadcast(partialMsg)

                    // Also write partial file for backward compat
                    writePartialFile(timestamp: timestamp, tsEpoch: tsEpoch, text: displayText)
                }
            }

            // Trigger final every finalInterval chunks (~30s with default 15 x 2s)
            if accumTexts.count >= finalInterval {
                let timestamp = Self.currentTimestamp()
                let tsEpoch = Date().timeIntervalSince1970

                // Prepend carryover audio, but cap total at 30s (whisper max)
                let maxSamples = 16000 * 30  // 30s at 16kHz
                var fullAudio = carryoverAudio + accumAudio
                if fullAudio.count > maxSamples {
                    // Trim carryover to fit within 30s
                    let excess = fullAudio.count - maxSamples
                    fullAudio = Array(fullAudio.dropFirst(excess))
                    fputs("[WARN] trimmed \(excess) samples (\(String(format: "%.1f", Double(excess)/16000.0))s) to stay within 30s whisper limit\n", stderr)
                }

                // Re-transcribe the full accumulated audio with sentence segmentation
                let finalStart = Date()

                if let segs = whisper.transcribeSegments(samples: fullAudio) {
                    var sentences = segs.map { seg -> String in
                        if let script = t2sScript {
                            return convertT2S(text: seg.text, script: script)
                        }
                        return seg.text
                    }

                    // Check if the last segment looks incomplete (no sentence-ending punctuation)
                    let lastSeg = sentences.last ?? ""
                    let endsWithPunct = lastSeg.hasSuffix("。") || lastSeg.hasSuffix("？") ||
                                        lastSeg.hasSuffix("！") || lastSeg.hasSuffix(".") ||
                                        lastSeg.hasSuffix("?") || lastSeg.hasSuffix("!")

                    if !endsWithPunct && sentences.count > 1 {
                        // Use whisper's actual segment timestamp for precise carryover
                        let lastCompleteSeg = segs[segs.count - 2]
                        let cutPoint = lastCompleteSeg.endSample
                        carryoverAudio = Array(fullAudio.suffix(from: min(cutPoint, fullAudio.count)))
                        sentences.removeLast()
                        fputs("[CARRYOVER] keeping \(carryoverAudio.count) samples (\(String(format: "%.1f", Double(carryoverAudio.count) / 16000.0))s) for next round\n", stderr)
                    } else {
                        carryoverAudio = []
                    }

                    if !sentences.isEmpty {
                        let finalText = sentences.joined(separator: " ")
                        let finalInference = Date().timeIntervalSince(finalStart)

                        // Push final via WebSocket with sentences array
                        let finalMsg = jsonString([
                            "type": "final",
                            "t": timestamp,
                            "ts": tsEpoch,
                            "text": finalText,
                            "sentences": sentences
                        ] as [String: Any])
                        wsServer.broadcast(finalMsg)

                        // Write to JSONL file (with sentences)
                        writeFinal(timestamp: timestamp, tsEpoch: tsEpoch, text: finalText, sentences: sentences)
                        fputs("[FINAL \(timestamp) \(String(format: "%.1fs", finalInference))] \(sentences.count) sentences: \(String(finalText.prefix(120)))...\n", stderr)

                        // Clear partial window — final has replaced it
                        window = []
                        let clearMsg = jsonString(["type": "clear_partial"] as [String: Any])
                        wsServer.broadcast(clearMsg)
                    }
                } else {
                    // Fallback: emit concatenated non-empty text
                    let nonEmpty = accumTexts.filter { !$0.isEmpty }
                    if !nonEmpty.isEmpty {
                        let finalText = nonEmpty.joined(separator: " ")
                        let finalMsg = jsonString(["type": "final", "t": timestamp, "ts": tsEpoch, "text": finalText] as [String: Any])
                        wsServer.broadcast(finalMsg)
                        writeFinal(timestamp: timestamp, tsEpoch: tsEpoch, text: finalText)
                    }
                    carryoverAudio = []
                }

                accumTexts = []
                accumAudio = []
            }
        }
    }

    // MARK: - Output

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func writePartialFile(timestamp: String, tsEpoch: Double, text: String) {
        // Use partialDir if set, otherwise derive from raw file path
        let dir = partialDir ?? (rawFile as NSString).deletingLastPathComponent
        let partialFile = (dir as NSString).appendingPathComponent("live_partial.json")
        let json = jsonString(["t": timestamp, "ts": tsEpoch, "text": text] as [String: Any])
        let tmp = partialFile + ".tmp"
        try? json.write(toFile: tmp, atomically: false, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: partialFile)
        try? FileManager.default.moveItem(atPath: tmp, toPath: partialFile)
    }

    private func writeFinal(timestamp: String, tsEpoch: Double, text: String, sentences: [String] = []) {
        var dict: [String: Any] = ["t": timestamp, "ts": tsEpoch, "text": text, "lang": "auto", "final": true]
        if !sentences.isEmpty { dict["sentences"] = sentences }
        let json = jsonString(dict)

        if let fh = FileHandle(forWritingAtPath: rawFile) {
            fh.seekToEndOfFile()
            fh.write((json + "\n").data(using: .utf8)!)
            fh.synchronizeFile()
            fh.closeFile()
        } else {
            try? (json + "\n").write(toFile: rawFile, atomically: false, encoding: .utf8)
        }
    }

    private func convertT2S(text: String, script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3.11", script, text]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        } catch {
            return text
        }
    }

    private static func currentTimestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date())
    }
}

// MARK: - Entry Point

func parseArgs() -> (model: String, chunkSec: Double, finalInterval: Int,
                     rawFile: String, partialDir: String?, t2sScript: String?, wsPort: UInt16, audioFile: String?) {
    let args = CommandLine.arguments
    var model = ""
    var chunkSec = 2.0
    var finalInterval = 10  // 10 x 2s = 20s (leave room for carryover within whisper's 30s max)
    var rawFile = "live_raw.jsonl"
    var partialDir: String? = nil
    var t2sScript: String? = nil
    var wsPort: UInt16 = 8421
    var audioFile: String? = nil

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--model", "-m":
            if i + 1 < args.count { model = args[i + 1]; i += 2 } else { i += 1 }
        case "--chunk-sec":
            if i + 1 < args.count, let v = Double(args[i + 1]) { chunkSec = v; i += 2 } else { i += 1 }
        case "--final-interval":
            if i + 1 < args.count, let v = Int(args[i + 1]) { finalInterval = v; i += 2 } else { i += 1 }
        case "--raw-file":
            if i + 1 < args.count { rawFile = args[i + 1]; i += 2 } else { i += 1 }
        case "--t2s-script":
            if i + 1 < args.count { t2sScript = args[i + 1]; i += 2 } else { i += 1 }
        case "--ws-port":
            if i + 1 < args.count, let v = UInt16(args[i + 1]) { wsPort = v; i += 2 } else { i += 1 }
        case "--audio-file":
            if i + 1 < args.count { audioFile = args[i + 1]; i += 2 } else { i += 1 }
        case "--partial-dir":
            if i + 1 < args.count { partialDir = args[i + 1]; i += 2 } else { i += 1 }
        // Legacy args (ignored)
        case "--partial-file":
            i += 2
        default:
            i += 1
        }
    }

    if model.isEmpty {
        fputs("Usage: stream-audio-whisper --model <path> [--chunk-sec 2] [--final-interval 5]\n", stderr)
        fputs("       [--raw-file <path>] [--t2s-script <path>] [--ws-port 8421] [--audio-file <path>]\n", stderr)
        _exit(1)
    }

    return (model, chunkSec, finalInterval, rawFile, partialDir, t2sScript, wsPort, audioFile)
}

let config = parseArgs()

// Start WebSocket server
let wsServer = WebSocketServer(port: config.wsPort)
wsServer.start()

let whisperMgr = WhisperManager(modelPath: config.model)
let transcriber = StreamingTranscriber(
    whisper: whisperMgr,
    wsServer: wsServer,
    chunkSec: config.chunkSec,
    finalInterval: config.finalInterval,
    rawFile: config.rawFile,
    partialDir: config.partialDir,
    t2sScript: config.t2sScript,
    audioFile: config.audioFile
)

signal(SIGINT) { _ in
    fputs("\nStopping...\n", stderr)
    transcriber.finalizeAudioFile()
    _exit(0)
}
signal(SIGTERM) { _ in
    fputs("\nStopping...\n", stderr)
    transcriber.finalizeAudioFile()
    _exit(0)
}

Task {
    do {
        try await transcriber.start()
    } catch {
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
        _exit(1)
    }
}

dispatchMain()
