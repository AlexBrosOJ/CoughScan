import Foundation
import AVFoundation

@main struct RegressionChecks {
    @MainActor static func main() throws {
        let name = "CoughScan.Regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CoughStorage(defaults: defaults, documentsDirectory: directory)
        func timestamp(_ day: Int) -> Int64 {
            Int64(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!.timeIntervalSince1970 * 1000)
        }
        storage.addMonitoringTime(dateCode: 20261115, seconds: 60)
        assert(storage.getPeriodStats(startDateCode: 20261101, endDateCode: 20261130).totalMonitoringSeconds == 60)
        storage.saveCoughRecord(timestamp: timestamp(14), probability: 0.1, coughDetected: true)
        storage.saveCoughRecord(timestamp: timestamp(15), probability: 0.9, coughDetected: true, coughCount: 9)
        let stats = storage.getPeriodStats(startDateCode: 20261101, endDateCode: 20261130)
        assert(stats.totalCoughs == 10 && stats.totalRecordings == 2)
        assert(abs(stats.avgProbability - 0.82) < 0.0001)
        assert(storage.getDailyStats(dateCode: 20261114).totalCoughs == 1)
        let valid = Data(#"{"probability":0.8,"cough_detected":true,"cough_count":3}"#.utf8)
        let decoded = try UploadResponse.decodeServerResponse(valid)
        assert(decoded.coughCount == 3)
        for json in [#"{}"#, #"{"status":"error"}"#, #"{"probability":2,"cough_detected":false}"#,
                     #"{"status":"error","probability":0,"cough_detected":false}"#] {
            do { _ = try UploadResponse.decodeServerResponse(Data(json.utf8)); fatalError("Accepted invalid response") }
            catch {}
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([0]).write(to: file)
        storage.pendingQueue = [PendingFileInfo(filePath: file.path, timestamp: timestamp(14))]
        storage.patientInfo = PatientInfo(lastName: "Test")
        storage.clearAllData()
        assert(!FileManager.default.fileExists(atPath: file.path))
        assert(storage.pendingQueue.isEmpty && storage.patientInfo.isEmpty)
        assert(storage.getTodayStats().totalRecordings == 0)
        let csv = stats.toCSV(patient: PatientInfo(lastName: "=A;B", notes: "строка\nдругая"))
        assert(csv.contains("\"'=A;B\"") && csv.contains("\"строка\nдругая\""))
        let writer = AudioChunkWriter()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 {
            for index in 0..<4800 { buffer.floatChannelData![channel][index] = 0.1 }
        }
        try writer.open(format: format)
        try writer.write(buffer)
        let (audioURL, _) = writer.close()!
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audio = try AVAudioFile(forReading: audioURL)
        assert(audio.length == 4800 && audio.fileFormat.channelCount == 1)
        assert(writer.close() == nil)
        print("PASS: stereo WAV finalization;")
        print("PASS: monitoring, weighted statistics, event dates, count, response validation, deletion, CSV")
    }
}
