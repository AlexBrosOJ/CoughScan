import Foundation

nonisolated struct PatientInfo: Codable {
    var lastName: String = ""
    var firstName: String = ""
    var middleName: String = ""
    var notes: String = ""
    
    var fullName: String {
        [lastName, firstName, middleName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    var isEmpty: Bool { fullName.trimmingCharacters(in: .whitespaces).isEmpty }
}

nonisolated struct UploadResponse: Codable {
    let status: String
    let probability: Float
    let coughDetected: Bool
    let message: String
    let coughCount: Int
    
    enum CodingKeys: String, CodingKey {
        case status, probability, message
        case coughDetected = "cough_detected"
        case coughCount = "cough_count"
    }
}

extension UploadResponse {
    static func decodeServerResponse(_ data: Data) throws -> UploadResponse {
        struct Response: Decodable {
            let status: String?
            let probability: Float
            let cough_detected: Bool
            let message: String?
            let cough_count: Int?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.probability.isFinite, (0...1).contains(response.probability),
              !(response.status.map { ["error", "failed", "failure"].contains($0.lowercased()) } ?? false),
              response.cough_count.map({ $0 >= 0 && $0 <= 1000 }) ?? true else {
            throw URLError(.cannotParseResponse)
        }
        return UploadResponse(status: response.status ?? "ok", probability: response.probability,
            coughDetected: response.cough_detected, message: response.message ?? "",
            coughCount: response.cough_detected ? max(1, response.cough_count ?? 1) : 0)
    }
}

nonisolated struct PendingFileInfo: Codable {
    let filePath: String
    let timestamp: Int64
    var retryCount: Int = 0
    var retryAfter: Date?
    var rejectedHTTPStatus: Int?
}

nonisolated struct DailyStatistics: Codable {
    let dateCode: Int
    let dateString: String
    var totalRecordings: Int = 0
    var totalCoughs: Int = 0
    var monitoringSeconds: Int = 0
    var coughProbabilitySum: Double = 0.0
    var hourlyCoughs: [Int] = Array(repeating: 0, count: 24)
    var hourlyRecordings: [Int] = Array(repeating: 0, count: 24)
    var hasData: Bool = false
    var lastUpdated: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    
    var avgProbability: Double {
        totalCoughs > 0 ? coughProbabilitySum / Double(totalCoughs) : 0
    }
    
    var monitoringTimeFormatted: String {
        let h = monitoringSeconds / 3600
        let m = (monitoringSeconds % 3600) / 60
        let s = monitoringSeconds % 60
        if h > 0 { return String(format: "%dч %02dмин %02dс", h, m, s) }
        if m > 0 { return String(format: "%dмин %02dс", m, s) }
        return "\(s)с"
    }
    
    func getPeakHour() -> (String, Int) {
        var maxHour = 0
        var maxCount = 0
        for (h, c) in hourlyCoughs.enumerated() where c > maxCount {
            maxCount = c
            maxHour = h
        }
        return (String(format: "%02d:00", maxHour), maxCount)
    }
    
    func getCoughsPerHourDisplay() -> String {
        guard monitoringSeconds > 0, totalCoughs > 0 else { return "0" }
        let hours = Double(monitoringSeconds) / 3600.0
        if hours >= 1.0 {
            return String(format: "%.1f", Double(totalCoughs) / hours)
        }
        let minutes = monitoringSeconds / 60
        return minutes > 0 ? "\(totalCoughs) за \(minutes) мин" : "\(totalCoughs) за \(monitoringSeconds) сек"
    }
}

nonisolated struct PeriodStatistics {
    var startDate: String
    var endDate: String
    var totalRecordings: Int
    var totalCoughs: Int
    var totalMonitoringSeconds: Int
    var avgProbability: Double
    var hourlyCoughs: [Int: Int]
    var dailyStats: [DailyStatistics]
    
    var monitoringTimeFormatted: String {
        let h = totalMonitoringSeconds / 3600
        let m = (totalMonitoringSeconds % 3600) / 60
        let s = totalMonitoringSeconds % 60
        if h > 0 { return String(format: "%dч %02dмин %02dс", h, m, s) }
        if m > 0 { return String(format: "%dмин %02dс", m, s) }
        return "\(s)с"
    }
    
    func getPeakHour() -> (String, Int) {
        let max = hourlyCoughs.max(by: { $0.value < $1.value })
        return (String(format: "%02d:00", max?.key ?? 0), max?.value ?? 0)
    }
    
    func getCoughsPerDay() -> Double {
        let days = dailyStats.filter { $0.hasData }.count
        return days > 0 ? Double(totalCoughs) / Double(days) : 0
    }
}

extension PeriodStatistics {
    func toCSV(patient: PatientInfo) -> String {
        func escape(_ value: String) -> String {
            var safe = value
            if let first = safe.first, ["=", "+", "-", "@", "\t", "\r"].contains(String(first)) { safe = "'" + safe }
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var csv = "ФИО;\(escape(patient.fullName))\n"
        csv += "Дата экспорта;\(Date().formatted(date: .numeric, time: .standard))\n\n"
        
        csv += "ОБЩАЯ СТАТИСТИКА\n"
        csv += "Количество записей;\(totalRecordings)\n"
        csv += "Количество кашлей;\(totalCoughs)\n"
        csv += "Средняя вероятность (%);\(Int(avgProbability * 100))\n"
        csv += "Время мониторинга;\(monitoringTimeFormatted)\n\n"
        
        csv += "АКТИВНОСТЬ ПО ЧАСАМ (ВЕСЬ ПЕРИОД)\n"
        csv += "Время;Кашлей\n"
        for i in 0..<24 {
            csv += String(format: "%02d:00;%d\n", i, hourlyCoughs[i] ?? 0)
        }
        csv += "\n"
        
        let peak = getPeakHour()
        csv += "ПАТТЕРНЫ КАШЛЯ\n"
        csv += "Пиковые часы;\(peak.0);\(peak.1)\n"
        csv += String(format: "Частота кашля (в день);%.1f\n", getCoughsPerDay())
        csv += "\n"
        
        csv += "ДЕТАЛЬНАЯ СТАТИСТИКА ПО ДНЯМ\n"
        csv += "Дата;Записей;Кашлей;Время мониторинга;Кашля в час;Пиковый час\n"
        
        for day in dailyStats {
            let peakDay = day.getPeakHour()
            csv += "\(day.dateString);\(day.totalRecordings);\(day.totalCoughs);\(day.monitoringTimeFormatted);\(day.getCoughsPerHourDisplay());\(peakDay.0) (\(peakDay.1))\n"
        }
        
        csv += "\nПРИМЕЧАНИЕ\n\(escape(patient.notes))\n"
        return csv
    }
}
