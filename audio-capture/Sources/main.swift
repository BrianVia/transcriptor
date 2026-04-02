import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Audio Capture Configuration

struct CaptureConfig {
    let outputPrefix: String  // e.g. /path/to/chunks/chunk_
    let outputPath: String?   // Legacy single-file mode
    let includeMic: Bool
    let sampleRate: Double = 16000  // Whisper expects 16kHz
    let channels: Int = 1           // Mono for transcription

    /// Returns the path for a given chunk number, or the single output path.
    func pathForChunk(_ number: Int) -> String {
        if let outputPath = outputPath {
            return outputPath
        }
        return "\(outputPrefix)\(String(format: "%04d", number)).wav"
    }
}

// MARK: - Audio Writer

class AudioWriter {
    private var fileHandle: FileHandle?
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 16
    private var dataSize: UInt32 = 0
    private var outputPath: String = ""

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)
    }

    func open(path: String) throws {
        outputPath = path
        FileManager.default.createFile(atPath: path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        dataSize = 0

        // Write placeholder WAV header (44 bytes)
        let header = Data(count: 44)
        try fileHandle?.write(contentsOf: header)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let fileHandle = fileHandle,
              let int16Data = buffer.int16ChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Interleave channels and convert to Data
        var data = Data(capacity: frameLength * channelCount * 2)
        for frame in 0..<frameLength {
            for channel in 0..<min(channelCount, Int(channels)) {
                var sample = int16Data[channel][frame]
                data.append(Data(bytes: &sample, count: 2))
            }
        }

        try fileHandle.write(contentsOf: data)
        dataSize += UInt32(data.count)
    }

    func close() throws {
        guard let fileHandle = fileHandle else { return }

        // Go back and write proper WAV header
        try fileHandle.seek(toOffset: 0)

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = dataSize + 36
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: UInt32 = 16
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1  // PCM
        header.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = channels
        header.append(Data(bytes: &numChannels, count: 2))
        var sr = sampleRate
        header.append(Data(bytes: &sr, count: 4))
        var br = byteRate
        header.append(Data(bytes: &br, count: 4))
        var ba = blockAlign
        header.append(Data(bytes: &ba, count: 2))
        var bps = bitsPerSample
        header.append(Data(bytes: &bps, count: 2))

        // data subchunk
        header.append(contentsOf: "data".utf8)
        var ds = dataSize
        header.append(Data(bytes: &ds, count: 4))

        try fileHandle.write(contentsOf: header)
        try fileHandle.close()
        self.fileHandle = nil
    }
}

// MARK: - Screen Capture Stream Output

class AudioCaptureDelegate: NSObject, SCStreamOutput {
    let writer: AudioWriter
    let targetFormat: AVAudioFormat

    init(writer: AudioWriter, sampleRate: Double) {
        self.writer = writer
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        // Get audio buffer
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }

        // Create source format
        let sourceFormat = AVAudioFormat(streamDescription: asbd)!

        // Create buffer from CMSampleBuffer
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return }
        sourceBuffer.frameLength = frameCount

        // Copy data to source buffer
        if let floatData = sourceBuffer.floatChannelData {
            let floatPointer = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            for channel in 0..<Int(sourceFormat.channelCount) {
                for frame in 0..<Int(frameCount) {
                    let index = frame * Int(sourceFormat.channelCount) + channel
                    if sourceFormat.isInterleaved {
                        floatData[0][frame * Int(sourceFormat.channelCount) + channel] = floatPointer[index]
                    } else {
                        floatData[channel][frame] = floatPointer[channel * Int(frameCount) + frame]
                    }
                }
            }
        }

        // Convert to target format (16kHz mono Int16)
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { return }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard status != .error else { return }

        do {
            try writer.write(outputBuffer)
        } catch {
            fputs("Error writing audio: \(error)\n", stderr)
        }
    }
}

// MARK: - Mic Capture

class MicCapture {
    private let engine = AVAudioEngine()
    private let writer: AudioWriter
    private let targetFormat: AVAudioFormat

    init(writer: AudioWriter, sampleRate: Double) {
        self.writer = writer
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    }

    func start() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "MicCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            let ratio = self.targetFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error else { return }

            do {
                try self.writer.write(outputBuffer)
            } catch {
                fputs("Error writing mic audio: \(error)\n", stderr)
            }
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Main Capture Controller

class CaptureController {
    private var stream: SCStream?
    private var delegate: AudioCaptureDelegate?
    private var micCapture: MicCapture?
    private var writer: AudioWriter?
    private let config: CaptureConfig
    private var currentChunk: Int = 1

    init(config: CaptureConfig) {
        self.config = config
    }

    func start() async throws {
        // Get available content — this is the call that checks screen recording permission.
        // By keeping the stream alive, we only trigger this once per recording session.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Create filter for all audio
        let filter = SCContentFilter(display: content.displays.first!, excludingApplications: [], exceptingWindows: [])

        // Configure stream for audio only
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = Int(config.sampleRate)
        streamConfig.channelCount = 2  // Capture stereo, convert to mono

        // We don't need video
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps minimum

        // Initialize writer
        writer = AudioWriter(sampleRate: config.sampleRate, channels: config.channels)
        let chunkPath = config.pathForChunk(currentChunk)
        try writer?.open(path: chunkPath)

        // Create delegate and stream
        delegate = AudioCaptureDelegate(writer: writer!, sampleRate: config.sampleRate)
        stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        try stream?.addStreamOutput(delegate!, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        try await stream?.startCapture()

        fputs("Recording started: \(chunkPath)\n", stderr)
    }

    /// Rotate to a new chunk file. Closes the current WAV and opens a new one.
    /// The SCStream stays running — no permission re-check needed.
    func rotateChunk() throws {
        guard let writer = writer else { return }

        // Finalize current chunk
        try writer.close()
        let finishedChunk = config.pathForChunk(currentChunk)
        fputs("Chunk \(currentChunk) finished: \(finishedChunk)\n", stderr)

        // Write completed chunk path to file so the CLI can pick it up
        appendCompletedChunk(finishedChunk)

        // Start new chunk
        currentChunk += 1
        let newPath = config.pathForChunk(currentChunk)
        try writer.open(path: newPath)
        fputs("Chunk \(currentChunk) started: \(newPath)\n", stderr)
    }

    func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        delegate = nil

        try writer?.close()

        // Write the final chunk path
        let finalPath = config.pathForChunk(currentChunk)
        appendCompletedChunk(finalPath)

        writer = nil

        fputs("Recording stopped\n", stderr)
    }
}

// MARK: - Signal Handling

var shouldStop = false
var shouldRotate = false

func setupSignalHandling() {
    signal(SIGINT) { _ in shouldStop = true }
    signal(SIGTERM) { _ in shouldStop = true }
    signal(SIGUSR1) { _ in shouldRotate = true }
}

// MARK: - PID & Completion File Helpers

let transcriptorDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".transcriptor")
let pidFile = transcriptorDir.appendingPathComponent("audio.pid")
let completedChunksFile = transcriptorDir.appendingPathComponent("completed-chunks")

func writePidFile() {
    let pid = ProcessInfo.processInfo.processIdentifier
    try? "\(pid)".write(to: pidFile, atomically: true, encoding: .utf8)
}

func removePidFile() {
    try? FileManager.default.removeItem(at: pidFile)
}

func appendCompletedChunk(_ path: String) {
    if let handle = try? FileHandle(forWritingTo: completedChunksFile) {
        handle.seekToEndOfFile()
        handle.write("\(path)\n".data(using: .utf8)!)
        try? handle.close()
    } else {
        try? "\(path)\n".write(to: completedChunksFile, atomically: false, encoding: .utf8)
    }
}

func clearCompletedChunks() {
    try? "".write(to: completedChunksFile, atomically: true, encoding: .utf8)
}

// MARK: - Main

@main
struct TranscriptorAudio {
    static func main() async {
        let args = CommandLine.arguments

        // Parse arguments
        var outputPath: String? = nil
        var outputPrefix: String? = nil
        var includeMic = false

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--output", "-o":
                if i + 1 < args.count {
                    outputPath = args[i + 1]
                    i += 1
                }
            case "--chunk-prefix", "-p":
                if i + 1 < args.count {
                    outputPrefix = args[i + 1]
                    i += 1
                }
            case "--mic", "-m":
                includeMic = true
            case "--help", "-h":
                print("""
                transcriptor-audio - Capture system audio for transcription

                Usage: transcriptor-audio [options]

                Options:
                  -o, --output PATH         Output WAV file path (single-file mode)
                  -p, --chunk-prefix PREFIX  Chunk file prefix (long-running mode)
                                            Files are named PREFIX0001.wav, PREFIX0002.wav, etc.
                                            Send SIGUSR1 to rotate to next chunk.
                  -m, --mic                 Include microphone audio
                  -h, --help                Show this help message

                The process will record until it receives SIGINT or SIGTERM.
                Send SIGUSR1 to rotate to the next chunk (only with --chunk-prefix).
                """)
                return
            default:
                break
            }
            i += 1
        }

        // Default to single-file mode if no prefix given
        if outputPrefix == nil && outputPath == nil {
            outputPath = "output.wav"
        }

        let config = CaptureConfig(
            outputPrefix: outputPrefix ?? "",
            outputPath: outputPrefix == nil ? outputPath : nil,
            includeMic: includeMic
        )
        let controller = CaptureController(config: config)

        setupSignalHandling()
        writePidFile()
        clearCompletedChunks()

        do {
            try await controller.start()

            // Wait for signals
            while !shouldStop {
                if shouldRotate {
                    shouldRotate = false
                    try controller.rotateChunk()
                }
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }

            try await controller.stop()
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }

        removePidFile()
    }
}
