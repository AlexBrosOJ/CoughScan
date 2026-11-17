import Foundation
import Combine

@MainActor
final class CoughStorage: ObservableObject {
    static let shared = CoughStorage()
    private let defaults: UserDefaults
    private let statsKey = "daily_stats_map"
    private let queueKey = "pending_queue"
    private let patientKey = "patient_info"
    
    private let documentsDirectory: URL
    init(defaults: UserDefaults = .standard, documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.defaults = defaults
        self.documentsDirectory = documentsDirectory
    }
    
    static let didChange = Notification.Name("CoughStorageDidChange")

    private func notifyChange() { NotificationCenter.default.post(name: Self.didChange, object: nil) }

    // MARK: Daily stats
    private var allStats: [Int: DailyStatistics] {
        get {
            guard let data = defaults.data(forKey: statsKey),
                  let decoded = try? JSONDecoder().decode([Int: DailyStatistics].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: statsKey)
                notifyChange()
            }
        }
    }
    
    func getDailyStats(dateCode: Int) -> DailyStatistics {
        allStats[dateCode] ?? DailyStatistics(
            dateCode: dateCode,
            dateString: Self.dateCodeToString(dateCode)
        )
    }
    
    func getTodayStats() -> DailyStatistics {
        getDailyStats(dateCode: Self.currentDateCode())
    }
    
    func saveCoughRecord(timestamp: Int64, probability: Float, coughDetected: Bool, coughCount: Int? = nil) {
        let dateCode = Self.dateCode(from: timestamp)
        let hour = Self.hour(from: timestamp)
        var stats = getDailyStats(dateCode: dateCode)
        
        stats.totalRecordings += 1
        if coughDetected {
            let count = max(1, coughCount ?? 1)
            stats.hourlyCoughs[hour] += count
            stats.totalCoughs += count
            stats.coughProbabilitySum += Double(probability) * Double(count)
        }
        stats.hourlyRecordings[hour] += 1
        stats.hasData = true
        stats.lastUpdated = Int64(Date().timeIntervalSince1970 * 1000)
        
        var map = allStats
        map[dateCode] = stats
        allStats = map
    }
    
    func addMonitoringTime(dateCode: Int, seconds: Int) {
        var stats = getDailyStats(dateCode: dateCode)
        stats.monitoringSeconds += max(0, seconds)
        stats.hasData = true
        var map = allStats
        map[dateCode] = stats
        allStats = map
    }
    
    func getPeriodStats(startDateCode: Int, endDateCode: Int) -> PeriodStatistics {
        let filtered = allStats.values
            .filter { $0.dateCode >= startDateCode && $0.dateCode <= endDateCode && $0.hasData }
            .sorted { $0.dateCode > $1.dateCode }
        
        guard !filtered.isEmpty else {
            return PeriodStatistics(
                startDate: Self.dateCodeToString(startDateCode),
                endDate: Self.dateCodeToString(endDateCode),
                totalRecordings: 0, totalCoughs: 0, totalMonitoringSeconds: 0,
                avgProbability: 0, hourlyCoughs: [:], dailyStats: []
            )
        }
        
        var hourly: [Int: Int] = [:]
        var totalMon = 0
        for day in filtered {
            for (h, c) in day.hourlyCoughs.enumerated() {
                hourly[h, default: 0] += c
            }
            totalMon += day.monitoringSeconds
        }
        
        let coughs = filtered.reduce(0) { $0 + $1.totalCoughs }
        let probabilitySum = filtered.reduce(0.0) { $0 + $1.coughProbabilitySum }
        
        return PeriodStatistics(
            startDate: filtered.last!.dateString,
            endDate: filtered.first!.dateString,
            totalRecordings: filtered.reduce(0) { $0 + $1.totalRecordings },
            totalCoughs: filtered.reduce(0) { $0 + $1.totalCoughs },
            totalMonitoringSeconds: totalMon,
            avgProbability: coughs > 0 ? probabilitySum / Double(coughs) : 0,
            hourlyCoughs: hourly,
            dailyStats: filtered
        )
    }
    
    // MARK: Patient
    var patientInfo: PatientInfo {
        get {
            guard let data = defaults.data(forKey: patientKey),
                  let p = try? JSONDecoder().decode(PatientInfo.self, from: data)
            else { return PatientInfo() }
            return p
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: patientKey)
            }
        }
    }
    
    // MARK: Queue
    var pendingQueue: [PendingFileInfo] {
        get {
            guard let data = defaults.data(forKey: queueKey),
                  let q = try? JSONDecoder().decode([PendingFileInfo].self, from: data)
            else { return [] }
            return q
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: queueKey)
            }
        }
    }
    
    // MARK: Helpers
    static func currentDateCode() -> Int { dateCode(from: Int64(Date().timeIntervalSince1970 * 1000)) }
    
    static func dateCode(from timestamp: Int64) -> Int {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }
    
    static func hour(from timestamp: Int64) -> Int {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        return Calendar.current.component(.hour, from: date)
    }
    
    static func dateCodeToString(_ code: Int) -> String {
        let y = code / 10000
        let m = (code % 10000) / 100
        let d = code % 100
        return String(format: "%02d.%02d.%04d", d, m, y)
    }
    func clearAllData() {
        let files = pendingQueue
        for item in files { try? FileManager.default.removeItem(atPath: item.filePath) }
        let dir = documentsDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            if (url.lastPathComponent.hasPrefix("chunk_") && url.pathExtension == "wav") ||
                (url.lastPathComponent.hasPrefix("Кашель_") && url.pathExtension == "csv") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        defaults.removeObject(forKey: statsKey)
        defaults.removeObject(forKey: queueKey)
        defaults.removeObject(forKey: patientKey)
        notifyChange()
    }
    func getMonthSummary(year: Int, month: Int) -> [Int: Int] {
        let monthStart = year * 10000 + month * 100 + 1
        let monthEnd = monthStart + 31
        
        var summary: [Int: Int] = [:]
        let filtered = allStats.filter { $0.key >= monthStart && $0.key <= monthEnd && $0.value.hasData }
        for (key, stat) in filtered {
            let day = key % 100
            summary[day] = stat.totalCoughs
        }
        return summary
    }
}
