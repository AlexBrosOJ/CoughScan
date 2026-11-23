import Foundation
import AVFoundation
import Combine
import UIKit
import Network

@MainActor
final class MonitoringManager: ObservableObject {
    static let shared = MonitoringManager()
    @Published var isMonitoring = false
    @Published private(set) var isPaused = false
    @Published var filesSent = 0
    @Published var pendingQueueSize = 0
    @Published var hasInternet = true
    @Published var monitoringTime = 0
    @Published var lastResult: UploadResponse?
    @Published var errorMessage: String?
    @Published private(set) var uploadError: String?
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var rejectedQueueSize = 0
    @Published private(set) var rejectedHTTPStatus: Int?

    private var engine: AVAudioEngine?
    private var writer = AudioChunkWriter()
    private var currentInputFormat: AVAudioFormat?
    private var chunkTimer: Timer?
    private var uptimeTimer: Timer?
    private var saveTimer: Timer?
    private var retryTimer: Timer?
    private var uploadRetryAfter: Date?
    private var retryOnNetworkRecovery = false
    private var sessionStart: Date?
    private var previousMonitoringTime = 0
    private var lastMonitoringSave = Date()
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private var audioGeneration = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskToken: UUID?
    private let uploadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "CoughScan.Network")
    private var observers: [NSObjectProtocol] = []

    private init() {
        recoverChunks()
        updateQueueCounts(CoughStorage.shared.pendingQueue)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let available = path.status == .satisfied
                if available && !self.hasInternet && self.retryOnNetworkRecovery {
                    self.uploadRetryAfter = nil
                    self.retryOnNetworkRecovery = false
                }
                self.hasInternet = available
                self.processQueue()
            }
        }
        networkMonitor.start(queue: networkQueue)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.processQueue()
                    if name == UIApplication.didBecomeActiveNotification {
                        self?.resumeAfterInterruption()
                    }
                }
            })
        }
        let session = AVAudioSession.sharedInstance()
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                    as? AVAudioSession.DeactivationContext, context.source == .system else { return }
            DispatchQueue.main.async { self?.pauseForInterruption() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                    as? AVAudioSession.ResumptionContext, context.recommendation == .shouldResume else { return }
            DispatchQueue.main.async { self?.resumeAfterInterruption() }
        })
        for name in [AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.routeChangeNotification {
                    let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                          reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if name == AVAudioSession.routeChangeNotification {
                        guard self.isMonitoring else { return }
                        self.pauseForInterruption()
                        self.resumeAfterInterruption()
                        return
                    }
                    guard self.isMonitoring || self.isPaused else { return }
                    self.stop()
                    self.errorMessage = "Аудиосистема перезапустилась. Запустите мониторинг снова."
                }
            })
        }
    }

    func start() {
        guard !isMonitoring, !isPaused else { return }
        previousMonitoringTime = 0
        monitoringTime = 0
        startAudio(resuming: false)
    }

    private func startAudio(resuming: Bool) {
        errorMessage = nil
        let token = UUID()
        audioGeneration = token
        var sessionActivated = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
            sessionActivated = true
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "CoughScan.Audio", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
            }
            let writer = AudioChunkWriter()
            try writer.open(format: format)
            self.writer = writer
            self.engine = engine
            currentInputFormat = format
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                do { try writer.write(buffer) }
                catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        guard let self, self.isMonitoring, self.audioGeneration == token else { return }
                        self.stop()
                        self.errorMessage = "Ошибка записи: \(message)"
                    }
                }
            }
            engine.prepare()
            try engine.start()
            isPaused = false
            isMonitoring = true
            let now = Date()
            sessionStart = now
            lastMonitoringSave = now
            chunkTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rotateChunk() }
            }
            uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let start = self.sessionStart else { return }
                    self.monitoringTime = self.previousMonitoringTime + max(0, Int(Date().timeIntervalSince(start)))
                }
            }
            saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveElapsedMonitoring() }
            }
            processQueue()
        } catch {
            stopAudio(deactivate: sessionActivated)
            enqueueClosedChunk()
            let action = resuming ? "возобновить" : "запустить"
            errorMessage = "Не удалось \(action) запись: \(error.localizedDescription)"
            processQueue()
        }
    }

    func stop() {
        guard isMonitoring || isPaused else { return }
        isPaused = false
        errorMessage = nil
        if isMonitoring { finishRecordingSegment(deactivate: true) }
        processQueue()
    }

    private func pauseForInterruption() {
        guard isMonitoring else { return }
        isPaused = true
        finishRecordingSegment(deactivate: false)
        processQueue()
    }

    private func resumeAfterInterruption() {
        guard isPaused, UserDefaults.standard.bool(forKey: "audio_upload_consent") else { return }
        startAudio(resuming: true)
    }

    private func finishRecordingSegment(deactivate: Bool) {
        let endedAt = Date()
        if let start = sessionStart {
            previousMonitoringTime += max(0, Int(endedAt.timeIntervalSince(start)))
        }
        monitoringTime = previousMonitoringTime
        isMonitoring = false
        sessionStart = nil
        stopAudio(deactivate: deactivate)
        enqueueClosedChunk()
        saveElapsedMonitoring(until: endedAt)
    }

    private func stopAudio(deactivate: Bool = true) {
        audioGeneration = UUID()
        chunkTimer?.invalidate(); chunkTimer = nil
        uptimeTimer?.invalidate(); uptimeTimer = nil
        saveTimer?.invalidate(); saveTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        currentInputFormat = nil
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func enqueueClosedChunk() {
        guard let (url, timestamp) = writer.close() else { return }
        var queue = CoughStorage.shared.pendingQueue
        queue.append(PendingFileInfo(filePath: url.path, timestamp: timestamp))
        CoughStorage.shared.pendingQueue = queue
        updateQueueCounts(queue)
    }

    private func rotateChunk() {
        guard isMonitoring, let format = currentInputFormat else { return }
        guard engine?.isRunning == true else {
            pauseForInterruption()
            return
        }
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
        uploadRetryAfter = nil
        retryOnNetworkRecovery = false
        isPaused = false
        if isMonitoring {
            stopAudio()
            _ = writer.close()
            isMonitoring = false
            sessionStart = nil
        }
        endBackgroundTask()
        CoughStorage.shared.clearAllData()
        updateQueueCounts([])
        filesSent = 0; monitoringTime = 0
        lastResult = nil; errorMessage = nil
        uploadError = nil; lastUploadAt = nil
    }

    private func recoverChunks() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var queue = CoughStorage.shared.pendingQueue.map { item -> PendingFileInfo in
            let url = dir.appendingPathComponent(URL(fileURLWithPath: item.filePath).lastPathComponent)
            return PendingFileInfo(filePath: url.path, timestamp: item.timestamp, retryCount: item.retryCount,
                                   retryAfter: item.retryAfter, rejectedHTTPStatus: item.rejectedHTTPStatus)
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

    private func updateQueueCounts(_ queue: [PendingFileInfo]) {
        let rejected = queue.filter { $0.rejectedHTTPStatus != nil }
        let pending = queue.count - rejected.count
        if pendingQueueSize != pending { pendingQueueSize = pending }
        if rejectedQueueSize != rejected.count { rejectedQueueSize = rejected.count }
        if rejectedHTTPStatus != rejected.last?.rejectedHTTPStatus {
            rejectedHTTPStatus = rejected.last?.rejectedHTTPStatus
        }
    }

    func retryRejectedUploads() {
        var queue = CoughStorage.shared.pendingQueue
        for index in queue.indices where queue[index].rejectedHTTPStatus != nil {
            queue[index].rejectedHTTPStatus = nil
            queue[index].retryCount = 0
            queue[index].retryAfter = nil
        }
        CoughStorage.shared.pendingQueue = queue
        updateQueueCounts(queue)
        processQueue()
    }

    private func processQueue() {
        guard task == nil else { return }
        guard UserDefaults.standard.bool(forKey: "audio_upload_consent"), hasInternet else {
            retryTimer?.invalidate(); retryTimer = nil
            endBackgroundTask()
            return
        }
        let queue = CoughStorage.shared.pendingQueue
        let now = Date()
        let selection = PendingFileInfo.nextUpload(in: queue, at: now, serverRetryAfter: uploadRetryAfter)
        guard let item = selection.item else {
            endBackgroundTask()
            scheduleUploadRetry(at: selection.retryAt)
            return
        }
        scheduleUploadRetry(at: nil)

        let request: URLRequest
        do {
            request = try makeRequest(item)
        } catch {
            if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile,
               UIApplication.shared.isProtectedDataAvailable {
                let remaining = queue.filter { $0.filePath != item.filePath }
                CoughStorage.shared.pendingQueue = remaining
                updateQueueCounts(remaining)
                uploadError = "Файл записи не найден на устройстве."
                DispatchQueue.main.async { [weak self] in self?.processQueue() }
            } else {
                handleUpload(.failure(.localRead), item: item)
            }
            return
        }

        if backgroundTask == .invalid {
            let token = UUID()
            backgroundTaskToken = token
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "UploadQueue") { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.backgroundTaskToken == token else { return }
                    self.task?.cancel()
                    self.endBackgroundTask()
                }
            }
        }
        let currentGeneration = generation
        task = uploadSession.dataTask(with: request) { [weak self] data, response, error in
            let result = UploadResponse.uploadResult(data: data, response: response, error: error)
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.task = nil
                self.handleUpload(result, item: item)
            }
        }
        task?.resume()
    }

    private func scheduleUploadRetry(at date: Date?) {
        if let date, retryTimer?.fireDate == date { return }
        retryTimer?.invalidate()
        retryTimer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryTimer = nil
                self?.processQueue()
            }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleUpload(_ result: Result<UploadResponse, UploadFailure>, item: PendingFileInfo) {
        var queue = CoughStorage.shared.pendingQueue
        guard let index = queue.firstIndex(where: { $0.filePath == item.filePath }) else {
            processQueue()
            return
        }
        switch result {
        case .success(let response):
            CoughStorage.shared.saveCoughRecord(timestamp: item.timestamp, probability: response.probability,
                coughDetected: response.coughDetected, coughCount: response.coughCount)
            queue.remove(at: index)
            try? FileManager.default.removeItem(atPath: item.filePath)
            filesSent += 1
            lastResult = response
            lastUploadAt = Date()
            uploadError = nil
            uploadRetryAfter = nil
            retryOnNetworkRecovery = false
        case .failure(let failure):
            let now = Date()
            if let rejection = failure.rejectedHTTPStatus {
                queue[index].rejectedHTTPStatus = rejection
                queue[index].retryAfter = nil
            } else {
                queue[index].retryCount = min(queue[index].retryCount + 1, 1000)
                let delay = min(60.0, pow(2.0, Double(min(queue[index].retryCount, 6))))
                queue[index].retryAfter = now.addingTimeInterval(delay)
                uploadRetryAfter = failure.serverRetryDate(now: now, itemDelay: delay)
                if case .network = failure { retryOnNetworkRecovery = true }
                else { retryOnNetworkRecovery = false }
                uploadError = "Отправка отложена: \(failure.localizedDescription). Записи сохранены."
            }
        }
        CoughStorage.shared.pendingQueue = queue
        updateQueueCounts(queue)
        DispatchQueue.main.async { [weak self] in self?.processQueue() }
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
        backgroundTaskToken = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func saveElapsedMonitoring(until now: Date = Date()) {
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
