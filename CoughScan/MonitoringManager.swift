import Foundation
import AVFoundation
import Combine
import UIKit
import Network

@MainActor
final class MonitoringManager: ObservableObject {
    static let shared = MonitoringManager()
    @Published var isMonitoring = false
    @Published var filesSent = 0
    @Published var pendingQueueSize = 0
    @Published var hasInternet = true
    @Published var monitoringTime = 0
    @Published var lastResult: UploadResponse?
    @Published var errorMessage: String?

    private var engine: AVAudioEngine?
    private let writer = AudioChunkWriter()
    private var currentInputFormat: AVAudioFormat?
    private var chunkTimer: Timer?
    private var uptimeTimer: Timer?
    private var saveTimer: Timer?
    private var retryTimer: Timer?
    private var sessionStart: Date?
    private var lastMonitoringSave = Date()
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "CoughScan.Network")
    private var observers: [NSObjectProtocol] = []

    private init() {
        recoverChunks()
        pendingQueueSize = CoughStorage.shared.pendingQueue.count
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.hasInternet = path.status == .satisfied
                if path.status == .satisfied { self?.processQueue() }
            }
        }
        networkMonitor.start(queue: networkQueue)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.processQueue() }
            })
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.routeChangeNotification {
                    let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                          reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
                }
                if notification.name == AVAudioSession.interruptionNotification {
                    guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                DispatchQueue.main.async {
                    guard let self, self.isMonitoring else { return }
                    self.stop()
                    self.errorMessage = "Запись прервана изменением аудиосессии. Запустите мониторинг снова."
                }
            })
        }
    }

    func start() {
        guard !isMonitoring else { return }
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "CoughScan.Audio", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
            }
            try writer.open(format: format)
            self.engine = engine
            currentInputFormat = format
            let writer = self.writer
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                do { try writer.write(buffer) }
                catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        guard let self, self.isMonitoring else { return }
                        self.stop()
                        self.errorMessage = "Ошибка записи: \(message)"
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isMonitoring = true
            sessionStart = Date()
            lastMonitoringSave = Date()
            monitoringTime = 0
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rotateChunk() }
            }
            uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let start = self.sessionStart else { return }
                    self.monitoringTime = Int(Date().timeIntervalSince(start))
                }
            }
            saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveElapsedMonitoring() }
            }
            processQueue()
        } catch {
            stopAudio()
            enqueueClosedChunk()
            errorMessage = "Не удалось запустить запись: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isMonitoring else { return }
        chunkTimer?.invalidate(); chunkTimer = nil
        uptimeTimer?.invalidate(); uptimeTimer = nil
        saveTimer?.invalidate(); saveTimer = nil
        stopAudio()
        enqueueClosedChunk()
        saveElapsedMonitoring()
        isMonitoring = false
        sessionStart = nil
        processQueue()
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        currentInputFormat = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func enqueueClosedChunk() {
        guard let (url, timestamp) = writer.close() else { return }
        var queue = CoughStorage.shared.pendingQueue
        queue.append(PendingFileInfo(filePath: url.path, timestamp: timestamp))
        CoughStorage.shared.pendingQueue = queue
        pendingQueueSize = queue.count
    }

    private func rotateChunk() {
        guard isMonitoring, let format = currentInputFormat else { return }
        enqueueClosedChunk()
        do { try writer.open(format: format) }
        catch {
            stop()
            errorMessage = "Не удалось создать аудиофайл: \(error.localizedDescription)"
        }
        processQueue()
    }

    func clearAllData() {
        // Invalidate callbacks before stopping or deleting anything.
        generation = UUID()
        task?.cancel(); task = nil
        retryTimer?.invalidate(); retryTimer = nil
        if isMonitoring {
            chunkTimer?.invalidate(); chunkTimer = nil
            uptimeTimer?.invalidate(); uptimeTimer = nil
            saveTimer?.invalidate(); saveTimer = nil
            stopAudio()
            _ = writer.close()
            isMonitoring = false
            sessionStart = nil
        }
        endBackgroundTask()
        CoughStorage.shared.clearAllData()
        pendingQueueSize = 0; filesSent = 0; monitoringTime = 0
        lastResult = nil; errorMessage = nil
    }

    private func recoverChunks() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var queue = CoughStorage.shared.pendingQueue.compactMap { item -> PendingFileInfo? in
            let url = dir.appendingPathComponent(URL(fileURLWithPath: item.filePath).lastPathComponent)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return PendingFileInfo(filePath: url.path, timestamp: item.timestamp, retryCount: item.retryCount)
        }
        let known = Set(queue.map { URL(fileURLWithPath: $0.filePath).lastPathComponent })
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard url.lastPathComponent.hasPrefix("chunk_"), url.pathExtension == "wav",
                  !known.contains(url.lastPathComponent),
                  let part = url.deletingPathExtension().lastPathComponent.split(separator: "_").dropFirst().first,
                  let timestamp = Int64(part) else { continue }
            if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                queue.append(PendingFileInfo(filePath: url.path, timestamp: timestamp))
            }
        }
        CoughStorage.shared.pendingQueue = queue.sorted { $0.timestamp < $1.timestamp }
    }

    private func processQueue() {
        guard UserDefaults.standard.bool(forKey: "audio_upload_consent"), task == nil, retryTimer == nil, hasInternet else { return }
        var queue = CoughStorage.shared.pendingQueue
        while let first = queue.first, !FileManager.default.fileExists(atPath: first.filePath) {
            queue.removeFirst()
        }
        CoughStorage.shared.pendingQueue = queue
        pendingQueueSize = queue.count
        guard let item = queue.first else { endBackgroundTask(); return }
        let currentGeneration = generation
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "UploadQueue") { [weak self] in
                DispatchQueue.main.async { self?.endBackgroundTask() }
            }
        }
        do {
            let request = try makeRequest(item)
            task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let result: Result<UploadResponse, Error>
                do {
                    if let error { throw error }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                        throw URLError(.badServerResponse)
                    }
                    result = .success(try UploadResponse.decodeServerResponse(data))
                } catch { result = .failure(error) }
                DispatchQueue.main.async {
                    guard let self, self.generation == currentGeneration else { return }
                    self.task = nil
                    self.handleUpload(result, item: item)
                }
            }
            task?.resume()
        } catch { handleUpload(.failure(error), item: item) }
    }

    private func handleUpload(_ result: Result<UploadResponse, Error>, item: PendingFileInfo) {
        var queue = CoughStorage.shared.pendingQueue
        guard let index = queue.firstIndex(where: { $0.filePath == item.filePath }) else { return }
        switch result {
        case .success(let response):
            CoughStorage.shared.saveCoughRecord(timestamp: item.timestamp, probability: response.probability,
                coughDetected: response.coughDetected, coughCount: response.coughCount)
            queue.remove(at: index)
            CoughStorage.shared.pendingQueue = queue
            try? FileManager.default.removeItem(atPath: item.filePath)
            filesSent += 1
            lastResult = response
            errorMessage = nil
            pendingQueueSize = queue.count
            processQueue()
        case .failure(let error):
            queue[index].retryCount = min(queue[index].retryCount + 1, 1000)
            CoughStorage.shared.pendingQueue = queue
            errorMessage = "Отправка отложена: \(error.localizedDescription). Записи сохранены на устройстве."
            let delay = min(60.0, pow(2.0, Double(min(queue[index].retryCount, 6))))
            endBackgroundTask()
            retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retryTimer = nil
                    self?.processQueue()
                }
            }
        }
    }

    private func makeRequest(_ item: PendingFileInfo) throws -> URLRequest {
        // Keep the existing server contract; replace the URL once HTTPS is available.
        guard let endpoint = URL(string: Bundle.main.object(forInfoDictionaryKey: "CoughUploadURL") as? String
            ?? "http://alexbrosoj-yam-134b.twc1.net/upload"),
            ["http", "https"].contains(endpoint.scheme ?? ""), endpoint.host != nil else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let url = URL(fileURLWithPath: item.filePath)
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(try Data(contentsOf: url))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"device_id\"\r\n\r\nios_\(UIDevice.current.model)\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func saveElapsedMonitoring() {
        let now = Date()
        // Split time at midnight and retain the fractional remainder.
        while lastMonitoringSave < now {
            let midnight = Calendar.current.startOfDay(for: lastMonitoringSave)
            guard let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: midnight) else { break }
            let end = min(now, nextDay)
            let seconds = Int(end.timeIntervalSince(lastMonitoringSave))
            if seconds > 0 {
                CoughStorage.shared.addMonitoringTime(
                    dateCode: CoughStorage.dateCode(from: Int64(lastMonitoringSave.timeIntervalSince1970 * 1000)), seconds: seconds)
            }
            if end == nextDay { lastMonitoringSave = nextDay }
            else { lastMonitoringSave = lastMonitoringSave.addingTimeInterval(Double(seconds)); break }
        }
    }
}
