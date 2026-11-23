import AVFoundation
import Foundation

// The audio callback and main-thread rotation must never access a file concurrently.
nonisolated final class AudioChunkWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var file: AVAudioFile?
    private var url: URL?
    private var timestamp: Int64 = 0
    private var frames: AVAudioFramePosition = 0

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
    }

    func open(format: AVAudioFormat) throws {
        lock.lock(); defer { lock.unlock() }
        timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let destination = directory.appendingPathComponent("chunk_\(timestamp)_\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        file = try AVAudioFile(forWriting: destination, settings: settings)
        url = destination
        frames = 0
        var excluded = destination
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        if buffer.format.channelCount == 1 {
            try file.write(from: buffer)
        } else {
            guard let source = buffer.floatChannelData,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
                  let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
                  let destination = mono.floatChannelData else {
                throw NSError(domain: "CoughScan.Audio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Неподдерживаемый формат микрофона"])
            }
            destination[0].update(from: source[0], count: Int(buffer.frameLength))
            mono.frameLength = buffer.frameLength
            try file.write(from: mono)
        }
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    func close() -> (URL, Int64)? {
        lock.lock(); defer { lock.unlock() }
        file = nil // Finalize the WAV header before handing the file to the uploader.
        guard let url else { return nil }
        self.url = nil
        guard frames > 0 else { try? FileManager.default.removeItem(at: url); return nil }
        return (url, timestamp)
    }
}
